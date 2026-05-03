// drogonR — server lifecycle and route registration.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <drogon/drogon.h>
#include <drogon/HttpAppFramework.h>
#include <drogon/RateLimiter.h>
#include <trantor/utils/ConcurrentTaskQueue.h>

#include "r_bridge.h"
#include "socket_compat.h"
#include "../inst/include/drogonR.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// drogonR-cpp-stream: TcpConnection/setUserCloseCallback live here.
#include <trantor/net/TcpConnection.h>

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
    std::string path;        // original user-facing path (for diagnostics)
    std::string regex;       // path translated to a Drogon regex
    std::vector<std::string> param_names;  // names matching regex captures
    SEXP        handler;     // R closure, kept alive via R_PreserveObject
};

struct StaticMount {
    std::string mount;       // URL prefix, e.g. "/assets" (no trailing slash)
    std::string dir;         // absolute directory on disk (canonical)
};

// Native (R-bypass) route. The `fn` pointer comes from
// R_GetCCallable("<package>", "<callable>") and is invoked on a
// Drogon worker thread (via drogon::async_run) so long handlers do
// not stall the I/O event loop.
struct CppRoute {
    std::string                method;
    std::string                path;
    std::string                regex;
    std::vector<std::string>   param_names;
    drogonr_unary_handler_t    fn;
};

// drogonR-cpp-stream: streaming variant of CppRoute. The backend
// pushes chunks via callbacks from drogonR.h; see Public ABI for
// the contract.
struct CppStreamRoute {
    std::string                method;
    std::string                path;
    std::string                regex;
    std::vector<std::string>   param_names;
    drogonr_stream_handler_t   fn;
    std::string                content_type;  // "" → "text/event-stream"
};

// Per-rule rate-limit configuration as registered from R via
// drogonR_register_rate_limits. Each rule may apply to many routes,
// and "scope" decides whether matched routes share one bucket
// ("global") or each gets its own ("per_route").
struct RateLimitRule {
    int                      capacity;
    double                   window;       // seconds
    drogon::RateLimiterType  type;
    bool                     global_scope; // true = "global", false = "per_route"
    std::vector<std::string> route_prefixes; // empty = match all routes
    // For global scope: a single shared limiter for every match. For
    // per_route: nullptr here; per-route limiters are built when the
    // route is installed.
    drogon::RateLimiterPtr   shared_limiter;
};

namespace {
std::vector<Route>            g_routes;
std::vector<CppRoute>         g_cppRoutes;
std::vector<CppStreamRoute>   g_cppStreamRoutes; // drogonR-cpp-stream
std::vector<StaticMount>      g_staticMounts;
std::vector<RateLimitRule>    g_rateLimitRules;
std::mutex                g_routesMutex;
std::atomic<bool>         g_running{false};
std::atomic<bool>         g_everStarted{false};
std::thread               g_drogonThread;
int                       g_wakePipe[2] = {-1, -1};

// Worker pool for native (R-bypass) handlers. Lazily created in
// drogonR_server_start so we don't hold worker threads alive when the
// server isn't running. Sized at 4 by default — enough to keep CPUs
// busy under typical inference workloads without dwarfing Drogon's
// own I/O pool. We can expose this as a dr_serve() arg later if
// users hit it as a bottleneck.
std::unique_ptr<trantor::ConcurrentTaskQueue> g_cppWorkerPool;
} // namespace

const Route *getRoute(int id) {
    std::lock_guard<std::mutex> lock(g_routesMutex);
    if (id < 0 || id >= static_cast<int>(g_routes.size())) return nullptr;
    return &g_routes[id];
}

// Escape regex metacharacters in a literal URL prefix. We hand the
// prefix to registerHandlerViaRegex below, so a mount of "/v1.0/assets"
// must become "/v1\.0/assets" or '.' would match any character.
static std::string escapeRegex(const std::string &s) {
    static const std::string special = R"(\.+*?()[]{}|^$)";
    std::string out;
    out.reserve(s.size() * 2);
    for (char c : s) {
        if (special.find(c) != std::string::npos) out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

// Resolve a relative path against `dir` and reject any request that
// would escape `dir` after lexical normalisation. We do NOT touch the
// filesystem here — std::filesystem::weakly_canonical would, and that
// turns missing files into 404 below instead of an unconditional 403.
// The check is purely lexical: join, normalize, then verify the
// normalized result still starts with the canonical mount dir + '/'.
//
// Drogon already URL-decodes routing parameters, so a request like
// %2e%2e/secret arrives as "../secret" here. We also reject absolute
// paths and embedded NULs defensively.
static bool resolveSafely(const std::string &dir,
                          const std::string &rel,
                          std::string &out) {
    if (rel.find('\0') != std::string::npos) return false;
    namespace fs = std::filesystem;
    fs::path rel_p(rel);
    if (rel_p.is_absolute()) return false;
    fs::path joined = fs::path(dir) / rel_p;
    fs::path normalized = joined.lexically_normal();
    std::string norm_str = normalized.string();
    std::string dir_str  = fs::path(dir).lexically_normal().string();
    // Strip any trailing slash from dir for a clean prefix compare.
    while (!dir_str.empty() && dir_str.back() == '/') dir_str.pop_back();
    if (norm_str.size() <= dir_str.size() ||
        norm_str.compare(0, dir_str.size(), dir_str) != 0 ||
        norm_str[dir_str.size()] != '/') {
        return false;
    }
    out = std::move(norm_str);
    return true;
}

// Mount a directory of static files at `mount`. Drogon's
// HttpResponse::newFileResponse handles MIME detection, Range
// requests, and 404 on missing files; we only have to gate path
// traversal up front.
static void installStaticMount(const StaticMount &sm) {
    std::string regex = "^" + escapeRegex(sm.mount) + "/(.*)$";
    std::string dir   = sm.dir;
    drogon::app().registerHandlerViaRegex(
        regex,
        [dir](const drogon::HttpRequestPtr &req,
              std::function<void(const drogon::HttpResponsePtr &)> &&cb)
        {
            const auto &params = req->getRoutingParameters();
            std::string rel = params.empty() ? std::string() : params[0];
            std::string full;
            if (!resolveSafely(dir, rel, full)) {
                auto resp = drogon::HttpResponse::newHttpResponse();
                resp->setStatusCode(drogon::k403Forbidden);
                resp->setContentTypeCode(drogon::CT_TEXT_PLAIN);
                resp->setBody("403 Forbidden");
                cb(resp);
                return;
            }
            // newFileResponse returns a 404 response when the file
            // does not exist or is unreadable, so we don't pre-check.
            auto resp = drogon::HttpResponse::newFileResponse(full);
            cb(resp);
        },
        {drogon::Get, drogon::Head});
}

// Bundle of (limiters, conservative Retry-After hint) for one route.
struct RouteLimiters {
    std::vector<drogon::RateLimiterPtr> limiters;
    double                              max_window = 0.0;
    bool empty() const { return limiters.empty(); }
};

// Build the rate-limiter list that applies to a given route path.
// For each rule in g_rateLimitRules:
//   - if route_prefixes is empty OR path starts with any prefix, the
//     rule applies;
//   - global scope shares one limiter across all matched routes;
//   - per-route scope creates a fresh limiter for this route only.
// Called once per route at install time, on the main R thread under
// no concurrent registration — no locking needed for g_rateLimitRules.
static RouteLimiters buildLimitersForPath(const std::string &path) {
    RouteLimiters out;
    for (auto &rule : g_rateLimitRules) {
        bool match = rule.route_prefixes.empty();
        if (!match) {
            for (const auto &pfx : rule.route_prefixes) {
                if (path.size() >= pfx.size() &&
                    path.compare(0, pfx.size(), pfx) == 0) {
                    match = true;
                    break;
                }
            }
        }
        if (!match) continue;
        if (rule.global_scope) {
            // Shared limiter constructed lazily the first time we see
            // a match. SafeRateLimiter wraps the underlying limiter
            // with a mutex — needed because Drogon I/O threads call
            // isAllowed() concurrently.
            if (!rule.shared_limiter) {
                auto base = drogon::RateLimiter::newRateLimiter(
                    rule.type,
                    static_cast<size_t>(rule.capacity),
                    std::chrono::duration<double>(rule.window));
                rule.shared_limiter =
                    std::make_shared<drogon::SafeRateLimiter>(base);
            }
            out.limiters.push_back(rule.shared_limiter);
        } else {
            auto base = drogon::RateLimiter::newRateLimiter(
                rule.type,
                static_cast<size_t>(rule.capacity),
                std::chrono::duration<double>(rule.window));
            out.limiters.push_back(
                std::make_shared<drogon::SafeRateLimiter>(base));
        }
        if (rule.window > out.max_window) out.max_window = rule.window;
    }
    return out;
}

// Build the 429 response sent when any limiter in the per-route list
// rejects a request. Uses the longest window across the matched
// rules as the Retry-After hint — conservative but informative.
static drogon::HttpResponsePtr makeRateLimitResponse(double retry_after_s) {
    auto resp = drogon::HttpResponse::newHttpResponse();
    resp->setStatusCode(drogon::k429TooManyRequests);
    resp->setContentTypeCode(drogon::CT_TEXT_PLAIN);
    resp->setBody("429 Too Many Requests");
    int secs = (retry_after_s > 0.0) ? (int) std::ceil(retry_after_s) : 1;
    resp->addHeader("Retry-After", std::to_string(secs));
    return resp;
}

// Check the per-route limiter list. If any rejects, populate `resp`
// with a 429 and return false (caller must invoke cb(resp) and bail).
static bool checkRateLimits(
    const std::vector<drogon::RateLimiterPtr> &limiters,
    double max_window,
    drogon::HttpResponsePtr &resp_out)
{
    for (const auto &lim : limiters) {
        if (!lim->isAllowed()) {
            resp_out = makeRateLimitResponse(max_window);
            return false;
        }
    }
    return true;
}

// Map an HTTP-method string to Drogon's enum. Defaults to GET if the
// caller hands in something unexpected — at the R layer we already
// validate, so this is just defensive.
static drogon::HttpMethod methodFromString(const std::string &m) {
    if (m == "GET")     return drogon::Get;
    if (m == "POST")    return drogon::Post;
    if (m == "PUT")     return drogon::Put;
    if (m == "DELETE")  return drogon::Delete;
    if (m == "PATCH")   return drogon::Patch;
    if (m == "HEAD")    return drogon::Head;
    if (m == "OPTIONS") return drogon::Options;
    return drogon::Get;
}

// Native (R-bypass) handler. The Drogon I/O thread captures the
// request snapshot and hands it off to a Drogon worker via
// async_run; the backend's C function then runs without ever
// touching R. Inference latency lives entirely outside the R
// dispatcher's control path.
static void installCppHandler(const CppRoute &r) {
    drogon::HttpMethod method = methodFromString(r.method);
    drogonr_unary_handler_t fn = r.fn;
    auto rl = buildLimitersForPath(r.path);

    drogon::app().registerHandlerViaRegex(
        r.regex,
        [fn, rl](const drogon::HttpRequestPtr &req,
             std::function<void(const drogon::HttpResponsePtr &)> &&cb)
        {
            if (!rl.empty()) {
                drogon::HttpResponsePtr deny;
                if (!checkRateLimits(rl.limiters, rl.max_window, deny)) {
                    cb(deny);
                    return;
                }
            }
            // Snapshot everything the handler needs onto the heap up
            // front. We move the snapshot + cb into the worker
            // closure so the Drogon I/O thread can return immediately
            // and start servicing the next connection.
            auto body    = std::make_shared<std::string>(req->body());
            auto query   = std::make_shared<std::string>(req->query());
            auto path_p  = std::make_shared<std::vector<std::string>>(
                                req->getRoutingParameters());
            auto headers = std::make_shared<std::vector<std::string>>();
            for (const auto &h : req->headers()) {
                headers->emplace_back(h.first);
                headers->emplace_back(h.second);
            }

            g_cppWorkerPool->runTaskInQueue([fn, body, query, path_p,
                                             headers,
                                             cb = std::move(cb)]() mutable {
                // Materialise the C-string arrays only here, on the
                // worker thread, so their backing pointers (into the
                // shared_ptr<vector<string>>) stay live for the
                // duration of the handler call.
                std::vector<const char*> path_ptrs;
                path_ptrs.reserve(path_p->size());
                for (const auto &s : *path_p) path_ptrs.push_back(s.c_str());

                std::vector<const char*> hdr_ptrs;
                hdr_ptrs.reserve(headers->size());
                for (const auto &s : *headers) hdr_ptrs.push_back(s.c_str());

                char  *out_body         = nullptr;
                size_t out_len          = 0;
                int    out_status       = 200;
                char  *out_content_type = nullptr;

                int rc = 0;
                try {
                    rc = fn(body->data(),  body->size(),
                            query->empty() ? nullptr : query->c_str(),
                            path_ptrs.empty() ? nullptr : path_ptrs.data(),
                            path_ptrs.size(),
                            hdr_ptrs.empty()  ? nullptr : hdr_ptrs.data(),
                            hdr_ptrs.size() / 2,
                            &out_body, &out_len,
                            &out_status,
                            &out_content_type);
                } catch (...) {
                    rc = -1;
                }

                auto resp = drogon::HttpResponse::newHttpResponse();
                if (rc != 0) {
                    // Backend signalled failure (or threw). Send a
                    // 500 with a fixed body — we cannot trust
                    // out_body in this case, but free it
                    // defensively if it was allocated before the
                    // failure.
                    if (out_body)         std::free(out_body);
                    if (out_content_type) std::free(out_content_type);
                    resp->setStatusCode(drogon::k500InternalServerError);
                    resp->setContentTypeCode(drogon::CT_TEXT_PLAIN);
                    resp->setBody("500 Internal Server Error: native "
                                  "backend returned non-zero");
                } else {
                    // setBody copies the bytes into the response, so
                    // we can free out_body right after.
                    if (out_body && out_len > 0) {
                        resp->setBody(std::string(out_body, out_len));
                    }
                    resp->setStatusCode(
                        static_cast<drogon::HttpStatusCode>(out_status));
                    if (out_content_type) {
                        resp->setContentTypeString(out_content_type);
                    } else {
                        resp->setContentTypeString("application/octet-stream");
                    }
                    if (out_body)         std::free(out_body);
                    if (out_content_type) std::free(out_content_type);
                }
                cb(resp);
            });
        },
        {method});
}

// drogonR-cpp-stream: per-request session state for a streaming
// cpp-handler. Lives on the heap, owned by a shared_ptr captured by
// every callback (the worker, the async-stream callback, the
// onClose callback). Released when the last reference goes away —
// typically after the backend's handler has returned and Drogon has
// drained any queued sends.
struct CppStreamSession {
    drogon::ResponseStreamPtr   stream;
    trantor::EventLoop         *loop = nullptr;
    std::mutex                  streamMutex;     // guards `stream`
    std::condition_variable     streamReady;     // signalled when stream != nullptr
    std::atomic<bool>           cancelled{false};
    std::atomic<bool>           closed{false};   // set once close() ran
};

} // namespace drogonR (close briefly so the C-ABI thunks can live
  // outside the namespace)

// drogonR-cpp-stream: thunks that satisfy the function-pointer types
// declared in <drogonR.h>. The session pointer is the C-ABI struct
// alias for drogonR::CppStreamSession (opaque on the backend side).
extern "C" {

// drogonR-cpp-stream: opaque ABI handle is a heap-allocated
// shared_ptr<CppStreamSession> "anchor". The worker-task that runs
// the backend owns it and deletes it after the backend returns —
// at that point queued send/close lambdas already hold their own
// shared_ptr copies via the captures below, so they keep `sess`
// alive until they execute on the Drogon I/O loop.
//
// Without the anchor, capturing a raw `sess.get()` in lambdas would
// not extend lifetime: the worker-task is the only shared owner of
// `sess`, and once it returns, the session is destroyed before the
// lambdas (still queued in queueInLoop) ever run — segfault on
// `sess->stream` access.

static int drogonR_cpp_stream_send(
    drogonr_stream_session_t *opaque,
    const char *data, size_t len)
{
    auto *anchor =
        reinterpret_cast<std::shared_ptr<drogonR::CppStreamSession>*>(opaque);
    if (!anchor) return -1;
    auto sess = *anchor;
    if (!sess) return -1;
    if (sess->cancelled.load(std::memory_order_acquire)) return -1;

    // Wait briefly for the async-stream callback to deliver the
    // stream pointer. In practice this is microseconds — Drogon
    // schedules the callback on the loop right after the response
    // is enqueued. Bail with -1 if cancelled while waiting.
    std::shared_ptr<std::string> buf;
    {
        std::unique_lock<std::mutex> lock(sess->streamMutex);
        if (!sess->stream) {
            sess->streamReady.wait_for(lock, std::chrono::seconds(5),
                [&sess]{
                    return sess->stream != nullptr ||
                           sess->cancelled.load(std::memory_order_acquire);
                });
        }
        if (sess->cancelled.load(std::memory_order_acquire)) return -1;
        if (!sess->stream) return -1; // timed out — treat as gone
        buf = std::make_shared<std::string>(data, len);
    }

    // Hop to the loop thread to call send(). We don't wait for the
    // result — the contract says "queued"; cancellation visibility
    // comes via the atomic flag on the next call. The lambda captures
    // `sess` by value (shared_ptr copy), keeping the session alive
    // until the loop runs the lambda — even after the worker-task
    // and its anchor are gone.
    sess->loop->queueInLoop([sess, buf]() {
        if (sess->stream && !sess->stream->send(*buf)) {
            sess->cancelled.store(true, std::memory_order_release);
        }
    });
    return 0;
}

static void drogonR_cpp_stream_close(drogonr_stream_session_t *opaque)
{
    auto *anchor =
        reinterpret_cast<std::shared_ptr<drogonR::CppStreamSession>*>(opaque);
    if (!anchor) return;
    auto sess = *anchor;
    if (!sess) return;
    bool was_open = false;
    if (sess->closed.compare_exchange_strong(was_open, true)) {
        sess->loop->queueInLoop([sess]() {
            if (sess->stream) {
                sess->stream->close();
                sess->stream.reset();
            }
        });
    }
}

static int drogonR_cpp_stream_is_cancelled(drogonr_stream_session_t *opaque)
{
    auto *anchor =
        reinterpret_cast<std::shared_ptr<drogonR::CppStreamSession>*>(opaque);
    if (!anchor) return 1;
    auto &sess = *anchor;
    if (!sess) return 1;
    return sess->cancelled.load(std::memory_order_acquire) ? 1 : 0;
}

} // extern "C"

namespace drogonR {

// drogonR-cpp-stream: install a streaming cpp-route. Same snapshot
// + worker-pool dispatch as installCppHandler, but the response is
// async-stream and the backend pushes via callbacks.
static void installCppStreamHandler(const CppStreamRoute &r) {
    drogon::HttpMethod method = methodFromString(r.method);
    drogonr_stream_handler_t fn = r.fn;
    std::string default_ct = r.content_type.empty()
                             ? std::string("text/event-stream")
                             : r.content_type;
    auto rl = buildLimitersForPath(r.path);

    drogon::app().registerHandlerViaRegex(
        r.regex,
        [fn, default_ct, rl](const drogon::HttpRequestPtr &req,
                         std::function<void(const drogon::HttpResponsePtr &)> &&cb)
        {
            if (!rl.empty()) {
                drogon::HttpResponsePtr deny;
                if (!checkRateLimits(rl.limiters, rl.max_window, deny)) {
                    cb(deny);
                    return;
                }
            }
            auto body    = std::make_shared<std::string>(req->body());
            auto query   = std::make_shared<std::string>(req->query());
            auto path_p  = std::make_shared<std::vector<std::string>>(
                                req->getRoutingParameters());
            auto headers = std::make_shared<std::vector<std::string>>();
            for (const auto &h : req->headers()) {
                headers->emplace_back(h.first);
                headers->emplace_back(h.second);
            }

            auto sess = std::make_shared<CppStreamSession>();

            // Hook the user-close callback so the backend's
            // is_cancelled() / send() see the disconnect promptly.
            // setUserCloseCallback runs on the drogon-loop thread,
            // same as the rest of the connection's lifecycle.
            if (auto conn = req->getConnectionPtr().lock()) {
                std::weak_ptr<CppStreamSession> weak = sess;
                conn->setUserCloseCallback(
                    [weak](const trantor::TcpConnectionPtr &) {
                        if (auto s = weak.lock()) {
                            s->cancelled.store(true,
                                std::memory_order_release);
                            // Wake any send() that's parked on the cv.
                            s->streamReady.notify_all();
                        }
                    });
            } else {
                sess->cancelled.store(true, std::memory_order_release);
            }

            // Build the async-stream response. Drogon delivers the
            // ResponseStreamPtr on the loop shortly after we hand the
            // response back via cb(resp). We stash it on the session
            // and signal any waiting send().
            auto resp = drogon::HttpResponse::newAsyncStreamResponse(
                [sess](drogon::ResponseStreamPtr s) mutable {
                    {
                        std::lock_guard<std::mutex> lock(sess->streamMutex);
                        sess->loop = trantor::EventLoop::getEventLoopOfCurrentThread();
                        sess->stream = std::move(s);
                    }
                    sess->streamReady.notify_all();
                },
                /*disableKickoffTimeout*/ true);
            resp->setStatusCode(drogon::k200OK);
            resp->setContentTypeString(default_ct);
            cb(resp);

            g_cppWorkerPool->runTaskInQueue(
                [fn, body, query, path_p, headers, sess]() mutable {
                    std::vector<const char*> path_ptrs;
                    path_ptrs.reserve(path_p->size());
                    for (const auto &s : *path_p) path_ptrs.push_back(s.c_str());

                    std::vector<const char*> hdr_ptrs;
                    hdr_ptrs.reserve(headers->size());
                    for (const auto &s : *headers) hdr_ptrs.push_back(s.c_str());

                    char *out_content_type = nullptr;

                    // Heap-allocated shared_ptr "anchor" handed to the
                    // backend as the opaque ABI handle. Send/close
                    // thunks dereference it to capture their own
                    // shared_ptr copy in the lambdas they post to the
                    // I/O loop, so the session outlives this worker
                    // task. The anchor itself is deleted right after
                    // the backend returns and we've issued the
                    // auto-close — by then any queued lambdas hold
                    // their own references.
                    auto *anchor =
                        new std::shared_ptr<CppStreamSession>(sess);
                    auto *opaque =
                        reinterpret_cast<drogonr_stream_session_t*>(anchor);

                    int rc = 0;
                    try {
                        rc = fn(body->data(), body->size(),
                                query->empty() ? nullptr : query->c_str(),
                                path_ptrs.empty() ? nullptr : path_ptrs.data(),
                                path_ptrs.size(),
                                hdr_ptrs.empty()  ? nullptr : hdr_ptrs.data(),
                                hdr_ptrs.size() / 2,
                                opaque,
                                &drogonR_cpp_stream_send,
                                &drogonR_cpp_stream_close,
                                &drogonR_cpp_stream_is_cancelled,
                                &out_content_type);
                    } catch (...) {
                        rc = -1;
                    }

                    if (out_content_type) {
                        // Per ABI we accept content_type from the
                        // backend, but Drogon already flushed the
                        // response headers when the first chunk went
                        // out. Free defensively; future revision can
                        // honour this if we delay the response head.
                        std::free(out_content_type);
                    }
                    if (rc != 0) {
                        LOG_WARN << "drogonR cpp-stream handler "
                                    "returned non-zero (" << rc << ")";
                    }
                    // Auto-close on return if the backend didn't.
                    drogonR_cpp_stream_close(opaque);
                    delete anchor;
                });
        },
        {method});
}

// Build a Drogon handler that captures the route id and forwards to the
// R dispatcher via the queue. Runs on a Drogon I/O thread.
static void installDrogonHandler(const Route &r, int route_id) {
    drogon::HttpMethod method = methodFromString(r.method);
    auto rl = buildLimitersForPath(r.path);

    drogon::app().registerHandlerViaRegex(
        r.regex,
        [route_id, rl](const drogon::HttpRequestPtr &req,
                   std::function<void(const drogon::HttpResponsePtr &)> &&cb)
        {
            if (!rl.empty()) {
                drogon::HttpResponsePtr deny;
                if (!checkRateLimits(rl.limiters, rl.max_window, deny)) {
                    cb(deny);
                    return;
                }
            }
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
            pr.path_params = req->getRoutingParameters();
            pr.respond  = std::move(cb);
            // drogonR patch: keep a weak-ref to the connection so a
            // streaming handler can hook its close event.
            pr.connection = req->getConnectionPtr();
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

SEXP drogonR_register_route(SEXP method_, SEXP path_, SEXP regex_,
                            SEXP param_names_, SEXP handler_) {
    if (drogonR::g_running.load()) {
        Rf_error("dr_register_route: cannot register routes while the "
                 "server is running. Stop it first with dr_stop().");
    }
    if (TYPEOF(method_)  != STRSXP || LENGTH(method_)  != 1)
        Rf_error("method must be a single string");
    if (TYPEOF(path_)    != STRSXP || LENGTH(path_)    != 1)
        Rf_error("path must be a single string");
    if (TYPEOF(regex_)   != STRSXP || LENGTH(regex_)   != 1)
        Rf_error("regex must be a single string");
    if (TYPEOF(param_names_) != STRSXP)
        Rf_error("param_names must be a character vector");
    if (TYPEOF(handler_) != CLOSXP)
        Rf_error("handler must be a function");

    drogonR::Route r;
    r.method  = CHAR(STRING_ELT(method_, 0));
    r.path    = CHAR(STRING_ELT(path_, 0));
    r.regex   = CHAR(STRING_ELT(regex_, 0));
    int npn = LENGTH(param_names_);
    r.param_names.reserve(npn);
    for (int i = 0; i < npn; ++i) {
        r.param_names.emplace_back(CHAR(STRING_ELT(param_names_, i)));
    }
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

SEXP drogonR_register_static(SEXP mount_, SEXP dir_) {
    if (drogonR::g_running.load()) {
        Rf_error("dr_register_static: cannot register mounts while the "
                 "server is running. Stop it first with dr_stop().");
    }
    if (TYPEOF(mount_) != STRSXP || LENGTH(mount_) != 1)
        Rf_error("mount must be a single string");
    if (TYPEOF(dir_)   != STRSXP || LENGTH(dir_)   != 1)
        Rf_error("dir must be a single string");

    drogonR::StaticMount sm;
    sm.mount = CHAR(STRING_ELT(mount_, 0));
    sm.dir   = CHAR(STRING_ELT(dir_, 0));
    {
        std::lock_guard<std::mutex> lock(drogonR::g_routesMutex);
        drogonR::g_staticMounts.push_back(std::move(sm));
    }
    return R_NilValue;
}

// Look up a C-callable registered by another package via
// R_RegisterCCallable("<package>", "<callable>", ...). Returns it
// wrapped in an R externalptr so the R layer can stash it on the
// `app` and ship it back to us at register time. We don't validate
// the type — the contract is that the callable matches
// drogonr_unary_handler_t; a wrong signature will manifest as a
// crash on first request, which is the same failure mode as a
// bad C-callable in any R package.
SEXP drogonR_resolve_ccallable(SEXP package_, SEXP callable_) {
    if (TYPEOF(package_)  != STRSXP || LENGTH(package_)  != 1)
        Rf_error("package must be a single string");
    if (TYPEOF(callable_) != STRSXP || LENGTH(callable_) != 1)
        Rf_error("callable must be a single string");
    const char *pkg = CHAR(STRING_ELT(package_, 0));
    const char *cal = CHAR(STRING_ELT(callable_, 0));
    DL_FUNC f = R_GetCCallable(pkg, cal);
    if (f == NULL) {
        Rf_error("R_GetCCallable returned NULL for %s::%s "
                 "(missing R_RegisterCCallable in the backend?)",
                 pkg, cal);
    }
    return R_MakeExternalPtr((void*) f, R_NilValue, R_NilValue);
}

SEXP drogonR_register_cpp_route(SEXP method_, SEXP path_, SEXP regex_,
                                SEXP param_names_, SEXP ptr_) {
    if (drogonR::g_running.load()) {
        Rf_error("dr_register_cpp_route: cannot register routes while "
                 "the server is running. Stop it first with dr_stop().");
    }
    if (TYPEOF(method_)  != STRSXP || LENGTH(method_)  != 1)
        Rf_error("method must be a single string");
    if (TYPEOF(path_)    != STRSXP || LENGTH(path_)    != 1)
        Rf_error("path must be a single string");
    if (TYPEOF(regex_)   != STRSXP || LENGTH(regex_)   != 1)
        Rf_error("regex must be a single string");
    if (TYPEOF(param_names_) != STRSXP)
        Rf_error("param_names must be a character vector");
    if (TYPEOF(ptr_) != EXTPTRSXP)
        Rf_error("ptr must be an external pointer to a "
                 "drogonr_unary_handler_t");

    void *raw = R_ExternalPtrAddr(ptr_);
    if (raw == NULL) {
        Rf_error("dr_register_cpp_route: external pointer is NULL "
                 "(callable was not resolved before serve)");
    }

    drogonR::CppRoute cr;
    cr.method = CHAR(STRING_ELT(method_, 0));
    cr.path   = CHAR(STRING_ELT(path_, 0));
    cr.regex  = CHAR(STRING_ELT(regex_, 0));
    int npn = LENGTH(param_names_);
    cr.param_names.reserve(npn);
    for (int i = 0; i < npn; ++i) {
        cr.param_names.emplace_back(CHAR(STRING_ELT(param_names_, i)));
    }
    cr.fn = reinterpret_cast<drogonr_unary_handler_t>(raw);
    {
        std::lock_guard<std::mutex> lock(drogonR::g_routesMutex);
        drogonR::g_cppRoutes.push_back(std::move(cr));
    }
    return R_NilValue;
}

// drogonR-cpp-stream: register a streaming cpp-route. Same shape as
// drogonR_register_cpp_route, plus an optional `content_type_` slot
// (NA_character_ → default "text/event-stream").
SEXP drogonR_register_cpp_stream_route(SEXP method_, SEXP path_, SEXP regex_,
                                       SEXP param_names_, SEXP ptr_,
                                       SEXP content_type_) {
    if (drogonR::g_running.load()) {
        Rf_error("dr_register_cpp_stream_route: cannot register routes "
                 "while the server is running. Stop it first with dr_stop().");
    }
    if (TYPEOF(method_)  != STRSXP || LENGTH(method_)  != 1)
        Rf_error("method must be a single string");
    if (TYPEOF(path_)    != STRSXP || LENGTH(path_)    != 1)
        Rf_error("path must be a single string");
    if (TYPEOF(regex_)   != STRSXP || LENGTH(regex_)   != 1)
        Rf_error("regex must be a single string");
    if (TYPEOF(param_names_) != STRSXP)
        Rf_error("param_names must be a character vector");
    if (TYPEOF(ptr_) != EXTPTRSXP)
        Rf_error("ptr must be an external pointer to a "
                 "drogonr_stream_handler_t");
    if (TYPEOF(content_type_) != STRSXP || LENGTH(content_type_) != 1)
        Rf_error("content_type must be a single string or NA");

    void *raw = R_ExternalPtrAddr(ptr_);
    if (raw == NULL) {
        Rf_error("dr_register_cpp_stream_route: external pointer is NULL "
                 "(callable was not resolved before serve)");
    }

    drogonR::CppStreamRoute cr;
    cr.method = CHAR(STRING_ELT(method_, 0));
    cr.path   = CHAR(STRING_ELT(path_, 0));
    cr.regex  = CHAR(STRING_ELT(regex_, 0));
    int npn = LENGTH(param_names_);
    cr.param_names.reserve(npn);
    for (int i = 0; i < npn; ++i) {
        cr.param_names.emplace_back(CHAR(STRING_ELT(param_names_, i)));
    }
    cr.fn = reinterpret_cast<drogonr_stream_handler_t>(raw);
    SEXP ct = STRING_ELT(content_type_, 0);
    if (ct != NA_STRING) cr.content_type = CHAR(ct);
    {
        std::lock_guard<std::mutex> lock(drogonR::g_routesMutex);
        drogonR::g_cppStreamRoutes.push_back(std::move(cr));
    }
    return R_NilValue;
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
    drogonR::g_cppRoutes.clear();
    drogonR::g_cppStreamRoutes.clear(); // drogonR-cpp-stream
    drogonR::g_staticMounts.clear();
    drogonR::g_rateLimitRules.clear();
    return R_NilValue;
}

// Bulk-replace the rate-limit rule table from the R-side list built by
// dr_rate_limit(). Called once per dr_serve() before route install so
// installDrogonHandler / installCppHandler / installCppStreamHandler can
// hand each route the limiters it needs.
//
// Expected SEXP layout: a list of named lists, each with elements
//   capacity (integer, >= 1)
//   window   (numeric, > 0)
//   type     (character: "sliding_window" | "fixed_window" | "token_bucket")
//   scope    (character: "per_route" | "global")
//   routes   (NULL or character vector of "/" prefixes)
// R-side dr_rate_limit() already validates these — we still defensively
// type-check here because anyone calling .Call() directly bypasses R.
SEXP drogonR_register_rate_limits(SEXP rules_) {
    if (drogonR::g_running.load()) {
        Rf_error("dr_register_rate_limits: cannot register rate limits "
                 "while the server is running. Stop it first with dr_stop().");
    }
    if (rules_ != R_NilValue && TYPEOF(rules_) != VECSXP) {
        Rf_error("rules must be a list or NULL");
    }
    drogonR::g_rateLimitRules.clear();
    if (rules_ == R_NilValue) return R_NilValue;

    R_xlen_t n = XLENGTH(rules_);
    drogonR::g_rateLimitRules.reserve(static_cast<size_t>(n));
    for (R_xlen_t i = 0; i < n; ++i) {
        SEXP rule = VECTOR_ELT(rules_, i);
        if (TYPEOF(rule) != VECSXP) {
            Rf_error("rules[[%lld]] must be a list", (long long)(i + 1));
        }
        SEXP cap_s   = Rf_getAttrib(rule, R_NamesSymbol);
        if (cap_s == R_NilValue) {
            Rf_error("rules[[%lld]] must be a named list", (long long)(i + 1));
        }
        SEXP capacity_ = R_NilValue, window_ = R_NilValue,
             type_    = R_NilValue, scope_  = R_NilValue,
             routes_  = R_NilValue;
        for (R_xlen_t j = 0; j < XLENGTH(rule); ++j) {
            const char *nm = CHAR(STRING_ELT(cap_s, j));
            SEXP val = VECTOR_ELT(rule, j);
            if      (strcmp(nm, "capacity") == 0) capacity_ = val;
            else if (strcmp(nm, "window")   == 0) window_   = val;
            else if (strcmp(nm, "type")     == 0) type_     = val;
            else if (strcmp(nm, "scope")    == 0) scope_    = val;
            else if (strcmp(nm, "routes")   == 0) routes_   = val;
        }
        if (capacity_ == R_NilValue || window_ == R_NilValue ||
            type_     == R_NilValue || scope_  == R_NilValue) {
            Rf_error("rules[[%lld]] missing required field "
                     "(capacity/window/type/scope)", (long long)(i + 1));
        }
        if ((TYPEOF(capacity_) != INTSXP && TYPEOF(capacity_) != REALSXP) ||
            LENGTH(capacity_) != 1)
            Rf_error("rules[[%lld]]$capacity must be a single number",
                     (long long)(i + 1));
        if (TYPEOF(window_) != REALSXP || LENGTH(window_) != 1)
            Rf_error("rules[[%lld]]$window must be a single numeric",
                     (long long)(i + 1));
        if (TYPEOF(type_) != STRSXP || LENGTH(type_) != 1)
            Rf_error("rules[[%lld]]$type must be a single string",
                     (long long)(i + 1));
        if (TYPEOF(scope_) != STRSXP || LENGTH(scope_) != 1)
            Rf_error("rules[[%lld]]$scope must be a single string",
                     (long long)(i + 1));

        drogonR::RateLimitRule rule_out;
        rule_out.capacity = (TYPEOF(capacity_) == INTSXP)
                            ? INTEGER(capacity_)[0]
                            : (int) REAL(capacity_)[0];
        rule_out.window   = REAL(window_)[0];
        const char *type_s  = CHAR(STRING_ELT(type_, 0));
        if      (strcmp(type_s, "sliding_window") == 0)
            rule_out.type = drogon::RateLimiterType::kSlidingWindow;
        else if (strcmp(type_s, "fixed_window") == 0)
            rule_out.type = drogon::RateLimiterType::kFixedWindow;
        else if (strcmp(type_s, "token_bucket") == 0)
            rule_out.type = drogon::RateLimiterType::kTokenBucket;
        else
            Rf_error("rules[[%lld]]$type unknown: %s",
                     (long long)(i + 1), type_s);
        const char *scope_s = CHAR(STRING_ELT(scope_, 0));
        if      (strcmp(scope_s, "global")    == 0) rule_out.global_scope = true;
        else if (strcmp(scope_s, "per_route") == 0) rule_out.global_scope = false;
        else Rf_error("rules[[%lld]]$scope unknown: %s",
                      (long long)(i + 1), scope_s);

        if (routes_ != R_NilValue) {
            if (TYPEOF(routes_) != STRSXP)
                Rf_error("rules[[%lld]]$routes must be NULL or a character vector",
                         (long long)(i + 1));
            R_xlen_t m = XLENGTH(routes_);
            rule_out.route_prefixes.reserve(static_cast<size_t>(m));
            for (R_xlen_t k = 0; k < m; ++k) {
                rule_out.route_prefixes.emplace_back(
                    CHAR(STRING_ELT(routes_, k)));
            }
        }
        drogonR::g_rateLimitRules.push_back(std::move(rule_out));
    }
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
                          SEXP max_queue_, SEXP cpp_workers_) {
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
    if (TYPEOF(cpp_workers_) != INTSXP || LENGTH(cpp_workers_) != 1)
        Rf_error("cpp_workers must be a single integer");

    int port        = INTEGER(port_)[0];
    int threads     = INTEGER(threads_)[0];
    int max_queue   = INTEGER(max_queue_)[0];
    int cpp_workers = INTEGER(cpp_workers_)[0];
    if (port <= 0 || port > 65535) Rf_error("port must be in 1..65535");
    if (threads < 1)               Rf_error("threads must be >= 1");
    if (max_queue < 1)             Rf_error("max_queue must be >= 1");
    if (cpp_workers < 1)           Rf_error("cpp_workers must be >= 1");

    const char *upload_path = CHAR(STRING_ELT(upload_path_, 0));

    // Non-blocking on both ends so reads/writes never stall the I/O threads.
    // On Windows this is a loopback TCP socketpair; on POSIX a plain pipe(2).
    if (drogonR::makeWakePipe(drogonR::g_wakePipe) != 0) {
        Rf_error("failed to create wakeup pipe");
    }

    drogonR::initQueueWakeup(drogonR::g_wakePipe[0], drogonR::g_wakePipe[1]);
    drogonR::registerDispatcherFd(drogonR::g_wakePipe[0]);
    drogonR::setQueueMaxSize(static_cast<std::size_t>(max_queue));

    // Spin up the native-handler worker pool unconditionally with
    // `cpp_workers` threads; idle threads are cheap, and starting it
    // up front keeps the start path branch-free even if the user
    // later registers a cpp route at runtime (currently disallowed,
    // but cheap to permit later).
    if (!drogonR::g_cppWorkerPool) {
        drogonR::g_cppWorkerPool =
            std::make_unique<trantor::ConcurrentTaskQueue>(
                static_cast<std::size_t>(cpp_workers), "drogonR-cpp");
    }

    // Install all currently-registered routes, native (cpp) routes
    // and static mounts into Drogon. Order matters: Drogon picks the
    // first registered handler whose regex matches. We register
    // R-side routes first (they're the most specific by construction
    // since `dr_get` paths are exact patterns), then native routes,
    // then static mounts (which use a `/<mount>/(.*)` catch-all and
    // would otherwise shadow more-specific dynamic routes mounted
    // beneath them).
    {
        std::lock_guard<std::mutex> lock(drogonR::g_routesMutex);
        for (size_t i = 0; i < drogonR::g_routes.size(); ++i) {
            drogonR::installDrogonHandler(drogonR::g_routes[i],
                                          static_cast<int>(i));
        }
        for (const auto &cr : drogonR::g_cppRoutes) {
            drogonR::installCppHandler(cr);
        }
        // drogonR-cpp-stream
        for (const auto &csr : drogonR::g_cppStreamRoutes) {
            drogonR::installCppStreamHandler(csr);
        }
        for (const auto &sm : drogonR::g_staticMounts) {
            drogonR::installStaticMount(sm);
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
    drogonR::clearAllStreamSessions();

    drogonR::closeWakeFd(drogonR::g_wakePipe[0]);
    drogonR::closeWakeFd(drogonR::g_wakePipe[1]);
    drogonR::g_wakePipe[0] = drogonR::g_wakePipe[1] = -1;

    // Drain & destroy the cpp worker pool. Its destructor blocks
    // until all enqueued tasks finish — by this point Drogon's
    // event loop has exited, so no new tasks will be enqueued, and
    // any in-flight ones can complete safely.
    drogonR::g_cppWorkerPool.reset();

    return R_NilValue;
}

} // extern "C"
