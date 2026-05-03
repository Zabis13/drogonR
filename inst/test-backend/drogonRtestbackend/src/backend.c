/*
 *  drogonRtestbackend — exercises every corner of the
 *  drogonr_unary_handler_t ABI: echo body, custom content-type,
 *  custom status, header read-back, path param read-back, error
 *  return.
 *
 *  All handlers are pure C (no R API). They run on a Drogon worker
 *  thread, so they MUST NOT call anything from <Rinternals.h>.
 */
#include <drogonR.h>

#include <R.h>
#include <R_ext/Rdynload.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* --- Helpers ----------------------------------------------------------- */

/* Allocate a fresh malloc()'d copy of `s` so drogonR can free() it. */
static char *dupcstr(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    char *out = (char*) malloc(n + 1);
    if (out) memcpy(out, s, n + 1);
    return out;
}

/* Allocate a malloc'd, NOT-null-terminated copy of (data, n) bytes. */
static char *dupbytes(const char *data, size_t n) {
    char *out = (char*) malloc(n > 0 ? n : 1);
    if (out && data && n > 0) memcpy(out, data, n);
    return out;
}

/* --- Handlers ---------------------------------------------------------- */

/* /echo — echo the request body verbatim with status 200 and a
 * fixed text/plain content-type. */
static int h_echo(const char *body,        size_t  body_len,
                  const char *query,
                  const char *const *path, size_t  path_n,
                  const char *const *hdrs, size_t  hdrs_n,
                  char  **out_body,        size_t *out_len,
                  int   *out_status,
                  char  **out_content_type) {
    (void) query; (void) path; (void) path_n; (void) hdrs; (void) hdrs_n;
    *out_body         = dupbytes(body, body_len);
    *out_len          = body_len;
    *out_status       = 200;
    *out_content_type = dupcstr("text/plain; charset=utf-8");
    return 0;
}

/* /status — read ?code=NNN out of the raw query string and return
 * that as the HTTP status. Body says "set status to NNN". */
static int h_status(const char *body,        size_t  body_len,
                    const char *query,
                    const char *const *path, size_t  path_n,
                    const char *const *hdrs, size_t  hdrs_n,
                    char  **out_body,        size_t *out_len,
                    int   *out_status,
                    char  **out_content_type) {
    (void) body; (void) body_len; (void) path; (void) path_n;
    (void) hdrs; (void) hdrs_n;
    int code = 200;
    if (query) {
        const char *p = strstr(query, "code=");
        if (p) code = atoi(p + 5);
    }
    char buf[64];
    int n = snprintf(buf, sizeof(buf), "set status to %d", code);
    *out_body         = dupbytes(buf, (size_t) n);
    *out_len          = (size_t) n;
    *out_status       = code;
    *out_content_type = dupcstr("text/plain");
    return 0;
}

/* /header — return the value of the X-Trace request header, or
 * "(missing)" if the client didn't send one. Tests the headers[]
 * flat-pair contract. */
static int h_header(const char *body,        size_t  body_len,
                    const char *query,
                    const char *const *path, size_t  path_n,
                    const char *const *hdrs, size_t  hdrs_n,
                    char  **out_body,        size_t *out_len,
                    int   *out_status,
                    char  **out_content_type) {
    (void) body; (void) body_len; (void) query; (void) path; (void) path_n;
    const char *val = NULL;
    for (size_t i = 0; i < hdrs_n; ++i) {
        const char *name = hdrs[2*i];
        /* Drogon lowercases header names — so do we. */
        if (name && strcmp(name, "x-trace") == 0) {
            val = hdrs[2*i + 1];
            break;
        }
    }
    const char *out = val ? val : "(missing)";
    *out_body         = dupcstr(out);
    *out_len          = strlen(out);
    *out_status       = 200;
    *out_content_type = dupcstr("text/plain");
    return 0;
}

/* /items/<id>/sub/<slug> — concatenate path params positionally. */
static int h_path(const char *body,        size_t  body_len,
                  const char *query,
                  const char *const *path, size_t  path_n,
                  const char *const *hdrs, size_t  hdrs_n,
                  char  **out_body,        size_t *out_len,
                  int   *out_status,
                  char  **out_content_type) {
    (void) body; (void) body_len; (void) query; (void) hdrs; (void) hdrs_n;
    char buf[512];
    int n = 0;
    if (path_n >= 2 && path[0] && path[1]) {
        n = snprintf(buf, sizeof(buf), "id=%s slug=%s", path[0], path[1]);
    } else {
        n = snprintf(buf, sizeof(buf), "no path params");
    }
    *out_body         = dupbytes(buf, (size_t) n);
    *out_len          = (size_t) n;
    *out_status       = 200;
    *out_content_type = dupcstr("text/plain");
    return 0;
}

/* /boom — return non-zero so drogonR sends its generic 500. We
 * intentionally allocate out_body BEFORE returning to verify
 * drogonR free()s it on the failure path. */
static int h_boom(const char *body,        size_t  body_len,
                  const char *query,
                  const char *const *path, size_t  path_n,
                  const char *const *hdrs, size_t  hdrs_n,
                  char  **out_body,        size_t *out_len,
                  int   *out_status,
                  char  **out_content_type) {
    (void) body; (void) body_len; (void) query; (void) path; (void) path_n;
    (void) hdrs; (void) hdrs_n;
    *out_body         = dupcstr("backend would-have-said");
    *out_len          = strlen("backend would-have-said");
    *out_status       = 200;
    *out_content_type = dupcstr("text/plain");
    return -1;  /* signal failure -> drogonR replies 500 */
}

/* /ping_json — fixed JSON {"ok":true}; bench/parity counterpart of
 * the plumber and drogonR-native /ping routes. */
static int h_ping_json(const char *body,        size_t  body_len,
                       const char *query,
                       const char *const *path, size_t  path_n,
                       const char *const *hdrs, size_t  hdrs_n,
                       char  **out_body,        size_t *out_len,
                       int   *out_status,
                       char  **out_content_type) {
    (void) body; (void) body_len; (void) query;
    (void) path; (void) path_n; (void) hdrs; (void) hdrs_n;
    static const char k[] = "{\"ok\":true}";
    *out_body         = dupbytes(k, sizeof(k) - 1);
    *out_len          = sizeof(k) - 1;
    *out_status       = 200;
    *out_content_type = dupcstr("application/json");
    return 0;
}

/* /ping_text — plain "ok"; floor-overhead bench counterpart. */
static int h_ping_text(const char *body,        size_t  body_len,
                       const char *query,
                       const char *const *path, size_t  path_n,
                       const char *const *hdrs, size_t  hdrs_n,
                       char  **out_body,        size_t *out_len,
                       int   *out_status,
                       char  **out_content_type) {
    (void) body; (void) body_len; (void) query;
    (void) path; (void) path_n; (void) hdrs; (void) hdrs_n;
    *out_body         = dupbytes("ok", 2);
    *out_len          = 2;
    *out_status       = 200;
    *out_content_type = dupcstr("text/plain");
    return 0;
}

/* --- Streaming handlers ----------------------------------------------- */

#include <unistd.h>  /* usleep */

/* /tick — push N SSE-style "data: i\n\n" frames, ~1ms apart. The body
 * (when non-empty) is parsed as the integer N; default is 5. We poll
 * is_cancelled between sleeps so a disconnected client makes the
 * handler exit quickly. */
static int sh_tick(const char *body,        size_t  body_len,
                   const char *query,
                   const char *const *path, size_t  path_n,
                   const char *const *hdrs, size_t  hdrs_n,
                   drogonr_stream_session_t *session,
                   drogonr_send_chunk_fn     send,
                   drogonr_close_stream_fn   close,
                   drogonr_is_cancelled_fn   is_cancelled,
                   char **out_content_type) {
    (void) query; (void) path; (void) path_n; (void) hdrs; (void) hdrs_n;
    int N = 5;
    if (body_len > 0 && body) {
        char buf[16] = {0};
        size_t n = body_len < 15 ? body_len : 15;
        memcpy(buf, body, n);
        int parsed = atoi(buf);
        if (parsed > 0) N = parsed;
    }

    char frame[64];
    for (int i = 1; i <= N; ++i) {
        if (is_cancelled(session)) break;
        int written = snprintf(frame, sizeof(frame),
                               "data: %d\n\n", i);
        if (written <= 0 || written >= (int) sizeof(frame)) continue;
        if (send(session, frame, (size_t) written) < 0) break;
        usleep(1000); /* 1 ms between frames */
    }
    close(session);
    *out_content_type = NULL;
    return 0;
}

/* /tick_long — like /tick but sleeps 50ms between tokens with NO send
 * (simulating an LLM thinking). Uses is_cancelled to bail. Sends
 * one "done" frame at the end so a successful run is observable. */
static int sh_tick_long(const char *body,        size_t  body_len,
                        const char *query,
                        const char *const *path, size_t  path_n,
                        const char *const *hdrs, size_t  hdrs_n,
                        drogonr_stream_session_t *session,
                        drogonr_send_chunk_fn     send,
                        drogonr_close_stream_fn   close,
                        drogonr_is_cancelled_fn   is_cancelled,
                        char **out_content_type) {
    (void) body; (void) body_len; (void) query;
    (void) path; (void) path_n; (void) hdrs; (void) hdrs_n;
    for (int i = 0; i < 100; ++i) {
        if (is_cancelled(session)) {
            close(session);
            *out_content_type = NULL;
            return 0;
        }
        usleep(50000); /* 50 ms */
    }
    static const char done[] = "data: finished\n\n";
    send(session, done, sizeof(done) - 1);
    close(session);
    *out_content_type = NULL;
    return 0;
}

/* --- Init -------------------------------------------------------------- */

void R_init_drogonRtestbackend(DllInfo *dll) {
    R_RegisterCCallable("drogonRtestbackend", "echo",      (DL_FUNC) h_echo);
    R_RegisterCCallable("drogonRtestbackend", "status",    (DL_FUNC) h_status);
    R_RegisterCCallable("drogonRtestbackend", "header",    (DL_FUNC) h_header);
    R_RegisterCCallable("drogonRtestbackend", "path",      (DL_FUNC) h_path);
    R_RegisterCCallable("drogonRtestbackend", "boom",      (DL_FUNC) h_boom);
    R_RegisterCCallable("drogonRtestbackend", "ping_json", (DL_FUNC) h_ping_json);
    R_RegisterCCallable("drogonRtestbackend", "ping_text", (DL_FUNC) h_ping_text);
    R_RegisterCCallable("drogonRtestbackend", "tick",      (DL_FUNC) sh_tick);
    R_RegisterCCallable("drogonRtestbackend", "tick_long", (DL_FUNC) sh_tick_long);
    R_useDynamicSymbols(dll, FALSE);
}
