#' Connect to an external WebSocket server
#'
#' Opens an outbound WebSocket connection from R to a remote server (for
#' example, a streaming LLM API or a chat backend). Unlike [dr_ws()],
#' which serves inbound connections on a running drogonR server, this is
#' drogonR acting as a *client*, and it works independently of
#' [dr_serve()] — you do not need a running server to use it.
#'
#' The connection runs on a dedicated background event loop. All three
#' callbacks fire on the main R thread (never on that loop), so they may
#' touch R state freely. The first connection lazily starts the client
#' subsystem; it stays alive until [dr_ws_shutdown()] or package unload,
#' so an open/close cycle does not thrash the background thread.
#'
#' @param url WebSocket URL, `ws://host[:port][/path]` or
#'   `wss://host[:port][/path]`. `wss://` requires a drogonR built with
#'   OpenSSL.
#' @param on_message `function(msg, binary)` called for every frame
#'   received from the server. `binary` is `TRUE` for binary frames.
#'   Required.
#' @param on_open `function()` called once when the connection is
#'   established. Optional.
#' @param on_close `function(reason, code)` called once when the
#'   connection ends. `reason` is `"connect_failed"` if the initial
#'   connect never succeeded, or `"closed"` if an established connection
#'   later dropped. Optional.
#'
#' @return A `drogon_ws_client` handle; pass it to
#'   [dr_ws_client_send()] and [dr_ws_client_close()].
#' @seealso [dr_ws_client_send()], [dr_ws_client_close()],
#'   [dr_ws_shutdown()]
#' @export
dr_ws_connect <- function(url, on_message, on_open = NULL, on_close = NULL) {
  if (!is.character(url) || length(url) != 1L || is.na(url) || !nzchar(url)) {
    stop("`url` must be a single non-empty string", call. = FALSE)
  }
  if (!is.function(on_message)) {
    stop("`on_message` must be a function(msg, binary)", call. = FALSE)
  }
  if (!is.null(on_open) && !is.function(on_open)) {
    stop("`on_open` must be a function() or NULL", call. = FALSE)
  }
  if (!is.null(on_close) && !is.function(on_close)) {
    stop("`on_close` must be a function(reason, code) or NULL", call. = FALSE)
  }

  parsed <- .dr_parse_ws_url(url)
  if (parsed$ssl && !isTRUE(.Call(drogonR_has_ssl))) {
    stop("wss:// requires a drogonR built with OpenSSL; this build is ",
         "plain-HTTP only. Reinstall with ",
         "--configure-args='--with-openssl', or use a ws:// URL.",
         call. = FALSE)
  }

  id <- .Call(drogonR_ws_connect, parsed$host, parsed$path,
              on_message, on_open, on_close)
  structure(id, class = "drogon_ws_client")
}

#' Send a message on a client WebSocket connection
#'
#' Pushes a message to the server over a connection opened with
#' [dr_ws_connect()]. If the connection is not (yet) established or has
#' closed, the call is a no-op and returns `FALSE`.
#'
#' @param client A `drogon_ws_client` from [dr_ws_connect()].
#' @param msg A single string to send.
#' @param binary Send as a binary frame instead of text. Default `FALSE`.
#' @return `TRUE` if the message was queued, `FALSE` otherwise, invisibly.
#' @seealso [dr_ws_connect()]
#' @export
dr_ws_client_send <- function(client, msg, binary = FALSE) {
  id <- .dr_ws_client_id(client)
  if (!is.character(msg) || length(msg) != 1L) {
    stop("`msg` must be a single string", call. = FALSE)
  }
  invisible(.Call(drogonR_ws_client_send, id, msg, isTRUE(binary)))
}

#' Close a client WebSocket connection
#'
#' Closes a connection opened with [dr_ws_connect()]. The `on_close` hook
#' (if any) fires once the close completes. A no-op if already closed.
#'
#' @param client A `drogon_ws_client` from [dr_ws_connect()].
#' @return `NULL`, invisibly.
#' @seealso [dr_ws_connect()], [dr_ws_shutdown()]
#' @export
dr_ws_client_close <- function(client) {
  id <- .dr_ws_client_id(client)
  .Call(drogonR_ws_client_close, id)
  invisible(NULL)
}

#' Shut down the WebSocket client subsystem
#'
#' Closes every open client connection and stops the background event
#' loop that services them. Called automatically when the package is
#' unloaded; call it explicitly to release the background thread early.
#' After shutdown, a fresh [dr_ws_connect()] transparently restarts the
#' subsystem.
#'
#' @return `NULL`, invisibly.
#' @seealso [dr_ws_connect()]
#' @export
dr_ws_shutdown <- function() {
  .Call(drogonR_ws_shutdown)
  invisible(NULL)
}

# A drogon_ws_client is a classed double carrying the client id set on
# the C++ side. Validate and unwrap to the plain double the .Call layer
# expects.
.dr_ws_client_id <- function(client) {
  if (!inherits(client, "drogon_ws_client")) {
    stop("`client` must be a drogon_ws_client (from dr_ws_connect())",
         call. = FALSE)
  }
  as.numeric(unclass(client))
}

# Parse a ws://host[:port][/path] URL into the pieces the C++ layer
# wants: a host string ("ws[s]://host:port", no path — Drogon's
# newWebSocketClient rejects a path there) and the request path
# separately. Minimal by design: no userinfo, no IPv6 literals in v1.
.dr_parse_ws_url <- function(url) {
  m <- regmatches(url, regexec(
    "^(ws|wss)://([^/?#]+)(.*)$", url, ignore.case = TRUE))[[1]]
  if (length(m) != 4L) {
    stop("`url` must look like ws://host[:port][/path] or ",
         "wss://host[:port][/path]; got '", url, "'", call. = FALSE)
  }
  scheme    <- tolower(m[2])
  authority <- m[3]                       # host[:port]
  rest      <- m[4]                        # "" or "/path[?query]"
  ssl       <- identical(scheme, "wss")

  # Default port so the host string is explicit for newWebSocketClient.
  if (!grepl(":", authority, fixed = TRUE)) {
    authority <- paste0(authority, if (ssl) ":443" else ":80")
  }
  path <- if (nzchar(rest)) rest else "/"

  list(host = paste0(scheme, "://", authority),
       path = path,
       ssl  = ssl)
}
