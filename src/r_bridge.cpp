// drogonR — entry-point registration with R.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <drogon/drogon.h>
#include <drogon/version.h>

#include "r_bridge.h"
#include "json_writer.h"

// Forward — defined in r_dispatcher.cpp. We avoid including <later_api.h>
// anywhere in the package: it instantiates a static initializer that
// would resolve later::execLaterNative2 at DLL-load time, which races
// R CMD check phases that load our namespace before later's DLL.
extern "C" SEXP drogonR_init_later(void);

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
    {"drogonR_init_later",      (DL_FUNC) &drogonR_init_later,      0},
    {"drogonR_server_start",    (DL_FUNC) &drogonR_server_start,    5},
    {"drogonR_server_stop",     (DL_FUNC) &drogonR_server_stop,     0},
    {"drogonR_server_running",  (DL_FUNC) &drogonR_server_running,  0},
    {"drogonR_reset_fork_state",(DL_FUNC) &drogonR_reset_fork_state,0},
    {"drogonR_register_route",     (DL_FUNC) &drogonR_register_route,     5},
    {"drogonR_register_static",    (DL_FUNC) &drogonR_register_static,    2},
    {"drogonR_register_rate_limits", (DL_FUNC) &drogonR_register_rate_limits, 1},
    {"drogonR_resolve_ccallable",  (DL_FUNC) &drogonR_resolve_ccallable,  2},
    {"drogonR_register_cpp_route", (DL_FUNC) &drogonR_register_cpp_route, 5},
    {"drogonR_register_cpp_stream_route",
        (DL_FUNC) &drogonR_register_cpp_stream_route, 6},
    {"drogonR_clear_routes",       (DL_FUNC) &drogonR_clear_routes,       0},
    {"drogonR_to_json",         (DL_FUNC) &drogonR_to_json,         2},
    {NULL, NULL, 0}
};

void R_init_drogonR(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    // Cast: <windows.h> (pulled in transitively by drogon/drogon.h on Windows)
    // defines FALSE as an int macro, which gcc13 rejects when passed where
    // Rboolean is expected.
    R_useDynamicSymbols(dll, (Rboolean) FALSE);
}

} // extern "C"
