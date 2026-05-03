/*
 *  drogonR — public C ABI for native (R-bypass) HTTP handlers.
 *
 *  This header is shipped via inst/include/, so any package that does
 *      LinkingTo: drogonR
 *  can `#include <drogonR.h>` from its C / C++ sources to get the
 *  exact handler signature drogonR expects when looking up callables
 *  via R_GetCCallable("<your-package>", "<your-callable>").
 *
 *  The intended audience is R packages whose hot path is C / C++
 *  (ggmlR, llamaR, whisperR, embedding/classifier packages) and who
 *  want to serve HTTP responses without round-tripping through the R
 *  main thread on every request. drogonR invokes registered handlers
 *  on Drogon's worker thread pool (via drogon::async_run), NOT on
 *  the R main thread — so handlers MUST NOT touch any SEXP / call
 *  any R API. Configuration (loading models, reading args) belongs
 *  in your package's R-side init, before dr_serve() is called.
 *
 *  Memory ownership
 *  ----------------
 *  drogonR owns:
 *      * `body`             (request body buffer, valid for the
 *                            duration of the call)
 *      * `query`            (raw query string or NULL)
 *      * `path_params[i]`   (NUL-terminated, count = path_params_n)
 *      * `headers[2*i]`,
 *        `headers[2*i+1]`   (name / value flat pairs, count =
 *                            headers_n; both NUL-terminated)
 *
 *  Backend allocates (handler must malloc, drogonR free()s after
 *  sending the response):
 *      * `*out_body`         — response body bytes (may be 0-len if
 *                              `*out_len` is 0; pass NULL in that
 *                              case)
 *      * `*out_content_type` — optional MIME (e.g. "application/json"),
 *                              or leave at its initial NULL for the
 *                              default "application/octet-stream"
 *
 *  Backend writes by-value:
 *      * `*out_len`          — number of bytes in *out_body
 *      * `*out_status`       — HTTP status code (e.g. 200)
 *
 *  Return value
 *  ------------
 *      0      — success; drogonR sends the response built from the
 *               out-parameters
 *      != 0   — backend failure; drogonR sends a 500 with a generic
 *               body. *out_body may be ignored / freed by drogonR.
 */
#ifndef DROGONR_H
#define DROGONR_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*drogonr_unary_handler_t)(
    const char         *body,           size_t  body_len,
    const char         *query,
    const char *const  *path_params,    size_t  path_params_n,
    const char *const  *headers,        size_t  headers_n,
    char              **out_body,       size_t *out_len,
    int                *out_status,
    char              **out_content_type);

/* ----------------------------------------------------------------
 * Streaming handler ABI
 *
 * For LLM token streams, SSE feeds, log tails — anything where the
 * backend wants to push chunks over time rather than build one body
 * up front.
 *
 * Threading: drogonR invokes a streaming handler on a worker thread
 * from its cppWorkerPool — NOT the R main thread, NOT a Drogon I/O
 * thread. The handler may block as long as it wants; only that one
 * worker is held. The session handle and the three callbacks are
 * valid for the lifetime of the call; do NOT store them past the
 * handler returning, do NOT pass them to other threads.
 *
 * Cancellation: client disconnect is detected by drogonR via
 * Drogon's TCP close event. The atomic flag inside the session is
 * set on Drogon's I/O thread; the backend reads it via
 * `is_cancelled(session)` (acquire) or notices the `-1` return
 * from `send(...)`. Use `is_cancelled` between sends when the
 * backend has long compute pauses (e.g. an LLM generating the
 * next token) so it can bail out promptly.
 *
 * Closing: backend SHOULD call `close(session)` when done. drogonR
 * also auto-closes if the handler returns without it, but explicit
 * close releases the chunked-transfer terminator immediately
 * (useful when the backend has handed generation off to a detached
 * thread and is about to return).
 *
 * Status code is always 200 — chunked responses can't change status
 * mid-stream. Headers other than Content-Type can be set on the
 * R side at registration time.
 * ----------------------------------------------------------------
 */

/* Opaque per-request session handle. */
typedef struct drogonr_stream_session drogonr_stream_session_t;

/* Push one chunk to the client.
 * Returns 0 on success; -1 if the connection has gone away (the
 * backend should stop generating and return promptly). The bytes
 * are copied — backend retains ownership of `data` and may free or
 * reuse it as soon as the call returns. */
typedef int (*drogonr_send_chunk_fn)(
    drogonr_stream_session_t *session,
    const char *data, size_t len);

/* Close the chunked response. Idempotent — extra calls are no-ops.
 * drogonR auto-closes after the handler returns if the backend
 * didn't, so calling this is optional but recommended. */
typedef void (*drogonr_close_stream_fn)(
    drogonr_stream_session_t *session);

/* Read the cancellation flag (acquire). Non-zero means the client
 * has disconnected; call this between expensive computations to
 * bail out promptly even when no send() has been attempted. */
typedef int (*drogonr_is_cancelled_fn)(
    drogonr_stream_session_t *session);

/* Streaming handler.
 *
 * Request snapshot fields (`body`, `query`, `path_params`,
 * `headers`) follow the same memory ownership rules as
 * drogonr_unary_handler_t — drogonR owns them and they are valid
 * for the duration of the call.
 *
 * Backend may set `*out_content_type` to a malloc()-ed MIME string;
 * drogonR free()s it after sending the response headers. NULL means
 * use the default ("text/event-stream").
 *
 * Return value: 0 on success, non-zero if the backend gave up
 * (logged for observability). drogonR closes the stream either
 * way. */
typedef int (*drogonr_stream_handler_t)(
    /* request snapshot, identical to drogonr_unary_handler_t */
    const char         *body,           size_t  body_len,
    const char         *query,
    const char *const  *path_params,    size_t  path_params_n,
    const char *const  *headers,        size_t  headers_n,
    /* per-call streaming session and the callbacks it accepts */
    drogonr_stream_session_t *session,
    drogonr_send_chunk_fn     send,
    drogonr_close_stream_fn   close,
    drogonr_is_cancelled_fn   is_cancelled,
    /* response metadata */
    char              **out_content_type);

#ifdef __cplusplus
}
#endif

#endif /* DROGONR_H */
