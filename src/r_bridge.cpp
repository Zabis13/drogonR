// drogonR — entry-point registration with R.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <drogon/drogon.h>
#include <drogon/version.h>

#include <later.h>

#include "r_bridge.h"
#include "json_writer.h"

extern "C" {

SEXP drogonR_smoke(void) {
    int threads = drogon::app().getThreadNum();
    return Rf_ScalarInteger(threads);
}

SEXP drogonR_drogon_version(void) {
    return Rf_mkString(DROGON_VERSION);
}

static const R_CallMethodDef CallEntries[] = {
    {"drogonR_smoke",           (DL_FUNC) &drogonR_smoke,           0},
    {"drogonR_drogon_version",  (DL_FUNC) &drogonR_drogon_version,  0},
    {"drogonR_server_start",    (DL_FUNC) &drogonR_server_start,    4},
    {"drogonR_server_stop",     (DL_FUNC) &drogonR_server_stop,     0},
    {"drogonR_server_running",  (DL_FUNC) &drogonR_server_running,  0},
    {"drogonR_reset_fork_state",(DL_FUNC) &drogonR_reset_fork_state,0},
    {"drogonR_register_route",  (DL_FUNC) &drogonR_register_route,  3},
    {"drogonR_clear_routes",    (DL_FUNC) &drogonR_clear_routes,    0},
    {"drogonR_to_json",         (DL_FUNC) &drogonR_to_json,         2},
    {NULL, NULL, 0}
};

void R_init_drogonR(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    // later's R_GetCCallable pointers are resolved lazily on first use;
    // see registerDispatcherFd() in r_dispatcher.cpp.
}

} // extern "C"
