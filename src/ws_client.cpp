// drogonR — WebSocket client subsystem.
//
// drogonR acting as a WS *client* to an external server (an LLM
// streaming API, a chat backend, ...). This is the mirror image of
// ws_session.cpp: there we accept inbound WS connections on the running
// Drogon server; here we open outbound ones, independent of dr_serve().
//
// Threading (same contract as every other bridge in this package):
//
//   * All client callbacks (message / connection-closed / connect
//     result) fire on the client's own EventLoop thread. They must
//     NEVER touch a SEXP. Each builds a ClientEvent (POD copy) and
//     pushes it onto g_wsClientEvents, then wakes the main-thread
//     dispatcher over the shared wake pipe (notifyDispatcher).
//   * drainWsClientEvents(), the main-thread pump, is called by the
//     dispatcher after the HTTP + server-WS queues; only there do we
//     touch the R hooks.
//   * Outgoing send/close from R hop back onto the client loop via
//     queueInLoop.
//
// Lifecycle (design decision #1: explicit, never auto-stop):
//
//   * g_wsClientLoop (one EventLoopThread shared by all clients) and the
//     dispatcher are brought up together, lazily, on the first
//     dr_ws_connect() — a single "client subsystem" start point, so
//     client events always have a live pump to drain them.
//   * They live until dr_ws_shutdown() or .onUnload. We do NOT stop the
//     loop when the last client closes (open/close thrashing, needless
//     start/stop synchronisation).
//
// Ownership (the teardown lesson, again): g_wsClients owns the R-visible
// state (preserved hooks). Client callbacks carry only a client_id; they
// re-resolve the live WsClient under g_wsClientMutex, so a callback that
// races teardown simply misses and no-ops. SEXPs are released only on
// the main thread, after the loop is joined.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>

#include <drogon/WebSocketClient.h>
#include <drogon/HttpRequest.h>
#include <trantor/net/EventLoop.h>
#include <trantor/net/EventLoopThread.h>

#include "r_bridge.h"

#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>

namespace drogonR {

// Defined in request_queue.cpp; wakes the main-thread dispatcher from an
// IO thread by writing a byte to the shared wake pipe. (Never call
// later's execLaterNative2 off the main thread — see ws_session.cpp.)
void notifyDispatcher();
// Defined in drogon_server.cpp; brings up the shared wake pipe + later
// fd-watch idempotently. The dispatcher's runDispatcher() already calls
// drainWsClientEvents(), so once this returns our events get pumped.
void ensureDispatcherRunning();

// One live outbound WebSocket client. Owns the preserved R hooks; the
// Drogon client is held so we can send/close/stop on its loop. The loop
// pointer is the client's own loop (== g_wsClientLoop->getLoop()).
struct WsClient {
    std::uint64_t id = 0;
    drogon::WebSocketClientPtr client;   // keeps the connection alive
    trantor::EventLoop *loop = nullptr;  // client's loop (for send/close)
    std::atomic<bool> closing{false};
    SEXP on_message = nullptr;           // function(msg, binary) or nil
    SEXP on_open    = nullptr;           // function() or nil
    SEXP on_close   = nullptr;           // function(reason, code) or nil
};

// A queued client event handed to the R hooks on the main thread.
enum class ClientEventType { Open, Message, Close };
struct ClientEvent {
    ClientEventType type;
    std::uint64_t   client_id = 0;
    std::string     message;             // Message events
    bool            binary = false;      // Message events
    std::string     reason;              // Close events ("closed"/"connect_failed")
    int             code = 0;            // Close events (reserved; 0 for now)
};

// --- subsystem state -------------------------------------------------
static std::mutex                                                 g_wsClientMutex;
static std::unordered_map<std::uint64_t, std::shared_ptr<WsClient>> g_wsClients;
static std::deque<ClientEvent>                                    g_wsClientEvents;
static std::atomic<std::uint64_t>                                 g_nextClientId{1};

// The dedicated loop thread. Shared by all clients; created on first
// connect, joined only at shutdown/unload. Guarded by g_wsClientMutex
// for creation; the pointer itself is only written on the main thread.
static std::unique_ptr<trantor::EventLoopThread> g_wsClientLoop;

static std::shared_ptr<WsClient> findClient(std::uint64_t id) {
    std::lock_guard<std::mutex> lock(g_wsClientMutex);
    auto it = g_wsClients.find(id);
    return it == g_wsClients.end() ? nullptr : it->second;
}

// Release the preserved hooks of one client. Main R thread only.
// Forward-declared here; used both by the pump and the connect error
// path below.
void releaseClientHooks(WsClient &c);

// Push an event and wake the main-thread dispatcher. Called on the
// client loop thread — hence the wake pipe, not later.
static void enqueueClientEvent(ClientEvent &&ev) {
    {
        std::lock_guard<std::mutex> lock(g_wsClientMutex);
        g_wsClientEvents.push_back(std::move(ev));
    }
    notifyDispatcher();
}

// Ensure the shared loop thread is running. Main R thread only (called
// from dr_ws_connect). Idempotent.
static trantor::EventLoop *ensureClientLoop() {
    if (!g_wsClientLoop) {
        g_wsClientLoop = std::make_unique<trantor::EventLoopThread>(
            "drogonR-wsclient");
        g_wsClientLoop->run();   // spins the thread, returns once looping
    }
    return g_wsClientLoop->getLoop();
}

std::size_t wsClientCount() {
    std::lock_guard<std::mutex> lock(g_wsClientMutex);
    return g_wsClients.size();
}

// --- main-thread pump ------------------------------------------------

// Call one R hook (closure) with a prepared call. Errors are caught and
// reported; a failing hook must not take down the dispatcher.
static void callClientHook(SEXP hook, SEXP call) {
    if (hook == nullptr || TYPEOF(hook) != CLOSXP) return;
    int err = 0;
    R_tryEval(call, R_GlobalEnv, &err);
    if (err) {
        REprintf("drogonR ws client: hook raised an error (ignored)\n");
    }
}

void releaseClientHooks(WsClient &c) {
    if (c.on_message && c.on_message != R_NilValue) R_ReleaseObject(c.on_message);
    if (c.on_open    && c.on_open    != R_NilValue) R_ReleaseObject(c.on_open);
    if (c.on_close   && c.on_close   != R_NilValue) R_ReleaseObject(c.on_close);
    c.on_message = c.on_open = c.on_close = nullptr;
}

void drainWsClientEvents() {
    std::deque<ClientEvent> batch;
    {
        std::lock_guard<std::mutex> lock(g_wsClientMutex);
        if (g_wsClientEvents.empty()) return;
        batch.swap(g_wsClientEvents);
    }

    for (auto &ev : batch) {
        // Re-resolve hooks under the lock; the client may have been
        // closed between enqueue and now.
        SEXP on_message = R_NilValue, on_open = R_NilValue,
             on_close = R_NilValue;
        bool erase_after = false;
        {
            std::lock_guard<std::mutex> lock(g_wsClientMutex);
            auto it = g_wsClients.find(ev.client_id);
            if (it != g_wsClients.end()) {
                on_message = it->second->on_message;
                on_open    = it->second->on_open;
                on_close   = it->second->on_close;
            }
            // A Close event is the last we will ever see for this client;
            // drop our owning entry after dispatching it (releasing the
            // preserved hooks) so the client and its SEXPs don't leak.
            erase_after = (ev.type == ClientEventType::Close);
        }

        switch (ev.type) {
        case ClientEventType::Open: {
            SEXP call = PROTECT(Rf_lang1(on_open));
            callClientHook(on_open, call);
            UNPROTECT(1);
            break;
        }
        case ClientEventType::Message: {
            // NOTE: same \0-truncation limitation as the server side —
            // mkString stops at the first null. Fine for text frames;
            // binary payloads with embedded nulls need RAWSXP marshalling
            // (tracked in TODO alongside the server-side binary item).
            SEXP msg  = PROTECT(Rf_mkString(ev.message.c_str()));
            SEXP bin  = PROTECT(Rf_ScalarLogical(ev.binary ? 1 : 0));
            SEXP call = PROTECT(Rf_lang3(on_message, msg, bin));
            callClientHook(on_message, call);
            UNPROTECT(3);
            break;
        }
        case ClientEventType::Close: {
            SEXP reason = PROTECT(Rf_mkString(ev.reason.c_str()));
            SEXP code   = PROTECT(Rf_ScalarInteger(ev.code));
            SEXP call   = PROTECT(Rf_lang3(on_close, reason, code));
            callClientHook(on_close, call);
            UNPROTECT(3);
            break;
        }
        }

        if (erase_after) {
            std::shared_ptr<WsClient> dead;
            {
                std::lock_guard<std::mutex> lock(g_wsClientMutex);
                auto it = g_wsClients.find(ev.client_id);
                if (it != g_wsClients.end()) {
                    dead = it->second;
                    g_wsClients.erase(it);
                }
            }
            if (dead) releaseClientHooks(*dead);
        }
    }
}

// --- teardown --------------------------------------------------------

void shutdownWsClients() {
    // Main R thread. Stop every client (on its loop), then join the loop
    // thread, then release SEXPs — the loop is dead by then, so we never
    // queueInLoop on a stopped loop.
    std::vector<std::shared_ptr<WsClient>> clients;
    {
        std::lock_guard<std::mutex> lock(g_wsClientMutex);
        for (auto &kv : g_wsClients) clients.push_back(kv.second);
    }
    for (auto &c : clients) {
        c->closing.store(true);
        if (c->client) c->client->stop();   // thread-safe; queues onto loop
    }

    // Join and destroy the loop thread. EventLoopThread's destructor
    // quits and joins. After this no client callback can fire.
    if (g_wsClientLoop) {
        g_wsClientLoop->getLoop()->quit();
        g_wsClientLoop.reset();   // dtor waits for the thread
    }

    // Now safe to drop everything and release SEXPs on the main thread.
    {
        std::lock_guard<std::mutex> lock(g_wsClientMutex);
        for (auto &kv : g_wsClients) releaseClientHooks(*kv.second);
        g_wsClients.clear();
        g_wsClientEvents.clear();
    }
}

} // namespace drogonR

// --- .Call entrypoints -----------------------------------------------

extern "C" {

// dr_ws_connect(host, path, use_ssl, on_message, on_open, on_close).
// The R layer parses the URL into host ("ws[s]://host[:port]"), path,
// and a use_ssl flag (and rejects wss:// on a non-OpenSSL build before
// we get here). Returns the numeric client id (classed drogon_ws_client
// on the R side).
SEXP drogonR_ws_connect(SEXP host_, SEXP path_,
                        SEXP on_message_, SEXP on_open_, SEXP on_close_) {
    if (TYPEOF(host_) != STRSXP || LENGTH(host_) != 1)
        Rf_error("host must be a single string");
    if (TYPEOF(path_) != STRSXP || LENGTH(path_) != 1)
        Rf_error("path must be a single string");

    std::string host = CHAR(STRING_ELT(host_, 0));
    std::string path = CHAR(STRING_ELT(path_, 0));

    // Bring up the client subsystem (loop + shared dispatcher) together,
    // so events have a live pump the moment the client fires them.
    trantor::EventLoop *loop = drogonR::ensureClientLoop();
    drogonR::ensureDispatcherRunning();

    std::uint64_t id =
        drogonR::g_nextClientId.fetch_add(1, std::memory_order_relaxed);

    auto wc  = std::make_shared<drogonR::WsClient>();
    wc->id   = id;
    wc->loop = loop;
    wc->on_message = (TYPEOF(on_message_) == CLOSXP) ? on_message_ : R_NilValue;
    wc->on_open    = (TYPEOF(on_open_)    == CLOSXP) ? on_open_    : R_NilValue;
    wc->on_close   = (TYPEOF(on_close_)   == CLOSXP) ? on_close_   : R_NilValue;
    if (wc->on_message != R_NilValue) R_PreserveObject(wc->on_message);
    if (wc->on_open    != R_NilValue) R_PreserveObject(wc->on_open);
    if (wc->on_close   != R_NilValue) R_PreserveObject(wc->on_close);

    // newWebSocketClient parses the scheme + host:port out of the host
    // string and runs on our dedicated loop. Path/query go on the request.
    wc->client = drogon::WebSocketClient::newWebSocketClient(host, loop);
    if (!wc->client) {
        drogonR::releaseClientHooks(*wc);
        Rf_error("failed to create WebSocket client for host '%s'",
                 host.c_str());
    }

    {
        std::lock_guard<std::mutex> lock(drogonR::g_wsClientMutex);
        drogonR::g_wsClients.emplace(id, wc);
    }

    // Inbound messages: copy onto the queue, wake the dispatcher.
    wc->client->setMessageHandler(
        [id](std::string &&message,
             const drogon::WebSocketClientPtr &,
             const drogon::WebSocketMessageType &type) {
            drogonR::ClientEvent ev;
            ev.type      = drogonR::ClientEventType::Message;
            ev.client_id = id;
            ev.message   = std::move(message);
            ev.binary    = (type == drogon::WebSocketMessageType::Binary);
            drogonR::enqueueClientEvent(std::move(ev));
        });

    // Connection closed (after a successful open): deliver on_close with
    // reason "closed". This does NOT fire for a failed initial connect —
    // that path is handled in the connect callback below (design #3: one
    // on_close, different reason).
    wc->client->setConnectionClosedHandler(
        [id](const drogon::WebSocketClientPtr &) {
            drogonR::ClientEvent ev;
            ev.type      = drogonR::ClientEventType::Close;
            ev.client_id = id;
            ev.reason    = "closed";
            drogonR::enqueueClientEvent(std::move(ev));
        });

    auto req = drogon::HttpRequest::newHttpRequest();
    req->setPath(path.empty() ? "/" : path);

    wc->client->connectToServer(
        req,
        [id](drogon::ReqResult r,
             const drogon::HttpResponsePtr &,
             const drogon::WebSocketClientPtr &) {
            if (r == drogon::ReqResult::Ok) {
                drogonR::ClientEvent ev;
                ev.type      = drogonR::ClientEventType::Open;
                ev.client_id = id;
                drogonR::enqueueClientEvent(std::move(ev));
            } else {
                // Connect failed: single error path via on_close.
                drogonR::ClientEvent ev;
                ev.type      = drogonR::ClientEventType::Close;
                ev.client_id = id;
                ev.reason    = "connect_failed";
                ev.code      = static_cast<int>(r);
                drogonR::enqueueClientEvent(std::move(ev));
            }
        });

    return Rf_ScalarReal(static_cast<double>(id));
}

SEXP drogonR_ws_client_send(SEXP client_id_, SEXP msg_, SEXP binary_) {
    if (TYPEOF(client_id_) != REALSXP || LENGTH(client_id_) != 1)
        Rf_error("client_id must be a single numeric");
    if (TYPEOF(msg_) != STRSXP || LENGTH(msg_) != 1)
        Rf_error("msg must be a single string");
    std::uint64_t id = static_cast<std::uint64_t>(REAL(client_id_)[0]);
    bool binary = (TYPEOF(binary_) == LGLSXP && LENGTH(binary_) >= 1 &&
                   LOGICAL(binary_)[0] == 1);

    auto wc = drogonR::findClient(id);
    if (!wc || wc->closing.load() || !wc->loop) return Rf_ScalarLogical(FALSE);
    auto client = wc->client;
    std::string buf = CHAR(STRING_ELT(msg_, 0));
    auto type = binary ? drogon::WebSocketMessageType::Binary
                       : drogon::WebSocketMessageType::Text;
    // Hop onto the client loop; never write from the main thread.
    wc->loop->queueInLoop([client, buf = std::move(buf), type]() {
        auto conn = client ? client->getConnection() : nullptr;
        if (conn && conn->connected()) conn->send(buf, type);
    });
    return Rf_ScalarLogical(TRUE);
}

SEXP drogonR_ws_client_close(SEXP client_id_) {
    if (TYPEOF(client_id_) != REALSXP || LENGTH(client_id_) != 1)
        Rf_error("client_id must be a single numeric");
    std::uint64_t id = static_cast<std::uint64_t>(REAL(client_id_)[0]);

    auto wc = drogonR::findClient(id);
    if (!wc) return R_NilValue;
    wc->closing.store(true);
    // stop() is thread-safe (queues onto the client loop) and triggers
    // the connection-closed handler, which enqueues the Close event that
    // drainWsClientEvents() uses to release + erase this client.
    if (wc->client) wc->client->stop();
    return R_NilValue;
}

SEXP drogonR_ws_shutdown(void) {
    drogonR::shutdownWsClients();
    return R_NilValue;
}

// Lets the R layer reject wss:// up front on a plain-HTTP build instead
// of surfacing an opaque connect_failed. Mirrors the -DUSE_OPENSSL flag
// the configure script sets when OpenSSL is found.
SEXP drogonR_has_ssl(void) {
#ifdef USE_OPENSSL
    return Rf_ScalarLogical(TRUE);
#else
    return Rf_ScalarLogical(FALSE);
#endif
}

} // extern "C"
