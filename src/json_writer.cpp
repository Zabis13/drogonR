// drogonR — direct R → JSON serializer.
//
// Replaces jsonlite::toJSON() on the fast path of dr_json() for the
// common scalar/vector/named-list shapes that real REST handlers
// produce. Anything we are not 100% sure about (factor, Date,
// POSIXct, RAW, S4, environments, deeply nested lists, AsIs-classed
// scalars) is signalled by returning R_NilValue from drogonR_to_json
// — the R-side caller then falls back to jsonlite::toJSON, so the
// fast path never silently produces incorrect JSON.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>

#include "json_writer.h"

// Rinternals.h gives us ISNAN, ISNA, R_PosInf, R_NegInf via R.h.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace {

constexpr int kMaxDepth = 64;

// Result codes for the recursive walker. We use a tri-state instead of
// an exception — exceptions across the R↔C++ boundary are unsafe.
enum class WriteResult {
    Ok,         // emitted JSON for x
    Unsupported // bail out; caller falls back to jsonlite
};

// Detect "supported atomic" — i.e. an atomic vector with no class
// attribute that would change how jsonlite encodes it. Factors are
// INTSXP with class="factor"; Date/POSIXct are REALSXP/INTSXP with
// class set. We cheaply check for ANY class attribute and refuse — the
// fallback path handles those correctly.
bool hasClass(SEXP x) {
    SEXP cls = Rf_getAttrib(x, R_ClassSymbol);
    return cls != R_NilValue && Rf_length(cls) > 0;
}

// Append a JSON-escaped string literal (including surrounding quotes)
// to buf. Input is assumed to be valid UTF-8 (or 7-bit ASCII); we do
// not transcode — that matches jsonlite's behaviour when the string is
// already CE_UTF8/CE_NATIVE on a UTF-8 locale. Control characters
// (< 0x20), '"' and '\\' are escaped; everything else is passed
// through byte-wise.
void appendEscapedString(std::string &buf, const char *s, std::size_t n) {
    buf.push_back('"');
    for (std::size_t i = 0; i < n; ++i) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        switch (c) {
            case '"':  buf.append("\\\"", 2); break;
            case '\\': buf.append("\\\\", 2); break;
            case '\b': buf.append("\\b", 2);  break;
            case '\f': buf.append("\\f", 2);  break;
            case '\n': buf.append("\\n", 2);  break;
            case '\r': buf.append("\\r", 2);  break;
            case '\t': buf.append("\\t", 2);  break;
            default:
                if (c < 0x20) {
                    char esc[8];
                    std::snprintf(esc, sizeof(esc), "\\u%04x", c);
                    buf.append(esc, 6);
                } else {
                    buf.push_back(static_cast<char>(c));
                }
        }
    }
    buf.push_back('"');
}

// jsonlite default na-handling: NA_character_ → null; NA in any other
// atomic → the *string* "NA"; non-finite doubles → "NaN"/"Inf"/"-Inf"
// (also strings). We mirror that exactly so dr_json() output is
// byte-identical to jsonlite::toJSON() for inputs we handle.
void appendCharSEXP(std::string &buf, SEXP c) {
    if (c == NA_STRING) {
        buf.append("null", 4);
        return;
    }
    const char *s = CHAR(c);
    appendEscapedString(buf, s, std::strlen(s));
}

void appendDouble(std::string &buf, double v) {
    if (ISNA(v))             { buf.append("\"NA\"", 4);   return; }
    if (ISNAN(v))            { buf.append("\"NaN\"", 5);  return; }
    if (v == R_PosInf)       { buf.append("\"Inf\"", 5);  return; }
    if (v == R_NegInf)       { buf.append("\"-Inf\"", 6); return; }
    char tmp[32];
    int n = std::snprintf(tmp, sizeof(tmp), "%.17g", v);
    if (n > 0) buf.append(tmp, static_cast<std::size_t>(n));
}

void appendInt(std::string &buf, int v) {
    if (v == NA_INTEGER) {
        buf.append("\"NA\"", 4);
        return;
    }
    char tmp[16];
    int n = std::snprintf(tmp, sizeof(tmp), "%d", v);
    if (n > 0) buf.append(tmp, static_cast<std::size_t>(n));
}

void appendBool(std::string &buf, int v) {
    // jsonlite quirk: logical NA → JSON null in any context, even
    // though NA_integer_ / NA_real_ become the *string* "NA".
    if (v == NA_LOGICAL)      buf.append("null", 4);
    else if (v == 0)          buf.append("false", 5);
    else                      buf.append("true", 4);
}

// Forward declaration — recursive.
WriteResult writeValue(std::string &buf, SEXP x, bool autoUnbox, int depth);

// Atomic emitter. Honours autoUnbox at length 1.
WriteResult writeAtomic(std::string &buf, SEXP x, bool autoUnbox) {
    if (hasClass(x)) return WriteResult::Unsupported;
    R_xlen_t n = Rf_xlength(x);
    bool unbox = autoUnbox && n == 1;

    switch (TYPEOF(x)) {
        case LGLSXP: {
            const int *p = LOGICAL(x);
            if (unbox) { appendBool(buf, p[0]); return WriteResult::Ok; }
            buf.push_back('[');
            for (R_xlen_t i = 0; i < n; ++i) {
                if (i) buf.push_back(',');
                appendBool(buf, p[i]);
            }
            buf.push_back(']');
            return WriteResult::Ok;
        }
        case INTSXP: {
            const int *p = INTEGER(x);
            if (unbox) { appendInt(buf, p[0]); return WriteResult::Ok; }
            buf.push_back('[');
            for (R_xlen_t i = 0; i < n; ++i) {
                if (i) buf.push_back(',');
                appendInt(buf, p[i]);
            }
            buf.push_back(']');
            return WriteResult::Ok;
        }
        case REALSXP: {
            const double *p = REAL(x);
            if (unbox) { appendDouble(buf, p[0]); return WriteResult::Ok; }
            buf.push_back('[');
            for (R_xlen_t i = 0; i < n; ++i) {
                if (i) buf.push_back(',');
                appendDouble(buf, p[i]);
            }
            buf.push_back(']');
            return WriteResult::Ok;
        }
        case STRSXP: {
            if (unbox) { appendCharSEXP(buf, STRING_ELT(x, 0)); return WriteResult::Ok; }
            buf.push_back('[');
            for (R_xlen_t i = 0; i < n; ++i) {
                if (i) buf.push_back(',');
                appendCharSEXP(buf, STRING_ELT(x, i));
            }
            buf.push_back(']');
            return WriteResult::Ok;
        }
        default:
            return WriteResult::Unsupported;
    }
}

// VECSXP — named list → JSON object, unnamed list → JSON array.
WriteResult writeList(std::string &buf, SEXP x, bool autoUnbox, int depth) {
    if (hasClass(x)) {
        // data.frame, AsIs, posixlt etc. — fallback. Plain `list()`
        // has no class attribute so it passes through.
        return WriteResult::Unsupported;
    }
    // drogonR patch: protect nms across allocating writeValue calls (rchk)
    SEXP nms = PROTECT(Rf_getAttrib(x, R_NamesSymbol));
    R_xlen_t n = Rf_xlength(x);
    bool isObject = (nms != R_NilValue && TYPEOF(nms) == STRSXP &&
                     Rf_xlength(nms) == n);

    if (isObject) {
        buf.push_back('{');
        for (R_xlen_t i = 0; i < n; ++i) {
            if (i) buf.push_back(',');
            SEXP key = STRING_ELT(nms, i);
            // jsonlite drops "" / NA names by silently using empty
            // strings — we don't want to silently disagree, so any
            // missing name kicks us to fallback.
            if (key == NA_STRING) { UNPROTECT(1); return WriteResult::Unsupported; }
            const char *ks = CHAR(key);
            if (ks[0] == '\0') { UNPROTECT(1); return WriteResult::Unsupported; }
            appendEscapedString(buf, ks, std::strlen(ks));
            buf.push_back(':');
            WriteResult r = writeValue(buf, VECTOR_ELT(x, i),
                                       autoUnbox, depth + 1);
            if (r != WriteResult::Ok) { UNPROTECT(1); return r; }
        }
        buf.push_back('}');
        UNPROTECT(1);
        return WriteResult::Ok;
    }
    // Unnamed (or partially named — we treat partial-naming as
    // unsupported, since the layout differs between jsonlite and what
    // we'd emit; conservatively bail).
    if (nms != R_NilValue) { UNPROTECT(1); return WriteResult::Unsupported; }
    UNPROTECT(1);  // drogonR patch: nms no longer needed past this point
    buf.push_back('[');
    for (R_xlen_t i = 0; i < n; ++i) {
        if (i) buf.push_back(',');
        WriteResult r = writeValue(buf, VECTOR_ELT(x, i),
                                   autoUnbox, depth + 1);
        if (r != WriteResult::Ok) return r;
    }
    buf.push_back(']');
    return WriteResult::Ok;
}

WriteResult writeValue(std::string &buf, SEXP x, bool autoUnbox, int depth) {
    if (depth > kMaxDepth) return WriteResult::Unsupported;
    if (x == R_NilValue) {
        // jsonlite emits "{}" for top-level NULL, but inside a list a
        // NULL element is also "{}" with the same library. We don't
        // want to second-guess that — bail to fallback for NULL at
        // any nested position. Top-level NULL is handled in the
        // entry point separately.
        if (depth > 0) return WriteResult::Unsupported;
        buf.append("{}", 2);
        return WriteResult::Ok;
    }
    switch (TYPEOF(x)) {
        case LGLSXP:
        case INTSXP:
        case REALSXP:
        case STRSXP:
            return writeAtomic(buf, x, autoUnbox);
        case VECSXP:
            return writeList(buf, x, autoUnbox, depth);
        default:
            return WriteResult::Unsupported;
    }
}

} // namespace

extern "C" SEXP drogonR_to_json(SEXP x, SEXP auto_unbox_) {
    bool autoUnbox = (TYPEOF(auto_unbox_) == LGLSXP &&
                      Rf_length(auto_unbox_) == 1 &&
                      LOGICAL(auto_unbox_)[0] == TRUE);

    std::string buf;
    buf.reserve(64);
    WriteResult r = writeValue(buf, x, autoUnbox, 0);
    if (r != WriteResult::Ok) return R_NilValue;

    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(out, 0, Rf_mkCharLenCE(
        buf.data(), static_cast<int>(buf.size()), CE_UTF8));
    UNPROTECT(1);
    return out;
}
