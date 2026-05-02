#ifndef DROGONR_BRIDGE_H
#define DROGONR_BRIDGE_H

#ifdef __cplusplus
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace drogon { class HttpResponse; }

namespace drogonR {

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
                          SEXP max_queue_);
SEXP drogonR_server_stop(void);
SEXP drogonR_server_running(void);
SEXP drogonR_reset_fork_state(void);

// Routing
SEXP drogonR_register_route(SEXP method_, SEXP path_, SEXP regex_,
                            SEXP param_names_, SEXP handler_);
SEXP drogonR_clear_routes(void);

#ifdef __cplusplus
}
#endif

#endif
