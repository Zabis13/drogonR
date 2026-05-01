// drogonR — R-side dispatcher.
//
// Runs entirely on the main R thread. Triggered by `later::later_fd()`
// when the wakeup pipe has data; drains the queue in one go; for each
// request: invokes the R closure, builds an HTTP response, calls
// Drogon's response callback. R errors are converted to HTTP 500 so
// the client connection never hangs.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Visibility.h>

#include <drogon/HttpResponse.h>
#include <drogon/HttpTypes.h>

#include <later.h>
// later_api.h's static initializer is intentionally instantiated only
// in r_bridge.cpp; here we only need the function declarations.

#include "r_bridge.h"

#include <deque>
#include <poll.h>
#include <string>
#include <strings.h>
#include <utility>

namespace drogonR {

// Provided by request_queue.cpp / drogon_server.cpp
std::deque<PendingRequest> drainQueue();
void                       drainWakePipe();
const struct Route        *getRoute(int id);
struct Route { std::string method; std::string path; SEXP handler; };

// Forward
static void runDispatcher(int * /*event_flags*/, void *data);

namespace {
int g_dispatcherFd = -1;

// Build a default 500 response with a short reason. Used when the R
// handler errors out or returns a malformed value.
drogon::HttpResponsePtr makeErrorResponse(const std::string &reason) {
    auto resp = drogon::HttpResponse::newHttpResponse();
    resp->setStatusCode(drogon::k500InternalServerError);
    resp->setContentTypeCode(drogon::CT_TEXT_PLAIN);
    resp->setBody(reason);
    return resp;
}

// Try to interpret an R object as the response: list(status=, body=, headers=)
// or a single string body (status defaults to 200).
drogon::HttpResponsePtr buildResponse(SEXP r_value) {
    auto resp = drogon::HttpResponse::newHttpResponse();
    resp->setStatusCode(drogon::k200OK);

    if (TYPEOF(r_value) == STRSXP && LENGTH(r_value) == 1) {
        resp->setBody(std::string(CHAR(STRING_ELT(r_value, 0))));
        resp->setContentTypeCode(drogon::CT_TEXT_PLAIN);
        return resp;
    }

    if (TYPEOF(r_value) != VECSXP) {
        return makeErrorResponse("R handler returned an unsupported value");
    }

    SEXP names = Rf_getAttrib(r_value, R_NamesSymbol);
    if (TYPEOF(names) != STRSXP) {
        return makeErrorResponse("R handler returned an unnamed list");
    }

    int n = LENGTH(r_value);
    SEXP s_body = R_NilValue, s_status = R_NilValue, s_headers = R_NilValue;
    for (int i = 0; i < n; ++i) {
        const char *nm = CHAR(STRING_ELT(names, i));
        SEXP v = VECTOR_ELT(r_value, i);
        if      (std::string(nm) == "status")  s_status  = v;
        else if (std::string(nm) == "body")    s_body    = v;
        else if (std::string(nm) == "headers") s_headers = v;
    }

    if (s_status != R_NilValue) {
        int code = 0;
        if      (TYPEOF(s_status) == INTSXP)  code = INTEGER(s_status)[0];
        else if (TYPEOF(s_status) == REALSXP) code = (int) REAL(s_status)[0];
        if (code >= 100 && code <= 599) {
            resp->setStatusCode(static_cast<drogon::HttpStatusCode>(code));
        }
    }

    if (s_body != R_NilValue) {
        if (TYPEOF(s_body) == STRSXP && LENGTH(s_body) >= 1) {
            resp->setBody(std::string(CHAR(STRING_ELT(s_body, 0))));
        } else if (TYPEOF(s_body) == RAWSXP) {
            resp->setBody(std::string(reinterpret_cast<const char *>(RAW(s_body)),
                                      LENGTH(s_body)));
        }
    }

    if (s_headers != R_NilValue && TYPEOF(s_headers) == VECSXP) {
        SEXP hnames = Rf_getAttrib(s_headers, R_NamesSymbol);
        if (TYPEOF(hnames) == STRSXP) {
            int hn = LENGTH(s_headers);
            for (int i = 0; i < hn; ++i) {
                SEXP hv = VECTOR_ELT(s_headers, i);
                if (TYPEOF(hv) != STRSXP || LENGTH(hv) < 1) continue;
                const char *hname = CHAR(STRING_ELT(hnames, i));
                const char *hval  = CHAR(STRING_ELT(hv, 0));
                // Content-Type goes through the dedicated setter so
                // Drogon doesn't append its own default text/html.
                if (strcasecmp(hname, "Content-Type") == 0) {
                    resp->setContentTypeString(hval);
                } else {
                    resp->addHeader(hname, hval);
                }
            }
        }
    }

    return resp;
}

// Build the call object: handler(req_list). The req_list is a named
// list with method/path/body/headers/query/params, classed
// `drogon_request` so the public accessors (dr_header/dr_query/dr_body)
// recognise it without an R-side conversion step. The class is set in
// C++ — never via an R-side wrapper after return — so a route with no
// middleware can call `handler(req_list)` directly with no extra
// Rf_applyClosure on the hot path.
SEXP buildRequestList(const PendingRequest &pr) {
    SEXP out   = PROTECT(Rf_allocVector(VECSXP, 6));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 6));

    SET_STRING_ELT(names, 0, Rf_mkChar("method"));
    SET_STRING_ELT(names, 1, Rf_mkChar("path"));
    SET_STRING_ELT(names, 2, Rf_mkChar("body"));
    SET_STRING_ELT(names, 3, Rf_mkChar("headers"));
    SET_STRING_ELT(names, 4, Rf_mkChar("query"));
    SET_STRING_ELT(names, 5, Rf_mkChar("params"));

    SET_VECTOR_ELT(out, 0, Rf_mkString(pr.method.c_str()));
    SET_VECTOR_ELT(out, 1, Rf_mkString(pr.path.c_str()));
    SET_VECTOR_ELT(out, 2, Rf_mkString(pr.body.c_str()));

    int nh = static_cast<int>(pr.headers.size());
    SEXP h    = PROTECT(Rf_allocVector(STRSXP, nh));
    SEXP hnms = PROTECT(Rf_allocVector(STRSXP, nh));
    for (int i = 0; i < nh; ++i) {
        SET_STRING_ELT(hnms, i, Rf_mkChar(pr.headers[i].first.c_str()));
        SET_STRING_ELT(h,    i, Rf_mkChar(pr.headers[i].second.c_str()));
    }
    Rf_setAttrib(h, R_NamesSymbol, hnms);
    SET_VECTOR_ELT(out, 3, h);

    int nq = static_cast<int>(pr.queries.size());
    SEXP q    = PROTECT(Rf_allocVector(STRSXP, nq));
    SEXP qnms = PROTECT(Rf_allocVector(STRSXP, nq));
    for (int i = 0; i < nq; ++i) {
        SET_STRING_ELT(qnms, i, Rf_mkChar(pr.queries[i].first.c_str()));
        SET_STRING_ELT(q,    i, Rf_mkChar(pr.queries[i].second.c_str()));
    }
    Rf_setAttrib(q, R_NamesSymbol, qnms);
    SET_VECTOR_ELT(out, 4, q);

    // params — empty list (path parameters not yet implemented; kept
    // present so user code reading req$params doesn't have to special-
    // case NULL between fast-path and slow-path).
    SET_VECTOR_ELT(out, 5, Rf_allocVector(VECSXP, 0));

    Rf_setAttrib(out, R_NamesSymbol, names);
    SEXP cls = PROTECT(Rf_mkString("drogon_request"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(7);
    return out;
}

// Wrapper for R_tryEval signal: invoke handler(req).
SEXP callHandlerSafely(SEXP handler, SEXP req_list, int *errorOccurred) {
    SEXP call = PROTECT(Rf_lang2(handler, req_list));
    SEXP res  = R_tryEval(call, R_GlobalEnv, errorOccurred);
    UNPROTECT(1);
    return res;
}
} // namespace

void registerDispatcherFd(int readFd) {
    g_dispatcherFd = readFd;

    // Initialize later (no-op call to ensure the symbol is loaded).
    later::later_fd(NULL, NULL, 0, NULL, 0);

    // Arm the first wait. The callback will re-arm itself on each fire.
    static struct pollfd pfd;
    pfd.fd      = g_dispatcherFd;
    pfd.events  = POLLIN;
    pfd.revents = 0;
    later::later_fd(runDispatcher, NULL, 1, &pfd, /*secs*/ 600);
}

void unregisterDispatcherFd() {
    g_dispatcherFd = -1;
}

// Main dispatcher — runs on the R main thread when the wakeup pipe fires.
static void runDispatcher(int * /*event_flags*/, void * /*data*/) {
    if (g_dispatcherFd < 0) return;

    drainWakePipe();

    auto items = drainQueue();
    for (auto &pr : items) {
        SEXP handler = R_NilValue;
        const Route *r = getRoute(pr.route_id);
        if (r) handler = r->handler;

        drogon::HttpResponsePtr resp;

        if (TYPEOF(handler) != CLOSXP) {
            resp = makeErrorResponse("no handler registered for this route");
        } else {
            SEXP req_list = PROTECT(buildRequestList(pr));
            int  err      = 0;
            SEXP res      = R_tryEval(PROTECT(Rf_lang2(handler, req_list)),
                                      R_GlobalEnv, &err);
            UNPROTECT(1); // call

            if (err) {
                UNPROTECT(1); // req_list
                // Pull the R-side error message (set by R_tryEval) so the
                // 500 body matches what the R-side wrap_handler used to
                // produce ("R handler error: <msg>"). geterrmessage() is
                // a base-R closure; one extra Rf_applyClosure here is
                // fine — this is the error path, not the hot path.
                int gerr = 0;
                SEXP gcall = PROTECT(
                    Rf_lang1(Rf_install("geterrmessage")));
                SEXP gres  = R_tryEval(gcall, R_GlobalEnv, &gerr);
                std::string body = "R handler error: ";
                if (!gerr && TYPEOF(gres) == STRSXP && LENGTH(gres) >= 1) {
                    body += CHAR(STRING_ELT(gres, 0));
                } else {
                    body += "(unknown error)";
                }
                UNPROTECT(1); // gcall
                resp = makeErrorResponse(body);
            } else {
                PROTECT(res);
                resp = buildResponse(res);
                UNPROTECT(1); // res
                UNPROTECT(1); // req_list
            }
        }

        // Per the contract: callback must be invoked outside the protected
        // region, exactly once, even on error paths.
        try {
            pr.respond(resp);
        } catch (...) { /* Drogon callback should not throw, but be safe */ }
    }

    // Re-arm.
    static struct pollfd pfd;
    pfd.fd      = g_dispatcherFd;
    pfd.events  = POLLIN;
    pfd.revents = 0;
    later::later_fd(runDispatcher, NULL, 1, &pfd, /*secs*/ 600);
}

} // namespace drogonR
