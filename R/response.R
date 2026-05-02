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

#' Build a plain-text response
#'
#' Sets `Content-Type: text/plain; charset=utf-8`. The charset is
#' explicit because some intermediaries / older clients otherwise
#' fall back to a non-UTF-8 default and mangle non-ASCII bodies.
#'
#' @param body Response body as a character string or raw vector.
#' @param status Integer HTTP status code, default 200.
#' @param headers Named list of additional response headers. An
#'   explicit `Content-Type` here wins over the default.
#'
#' @return A response list (see [dr_response()]).
#' @examples
#' dr_text("hello")
#' dr_text("not found", status = 404L)
#' @export
dr_text <- function(body = "", status = 200L, headers = list()) {
  headers[["Content-Type"]] <-
    headers[["Content-Type"]] %||% "text/plain; charset=utf-8"
  .dr_response(status, body, headers)
}

#' Build an HTML response
#'
#' Sets `Content-Type: text/html; charset=utf-8`.
#'
#' @inheritParams dr_text
#' @return A response list (see [dr_response()]).
#' @examples
#' dr_html("<h1>hi</h1>")
#' @export
dr_html <- function(body = "", status = 200L, headers = list()) {
  headers[["Content-Type"]] <-
    headers[["Content-Type"]] %||% "text/html; charset=utf-8"
  .dr_response(status, body, headers)
}

#' Build a redirect response
#'
#' Sets the `Location` header and an empty body. Default status is
#' 302 (Found / temporary). Use `status = 301L` for permanent moves,
#' `303L` after a POST, or `307L`/`308L` to preserve the request method.
#'
#' @param location Target URL (absolute or relative).
#' @param status Integer HTTP status code, default 302.
#' @param headers Named list of additional response headers.
#'
#' @return A response list (see [dr_response()]).
#' @examples
#' dr_redirect("/login")
#' dr_redirect("https://example.com", status = 301L)
#' @export
dr_redirect <- function(location, status = 302L, headers = list()) {
  if (!is.character(location) || length(location) != 1L || is.na(location) ||
      !nzchar(location)) {
    stop("`location` must be a single non-empty string", call. = FALSE)
  }
  headers[["Location"]] <- location
  .dr_response(status, "", headers)
}

# Built-in MIME map. Covers ~99% of static content seen in REST APIs
# (avoids depending on the `mime` package). Lookup is case-insensitive
# on the extension. Unknown extensions fall back to
# application/octet-stream — clients then guess from sniffing.
.dr_mime_table <- c(
  html  = "text/html; charset=utf-8",
  htm   = "text/html; charset=utf-8",
  css   = "text/css; charset=utf-8",
  js    = "application/javascript; charset=utf-8",
  json  = "application/json",
  xml   = "application/xml",
  txt   = "text/plain; charset=utf-8",
  csv   = "text/csv; charset=utf-8",
  png   = "image/png",
  jpg   = "image/jpeg",
  jpeg  = "image/jpeg",
  gif   = "image/gif",
  svg   = "image/svg+xml",
  webp  = "image/webp",
  ico   = "image/x-icon",
  pdf   = "application/pdf",
  zip   = "application/zip",
  gz    = "application/gzip",
  mp3   = "audio/mpeg",
  mp4   = "video/mp4",
  webm  = "video/webm",
  woff  = "font/woff",
  woff2 = "font/woff2",
  ttf   = "font/ttf",
  otf   = "font/otf",
  wasm  = "application/wasm"
)

.dr_guess_mime <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (!nzchar(ext)) return("application/octet-stream")
  hit <- .dr_mime_table[[ext]]
  if (is.null(hit)) "application/octet-stream" else hit
}

#' Build a file response
#'
#' Reads `path` into memory as raw bytes and returns it as the body.
#' For v0.1 the entire file is held in R memory; sendfile-style
#' zero-copy delivery is planned for v0.2 via `dr_static()`. Files
#' larger than 50 MB emit a warning; files larger than 500 MB raise
#' an error to prevent accidental out-of-memory loads.
#'
#' @param path Path to a regular file readable by the calling process.
#' @param content_type MIME type for the response. `NULL` (the
#'   default) auto-detects from the file extension via a built-in
#'   table; unknown extensions become `application/octet-stream`.
#' @param status Integer HTTP status code, default 200.
#' @param headers Named list of additional response headers.
#' @param download_as If a non-empty string, sets
#'   `Content-Disposition: attachment; filename="..."` so browsers
#'   prompt to save under that name.
#'
#' @return A response list (see [dr_response()]).
#' @examples
#' \dontrun{
#' dr_file("/tmp/report.pdf")
#' dr_file("/tmp/report.pdf", download_as = "Q3-report.pdf")
#' }
#' @export
dr_file <- function(path, content_type = NULL, status = 200L,
                    headers = list(), download_as = NULL) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single string", call. = FALSE)
  }
  if (!file.exists(path)) {
    stop("dr_file: file not found: ", path, call. = FALSE)
  }
  size <- file.size(path)
  if (is.na(size)) {
    stop("dr_file: cannot stat file: ", path, call. = FALSE)
  }
  if (size > 500L * 1024L * 1024L) {
    stop("dr_file: file > 500MB (", round(size / 1024 / 1024), "MB): ",
         "use dr_static() for large files or sendfile support ",
         "(planned for v0.2). Path: ", path, call. = FALSE)
  }
  if (size > 50L * 1024L * 1024L) {
    warning("dr_file: loading ", round(size / 1024 / 1024),
            "MB into memory; consider dr_static() for large files",
            call. = FALSE)
  }
  if (is.null(content_type)) {
    content_type <- .dr_guess_mime(path)
  }
  if (!is.character(content_type) || length(content_type) != 1L) {
    stop("`content_type` must be NULL or a single string", call. = FALSE)
  }
  body <- readBin(path, what = "raw", n = as.integer(size))
  headers[["Content-Type"]] <-
    headers[["Content-Type"]] %||% content_type
  if (!is.null(download_as)) {
    if (!is.character(download_as) || length(download_as) != 1L ||
        is.na(download_as) || !nzchar(download_as)) {
      stop("`download_as` must be NULL or a single non-empty string",
           call. = FALSE)
    }
    headers[["Content-Disposition"]] <-
      sprintf('attachment; filename="%s"', download_as)
  }
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
