#' Register a WebSocket endpoint
#'
#' Adds a full-duplex WebSocket route to a `drogon_app`. Unlike the
#' request/response routes (`dr_get()` etc.), a WebSocket connection is
#' long-lived: the server can push messages to the client at any time via
#' [dr_ws_send()], and the client can send messages back, each delivered
#' to `on_message`.
#'
#' The three hooks all run on the main R thread (never on Drogon's I/O
#' threads), so they may touch R state freely. Each receives a
#' `drogon_ws_conn` handle identifying the connection; pass it to
#' [dr_ws_send()] / [dr_ws_close()].
#'
#' @param app A `drogon_app` (see [dr_app()]).
#' @param path Exact request path to serve, e.g. `"/ws/echo"`.
#' @param on_message `function(conn, msg, binary)` called for every frame
#'   received from the client. `binary` is `TRUE` for binary frames.
#'   Required.
#' @param on_connect `function(conn)` called once when a client connects.
#'   Optional.
#' @param on_close `function(conn)` called once when the connection
#'   closes (client- or server-initiated). Optional.
#'
#' @return The `app`, invisibly modified, for piping.
#' @seealso [dr_ws_send()], [dr_ws_close()]
#' @export
dr_ws <- function(app, path, on_message,
                  on_connect = NULL, on_close = NULL) {
  .dr_check_app(app)
  if (!is.character(path) || length(path) != 1L) {
    stop("`path` must be a single string", call. = FALSE)
  }
  if (!is.function(on_message)) {
    stop("`on_message` must be a function(conn, msg, binary)", call. = FALSE)
  }
  if (!is.null(on_connect) && !is.function(on_connect)) {
    stop("`on_connect` must be a function(conn) or NULL", call. = FALSE)
  }
  if (!is.null(on_close) && !is.function(on_close)) {
    stop("`on_close` must be a function(conn) or NULL", call. = FALSE)
  }

  if (!is.null(app$ws_routes[[path]])) {
    warning("overwriting existing WebSocket route for ", path, call. = FALSE)
  }
  app$ws_routes[[path]] <- list(path       = path,
                                on_connect = on_connect,
                                on_message = on_message,
                                on_close   = on_close)
  invisible(app)
}

#' Register a C++ (R-bypass) WebSocket endpoint
#'
#' Like [dr_ws()], but every frame is handled by a compiled C function in
#' another R package rather than by R closures. The handler runs on
#' Drogon's I/O thread with no round-trip through R, which is what you
#' want when a backend owns the socket and streams data from C/C++ (e.g.
#' an LLM emitting tokens).
#'
#' The `callable` must be a function pointer of type
#' `drogonr_ws_handler_t` (see `inst/include/drogonR.h`), registered by
#' the backend package via `R_RegisterCCallable()`. It is resolved
#' eagerly here, so a missing symbol fails at registration, not on the
#' first connection.
#'
#' A C++ route ignores the R hooks of [dr_ws()]; the two cannot be mixed
#' on the same path.
#'
#' # Continuous-batching guards
#'
#' The optional `max_conns`, `idle_timeout`, and `max_lifetime` bound a
#' native route the way `-np N` and the slot timeouts bound
#' `llama-server`. They exist so an LLM scheduler layered on this ABI
#' doesn't have to re-implement them, less reliably, itself:
#'
#' * `max_conns` — refuse a new connection once this many are already
#'   live on the route. The rejected client gets a WebSocket close with
#'   code 1013 ("Try Again Later"), not a bare TCP reset, so it can
#'   back off and retry. `0` (default) means unlimited.
#' * `idle_timeout` — close a connection after this many seconds with no
#'   outgoing frame (i.e. the backend has stopped streaming tokens to
#'   it — typically a stalled or crashed decode thread). `0` disables.
#' * `max_lifetime` — hard ceiling, in seconds, on a connection's total
#'   duration regardless of activity. `0` disables.
#'
#' All three apply only to C++ routes; they are the transport's safety
#' net, not a substitute for the backend's own queue bound.
#'
#' @param app A `drogon_app` (see [dr_app()]).
#' @param path Exact request path to serve.
#' @param package Name of the package exporting the callable.
#' @param callable Name of the `R_RegisterCCallable()` symbol.
#' @param max_conns Maximum concurrent connections on this route; `0`
#'   (default) for unlimited.
#' @param idle_timeout Seconds without an outgoing frame before the
#'   connection is closed; `0` (default) disables idle reaping.
#' @param max_lifetime Absolute seconds a connection may live; `0`
#'   (default) disables the lifetime ceiling.
#' @return The `app`, invisibly modified, for piping.
#' @seealso [dr_ws()]
#' @export
dr_ws_cpp <- function(app, path, package, callable,
                      max_conns = 0, idle_timeout = 0, max_lifetime = 0) {
  .dr_check_app(app)
  if (!is.character(path) || length(path) != 1L) {
    stop("`path` must be a single string", call. = FALSE)
  }
  chk_num <- function(x, nm) {
    if (!is.numeric(x) || length(x) != 1L || is.na(x) || x < 0) {
      stop("`", nm, "` must be a single non-negative number", call. = FALSE)
    }
  }
  chk_num(max_conns, "max_conns")
  chk_num(idle_timeout, "idle_timeout")
  chk_num(max_lifetime, "max_lifetime")
  if (!requireNamespace(package, quietly = TRUE)) {
    stop("dr_ws_cpp: package '", package, "' is not installed; ",
         "install it before registering native handlers", call. = FALSE)
  }
  ptr <- tryCatch(
    .Call(drogonR_resolve_ccallable, package, callable),
    error = function(e) {
      stop("dr_ws_cpp: R_GetCCallable(\"", package, "\", \"", callable,
           "\") failed: ", conditionMessage(e),
           ". Make sure the package's R_init_", package,
           "() registers the callable.", call. = FALSE)
    })
  if (!is.null(app$ws_routes[[path]])) {
    warning("overwriting existing WebSocket route for ", path, call. = FALSE)
  }
  app$ws_routes[[path]] <- list(path = path, cpp_ptr = ptr,
                                max_conns    = as.numeric(max_conns),
                                idle_timeout = as.numeric(idle_timeout),
                                max_lifetime = as.numeric(max_lifetime))
  invisible(app)
}

#' Send a message on a WebSocket connection
#'
#' Pushes a message to the client of a live WebSocket connection. Safe to
#' call from any of the `dr_ws()` hooks. If the connection has already
#' closed, the call is a silent no-op.
#'
#' @param conn A `drogon_ws_conn` handle, as passed to a `dr_ws()` hook.
#' @param msg A single string to send.
#' @param binary Send as a binary frame instead of text. Default `FALSE`.
#'
#' @return `NULL`, invisibly.
#' @seealso [dr_ws()]
#' @export
dr_ws_send <- function(conn, msg, binary = FALSE) {
  id <- .dr_ws_conn_id(conn)
  if (!is.character(msg) || length(msg) != 1L) {
    stop("`msg` must be a single string", call. = FALSE)
  }
  .Call(drogonR_ws_send, id, msg, isTRUE(binary))
  invisible(NULL)
}

#' Close a WebSocket connection
#'
#' Initiates a server-side close of a live WebSocket connection. The
#' `on_close` hook (if any) fires once the close completes. A no-op if the
#' connection is already gone.
#'
#' @param conn A `drogon_ws_conn` handle, as passed to a `dr_ws()` hook.
#' @return `NULL`, invisibly.
#' @seealso [dr_ws()]
#' @export
dr_ws_close <- function(conn) {
  id <- .dr_ws_conn_id(conn)
  .Call(drogonR_ws_close, id)
  invisible(NULL)
}

#' Add a connection to a broadcast room
#'
#' Rooms are named groups of WebSocket connections. [dr_ws_broadcast()]
#' sends a message to every member of a room at once, so you don't have to
#' track connection handles yourself. Joining a room a connection is
#' already in is a no-op.
#'
#' A connection is removed from all its rooms automatically when it
#' closes, so you only need [dr_ws_leave()] to remove it early.
#'
#' @param conn A `drogon_ws_conn` handle, as passed to a `dr_ws()` hook.
#' @param room A single string naming the room.
#' @return `NULL`, invisibly.
#' @seealso [dr_ws_broadcast()], [dr_ws_leave()], [dr_ws()]
#' @export
dr_ws_join <- function(conn, room) {
  id <- .dr_ws_conn_id(conn)
  room <- .dr_ws_room_name(room)
  .Call(drogonR_ws_join, room, id)
  invisible(NULL)
}

#' Remove a connection from a broadcast room
#'
#' @param conn A `drogon_ws_conn` handle, as passed to a `dr_ws()` hook.
#' @param room A single string naming the room.
#' @return `NULL`, invisibly.
#' @seealso [dr_ws_join()], [dr_ws_broadcast()]
#' @export
dr_ws_leave <- function(conn, room) {
  id <- .dr_ws_conn_id(conn)
  room <- .dr_ws_room_name(room)
  .Call(drogonR_ws_leave, room, id)
  invisible(NULL)
}

#' Broadcast a message to every connection in a room
#'
#' Sends `msg` to all connections currently in `room`. Connections that
#' have closed are skipped silently. Safe to call from any `dr_ws()` hook.
#'
#' @param room A single string naming the room.
#' @param msg A single string to send.
#' @param binary Send as a binary frame instead of text. Default `FALSE`.
#' @return The number of connections the message was queued to, invisibly.
#' @seealso [dr_ws_join()], [dr_ws()]
#' @export
dr_ws_broadcast <- function(room, msg, binary = FALSE) {
  room <- .dr_ws_room_name(room)
  if (!is.character(msg) || length(msg) != 1L) {
    stop("`msg` must be a single string", call. = FALSE)
  }
  invisible(.Call(drogonR_ws_broadcast, room, msg, isTRUE(binary)))
}

# A drogon_ws_conn is a classed double carrying the connection id set on
# the C++ side. Validate and unwrap to the plain double the .Call layer
# expects.
.dr_ws_conn_id <- function(conn) {
  if (!inherits(conn, "drogon_ws_conn")) {
    stop("`conn` must be a drogon_ws_conn (passed to a dr_ws() hook)",
         call. = FALSE)
  }
  as.numeric(unclass(conn))
}

.dr_ws_room_name <- function(room) {
  if (!is.character(room) || length(room) != 1L || is.na(room) ||
      !nzchar(room)) {
    stop("`room` must be a single non-empty string", call. = FALSE)
  }
  room
}
