#ifndef DROGONR_BRIDGE_H
#define DROGONR_BRIDGE_H

#ifdef __cplusplus
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#define R_NO_REMAP
#include <Rinternals.h>

namespace drogon { class HttpResponse; }
namespace trantor { class TcpConnection; }

namespace drogonR {

// One header to send with the initial chunked-transfer response of a
// streaming endpoint. Keeps stream_session.cpp's interface free of
// any direct R headers.
struct StreamHeader { std::string name, value; };

// Implemented in stream_session.cpp. Opens an async-stream response,
// preserves next_chunk/state across GC, and pumps next_chunk on the
// main R thread until done. `respond` is Drogon's response callback,
// invoked exactly once with the streaming HttpResponse.
void startStreamSession(
    const std::function<void(const std::shared_ptr<drogon::HttpResponse>&)> &respond,
    SEXP next_chunk, SEXP state,
    const std::string &content_type,
    const std::vector<StreamHeader> &headers,
    // drogonR patch: weak-ref to the TCP connection so the stream
    // session can register an onClose callback for cancel detection.
    // Empty weak_ptr is allowed — caller falls back to send()-based
    // detection only.
    const std::weak_ptr<trantor::TcpConnection> &connection,
    // Floor on the delay between consecutive next_chunk() pumps, in
    // seconds. 0.0 means "as fast as the loop will allow".
    double min_interval);

// Drop every active streaming session and release the SEXPs they
// hold. Called at server stop.
void clearAllStreamSessions();


// --- WebSocket bridge (ws_session.cpp) ------------------------------
//
// One universal WebSocket controller ("RWebSocketController") is
// registered with Drogon on every dr_ws() path (Drogon resolves a
// single class-name to one singleton, so the same object serves all
// paths). It dispatches by req->path() to the matching R hook set.
//
// A WsRoute holds the three R hooks (on_connect / on_message /
// on_close) for one path, preserved across GC. Registered before the
// server starts, mirroring the HTTP Route table.
struct WsRoute {
    std::string path;    // exact match against req->path()
    SEXP on_connect = nullptr;   // function(conn) or R_NilValue
    SEXP on_message = nullptr;   // function(conn, msg, binary)
    SEXP on_close   = nullptr;   // function(conn) or R_NilValue
    // C++ fast-path: a resolved drogonr_ws_handler_t (stored as void* so
    // this header needn't pull in <drogonR.h>). When non-NULL the route
    // is served entirely in C++ on the IO thread and the R hooks above
    // are ignored.
    void *cpp_fn = nullptr;

    // Continuous-batching guards. Apply only to cpp_fn routes; ignored
    // for R-hook routes (max_conns == 0 / *_ms == 0 means "off", which
    // is the default and preserves pre-batching behaviour).
    //   max_conns   — cap on concurrent live cpp-WS sessions on this
    //                 route; the (N+1)th connection is refused at connect
    //                 with WS close 1013 ("try again later").
    //   idle_ms     — close a session after this long with no send()
    //                 to the peer (a stalled/crashed decode thread).
    //   lifetime_ms — hard ceiling on a session's total lifetime,
    //                 regardless of activity.
    int      max_conns   = 0;
    int64_t  idle_ms     = 0;
    int64_t  lifetime_ms = 0;
    // Live cpp-WS session count for this route. shared_ptr so a WsSession
    // can hold a reference and decrement on erase even after the route
    // table is torn down; atomic because connect/erase run on IO threads.
    std::shared_ptr<std::atomic<int>> live =
        std::make_shared<std::atomic<int>>(0);
};

// Register a WsRoute; preserves the hooks. Returns its index. Called
// from the R layer while the server is stopped.
int  addWsRoute(WsRoute &&route);
// Number of registered WS routes (server-start decides whether to
// register the universal controller at all).
std::size_t wsRouteCount();
// Hook the universal controller into Drogon. Called once at
// server-start, after the HTTP routes are installed.
void installWsRoutes();
// Drop every WS route + active session, release SEXPs. Called at
// server stop (main R thread; the IO loop is already joined, so we
// iterate our own session map and never touch a dead connection).
void clearAllWsSessions();

// True while Drogon is serving. Defined in drogon_server.cpp; used by
// ws_session.cpp to reject registration on a running server.
bool serverRunning();

// Drain queued WebSocket events and dispatch them to the R hooks. Runs
// on the main R thread, called by the dispatcher after the HTTP queue.
void drainWsEvents();

// Room (broadcast group) ops. A room is a named set of conn_ids;
// broadcast resolves each to a live session and sends on its loop.
void roomJoin(const std::string &room, std::uint64_t id);
void roomLeave(const std::string &room, std::uint64_t id);
int  roomBroadcast(const std::string &room, const std::string &data,
                   bool binary);

// --- WebSocket client subsystem (ws_client.cpp) ----------------------
// drogonR acting as a WS *client* to an external server (e.g. an LLM
// streaming API). Runs on its own EventLoopThread (g_wsClientLoop),
// independent of dr_serve; the loop is brought up lazily on the first
// dr_ws_connect() together with the shared dispatcher, and torn down
// only by dr_ws_shutdown() or .onUnload — never auto-stopped after the
// last client closes. Client callbacks fire on that loop thread, never
// touch SEXPs, and cross to the main R thread over the same wake pipe as
// HTTP requests. drainWsClientEvents() is the main-thread pump; it is
// called by the dispatcher right after drainWsEvents(). Harmless no-op
// when no clients exist.
void drainWsClientEvents();
// Stop every client, join the loop thread, release preserved hooks.
// Called from dr_ws_shutdown() / .onUnload on the main R thread.
void shutdownWsClients();
// Number of live clients — lets the dispatcher-teardown path know the
// client subsystem still needs the shared wake pipe alive.
std::size_t wsClientCount();


// Plain-old-data snapshot of an HTTP request, taken on the Drogon I/O
// thread before being handed to the R main thread. Owns its own copies
// of all string buffers, so it has no dependency on the lifetime of
// any Drogon object.
struct PendingRequest {
    std::string method;
    std::string path;
    std::string body;
    std::vector<std::pair<std::string, std::string>> headers;
    std::vector<std::pair<std::string, std::string>> queries;

    // Positional path parameters captured by the route's regex, in
    // matching order. The R-side wrapper joins them with the route's
    // saved param_names to build a named character vector.
    std::vector<std::string> path_params;

    // Drogon's response callback. Captured by move at push time. The
    // dispatcher invokes it once with the constructed HttpResponsePtr.
    // If the dispatcher fails (R error, missing handler), it must still
    // be called with a 500 response — never silently dropped, or the
    // client connection hangs.
    std::function<void(const std::shared_ptr<drogon::HttpResponse> &)> respond;

    // drogonR patch: weak-ref to the underlying TCP connection. Used
    // only by streaming responses to wire up an onClose callback for
    // disconnect detection. Empty for non-streaming requests is fine.
    std::weak_ptr<trantor::TcpConnection> connection;

    // Index into the registered-handler table (route_t entry).
    int route_id = -1;
};

// Try to enqueue a request. Returns true on success; false if the
// queue is full and the caller must respond with 503 itself (the
// PendingRequest's `respond` callback is left intact and the move
// is rolled back so the caller still owns the cb).
bool enqueueRequest(PendingRequest &&req);
void notifyDispatcher();
void setQueueMaxSize(std::size_t n);

// Shared dispatcher infrastructure (wake pipe + fd binding + later
// fd-watch). Idempotent; main R thread only. Defined in
// drogon_server.cpp; called from server start and lazily from the
// WS-client subsystem. shutdownDispatcher() is the counterpart —
// callers must ensure the server is stopped and no WS clients are
// alive before invoking it.
void ensureDispatcherRunning();
void shutdownDispatcher();

} // namespace drogonR
#endif // __cplusplus

#ifdef __cplusplus
extern "C" {
#endif

#include <Rinternals.h>

// Smoke / introspection
SEXP drogonR_smoke(void);
SEXP drogonR_drogon_version(void);

// Server lifecycle
SEXP drogonR_server_start(SEXP port_, SEXP threads_, SEXP upload_path_,
                          SEXP max_queue_, SEXP cpp_workers_);
SEXP drogonR_server_stop(void);
SEXP drogonR_server_running(void);
SEXP drogonR_reset_fork_state(void);

// Routing
SEXP drogonR_register_route(SEXP method_, SEXP path_, SEXP regex_,
                            SEXP param_names_, SEXP handler_);
SEXP drogonR_register_static(SEXP mount_, SEXP dir_);
SEXP drogonR_register_rate_limits(SEXP rules_);
SEXP drogonR_resolve_ccallable(SEXP package_, SEXP callable_);
SEXP drogonR_register_cpp_route(SEXP method_, SEXP path_, SEXP regex_,
                                SEXP param_names_, SEXP ptr_);
SEXP drogonR_register_cpp_stream_route(SEXP method_, SEXP path_, SEXP regex_,
                                       SEXP param_names_, SEXP ptr_,
                                       SEXP content_type_);
SEXP drogonR_clear_routes(void);

// WebSocket routing + outbound ops. register_ws takes the path and the
// three hooks (any may be NULL); ws_send/ws_close act on a live
// connection identified by its conn_id (a double carrying a uint64).
SEXP drogonR_register_ws(SEXP path_, SEXP on_connect_, SEXP on_message_,
                         SEXP on_close_);
SEXP drogonR_register_ws_cpp(SEXP path_, SEXP ptr_,
                             SEXP max_conns_, SEXP idle_timeout_,
                             SEXP max_lifetime_);
SEXP drogonR_ws_send(SEXP conn_id_, SEXP msg_, SEXP binary_);
SEXP drogonR_ws_close(SEXP conn_id_);
SEXP drogonR_ws_join(SEXP room_, SEXP conn_id_);
SEXP drogonR_ws_leave(SEXP room_, SEXP conn_id_);
SEXP drogonR_ws_broadcast(SEXP room_, SEXP msg_, SEXP binary_);

// WebSocket client subsystem (ws_client.cpp).
SEXP drogonR_ws_connect(SEXP host_, SEXP path_, SEXP on_message_,
                        SEXP on_open_, SEXP on_close_);
SEXP drogonR_ws_client_send(SEXP client_id_, SEXP msg_, SEXP binary_);
SEXP drogonR_ws_client_close(SEXP client_id_);
SEXP drogonR_ws_shutdown(void);
// TRUE if the package was built with OpenSSL (so wss:// is possible).
SEXP drogonR_has_ssl(void);

#ifdef __cplusplus
}
#endif

#endif
