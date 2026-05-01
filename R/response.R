#' Build an HTTP response
#'
#' Constructs the list shape that route handlers must return: a `status`,
#' a `body`, and a list of headers. Returning the result of `dr_response()`
#' is interchangeable with returning a plain list with the same fields.
#'
#' @param body Response body as a character string or raw vector.
#' @param status Integer HTTP status code, default 200.
#' @param headers Named list of response headers.
#'
#' @return A list with elements `status`, `body`, `headers`.
#' @examples
#' dr_response("ok")
#' dr_response("not found", status = 404L)
#' @export
dr_response <- function(body = "", status = 200L, headers = list()) {
  .dr_response(status, body, headers)
}

.dr_response <- function(status, body, headers) {
  list(status  = as.integer(status),
       body    = body,
       headers = headers)
}

#' Build a JSON response
#'
#' Serialises `x` with [jsonlite::toJSON()] and sets `Content-Type:
#' application/json` (unless already set in `headers`).
#'
#' @param x R object to serialise.
#' @param status Integer HTTP status code, default 200.
#' @param headers Named list of additional response headers.
#' @param auto_unbox Passed to [jsonlite::toJSON()]; default `TRUE` so
#'   length-1 vectors become JSON scalars.
#'
#' @return A response list (see [dr_response()]).
#' @examples
#' dr_json(list(ok = TRUE, n = 1L))
#' @export
dr_json <- function(x, status = 200L, headers = list(), auto_unbox = TRUE) {
  # Fast path: a small C++ walker handles the common shapes that real
  # REST handlers produce (LGL/INT/REAL/STR/NULL/named or unnamed
  # VECSXP without class attributes). It returns NULL on anything it's
  # not certain about (factor, Date/POSIXct, RAW, S4, AsIs, deeply
  # nested) — we then fall back to jsonlite, which is the source of
  # truth for everything we don't reimplement.
  body <- .Call(drogonR_to_json, x, isTRUE(auto_unbox))
  if (is.null(body)) {
    if (!requireNamespace("jsonlite", quietly = TRUE)) {
      stop("dr_json() requires the jsonlite package for this input",
           call. = FALSE)
    }
    body <- as.character(jsonlite::toJSON(x, auto_unbox = auto_unbox))
  }
  headers[["Content-Type"]] <-
    headers[["Content-Type"]] %||% "application/json"
  .dr_response(status, body, headers)
}

.dr_normalize_response <- function(res) {
  if (is.character(res) && length(res) == 1L) {
    return(.dr_response(200L, res, list("Content-Type" = "text/plain")))
  }
  if (is.list(res) && !is.null(res$body)) {
    if (is.null(res$status))  res$status  <- 200L
    if (is.null(res$headers)) res$headers <- list()
    res$status <- as.integer(res$status)
    return(res)
  }
  .dr_response(500L, "R handler returned an unsupported value",
               list("Content-Type" = "text/plain"))
}
