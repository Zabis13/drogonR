#!/usr/bin/env Rscript
# Diagnostic walkthrough of the drogonR public API.
#
# The server runs in a child Rscript process (so its main R thread can
# crank `later::run_now()` and dispatch incoming requests); this parent
# process drives curl and prints request + response side-by-side. Use
# this as a smoke check after rebuilding the package or as an
# executable cheatsheet for v0.1.
#
# Run:
#   Rscript inst/examples/diag-api-walkthrough.R
#
# Requires: drogonR installed, processx, curl on PATH.

suppressPackageStartupMessages({
  library(drogonR)
})

flush_now <- function() { try(flush.console(), silent = TRUE); invisible() }

T0 <- Sys.time()
ts <- function(...) {
  dt <- as.numeric(Sys.time() - T0, units = "secs")
  cat(sprintf("[t=%6.3fs] ", dt), ..., "\n", sep = "")
  flush_now()
}

PORT <- 28950L
BASE <- sprintf("http://127.0.0.1:%d", PORT)

# ---------------------------------------------------------------------
# Server setup function — runs inside the child Rscript. Keep this as
# a self-contained closure: anything captured from the parent must
# survive saveRDS()/readRDS().
# ---------------------------------------------------------------------
server_setup <- function(app) {
  `%||%` <- function(a, b) if (is.null(a)) b else a

  # Pre-stage a tiny PNG and a CSV in tempdir so dr_file has something
  # real to serve. The child process inherits the rds-saved closure but
  # not arbitrary R state, so we recreate the files here on its side.
  png_bytes <- as.raw(c(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                        0x01, 0x02, 0x03, 0x04, 0x05))
  png_path  <- file.path(tempdir(), "drogonR-diag-tiny.png")
  csv_path  <- file.path(tempdir(), "drogonR-diag-data.csv")
  writeBin(png_bytes, png_path)
  writeLines(c("col_a,col_b", "1,foo", "2,bar"), csv_path)

  # Static-mount target: a small directory with one CSS file. Lives in
  # tempdir so we never write to the install tree.
  static_dir <- file.path(tempdir(), "drogonR-diag-static")
  dir.create(static_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines("body { font: 14px sans-serif; }",
             file.path(static_dir, "site.css"))

  app |>
    dr_on_error(function(req, err) {
      dr_json(list(error = conditionMessage(err),
                   path  = req$path,
                   from  = "dr_on_error"),
              status = 500L)
    }) |>
    dr_static("/assets", static_dir) |>
    dr_get("/hello", function(req) "hello world") |>
    dr_get("/users/:id", function(req) {
      sprintf("user id = %s", req$params[["id"]])
    }) |>
    dr_get("/api/<x>/posts/{slug}", function(req) {
      sprintf("x=%s slug=%s",
              req$params[["x"]], req$params[["slug"]])
    }) |>
    dr_get("/v1.0/users/:id", function(req) {
      sprintf("v1.0 user = %s", req$params[["id"]])
    }) |>
    dr_post("/echo-json", function(req) {
      parsed <- dr_body(req, as = "json")
      dr_json(list(received = parsed,
                   keys     = names(parsed)))
    }) |>
    dr_get("/search", function(req) {
      q <- dr_query(req, "q")
      n <- dr_query(req, "n")
      sprintf("q=%s n=%s", q %||% "(none)", n %||% "(none)")
    }) |>
    dr_get("/whoami", function(req) {
      ua <- dr_header(req, "user-agent")
      sprintf("UA = %s", ua %||% "(none)")
    }) |>
    dr_get("/json", function(req) {
      dr_json(list(ok = TRUE, n = 42L, items = c("a", "b", "c")))
    }) |>
    dr_get("/boom", function(req) {
      stop("kaboom: something went wrong")
    }) |>
    dr_get("/text", function(req) dr_text("plain UTF-8 text — café")) |>
    dr_get("/page", function(req) dr_html("<h1>Hello</h1><p>world</p>")) |>
    dr_get("/redir", function(req) dr_redirect("/hello")) |>
    dr_get("/file/png", function(req) dr_file(png_path)) |>
    dr_get("/file/csv", function(req) dr_file(csv_path,
                                              download_as = "report.csv"))
}

# ---------------------------------------------------------------------
# Helpers — child server lifecycle + curl-based hits.
# ---------------------------------------------------------------------

start_server <- function(port, setup) {
  if (!requireNamespace("processx", quietly = TRUE)) {
    stop("This script needs the 'processx' package")
  }
  script <- system.file("examples", "server-runner.R", package = "drogonR")
  if (!nzchar(script)) {
    # Fall back to the test helper, which has the same shape.
    script <- file.path(find.package("drogonR"),
                        "..", "drogonR", "tests", "testthat",
                        "server-script.R")
  }
  rds <- tempfile("drogonR-diag-", fileext = ".rds")
  saveRDS(list(setup = setup, port = port), rds)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script, rds),
    stdout  = "|", stderr = "|")
  attr(proc, "rds") <- rds
  proc
}

wait_ready <- function(port, path = "/hello", timeout = 10) {
  deadline <- Sys.time() + timeout
  url <- sprintf("http://127.0.0.1:%d%s", port, path)
  Sys.sleep(0.3)
  repeat {
    code <- suppressWarnings(system2(
      "curl", args = shQuote(c("-s", "-o", "/dev/null",
                               "-w", "%{http_code}",
                               "--max-time", "1", url)),
      stdout = TRUE, stderr = TRUE))
    if (length(code) == 1L && nzchar(code) && code != "000") {
      return(invisible(TRUE))
    }
    if (Sys.time() > deadline) {
      stop(sprintf("server on :%d did not respond within %ds", port, timeout))
    }
    Sys.sleep(0.1)
  }
}

stop_server <- function(proc) {
  rds <- attr(proc, "rds")
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

# Pretty banner around each case.
section <- function(n, title) {
  cat("\n")
  cat(strrep("=", 72), "\n", sep = "")
  cat(sprintf("[%02d] %s\n", n, title))
  cat(strrep("=", 72), "\n", sep = "")
  flush_now()
}

# Hit an endpoint with curl, print the request line and response body.
hit <- function(method, path, body = NULL, headers = character()) {
  url <- paste0(BASE, path)
  args <- c("-s", "-X", method, "--max-time", "5",
            "-w", " [HTTP %{http_code}]")
  for (h in headers) args <- c(args, "-H", h)
  if (!is.null(body)) args <- c(args, "--data-binary", body)
  args <- c(args, url)
  qargs <- shQuote(args)
  cat("$ curl ", paste(qargs, collapse = " "), "\n", sep = "")
  t0 <- Sys.time()
  out <- tryCatch(system2("curl", args = qargs,
                          stdout = TRUE, stderr = TRUE),
                  error = function(e) paste("ERROR:", conditionMessage(e)))
  dt <- as.numeric(Sys.time() - t0, units = "secs")
  cat(paste(out, collapse = "\n"), "\n", sep = "")
  cat(sprintf("(took %.3fs)\n", dt))
  flush_now()
  invisible(paste(out, collapse = "\n"))
}

# ---------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------

ts("starting server in child Rscript on port ", PORT)
proc <- start_server(PORT, server_setup)
on.exit(stop_server(proc), add = TRUE)
wait_ready(PORT, "/hello")
ts("server ready, walking through cases")

section(1, "GET /hello — plain text, no parameters")
hit("GET", "/hello")

section(2, "GET /users/:id — Express-style path parameter")
hit("GET", "/users/42")

section(3, "GET /api/<x>/posts/{slug} — mixed placeholder syntaxes")
hit("GET", "/api/foo/posts/hello-world")

section(4, "GET /v1.0/users/:id — literal '.' in the path")
hit("GET", "/v1.0/users/abc")
ts("now hitting /v1X0/... — should be 404 because '.' is escaped")
hit("GET", "/v1X0/users/abc")

section(5, "POST /echo-json — JSON body parsed via dr_body(as='json')")
hit("POST", "/echo-json",
    body    = '{"name":"jane","age":30}',
    headers = "Content-Type: application/json")

section(6, "GET /search?q=cats&n=10 — query parameters")
hit("GET", "/search?q=cats&n=10")

section(7, "GET /whoami — request header inspection")
hit("GET", "/whoami", headers = "User-Agent: drogonR-diag/1.0")

section(8, "GET /json — fast-path JSON response")
hit("GET", "/json")

section(9, "GET /boom — handler error → dr_on_error JSON 500")
b9 <- hit("GET", "/boom")
if (!grepl("kaboom", b9, fixed = TRUE)) {
  cat("WARN: response body did not contain 'kaboom' — error message ",
      "propagation may be broken.\n", sep = "")
}
if (!grepl("HTTP 500", b9, fixed = TRUE)) {
  cat("WARN: status code is not 500.\n")
}
if (!grepl("dr_on_error", b9, fixed = TRUE)) {
  cat("WARN: custom on_error did not run (no 'dr_on_error' marker).\n")
}

section(10, "GET /not-a-route — implicit 404")
hit("GET", "/does-not-exist")

section(11, "GET /text — dr_text() with charset=utf-8 (only header shown)")
hit("GET", "/text", headers = "Accept: */*")
ts("checking the Content-Type header explicitly")
hit_head <- system2("curl",
                    args = shQuote(c("-s", "-D", "-", "-o", "/dev/null",
                                     paste0(BASE, "/text"))),
                    stdout = TRUE)
ct_line <- grep("(?i)^Content-Type:", hit_head, value = TRUE, perl = TRUE)
cat("header  : ", paste(ct_line, collapse = " "), "\n", sep = ""); flush_now()

section(12, "GET /page — dr_html() with charset=utf-8")
hit("GET", "/page")

section(13, "GET /redir — dr_redirect('/hello'), 302 with Location header")
ts("first without -L (we want to see the 302 itself)")
hit_redir <- system2("curl",
                     args = shQuote(c("-s", "-D", "-", "-o", "/dev/null",
                                      "-w", "[HTTP %{http_code}]",
                                      paste0(BASE, "/redir"))),
                     stdout = TRUE)
cat(paste(hit_redir, collapse = "\n"), "\n", sep = ""); flush_now()
ts("then with -L so curl follows to /hello")
hit("GET", "/redir", headers = character()) # default curl in `hit` doesn't follow
# A more honest follow-through, using -L:
follow <- system2("curl",
                  args = shQuote(c("-sL", "-w", " [final HTTP %{http_code}]",
                                   paste0(BASE, "/redir"))),
                  stdout = TRUE)
cat("-L final: ", paste(follow, collapse = " "), "\n", sep = ""); flush_now()

section(14, "GET /file/png — dr_file(): bytes + auto MIME (image/png)")
ts("printing only the response headers (body is binary)")
hit_png <- system2("curl",
                   args = shQuote(c("-s", "-D", "-", "-o", "/dev/null",
                                    "-w", " [HTTP %{http_code}]",
                                    paste0(BASE, "/file/png"))),
                   stdout = TRUE)
cat(paste(hit_png, collapse = "\n"), "\n", sep = ""); flush_now()

section(15, "GET /file/csv — dr_file(..., download_as) → Content-Disposition")
hit_csv <- system2("curl",
                   args = shQuote(c("-s", "-D", "-", paste0(BASE, "/file/csv"))),
                   stdout = TRUE)
cat(paste(hit_csv, collapse = "\n"), "\n", sep = ""); flush_now()

section(16, "GET /assets/site.css — dr_static() served from C++ I/O thread")
hit_css <- system2("curl",
                   args = shQuote(c("-s", "-D", "-",
                                    paste0(BASE, "/assets/site.css"))),
                   stdout = TRUE)
cat(paste(hit_css, collapse = "\n"), "\n", sep = ""); flush_now()

section(17, "GET /assets/%2e%2e/passwd — path traversal must be 403/404")
hit("GET", "/assets/%2e%2e/passwd")

cat("\n")
ts("done — stopping server")
