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

/* ----------------------------------------------------------------
 * WebSocket handler ABI (full-duplex, R-bypass)
 *
 * For backends that own a long-lived, bidirectional connection and
 * want to handle every frame in C/C++ — e.g. an LLM that streams
 * tokens back over a socket without a round-trip through R per
 * token. Registered from R via dr_ws_cpp(app, path, package,
 * callable).
 *
 * Threading: the handler is invoked on the connection's Drogon I/O
 * thread, once per event (connect / message / close). Events for a
 * single connection are delivered in order. The handler MUST NOT
 * touch any SEXP / call any R API, and MUST NOT block the I/O
 * thread: if it needs to do long work (token generation), it should
 * hand off to its own detached thread and stream results back via
 * the send() callback from there. Blocking the I/O thread stalls
 * every other connection sharing that loop.
 *
 * O(1) contract (continuous-batching backends): the handler runs
 * synchronously on the I/O thread, so for a scheduler that batches
 * many connections into one decode loop it MUST return in O(1):
 * enqueue the request (prompt + session handle + a send closure) onto
 * your own queue, wake your own decode thread, and return. Do the
 * generation on that detached thread and push tokens back via send()
 * — exactly the same discipline the streaming ABI documents. The
 * session handle survives past the handler returning (see below), so
 * the decode thread can keep using it.
 *
 * Session lifetime & safety: `session` is an opaque lookup handle,
 * NOT a pointer to an object. It carries no ownership: do not free it,
 * do not retain/release it, and do NOT cache anything you derive from
 * it — just keep the handle itself and pass it back to the callbacks.
 * Each callback re-resolves the live connection internally, so it is
 * safe to keep the handle in a detached backend thread and call
 * send()/close() after the peer has gone (or after WS_CLOSE was
 * delivered): the lookup simply misses and the call is a no-op, never
 * a use-after-free.
 *
 * Cancellation while streaming: if the client sends another frame
 * (e.g. "stop") while your detached thread is still generating, that
 * frame arrives as a fresh WS_MESSAGE on the I/O thread, concurrent
 * with your thread. drogonR does NOT serialise your detached work
 * against it — coordinating cancellation is the backend's job (set
 * your own flag from the WS_MESSAGE handler and poll it). send() is
 * always safe regardless.
 * ----------------------------------------------------------------
 */

/* Opaque per-connection session handle. */
typedef struct drogonr_ws_session drogonr_ws_session_t;

/* Which lifecycle event the handler is being called for. */
typedef enum {
    DROGONR_WS_CONNECT = 0,   /* new connection; msg is NULL, len 0   */
    DROGONR_WS_MESSAGE = 1,   /* a frame arrived; msg/len/binary set  */
    DROGONR_WS_CLOSE   = 2     /* connection closed; msg is NULL, len 0 */
} drogonr_ws_event_t;

/* Send a frame to the peer. `binary` != 0 sends a binary frame,
 * else text. Returns 0 if the frame was queued, -1 if the
 * connection is gone (safe to ignore; keep going or stop as you
 * like). The bytes are copied — the backend keeps ownership of
 * `data`. Thread-safe: callable from a detached backend thread. */
typedef int (*drogonr_ws_send_fn)(
    drogonr_ws_session_t *session,
    const char *data, size_t len, int binary);

/* Close the connection from the server side. Idempotent; safe after
 * the peer has already gone. Thread-safe. */
typedef void (*drogonr_ws_close_fn)(
    drogonr_ws_session_t *session);

/* Non-zero if the connection is still open. A backend-side hint only
 * (e.g. skip starting expensive work if already disconnected) — not
 * required for safety, since send() no-ops on a dead connection.
 * Thread-safe.
 *
 * Cheap by design (one mutex lock + a connected() read), so a batched
 * backend SHOULD poll it between decode steps to drop a disconnected
 * connection from the batch promptly rather than spend compute on a
 * peer that has already gone. */
typedef int (*drogonr_ws_is_connected_fn)(
    drogonr_ws_session_t *session);

/* WebSocket handler.
 *
 * Called once per event. `msg`/`len` are the frame payload for
 * DROGONR_WS_MESSAGE (NULL / 0 otherwise); `binary` is non-zero for
 * a binary frame. `msg` is owned by drogonR and valid only for the
 * duration of the call — copy it if you need it later.
 *
 * Return value is currently ignored (reserved; return 0). */
typedef int (*drogonr_ws_handler_t)(
    drogonr_ws_session_t      *session,
    drogonr_ws_event_t         event,
    const char                *msg,     size_t len,
    int                        binary,
    drogonr_ws_send_fn         send,
    drogonr_ws_close_fn        close,
    drogonr_ws_is_connected_fn is_connected);

#ifdef __cplusplus
}
#endif

#endif /* DROGONR_H */
