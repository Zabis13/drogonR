#ifndef DROGONR_JSON_WRITER_H
#define DROGONR_JSON_WRITER_H

// drogonR — direct R → JSON serializer.
//
// Replaces a `jsonlite::toJSON()` call inside `dr_json()` for the common
// types we hit on every request (LGL/INT/REAL/STR/NULL/named or unnamed
// VECSXP). Anything we don't handle (factor, Date/POSIXct, RAW, S4,
// environments, deeply-nested lists) makes us return R_NilValue so the
// R-side caller can fall back to jsonlite. We never produce wrong JSON
// silently — output it ourselves only when we're confident.

#ifdef __cplusplus
extern "C" {
#endif

#include <Rinternals.h>

// Serialize x to JSON. auto_unbox_ is a length-1 LGLSXP — when TRUE,
// length-1 atomics inside a named-list value become JSON scalars
// instead of single-element arrays (matches jsonlite default in
// dr_json()).
//
// Returns a STRSXP of length 1 with the JSON text on success, or
// R_NilValue when we encountered a type or shape we don't handle.
SEXP drogonR_to_json(SEXP x, SEXP auto_unbox_);

#ifdef __cplusplus
}
#endif

#endif // DROGONR_JSON_WRITER_H
