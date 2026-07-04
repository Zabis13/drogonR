// drogonR — streaming response sessions.
//
// When an R handler returns a `drogon_stream` value, the dispatcher
// hands it here via startStreamSession(). We open a Drogon async-
// stream response, preserve the R closure + state across GC, and
// pump next_chunk() on the main R thread one step at a time. Each
// step:
//
//   1. main thread:  call next_chunk(state, cancelled)
//   2. main thread:  parse the returned list(chunk, state, done)
//   3. drogon loop:  stream->send(chunk) (or close if done)
//   4. main thread:  schedule the next pump via later::later(0, …)
//
// Disconnect: stream->send() returns false on the Drogon loop when
// the client is gone. We set a per-session atomic `cancelled` flag
// there; the next pump reads it (acquire), passes cancelled = TRUE
// to the generator one final time for cleanup, and tears down —
// regardless of `done` — so the generator is guaranteed exactly one
// post-cancel invocation.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <drogon/HttpResponse.h>
#include <drogon/HttpAppFramework.h>
#include <trantor/net/EventLoop.h>
// drogonR patch: needed for setUserCloseCallback().
#include <trantor/net/TcpConnection.h>

#include "r_bridge.h"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#ifdef _WIN32
  #define strcasecmp _stricmp
#else
  #include <strings.h>
#endif

namespace drogonR {

// later::execLaterNative2 — resolved at .onLoad time via
// drogonR_init_later (extended in r_dispatcher.cpp). NULL until init.
typedef void (*later_fn)(void (*)(void*), void*, double, int);
extern later_fn g_later;  // defined in r_dispatcher.cpp

namespace {

// Per-stream state kept alive across pumps.
//
// `next_chunk` and `state` are SEXPs preserved via R_PreserveObject;
// they're freed via R_ReleaseObject when the session ends. The
// stream pointer is owned by Drogon's async-stream callback; we
// borrow it through `stream` (a moved-from unique_ptr stash) and
// hand it back to Drogon's loop when sending.
//
// The `closing` flag exists because between scheduling a pump and
// the pump running, an error path may have already torn the session
// down. The pump checks it under the global lock.
struct StreamSession {
    std::uint64_t id;

    // R-side closures, preserved.
    SEXP next_chunk = nullptr;
    SEXP state      = nullptr;

    // Drogon-side. The stream pointer is delivered to us inside the
    // async-stream callback (which Drogon invokes once per response
    // on its event loop); we move it into the session at that point.
    drogon::ResponseStreamPtr stream;
    trantor::EventLoop       *loop = nullptr;

    // Set when the session has begun teardown. Pumps observe this
    // and bail out without touching anything.
    std::atomic<bool> closing{false};

    // Set on the Drogon loop when stream->send() reports the client
    // is gone. Read on the main R thread on the next pump.
    std::atomic<bool> cancelled{false};

    // Floor (in seconds) for the delay between consecutive pumps.
    // Set once at session start; read on each scheduleNextPump().
    double min_interval{0.0};
};

std::mutex                                                       g_streamMutex;
std::unordered_map<std::uint64_t, std::shared_ptr<StreamSession>> g_streams;
std::atomic<std::uint64_t>                                       g_nextStreamId{1};

std::shared_ptr<StreamSession> findSession(std::uint64_t id) {
    std::lock_guard<std::mutex> lock(g_streamMutex);
    auto it = g_streams.find(id);
    if (it == g_streams.end()) return nullptr;
    return it->second;
}

void eraseSession(std::uint64_t id) {
    std::lock_guard<std::mutex> lock(g_streamMutex);
    g_streams.erase(id);
}

// Release SEXPs the session was holding alive. MUST run on the main
// R thread (R_ReleaseObject mutates R's preserved-objects list).
void releaseSEXPs(StreamSession &s) {
    if (s.next_chunk) { R_ReleaseObject(s.next_chunk); s.next_chunk = nullptr; }
    if (s.state)      { R_ReleaseObject(s.state);      s.state      = nullptr; }
}

// Forward decl — pump callback scheduled via later::later().
void pumpStreamMain(void *data);

// The session id is smuggled through later's void* payload by value
// (no heap carrier), so an orphaned pump left in later's queue at
// teardown frees nothing when it's dropped. Requires void* to hold a
// uint64_t — true on every 64-bit target we build for (Linux/macOS/BSD
// epoll/kqueue, Windows LLP64 wepoll).
static_assert(sizeof(void *) >= sizeof(std::uint64_t),
              "drogonR stream pump packs the session id into later's void* "
              "payload; a 32-bit void* would truncate it");

// Schedule a pump on the main R thread. The session's configured
// min_interval is honoured as a delay floor — looking the session up
// adds a hash hit per pump but keeps the rate-limit field in one place.
void scheduleNextPump(std::uint64_t id) {
    if (g_later == nullptr) return;          // server shutting down
    double secs = 0.0;
    if (auto sess = findSession(id)) {
        secs = sess->min_interval;
    }
    void *carrier = reinterpret_cast<void *>(static_cast<std::uintptr_t>(id));
    g_later(&pumpStreamMain, carrier, secs, /*loop*/ 0);
}

// Send a chunk on the Drogon loop (NOT the main R thread). If send()
// returns false the connection is gone; record it on the session so
// the next pump can deliver one final cancelled = TRUE to the R
// generator and tear down.
void sendChunkInLoop(std::shared_ptr<StreamSession> sess, std::string data) {
    auto *raw = sess.get();
    raw->loop->queueInLoop([sess = std::move(sess), data = std::move(data)]() {
        if (!sess->stream) return;
        if (!sess->stream->send(data)) {
            sess->cancelled.store(true, std::memory_order_release);
        }
    });
}

// Close the stream on the Drogon loop, then erase the session and
// release SEXPs back on the main R thread.
void closeStreamFromMain(std::shared_ptr<StreamSession> sess) {
    sess->closing.store(true);
    auto *raw = sess.get();
    raw->loop->queueInLoop([sess]() {
        if (sess->stream) {
            sess->stream->close();
            sess->stream.reset();
        }
    });
    // SEXPs released here on main thread; Drogon-side resources
    // will be freed on the next loop tick.
    releaseSEXPs(*sess);
    eraseSession(sess->id);
}

// Look up a string field by name in a list. Returns NULL on miss.
SEXP namedField(SEXP list, const char *name) {
    if (TYPEOF(list) != VECSXP) return R_NilValue;
    SEXP nms = Rf_getAttrib(list, R_NamesSymbol);
    if (TYPEOF(nms) != STRSXP) return R_NilValue;
    int n = LENGTH(list);
    for (int i = 0; i < n; ++i) {
        if (std::strcmp(CHAR(STRING_ELT(nms, i)), name) == 0) {
            return VECTOR_ELT(list, i);
        }
    }
    return R_NilValue;
}

// Pump callback. Runs on the main R thread under later's scheduler.
void pumpStreamMain(void *data) {
    std::uint64_t id = static_cast<std::uint64_t>(
        reinterpret_cast<std::uintptr_t>(data));

    auto sess = findSession(id);
    if (!sess) return;
    if (sess->closing.load()) return;
    // The async-stream callback may not have run yet (Drogon delivers
    // the stream pointer asynchronously). If the stream isn't ready,
    // re-arm and try again on the next tick. Cheap: zero-delay later.
    if (!sess->stream) {
        scheduleNextPump(id);
        return;
    }

    // Build call: next_chunk(state, cancelled)
    bool was_cancelled = sess->cancelled.load(std::memory_order_acquire);
    int err = 0;
    SEXP cancelled = PROTECT(Rf_ScalarLogical(was_cancelled ? 1 : 0));
    SEXP call = PROTECT(Rf_lang3(sess->next_chunk, sess->state, cancelled));
    SEXP res  = R_tryEval(call, R_GlobalEnv, &err);
    UNPROTECT(2);

    if (err) {
        // R-side error in the generator — log via REprintf and tear
        // down. Connection gets a truncated chunked response, which
        // is the best we can do once the headers are out.
        REprintf("drogonR stream: next_chunk() raised an error; "
                 "closing stream\n");
        closeStreamFromMain(sess);
        return;
    }

    PROTECT(res);
    if (TYPEOF(res) != VECSXP) {
        REprintf("drogonR stream: next_chunk() must return a list; "
                 "closing stream\n");
        UNPROTECT(1);
        closeStreamFromMain(sess);
        return;
    }

    SEXP s_chunk = namedField(res, "chunk");
    SEXP s_state = namedField(res, "state");
    SEXP s_done  = namedField(res, "done");

    // Update preserved state if the generator returned one. Old
    // state is released only after the new one is preserved so a
    // pathological gc between the two can't drop the session.
    if (s_state != R_NilValue) {
        R_PreserveObject(s_state);
        SEXP old = sess->state;
        sess->state = s_state;
        if (old) R_ReleaseObject(old);
    }

    bool done = false;
    if (TYPEOF(s_done) == LGLSXP && LENGTH(s_done) >= 1) {
        done = (LOGICAL(s_done)[0] == 1);
    }

    std::string chunk;
    if (TYPEOF(s_chunk) == STRSXP && LENGTH(s_chunk) >= 1) {
        chunk = CHAR(STRING_ELT(s_chunk, 0));
    }

    UNPROTECT(1); // res

    // If we were cancelled, this pump just delivered the one and
    // only cleanup call to the generator. Don't bother sending its
    // chunk (the client is gone), don't schedule another pump —
    // tear down regardless of `done`.
    if (was_cancelled) {
        closeStreamFromMain(sess);
        return;
    }

    if (!chunk.empty()) {
        sendChunkInLoop(sess, std::move(chunk));
    }
    if (done) {
        closeStreamFromMain(sess);
    } else {
        scheduleNextPump(id);
    }
}

} // namespace

// Public entrypoint, called from the dispatcher.
//
// `respond` is Drogon's response callback; we pass it the
// async-stream HttpResponse we build. `next_chunk` and `state` are
// borrowed from the R-side `drogon_stream` value — we preserve them
// for the lifetime of the session.
//
// Headers (incl. Content-Type) come from the R-side stream value;
// the dispatcher passes them through here as a parsed list (declared
// in r_bridge.h).
void startStreamSession(
    const std::function<void(const drogon::HttpResponsePtr&)> &respond,
    SEXP next_chunk, SEXP state,
    const std::string &content_type,
    const std::vector<StreamHeader> &headers,
    const std::weak_ptr<trantor::TcpConnection> &connection,
    double min_interval)
{
    auto sess = std::make_shared<StreamSession>();
    sess->id           = g_nextStreamId.fetch_add(1, std::memory_order_relaxed);
    sess->min_interval = (min_interval > 0.0) ? min_interval : 0.0;

    R_PreserveObject(next_chunk); sess->next_chunk = next_chunk;
    if (state != R_NilValue) {
        R_PreserveObject(state);
        sess->state = state;
    }

    {
        std::lock_guard<std::mutex> lock(g_streamMutex);
        g_streams.emplace(sess->id, sess);
    }
    std::uint64_t id = sess->id;

    // drogonR patch: hook the connection's user-close callback so we
    // get notified the moment the kernel/Drogon detects the peer
    // closed. Without this we'd only learn at the next send() that
    // returned false — for small chunks that can take hundreds of
    // pumps because the kernel TCP buffer absorbs the writes silently.
    if (auto conn = connection.lock()) {
        std::weak_ptr<StreamSession> weakSess = sess;
        conn->setUserCloseCallback(
            [weakSess](const trantor::TcpConnectionPtr &) {
                if (auto s = weakSess.lock()) {
                    s->cancelled.store(true, std::memory_order_release);
                }
            });
    } else {
        // Connection already gone before the session even started.
        // Mark cancelled now; the first pump will deliver one final
        // cleanup call to the generator and tear down.
        sess->cancelled.store(true, std::memory_order_release);
    }

    // Build the async-stream response. Drogon will call our callback
    // on its loop once per response, handing us the ResponseStreamPtr.
    auto resp = drogon::HttpResponse::newAsyncStreamResponse(
        [sess](drogon::ResponseStreamPtr s) mutable {
            // Stash the stream + the loop we were called on, so the
            // main R thread can safely queueInLoop sends/closes.
            sess->loop   = trantor::EventLoop::getEventLoopOfCurrentThread();
            sess->stream = std::move(s);
        },
        /*disableKickoffTimeout*/ true);

    resp->setStatusCode(drogon::k200OK);
    resp->setContentTypeString(content_type);
    for (const auto &h : headers) {
        if (strcasecmp(h.name.c_str(), "Content-Type") == 0) {
            resp->setContentTypeString(h.value);
        } else {
            resp->addHeader(h.name, h.value);
        }
    }

    // Hand the response back to Drogon. The stream callback above
    // fires shortly after; until it does, our pump will see
    // sess->stream == nullptr and re-arm.
    respond(resp);
    scheduleNextPump(id);
}

// Discard every active stream session. Called at server stop so
// preserved SEXPs don't leak across server lifetimes.
void clearAllStreamSessions() {
    std::vector<std::shared_ptr<StreamSession>> drained;
    {
        std::lock_guard<std::mutex> lock(g_streamMutex);
        for (auto &kv : g_streams) drained.push_back(kv.second);
        g_streams.clear();
    }
    for (auto &sess : drained) {
        sess->closing.store(true);
        // By the time server_stop() calls us, Drogon's IO EventLoop has
        // already been quit() + joined, so sess->loop dangles at a
        // destroyed EventLoop — queueInLoop on it is a use-after-free.
        // (EventLoop::loop() drains funcsOnQuit_, which closes the
        // TcpConnection, *before* the thread-local shared_ptr<EventLoop>
        // is released at thread exit; join() returns only after that.)
        // Dropping the stream here is safe without the loop: ~ResponseStream
        // calls close(), but AsyncStreamImpl's send/close lock a weak_ptr
        // to the already-destroyed TcpConnection and no-op on lock failure.
        sess->stream.reset();
        // Release on caller's thread (must be main R thread for this
        // to be safe — clearAllStreamSessions is invoked from the
        // dispatcher's stop path).
        releaseSEXPs(*sess);
    }
}

} // namespace drogonR
