// drogonR — WebSocket bridge.
//
// Drogon's WebSocket router resolves a controller by *class name* to a
// single DrClassMap singleton (HttpControllersRouter.cc:280). So one
// universal controller class, RWebSocketController, is registered on
// every dr_ws() path; it dispatches by req->path() to the R hooks the
// user set for that path.
//
// Threading (same contract as the HTTP/stream bridge):
//
//   * The three Drogon hooks (handleNewConnection / handleNewMessage /
//     handleConnectionClosed) all run on the connection's IO thread
//     (messageCallback_ fires in the WS parser, WebSocketConnectionImpl
//     .cc:464). They must NEVER touch a SEXP.
//   * On each hook the IO thread builds a WsEvent (POD copy of the
//     message + conn_id) and pushes it; the pump — scheduled via later
//     on the main R thread — drains events and calls the R hook.
//   * Outgoing send/close from R go back onto the connection's loop via
//     queueInLoop (like sendChunkInLoop for streams).
//
// Ownership / lifetime (the teardown lesson from the stream sessions):
//
//   * g_wsSessions (conn_id -> shared_ptr<WsSession>) is the *owner* of
//     the per-connection state. The Drogon connection only carries the
//     conn_id in its context (a make_shared<uint64_t>), never a SEXP.
//   * At server stop the IO loop is already quit()+joined, so its
//     EventLoop is destroyed. clearAllWsSessions() therefore iterates
//     *our* map and only drops handles + releases SEXPs on the main
//     thread — it never calls queueInLoop or conn->getContext on a dead
//     connection.
//
// Everything lives in namespace drogonR (no anonymous namespace) so the
// controller class, the shared state, and the extern "C" outbound ops
// can all see each other within this one translation unit.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>

#include <drogon/HttpAppFramework.h>
#include <drogon/WebSocketController.h>
#include <drogon/WebSocketConnection.h>
#include <trantor/net/EventLoop.h>

#include "r_bridge.h"
#include "../inst/include/drogonR.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace drogonR {

// Wake the main-thread dispatcher (writes a byte to the wakeup pipe).
// Thread-safe: safe to call from a Drogon IO thread. Defined in
// request_queue.cpp — same mechanism HTTP requests use to cross the
// IO -> main boundary. We must NOT call later's execLaterNative2 from
// an IO thread (it is main-thread-only and corrupts later's registry).
void notifyDispatcher();

// One live WebSocket connection. Owns the R-visible state; the Drogon
// connection is held so we can send/close on its loop. It is also the
// anchor object for the C++ fast path: the ABI session handle wraps a
// shared_ptr<WsSession>, so a backend that keeps the handle across a
// detached thread keeps this object alive past teardown — a late
// send()/close() then finds conn already gone and no-ops.
struct WsSession {
    std::uint64_t id = 0;
    int route_id = -1;                       // index into g_wsRoutes
    drogon::WebSocketConnectionPtr conn;     // borrowed; used for send/close
    trantor::EventLoop *loop = nullptr;      // captured on the IO thread
    std::atomic<bool> closing{false};
    // Snapshot of the route's C++ handler (NULL for R-hook routes),
    // taken at connect so per-event dispatch needn't touch the route
    // table. Cast to drogonr_ws_handler_t at the call site.
    void *cpp_fn = nullptr;

    // --- continuous-batching guards (cpp_fn routes only) -------------
    // Snapshot of the route's reap thresholds, taken at connect so the
    // reaper needn't relock the route table per session. 0 == off.
    int64_t idle_ms     = 0;
    int64_t lifetime_ms = 0;
    // connect_ms: monotonic ms at connect (lifetime ceiling reference).
    // last_send_ms: monotonic ms of the most recent successful send()
    // (idle reference); seeded to connect_ms so a session that never
    // sends still ages out via idle_ms. Written on any thread that
    // sends, read by the reaper — hence atomic.
    int64_t              connect_ms = 0;
    std::atomic<int64_t> last_send_ms{0};
    // Shared live-count of the owning route; decremented once when this
    // session is erased. Held here (not looked up) so teardown after the
    // route table is gone still balances the count.
    std::shared_ptr<std::atomic<int>> live_counter;
    std::atomic<bool>                 counted{false};
};

// Monotonic clock in milliseconds. Used for reap timing only.
static int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(
               steady_clock::now().time_since_epoch())
        .count();
}

// A queued event to hand to the R hooks on the main thread.
enum class WsEventType { Connect, Message, Close };
struct WsEvent {
    WsEventType   type;
    std::uint64_t conn_id = 0;
    int           route_id = -1;
    std::string   message;   // Message events only
    bool          binary = false;
};

// --- route table (built while stopped, read while running) ----------
static std::vector<WsRoute> g_wsRoutes;
static std::mutex           g_wsRoutesMutex;

// --- live sessions + event queue (touched on IO + main threads) -----
static std::mutex                                                    g_wsMutex;
static std::unordered_map<std::uint64_t, std::shared_ptr<WsSession>> g_wsSessions;
static std::deque<WsEvent>                                           g_wsEvents;
static std::atomic<std::uint64_t>                                    g_nextWsId{1};

std::shared_ptr<WsSession> findWsSession(std::uint64_t id) {
    std::lock_guard<std::mutex> lock(g_wsMutex);
    auto it = g_wsSessions.find(id);
    return it == g_wsSessions.end() ? nullptr : it->second;
}

// --- rooms (broadcast groups) ---------------------------------------
// A room is a named, thread-safe set of conn_ids. Rooms hold only ids,
// never connection pointers or SEXPs; a broadcast resolves each id to a
// live session via findWsSession() and sends on that session's loop, so
// a stale id (peer already gone) is a harmless miss, not a dangling use.
static std::mutex                                                   g_roomsMutex;
static std::unordered_map<std::string, std::unordered_set<std::uint64_t>>
                                                                    g_wsRooms;

// Drop a conn_id from every room. Called when its session ends so rooms
// don't accumulate dead ids.
static void dropFromAllRooms(std::uint64_t id) {
    std::lock_guard<std::mutex> lock(g_roomsMutex);
    for (auto &kv : g_wsRooms) kv.second.erase(id);
}

static void eraseWsSession(std::uint64_t id) {
    std::shared_ptr<WsSession> sess;
    {
        std::lock_guard<std::mutex> lock(g_wsMutex);
        auto it = g_wsSessions.find(id);
        if (it != g_wsSessions.end()) {
            sess = it->second;
            g_wsSessions.erase(it);
        }
    }
    // Give back the route's concurrency slot exactly once, even if erase
    // races with the reaper (both may reach here for the same session).
    if (sess && sess->live_counter &&
        sess->counted.exchange(false, std::memory_order_acq_rel)) {
        sess->live_counter->fetch_sub(1, std::memory_order_acq_rel);
    }
    dropFromAllRooms(id);
}

// Queue an outbound message on a connection's loop, given its id. Shared
// by dr_ws_send and dr_ws_broadcast. No-op if the session is gone,
// closing, or has no loop yet. Runs on the main R thread.
static void sendToConn(std::uint64_t id, std::string data, bool binary) {
    auto sess = findWsSession(id);
    if (!sess || sess->closing.load() || !sess->loop) return;
    auto conn = sess->conn;
    auto type = binary ? drogon::WebSocketMessageType::Binary
                       : drogon::WebSocketMessageType::Text;
    sess->loop->queueInLoop([conn, data = std::move(data), type]() {
        if (conn && conn->connected()) conn->send(data, type);
    });
}

// --- C++ fast path ---------------------------------------------------
// The ABI session handle (drogonr_ws_session_t*) carries the conn_id by
// value — it is NOT a pointer to any object and has no ownership. Every
// callback re-resolves the live session via findWsSession(id) under
// g_wsMutex, so the handle stays valid for lookup even from a detached
// backend thread outliving the call: once the session is erased (client
// gone / teardown) the lookup simply misses and the callback no-ops.
// This is why no retain/release and no anchor object are needed.
static_assert(sizeof(drogonr_ws_session_t*) >= sizeof(std::uint64_t),
              "conn_id is packed into the ABI session handle pointer");

static std::uint64_t handleId(drogonr_ws_session_t *h) {
    return static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(h));
}
static drogonr_ws_session_t *idHandle(std::uint64_t id) {
    return reinterpret_cast<drogonr_ws_session_t*>(
        static_cast<std::uintptr_t>(id));
}

extern "C" {

static int wsCppSend(drogonr_ws_session_t *h, const char *data, size_t len,
                     int binary) {
    auto sess = findWsSession(handleId(h));
    if (!sess || sess->closing.load() || !sess->loop) return -1;
    auto conn = sess->conn;
    if (!conn || !conn->connected()) return -1;
    auto type = binary ? drogon::WebSocketMessageType::Binary
                       : drogon::WebSocketMessageType::Text;
    std::string buf(data, len);
    // Resolved the session, but the actual socket write must still hop
    // onto the connection's IO loop — never write from this thread.
    sess->loop->queueInLoop([conn, buf = std::move(buf), type]() {
        if (conn && conn->connected()) conn->send(buf, type);
    });
    // Refresh the idle-reap clock: a backend that keeps streaming tokens
    // is alive even if it never receives an inbound frame.
    sess->last_send_ms.store(nowMs(), std::memory_order_relaxed);
    return 0;
}

static void wsCppClose(drogonr_ws_session_t *h) {
    auto sess = findWsSession(handleId(h));
    if (!sess || !sess->loop) return;
    sess->closing.store(true);
    auto conn = sess->conn;
    sess->loop->queueInLoop([conn]() {
        if (conn && conn->connected()) conn->shutdown();
    });
}

static int wsCppIsConnected(drogonr_ws_session_t *h) {
    auto sess = findWsSession(handleId(h));
    if (!sess || sess->closing.load()) return 0;
    auto conn = sess->conn;
    return (conn && conn->connected()) ? 1 : 0;
}

} // extern "C"

// Dispatch one event to a route's C++ handler on the IO thread. The
// handle is just the conn_id — the callbacks re-resolve the session, so
// there is nothing to allocate or free here, and a detached backend
// thread keeping the handle stays safe (lookup misses after teardown).
static void dispatchCpp(const std::shared_ptr<WsSession> &sess,
                        drogonr_ws_event_t event,
                        const char *msg, std::size_t len, bool binary) {
    auto fn = reinterpret_cast<drogonr_ws_handler_t>(sess->cpp_fn);
    if (!fn) return;
    fn(idHandle(sess->id), event, msg, len, binary ? 1 : 0,
       &wsCppSend, &wsCppClose, &wsCppIsConnected);
}

// Match a request path to a registered WS route. Exact match only for
// now (dr_ws paths are exact patterns, like dr_get). Returns -1 on miss.
static int routeIdForPath(const std::string &path) {
    std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
    for (std::size_t i = 0; i < g_wsRoutes.size(); ++i) {
        if (g_wsRoutes[i].path == path) return static_cast<int>(i);
    }
    return -1;
}

// The route's C++ handler (NULL for R-hook routes), snapshotted at
// connect so per-event dispatch needn't relock the route table.
static void *cppFnForRoute(int route_id) {
    std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
    if (route_id < 0 || route_id >= static_cast<int>(g_wsRoutes.size()))
        return nullptr;
    return g_wsRoutes[route_id].cpp_fn;
}

// The route's continuous-batching guards, snapshotted at connect. All
// zero / null for an unknown or unguarded route.
struct WsGuards {
    int      max_conns   = 0;
    int64_t  idle_ms     = 0;
    int64_t  lifetime_ms = 0;
    std::shared_ptr<std::atomic<int>> live;
};
static WsGuards guardsForRoute(int route_id) {
    std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
    WsGuards g;
    if (route_id < 0 || route_id >= static_cast<int>(g_wsRoutes.size()))
        return g;
    const WsRoute &r = g_wsRoutes[route_id];
    g.max_conns   = r.max_conns;
    g.idle_ms     = r.idle_ms;
    g.lifetime_ms = r.lifetime_ms;
    g.live        = r.live;
    return g;
}

// Push an event and wake the main-thread dispatcher. Called on the IO
// thread — hence the wake-pipe (not later, which is main-thread-only).
static void enqueueWsEvent(WsEvent &&ev) {
    {
        std::lock_guard<std::mutex> lock(g_wsMutex);
        g_wsEvents.push_back(std::move(ev));
    }
    notifyDispatcher();
}

// The universal controller. Registered under the single class name
// "drogonR::RWebSocketController"; Drogon hands us every WS connection
// on every dr_ws() path through this one singleton.
class RWebSocketController
    : public drogon::WebSocketController<RWebSocketController, /*AutoCreation*/ false>
{
  public:
    // AutoCreation is false, so Drogon's pathRegistrator does not call
    // this — but the class template still names it, so it must exist.
    // We register paths ourselves in installWsRoutes(), not via the
    // WS_PATH_* macros, so this is intentionally empty.
    static void initPathRouting() {}

    void handleNewConnection(const drogon::HttpRequestPtr &req,
                             const drogon::WebSocketConnectionPtr &conn) override
    {
        // IO thread. No SEXP here.
        int route_id = routeIdForPath(req->path());
        void *cpp_fn = cppFnForRoute(route_id);   // NULL for R-hook routes

        // Continuous-batching guards apply only to cpp routes. Read the
        // route's live-count / thresholds before we commit a session so
        // an over-capacity connect can be refused without side effects.
        WsGuards guards;
        if (cpp_fn) guards = guardsForRoute(route_id);

        // Reject over the concurrency cap. Increment-then-check against
        // the shared counter so two simultaneous connects can't both
        // sneak past a limit of N-1; roll back and refuse on overflow.
        // The handshake has already completed by the time we get here
        // (HttpServer sends 101 before calling handleNewConnection), so
        // this is a full WebSocket — shutdown() with a close code works.
        // 1013 "Try Again Later" is not in the vendored CloseCode enum
        // (it stops at 1011); cast the raw RFC6455 number in.
        if (cpp_fn && guards.max_conns > 0 && guards.live) {
            int after = guards.live->fetch_add(1, std::memory_order_acq_rel) + 1;
            if (after > guards.max_conns) {
                guards.live->fetch_sub(1, std::memory_order_acq_rel);
                conn->shutdown(static_cast<drogon::CloseCode>(1013),
                               "server at capacity");
                return;
            }
        }

        std::uint64_t id = g_nextWsId.fetch_add(1, std::memory_order_relaxed);

        auto sess      = std::make_shared<WsSession>();
        sess->id       = id;
        sess->route_id = route_id;
        sess->conn     = conn;
        sess->loop     = trantor::EventLoop::getEventLoopOfCurrentThread();
        sess->cpp_fn   = cpp_fn;

        if (cpp_fn) {
            int64_t t = nowMs();
            sess->idle_ms     = guards.idle_ms;
            sess->lifetime_ms = guards.lifetime_ms;
            sess->connect_ms  = t;
            sess->last_send_ms.store(t, std::memory_order_relaxed);
            // Record the live-count reference for balanced decrement on
            // erase. Only mark counted when we actually incremented above
            // (max_conns > 0); otherwise there's nothing to give back.
            if (guards.max_conns > 0 && guards.live) {
                sess->live_counter = guards.live;
                sess->counted.store(true, std::memory_order_relaxed);
            }
        }

        // Stash only the conn_id on the Drogon side (never a SEXP), so
        // handleNewMessage/Closed can find the session cheaply.
        conn->setContext(std::make_shared<std::uint64_t>(id));

        {
            std::lock_guard<std::mutex> lock(g_wsMutex);
            g_wsSessions.emplace(id, sess);
        }

        // C++ fast path: dispatch on this IO thread, bypassing R.
        if (sess->cpp_fn) {
            dispatchCpp(sess, DROGONR_WS_CONNECT, nullptr, 0, false);
            return;
        }

        WsEvent ev;
        ev.type     = WsEventType::Connect;
        ev.conn_id  = id;
        ev.route_id = route_id;
        enqueueWsEvent(std::move(ev));
    }

    void handleNewMessage(const drogon::WebSocketConnectionPtr &conn,
                          std::string &&message,
                          const drogon::WebSocketMessageType &type) override
    {
        if (!conn->hasContext()) return;
        std::uint64_t id = *conn->getContext<std::uint64_t>();

        std::shared_ptr<WsSession> sess;
        {
            std::lock_guard<std::mutex> lock(g_wsMutex);
            auto it = g_wsSessions.find(id);
            if (it == g_wsSessions.end()) return;   // already torn down
            sess = it->second;
        }

        bool binary = (type == drogon::WebSocketMessageType::Binary);
        if (sess->cpp_fn) {
            dispatchCpp(sess, DROGONR_WS_MESSAGE,
                        message.data(), message.size(), binary);
            return;
        }

        WsEvent ev;
        ev.type     = WsEventType::Message;
        ev.conn_id  = id;
        ev.route_id = sess->route_id;
        ev.message  = std::move(message);
        ev.binary   = binary;
        enqueueWsEvent(std::move(ev));
    }

    void handleConnectionClosed(
        const drogon::WebSocketConnectionPtr &conn) override
    {
        if (!conn->hasContext()) return;
        std::uint64_t id = *conn->getContext<std::uint64_t>();

        std::shared_ptr<WsSession> sess;
        {
            std::lock_guard<std::mutex> lock(g_wsMutex);
            auto it = g_wsSessions.find(id);
            if (it == g_wsSessions.end()) return;
            sess = it->second;
            sess->closing.store(true);
        }

        if (sess->cpp_fn) {
            // Deliver the close to the backend on the IO thread, then
            // drop our owning reference (any detached backend thread that
            // kept the anchor keeps the session alive until it releases).
            dispatchCpp(sess, DROGONR_WS_CLOSE, nullptr, 0, false);
            eraseWsSession(id);
            return;
        }

        WsEvent ev;
        ev.type     = WsEventType::Close;
        ev.conn_id  = id;
        ev.route_id = sess->route_id;
        enqueueWsEvent(std::move(ev));
    }
};

// Build the `drogon_ws_conn` object handed to R hooks: a classed double
// carrying the conn_id (uint64 is exact in a double up to 2^53, far more
// connections than any process will see).
static SEXP makeWsConn(std::uint64_t id) {
    SEXP obj = PROTECT(Rf_ScalarReal(static_cast<double>(id)));
    SEXP cls = PROTECT(Rf_mkString("drogon_ws_conn"));
    Rf_setAttrib(obj, R_ClassSymbol, cls);
    UNPROTECT(2);
    return obj;
}

// Call one R hook (closure) with the prepared call. Errors are caught
// and printed; a failing hook must not take down the dispatcher.
static void callHook(SEXP hook, SEXP call) {
    if (hook == nullptr || TYPEOF(hook) != CLOSXP) return;
    int err = 0;
    R_tryEval(call, R_GlobalEnv, &err);
    if (err) {
        REprintf("drogonR ws: hook raised an error (ignored)\n");
    }
}

// Main-thread pump: drain queued events, dispatch to R hooks. Called by
// the dispatcher (r_dispatcher.cpp) on the main R thread, right after it
// drains the HTTP request queue.
void drainWsEvents() {
    std::deque<WsEvent> batch;
    {
        std::lock_guard<std::mutex> lock(g_wsMutex);
        batch.swap(g_wsEvents);
    }

    for (auto &ev : batch) {
        SEXP on_connect = R_NilValue, on_message = R_NilValue,
             on_close = R_NilValue;
        {
            std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
            if (ev.route_id >= 0 &&
                ev.route_id < static_cast<int>(g_wsRoutes.size())) {
                on_connect = g_wsRoutes[ev.route_id].on_connect;
                on_message = g_wsRoutes[ev.route_id].on_message;
                on_close   = g_wsRoutes[ev.route_id].on_close;
            }
        }

        SEXP conn = PROTECT(makeWsConn(ev.conn_id));

        switch (ev.type) {
        case WsEventType::Connect: {
            SEXP call = PROTECT(Rf_lang2(on_connect, conn));
            callHook(on_connect, call);
            UNPROTECT(1);
            break;
        }
        case WsEventType::Message: {
            SEXP msg  = PROTECT(Rf_mkString(ev.message.c_str()));
            SEXP bin  = PROTECT(Rf_ScalarLogical(ev.binary ? 1 : 0));
            SEXP call = PROTECT(Rf_lang4(on_message, conn, msg, bin));
            callHook(on_message, call);
            UNPROTECT(3);
            break;
        }
        case WsEventType::Close: {
            SEXP call = PROTECT(Rf_lang2(on_close, conn));
            callHook(on_close, call);
            UNPROTECT(1);
            // The connection is gone; drop our owning session.
            eraseWsSession(ev.conn_id);
            break;
        }
        }
        UNPROTECT(1); // conn
    }
}

// --- public API (declared in r_bridge.h) ----------------------------

int addWsRoute(WsRoute &&route) {
    if (route.on_connect && route.on_connect != R_NilValue)
        R_PreserveObject(route.on_connect);
    if (route.on_message && route.on_message != R_NilValue)
        R_PreserveObject(route.on_message);
    if (route.on_close && route.on_close != R_NilValue)
        R_PreserveObject(route.on_close);
    std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
    int id = static_cast<int>(g_wsRoutes.size());
    g_wsRoutes.push_back(std::move(route));
    return id;
}

std::size_t wsRouteCount() {
    std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
    return g_wsRoutes.size();
}

// --- room ops (called from the .Call entrypoints, main R thread) -----

void roomJoin(const std::string &room, std::uint64_t id) {
    std::lock_guard<std::mutex> lock(g_roomsMutex);
    g_wsRooms[room].insert(id);
}

void roomLeave(const std::string &room, std::uint64_t id) {
    std::lock_guard<std::mutex> lock(g_roomsMutex);
    auto it = g_wsRooms.find(room);
    if (it != g_wsRooms.end()) {
        it->second.erase(id);
        if (it->second.empty()) g_wsRooms.erase(it);
    }
}

// Send `data` to every live member of `room`. Snapshot the id set under
// the lock, then send outside it (sendToConn takes g_wsMutex, so holding
// g_roomsMutex across it would invert lock order). Returns the number of
// members the message was queued to.
int roomBroadcast(const std::string &room, const std::string &data,
                  bool binary) {
    std::vector<std::uint64_t> ids;
    {
        std::lock_guard<std::mutex> lock(g_roomsMutex);
        auto it = g_wsRooms.find(room);
        if (it == g_wsRooms.end()) return 0;
        ids.assign(it->second.begin(), it->second.end());
    }
    int n = 0;
    for (auto id : ids) { sendToConn(id, data, binary); ++n; }
    return n;
}

// --- reaper: close idle / over-lifetime cpp-WS sessions --------------
//
// One periodic timer on the server loop (NOT a timer per session)
// scans g_wsSessions and shuts down cpp sessions that have gone quiet
// (no send() for idle_ms) or outlived lifetime_ms. Shutting the
// connection makes Drogon fire handleConnectionClosed → the backend
// gets its CLOSE event and eraseWsSession runs, exactly as for a
// client-initiated close. We never touch a SEXP here.
static std::atomic<bool> g_wsReaperStop{false};
static trantor::TimerId  g_wsReaperTimer = 0;
static bool              g_wsReaperArmed = false;

static void reapExpiredSessions() {
    if (g_wsReaperStop.load(std::memory_order_acquire)) return;
    int64_t now = nowMs();

    // Snapshot expired sessions under the lock, then act outside it:
    // conn->shutdown() is queued on the session's own loop, and taking
    // g_wsMutex across that is unnecessary (and would widen the lock).
    std::vector<std::shared_ptr<WsSession>> expired;
    {
        std::lock_guard<std::mutex> lock(g_wsMutex);
        for (auto &kv : g_wsSessions) {
            auto &s = kv.second;
            if (!s->cpp_fn || s->closing.load()) continue;
            bool idle = s->idle_ms > 0 &&
                        (now - s->last_send_ms.load(std::memory_order_relaxed))
                            > s->idle_ms;
            bool over = s->lifetime_ms > 0 &&
                        (now - s->connect_ms) > s->lifetime_ms;
            if (idle || over) expired.push_back(s);
        }
    }
    for (auto &s : expired) {
        s->closing.store(true);
        if (!s->loop) continue;
        auto conn = s->conn;
        s->loop->queueInLoop([conn]() {
            if (conn && conn->connected()) conn->shutdown();
        });
    }
}

// Arm the reaper on the server loop if any route asked for reaping.
// Called from installWsRoutes() under g_wsRoutesMutex.
static void armWsReaperLocked() {
    int64_t minThresh = 0;
    for (const auto &r : g_wsRoutes) {
        if (!r.cpp_fn) continue;
        for (int64_t v : {r.idle_ms, r.lifetime_ms}) {
            if (v > 0 && (minThresh == 0 || v < minThresh)) minThresh = v;
        }
    }
    if (minThresh == 0) return;  // no route wants reaping

    // Scan at half the tightest threshold so a session overshoots its
    // deadline by at most ~half of it; clamp to a sane [50ms, 1s] band
    // so tiny thresholds don't spin and huge ones still get checked.
    double interval = static_cast<double>(minThresh) / 2.0 / 1000.0;
    if (interval < 0.05) interval = 0.05;
    if (interval > 1.0)  interval = 1.0;

    g_wsReaperStop.store(false, std::memory_order_release);
    g_wsReaperTimer = drogon::app().getLoop()->runEvery(
        interval, [] { reapExpiredSessions(); });
    g_wsReaperArmed = true;
}

void installWsRoutes() {
    std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
    if (g_wsRoutes.empty()) return;

    // classTypeName() touches DrObject<T>::alloc_, whose constructor
    // registers our controller in DrClassMap and yields the demangled
    // class name. Drogon's router resolves that name to a single
    // getSingleInstance() singleton shared by every path, so binding all
    // dr_ws() paths to it gives one controller that dispatches by path.
    const std::string &cls = RWebSocketController::classTypeName();
    for (const auto &r : g_wsRoutes) {
        drogon::app().registerWebSocketController(r.path, cls);
    }

    armWsReaperLocked();
}

void clearAllWsSessions() {
    // Main R thread, after the IO loop has been joined. Iterate our own
    // map; the Drogon connections/loops are already gone, so we only
    // drop handles and release the preserved SEXPs — never queueInLoop
    // or conn->getContext on a dead connection.

    // Disarm the reaper. The server loop has already been quit()+joined,
    // so its timer will never fire again and invalidateTimer() on the
    // dead loop would be unsafe — flipping the stop flag and resetting
    // the armed state is enough, and lets a fresh serve re-arm cleanly.
    g_wsReaperStop.store(true, std::memory_order_release);
    g_wsReaperArmed = false;
    g_wsReaperTimer = 0;
    {
        std::lock_guard<std::mutex> lock(g_wsMutex);
        g_wsSessions.clear();
        g_wsEvents.clear();
    }
    {
        std::lock_guard<std::mutex> lock(g_roomsMutex);
        g_wsRooms.clear();
    }
    std::lock_guard<std::mutex> lock(g_wsRoutesMutex);
    for (auto &r : g_wsRoutes) {
        if (r.on_connect && r.on_connect != R_NilValue) R_ReleaseObject(r.on_connect);
        if (r.on_message && r.on_message != R_NilValue) R_ReleaseObject(r.on_message);
        if (r.on_close   && r.on_close   != R_NilValue) R_ReleaseObject(r.on_close);
        r.on_connect = r.on_message = r.on_close = nullptr;
    }
    g_wsRoutes.clear();
}

} // namespace drogonR

// --- .Call entrypoints -----------------------------------------------

extern "C" {

SEXP drogonR_register_ws(SEXP path_, SEXP on_connect_, SEXP on_message_,
                         SEXP on_close_) {
    if (drogonR::serverRunning()) {
        Rf_error("dr_ws: cannot register while the server is running. "
                 "Stop it first with dr_stop().");
    }
    if (TYPEOF(path_) != STRSXP || LENGTH(path_) != 1)
        Rf_error("path must be a single string");

    // Normalise to R_NilValue (never a raw nullptr) so the dispatcher can
    // TYPEOF() the hooks safely and R_PreserveObject skips the empties.
    drogonR::WsRoute r;
    r.path       = CHAR(STRING_ELT(path_, 0));
    r.on_connect = (TYPEOF(on_connect_) == CLOSXP) ? on_connect_ : R_NilValue;
    r.on_message = (TYPEOF(on_message_) == CLOSXP) ? on_message_ : R_NilValue;
    r.on_close   = (TYPEOF(on_close_)   == CLOSXP) ? on_close_   : R_NilValue;

    int id = drogonR::addWsRoute(std::move(r));
    return Rf_ScalarInteger(id);
}

// Read a single non-negative numeric arg (0 == "off"). Rounds to the
// nearest whole unit; rejects NA / negative / wrong shape.
static double reqNonNegNum(SEXP x, const char *what) {
    if (TYPEOF(x) != REALSXP && TYPEOF(x) != INTSXP)
        Rf_error("%s must be a single number", what);
    if (LENGTH(x) != 1)
        Rf_error("%s must be a single number", what);
    double v = (TYPEOF(x) == INTSXP) ? (double)INTEGER(x)[0] : REAL(x)[0];
    if (ISNAN(v) || v < 0)
        Rf_error("%s must be a non-negative number", what);
    return v;
}

SEXP drogonR_register_ws_cpp(SEXP path_, SEXP ptr_,
                             SEXP max_conns_, SEXP idle_timeout_,
                             SEXP max_lifetime_) {
    if (drogonR::serverRunning()) {
        Rf_error("dr_ws_cpp: cannot register while the server is running. "
                 "Stop it first with dr_stop().");
    }
    if (TYPEOF(path_) != STRSXP || LENGTH(path_) != 1)
        Rf_error("path must be a single string");
    if (TYPEOF(ptr_) != EXTPTRSXP)
        Rf_error("callable must be an external pointer "
                 "(from dr_resolve_ccallable)");
    void *fn = R_ExternalPtrAddr(ptr_);
    if (fn == nullptr)
        Rf_error("callable resolved to a NULL pointer");

    // Batching guards: max_conns is a count; the timeouts arrive in
    // seconds and are stored as whole milliseconds. 0 == off (default).
    double max_conns   = reqNonNegNum(max_conns_,    "max_conns");
    double idle_secs   = reqNonNegNum(idle_timeout_, "idle_timeout");
    double life_secs   = reqNonNegNum(max_lifetime_, "max_lifetime");

    drogonR::WsRoute r;
    r.path        = CHAR(STRING_ELT(path_, 0));
    r.on_connect  = R_NilValue;
    r.on_message  = R_NilValue;
    r.on_close    = R_NilValue;
    r.cpp_fn      = fn;
    r.max_conns   = (int)(max_conns + 0.5);
    r.idle_ms     = (int64_t)(idle_secs * 1000.0 + 0.5);
    r.lifetime_ms = (int64_t)(life_secs * 1000.0 + 0.5);

    int id = drogonR::addWsRoute(std::move(r));
    return Rf_ScalarInteger(id);
}

SEXP drogonR_ws_send(SEXP conn_id_, SEXP msg_, SEXP binary_) {
    if (TYPEOF(conn_id_) != REALSXP || LENGTH(conn_id_) != 1)
        Rf_error("conn_id must be a single numeric");
    if (TYPEOF(msg_) != STRSXP || LENGTH(msg_) != 1)
        Rf_error("msg must be a single string");
    std::uint64_t id = static_cast<std::uint64_t>(REAL(conn_id_)[0]);
    bool binary = (TYPEOF(binary_) == LGLSXP && LENGTH(binary_) >= 1 &&
                   LOGICAL(binary_)[0] == 1);
    drogonR::sendToConn(id, CHAR(STRING_ELT(msg_, 0)), binary);
    return R_NilValue;
}

SEXP drogonR_ws_close(SEXP conn_id_) {
    if (TYPEOF(conn_id_) != REALSXP || LENGTH(conn_id_) != 1)
        Rf_error("conn_id must be a single numeric");
    std::uint64_t id = static_cast<std::uint64_t>(REAL(conn_id_)[0]);

    auto sess = drogonR::findWsSession(id);
    if (!sess || !sess->loop) return R_NilValue;
    sess->closing.store(true);
    auto conn = sess->conn;
    sess->loop->queueInLoop([conn]() {
        if (conn && conn->connected()) conn->shutdown();
    });
    return R_NilValue;
}

SEXP drogonR_ws_join(SEXP room_, SEXP conn_id_) {
    if (TYPEOF(room_) != STRSXP || LENGTH(room_) != 1)
        Rf_error("room must be a single string");
    if (TYPEOF(conn_id_) != REALSXP || LENGTH(conn_id_) != 1)
        Rf_error("conn_id must be a single numeric");
    drogonR::roomJoin(CHAR(STRING_ELT(room_, 0)),
                      static_cast<std::uint64_t>(REAL(conn_id_)[0]));
    return R_NilValue;
}

SEXP drogonR_ws_leave(SEXP room_, SEXP conn_id_) {
    if (TYPEOF(room_) != STRSXP || LENGTH(room_) != 1)
        Rf_error("room must be a single string");
    if (TYPEOF(conn_id_) != REALSXP || LENGTH(conn_id_) != 1)
        Rf_error("conn_id must be a single numeric");
    drogonR::roomLeave(CHAR(STRING_ELT(room_, 0)),
                       static_cast<std::uint64_t>(REAL(conn_id_)[0]));
    return R_NilValue;
}

SEXP drogonR_ws_broadcast(SEXP room_, SEXP msg_, SEXP binary_) {
    if (TYPEOF(room_) != STRSXP || LENGTH(room_) != 1)
        Rf_error("room must be a single string");
    if (TYPEOF(msg_) != STRSXP || LENGTH(msg_) != 1)
        Rf_error("msg must be a single string");
    bool binary = (TYPEOF(binary_) == LGLSXP && LENGTH(binary_) >= 1 &&
                   LOGICAL(binary_)[0] == 1);
    int n = drogonR::roomBroadcast(CHAR(STRING_ELT(room_, 0)),
                                   CHAR(STRING_ELT(msg_, 0)), binary);
    return Rf_ScalarInteger(n);
}

} // extern "C"
