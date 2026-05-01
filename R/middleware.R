#' Register middleware
#'
#' Append a middleware function to the app's middleware chain. Middleware
#' runs in registration order before the matched route handler. Each
#' middleware receives `(req, nxt)`: call `nxt()` to pass control to the
#' next link (its return value is the downstream response, which you may
#' return as-is or modify), or return a response of your own to short-
#' circuit the chain. Throwing an error has the same effect as the route
#' handler throwing — the chain stops and a 500 is returned.
#'
#' @param app A `drogon_app` created by [dr_app()].
#' @param middleware A function of two arguments, `function(req, nxt)`.
#'
#' @return The `app`, invisibly.
#' @examples
#' app <- dr_app() |>
#'   dr_use(function(req, nxt) {
#'     t0 <- Sys.time()
#'     res <- nxt()
#'     message("served ", req$path, " in ",
#'             format(Sys.time() - t0))
#'     res
#'   }) |>
#'   dr_get("/ping", function(req) "pong")
#' @export
dr_use <- function(app, middleware) {
  .dr_check_app(app)
  if (!is.function(middleware)) {
    stop("`middleware` must be a function", call. = FALSE)
  }
  app$middleware[[length(app$middleware) + 1L]] <- middleware
  invisible(app)
}

# Run [mw1, mw2, ..., handler] as an Express-style chain.
#
# Each middleware is called as mw(req, nxt). The terminal handler is
# called as handler(req). The handler's return value — and any short-
# circuit return from a middleware — is normalised to the canonical
# list(status, body, headers) shape before being handed back up the
# chain, so middleware can always treat `nxt()`'s result as a list
# (e.g. `res$headers[["X-Tag"]] <- "y"`) without having to handle
# bare-string returns.
.dr_run_chain <- function(middleware, handler, req) {
  i <- 0L
  n <- length(middleware)
  step <- function() {
    i <<- i + 1L
    if (i > n) return(.dr_normalize_response(handler(req)))
    mw <- middleware[[i]]
    .dr_normalize_response(mw(req, step))
  }
  step()
}
