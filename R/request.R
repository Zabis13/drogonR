.dr_make_request <- function(req_list) {
  req <- new.env(parent = emptyenv())
  req$method  <- req_list$method
  req$path    <- req_list$path
  req$body    <- req_list$body
  req$headers <- req_list$headers %||% character()
  req$query   <- req_list$query   %||% character()
  req$params  <- list()
  class(req) <- "drogon_request"
  req
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Read a request header
#'
#' Looks up a header by name, case-insensitively.
#'
#' @param req A `drogon_request` passed to your route handler.
#' @param name Header name (e.g. `"Content-Type"`).
#'
#' @return The header value as a single string, or `NULL` if absent.
#' @export
dr_header <- function(req, name) {
  if (!inherits(req, "drogon_request")) {
    stop("`req` must be a drogon_request", call. = FALSE)
  }
  h <- req$headers
  if (length(h) == 0L) return(NULL)
  nm <- names(h)
  if (is.null(nm)) return(NULL)
  hit <- which(tolower(nm) == tolower(name))
  if (length(hit) == 0L) NULL else unname(h[[hit[1]]])
}

#' Read query-string parameters
#'
#' Returns either the named character vector of all query parameters
#' (when `name = NULL`, the default), or the value of a single parameter.
#' Drogon parses and URL-decodes the query string before delivery.
#'
#' @param req A `drogon_request`.
#' @param name Parameter name, or `NULL` to get the full named vector.
#'
#' @return A named character vector when `name` is `NULL`, otherwise a
#'   single string or `NULL` if the parameter is absent.
#' @export
dr_query <- function(req, name = NULL) {
  if (!inherits(req, "drogon_request")) {
    stop("`req` must be a drogon_request", call. = FALSE)
  }
  q <- req$query
  if (is.null(name)) return(q)
  if (length(q) == 0L) return(NULL)
  hit <- which(names(q) == name)
  if (length(hit) == 0L) NULL else unname(q[[hit[1]]])
}

#' Read the request body
#'
#' Returns the body as raw text, parsed JSON, or a raw byte vector.
#'
#' @param req A `drogon_request`.
#' @param as Output form: `"text"` (default), `"json"`, or `"raw"`.
#'   `"json"` requires the `jsonlite` package.
#'
#' @return A character string, parsed R object, or raw vector.
#' @export
dr_body <- function(req, as = c("text", "json", "raw")) {
  if (!inherits(req, "drogon_request")) {
    stop("`req` must be a drogon_request", call. = FALSE)
  }
  as <- match.arg(as)
  switch(as,
         text = req$body,
         raw  = charToRaw(req$body %||% ""),
         json = {
           if (!requireNamespace("jsonlite", quietly = TRUE)) {
             stop("dr_body(as = 'json') requires the jsonlite package",
                  call. = FALSE)
           }
           jsonlite::fromJSON(req$body %||% "null", simplifyVector = TRUE)
         })
}
