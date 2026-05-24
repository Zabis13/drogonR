# drogonR streaming responses (HTTP chunked, Server-Sent-Events, NDJSON, ...).
#
# A streaming handler returns a `drogon_stream` value instead of a
# normal response list. The dispatcher recognises the class and opens
# a chunked-transfer response on Drogon's side; from then on it pumps
# the user's `next_chunk` function on the main R thread, one chunk at
# a time, scheduling each step via later::later() so other requests
# keep getting serviced between chunks.
#
# Disconnect: when the client goes away, the next stream->send() on
# the Drogon loop returns false; the dispatcher records that and the
# next pump runs once with cancelled = TRUE so the generator can free
# its state, then closes the session.

#' Open a streaming HTTP response
#'
#' Return value for a route handler when the response should be
#' streamed (HTTP chunked transfer). Instead of producing one body
#' string, the handler returns a `drogon_stream` describing how to
#' generate chunks on demand. The dispatcher pumps `next_chunk()` on
#' the main R thread, one chunk per pump, until it signals `done`.
#'
#' Each pump receives the current `state` and a `cancelled` flag.
#' `cancelled` is `TRUE` when the dispatcher has detected that the
#' client connection is gone; the generator will be invoked exactly
#' once with `cancelled = TRUE` so it can free state, and the stream
#' is then closed regardless of what the call returns. It returns a
#' list with three slots:
#'
#' * `chunk`   — character(1) bytes to send right now (sent verbatim;
#'   format SSE / NDJSON / etc. yourself, or use one of the helpers
#'   built on top of `dr_stream()`).
#' * `state`   — the value passed to the next pump. Pass back the
#'   incoming `state` unchanged if you don't need to mutate it.
#' * `done`    — `TRUE` to close the response after this chunk;
#'   `FALSE` to schedule another pump.
#'
#' @section Threading:
#' `next_chunk()` always runs on the main R thread. R is
#' single-threaded, so this is the only place it could safely run.
#' Heavy work inside one pump blocks every other request and every
#' other stream until it returns — keep each step short, and split
#' long generation across many pumps.
#'
#' @param next_chunk Function `function(state, cancelled)` returning
#'   `list(chunk = , state = , done = )`. See above.
#' @param state Initial state passed to the first pump. Anything an R
#'   value can hold; opaque to the dispatcher.
#' @param content_type MIME type for the response. Defaults to
#'   `"text/event-stream"` since SSE is the most common use case.
#' @param headers Named list of additional response headers to send
#'   in the initial chunked-transfer response (status is always 200).
#'   `Content-Type` here overrides the `content_type` argument.
#' @param min_interval Minimum delay in seconds between consecutive
#'   `next_chunk()` calls. `0` (default) pumps as fast as the event
#'   loop allows. Set to `0.1` to throttle to ~10 chunks/sec, etc.
#'   Useful for SSE feeds that should be paced rather than bursted.
#'   The delay is a floor, not a guarantee — heavy R-side work or
#'   other queued callbacks may push the next pump out further.
#'
#' @return A list of class `drogon_stream` carrying `next_chunk`,
#'   `state`, `content_type`, `headers`, and `min_interval`. Return
#'   it from a route handler; the dispatcher recognises the class
#'   and opens an HTTP chunked-transfer response, then pumps
#'   `next_chunk()` on the main R thread until it signals
#'   `done = TRUE`.
#'
#' @examples
#' \dontrun{
#' app <- dr_app() |>
#'   dr_get("/sse", function(req) {
#'     dr_stream(
#'       state      = list(i = 0L, n = 5L),
#'       next_chunk = function(state, cancelled) {
#'         if (cancelled || state$i >= state$n) {
#'           return(list(chunk = "", state = state, done = TRUE))
#'         }
#'         state$i <- state$i + 1L
#'         list(chunk = sprintf("data: %d\n\n", state$i),
#'              state = state, done = FALSE)
#'       })
#'   })
#' dr_serve(app, port = 8080L)
#' # curl -N http://127.0.0.1:8080/sse
#' }
#' @export
dr_stream <- function(next_chunk,
                      state        = NULL,
                      content_type = "text/event-stream",
                      headers      = list(),
                      min_interval = 0) {
  if (!is.function(next_chunk)) {
    stop("`next_chunk` must be a function(state, cancelled)", call. = FALSE)
  }
  if (!is.character(content_type) || length(content_type) != 1L ||
      is.na(content_type) || !nzchar(content_type)) {
    stop("`content_type` must be a single non-empty string", call. = FALSE)
  }
  if (!is.list(headers)) {
    stop("`headers` must be a (possibly empty) named list", call. = FALSE)
  }
  if (length(headers) > 0L) {
    nm <- names(headers)
    if (is.null(nm) || any(!nzchar(nm)) || anyNA(nm)) {
      stop("`headers` must be a named list (every entry needs a name)",
           call. = FALSE)
    }
  }
  if (!is.numeric(min_interval) || length(min_interval) != 1L ||
      is.na(min_interval) || min_interval < 0) {
    stop("`min_interval` must be a single non-negative number (seconds)",
         call. = FALSE)
  }

  out <- list(next_chunk   = next_chunk,
              state        = state,
              content_type = content_type,
              headers      = headers,
              min_interval = as.numeric(min_interval))
  class(out) <- c("drogon_stream", "list")
  out
}

#' Open a Server-Sent-Events streaming response
#'
#' Convenience wrapper around [dr_stream()] for the common case of an
#' SSE feed where each tick emits one `data:` field. The generator
#' returns `data` (a string), `state`, and `done`; the helper formats
#' the SSE frame, splitting embedded newlines into multiple `data:`
#' lines per the SSE spec, and adds the headers a typical SSE client
#' expects (no caching, no proxy buffering).
#'
#' For SSE features beyond plain `data:` (`event:`, `id:`, `retry:`),
#' use [dr_stream()] directly and format the frame yourself.
#'
#' @param generator Function `function(state, cancelled)` returning
#'   `list(data = , state = , done = )`. `data` may contain newlines;
#'   they are split into multiple `data:` lines automatically. An
#'   empty `data` is allowed (sends a keep-alive frame).
#' @param state Initial state, as in [dr_stream()].
#' @param headers Extra response headers to merge with the SSE
#'   defaults (`Content-Type: text/event-stream`,
#'   `Cache-Control: no-cache`, `X-Accel-Buffering: no`). User-supplied
#'   entries with the same name win.
#' @param min_interval Floor on the delay between consecutive
#'   `generator()` calls, in seconds. See [dr_stream()] for details.
#'   Default `0` (no throttling).
#'
#' @return A `drogon_stream` value to return from a route handler.
#'
#' @examples
#' \dontrun{
#' app <- dr_app() |>
#'   dr_get("/sse", function(req) {
#'     dr_stream_sse(
#'       state = list(i = 0L, n = 5L),
#'       generator = function(state, cancelled) {
#'         if (cancelled || state$i >= state$n) {
#'           return(list(data = "", state = state, done = TRUE))
#'         }
#'         state$i <- state$i + 1L
#'         list(data = sprintf("tick %d", state$i),
#'              state = state, done = FALSE)
#'       })
#'   })
#' dr_serve(app, port = 8080L)
#' # curl -N http://127.0.0.1:8080/sse
#' }
#' @export
dr_stream_sse <- function(generator, state = NULL, headers = list(),
                          min_interval = 0) {
  if (!is.function(generator)) {
    stop("`generator` must be a function(state, cancelled)", call. = FALSE)
  }

  defaults <- list(`Cache-Control`    = "no-cache",
                   `X-Accel-Buffering` = "no")
  user_nm  <- names(headers)
  merged   <- c(headers, defaults[setdiff(names(defaults), user_nm)])

  next_chunk <- function(state, cancelled) {
    out <- generator(state, cancelled)
    if (!is.list(out)) {
      stop("SSE generator must return a list(data=, state=, done=)",
           call. = FALSE)
    }
    data <- out$data %||% ""
    if (!is.character(data) || length(data) != 1L || is.na(data)) {
      stop("SSE generator: `data` must be a single string", call. = FALSE)
    }
    # Split on \n so each line gets its own `data:` prefix per the SSE
    # spec; trailing blank line terminates the frame.
    lines <- strsplit(data, "\n", fixed = TRUE)[[1L]]
    if (length(lines) == 0L) lines <- ""
    chunk <- paste0(paste0("data: ", lines, collapse = "\n"), "\n\n")
    list(chunk = chunk,
         state = out$state,
         done  = isTRUE(out$done))
  }

  dr_stream(next_chunk   = next_chunk,
            state        = state,
            content_type = "text/event-stream",
            headers      = merged,
            min_interval = min_interval)
}
