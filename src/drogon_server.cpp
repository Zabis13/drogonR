// drogonR — server lifecycle and route registration.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>

#include <drogon/drogon.h>
#include <drogon/HttpAppFramework.h>

#include "r_bridge.h"

#include <atomic>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace drogonR {

// --- Wakeup pipe / dispatcher hooks ---------------------------------------
void   initQueueWakeup(int readFd, int writeFd);
void   resetQueueWakeup();
void   registerDispatcherFd(int readFd);
void   unregisterDispatcherFd();
void   requireLaterInitializedExternal();
extern std::atomic<int> g_wakeReadFd_unused; // silence linker if unused

// --- Route table ----------------------------------------------------------
struct Route {
    std::string method;
    std::string path;
    SEXP        handler;   // R closure, kept alive via R_PreserveObject
};

namespace {
std::vector<Route>      g_routes;
std::mutex              g_routesMutex;
std::atomic<bool>       g_running{false};
std::atomic<bool>       g_everStarted{false};
std::thread             g_drogonThread;
int                     g_wakePipe[2] = {-1, -1};
} // namespace

const Route *getRoute(int id) {
    std::lock_guard<std::mutex> lock(g_routesMutex);
    if (id < 0 || id >= static_cast<int>(g_routes.size())) return nullptr;
    return &g_routes[id];
}

// Build a Drogon handler that captures the route id and forwards to the
// R dispatcher via the queue. Runs on a Drogon I/O thread.
static void installDrogonHandler(const Route &r, int route_id) {
    drogon::HttpMethod method = drogon::Get;
    if      (r.method == "GET")     method = drogon::Get;
    else if (r.method == "POST")    method = drogon::Post;
    else if (r.method == "PUT")     method = drogon::Put;
    else if (r.method == "DELETE")  method = drogon::Delete;
    else if (r.method == "PATCH")   method = drogon::Patch;
    else if (r.method == "HEAD")    method = drogon::Head;
    else if (r.method == "OPTIONS") method = drogon::Options;

    drogon::app().registerHandler(
        r.path,
        [route_id](const drogon::HttpRequestPtr &req,
                   std::function<void(const drogon::HttpResponsePtr &)> &&cb)
        {
            PendingRequest pr;
            pr.method   = req->methodString();
            pr.path     = std::string(req->path());
            pr.body     = std::string(req->body());
            for (const auto &h : req->headers()) {
                pr.headers.emplace_back(h.first, h.second);
            }
            for (const auto &q : req->getParameters()) {
                pr.queries.emplace_back(q.first, q.second);
            }
            pr.respond  = std::move(cb);
            pr.route_id = route_id;
            if (!enqueueRequest(std::move(pr))) {
                // Queue full — shed load with 503 directly from the
                // I/O thread. The dispatcher / R never sees this
                // request, so there is no R-side overhead under
                // overload.
                auto resp = drogon::HttpResponse::newHttpResponse();
                resp->setStatusCode(drogon::k503ServiceUnavailable);
                resp->setBody("503 Service Unavailable: request "
                              "queue is full");
                pr.respond(resp);
            }
        },
        {method});
}

} // namespace drogonR


// --- C entry points -------------------------------------------------------

extern "C" {

SEXP drogonR_register_route(SEXP method_, SEXP path_, SEXP handler_) {
    if (drogonR::g_running.load()) {
        Rf_error("dr_register_route: cannot register routes while the "
                 "server is running. Stop it first with dr_stop().");
    }
    if (TYPEOF(method_)  != STRSXP || LENGTH(method_)  != 1)
        Rf_error("method must be a single string");
    if (TYPEOF(path_)    != STRSXP || LENGTH(path_)    != 1)
        Rf_error("path must be a single string");
    if (TYPEOF(handler_) != CLOSXP)
        Rf_error("handler must be a function");

    drogonR::Route r;
    r.method  = CHAR(STRING_ELT(method_, 0));
    r.path    = CHAR(STRING_ELT(path_, 0));
    r.handler = handler_;
    R_PreserveObject(r.handler);

    int id;
    {
        std::lock_guard<std::mutex> lock(drogonR::g_routesMutex);
        id = static_cast<int>(drogonR::g_routes.size());
        drogonR::g_routes.push_back(std::move(r));
    }
    return Rf_ScalarInteger(id);
}

SEXP drogonR_clear_routes(void) {
    if (drogonR::g_running.load()) {
        Rf_error("dr_clear_routes: cannot clear routes while the "
                 "server is running. Stop it first with dr_stop().");
    }
    std::lock_guard<std::mutex> lock(drogonR::g_routesMutex);
    for (auto &r : drogonR::g_routes) {
        if (r.handler != R_NilValue) R_ReleaseObject(r.handler);
    }
    drogonR::g_routes.clear();
    return R_NilValue;
}

SEXP drogonR_server_running(void) {
    return Rf_ScalarLogical(drogonR::g_running.load() ? TRUE : FALSE);
}

// Called from each mcparallel() worker child immediately after fork. The
// parent R session may have already called dr_serve()/dr_stop() during
// earlier tests or interactive use; that flips g_everStarted to true and
// the flag is copied into every fork()-ed worker. Without this reset the
// worker's drogonR_server_start() trips the "cannot be restarted in the
// same R session" guard and exits before Drogon ever binds. The supervisor
// itself never calls this — it must keep the guard, since it really is
// the same session.
SEXP drogonR_reset_fork_state(void) {
    drogonR::g_running.store(false);
    drogonR::g_everStarted.store(false);
    return R_NilValue;
}

SEXP drogonR_server_start(SEXP port_, SEXP threads_, SEXP upload_path_,
                          SEXP max_queue_) {
    drogonR::requireLaterInitializedExternal();
    if (drogonR::g_running.load()) {
        Rf_error("server is already running");
    }
    if (drogonR::g_everStarted.load()) {
        Rf_error("drogonR: Drogon cannot be restarted in the same R "
                 "session. Please restart R.");
    }
    if (TYPEOF(port_) != INTSXP    || LENGTH(port_)    != 1)
        Rf_error("port must be a single integer");
    if (TYPEOF(threads_) != INTSXP || LENGTH(threads_) != 1)
        Rf_error("threads must be a single integer");
    if (TYPEOF(upload_path_) != STRSXP || LENGTH(upload_path_) != 1)
        Rf_error("upload_path must be a single string");
    if (TYPEOF(max_queue_) != INTSXP || LENGTH(max_queue_) != 1)
        Rf_error("max_queue must be a single integer");

    int port      = INTEGER(port_)[0];
    int threads   = INTEGER(threads_)[0];
    int max_queue = INTEGER(max_queue_)[0];
    if (port <= 0 || port > 65535) Rf_error("port must be in 1..65535");
    if (threads < 1)               Rf_error("threads must be >= 1");
    if (max_queue < 1)             Rf_error("max_queue must be >= 1");

    const char *upload_path = CHAR(STRING_ELT(upload_path_, 0));

    if (::pipe(drogonR::g_wakePipe) != 0) {
        Rf_error("failed to create wakeup pipe");
    }
    // Non-blocking on both ends so reads/writes never stall the I/O threads.
    ::fcntl(drogonR::g_wakePipe[0], F_SETFL, O_NONBLOCK);
    ::fcntl(drogonR::g_wakePipe[1], F_SETFL, O_NONBLOCK);

    drogonR::initQueueWakeup(drogonR::g_wakePipe[0], drogonR::g_wakePipe[1]);
    drogonR::registerDispatcherFd(drogonR::g_wakePipe[0]);
    drogonR::setQueueMaxSize(static_cast<std::size_t>(max_queue));

    // Install all currently-registered routes into Drogon.
    {
        std::lock_guard<std::mutex> lock(drogonR::g_routesMutex);
        for (size_t i = 0; i < drogonR::g_routes.size(); ++i) {
            drogonR::installDrogonHandler(drogonR::g_routes[i],
                                          static_cast<int>(i));
        }
    }

    drogon::app().setThreadNum(threads);
    drogon::app().setUploadPath(upload_path);
    // SO_REUSEPORT lets multi-process workers share the same port; harmless
    // for single-process serve (kernel just doesn't load-balance anything).
    drogon::app().enableReusePort(true);

    // Drogon's main EventLoop is a function-local static (eventfd + timerfd
    // on Linux). If anything in the supervisor touched drogon::app() before
    // mcparallel() forked us — even indirectly via static initializers in
    // the package's shared library — those fds are inherited and shared
    // across all workers. The symptom is a flaky failure where one worker
    // out of N binds the SO_REUSEPORT socket but never enters LISTEN,
    // because its runInLoop() task that calls Acceptor::listen() is lost
    // to a wakeup race. Drogon does the same reset internally in daemon /
    // relaunch-on-error mode; we have to do it ourselves because the fork
    // happens outside Drogon.
#ifdef __linux__
    drogon::app().getLoop()->resetTimerQueue();
#endif
    drogon::app().getLoop()->resetAfterFork();

    drogon::app().addListener("0.0.0.0", port);

    drogonR::g_running.store(true);
    drogonR::g_everStarted.store(true);
    drogonR::g_drogonThread = std::thread([]() {
        drogon::app().run();
    });

    return R_NilValue;
}

SEXP drogonR_server_stop(void) {
    if (!drogonR::g_running.load()) {
        return R_NilValue;
    }
    drogon::app().quit();
    if (drogonR::g_drogonThread.joinable()) {
        drogonR::g_drogonThread.join();
    }
    drogonR::g_running.store(false);

    drogonR::unregisterDispatcherFd();
    drogonR::resetQueueWakeup();
    drogonR::setQueueMaxSize(0);

    if (drogonR::g_wakePipe[0] >= 0) ::close(drogonR::g_wakePipe[0]);
    if (drogonR::g_wakePipe[1] >= 0) ::close(drogonR::g_wakePipe[1]);
    drogonR::g_wakePipe[0] = drogonR::g_wakePipe[1] = -1;

    return R_NilValue;
}

} // extern "C"
