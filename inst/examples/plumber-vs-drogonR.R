#!/usr/bin/env Rscript
# Side-by-side: the same plumber.R served by plumber::pr_run() vs.
# drogonR::pr_run(). The point is to demonstrate the one-line swap:
#
#     library(plumber)                       library(plumber)
#     pr <- pr("plumber.R")                  pr <- pr("plumber.R")
#     plumber::pr_run(pr, port = 8001)       drogonR::pr_run(pr, port = 8002)
#
# Both servers run in fresh child Rscript processes (so this parent can
# drive curl while their main R threads service requests). For every
# case we hit both ports and print the responses next to each other.
# A divergence column flags any difference in status / body so a
# regression in the shim is loud, not silent.
#
# Run:
#   Rscript inst/examples/plumber-vs-drogonR.R
#
# Requires: drogonR + plumber installed, processx, curl on PATH.

suppressPackageStartupMessages({
  library(drogonR)
})

if (!requireNamespace("plumber", quietly = TRUE)) {
  message("This example requires the 'plumber' package.\n",
          "Install it with: install.packages(\"plumber\")")
  quit(status = 1L, save = "no")
}
if (!requireNamespace("processx", quietly = TRUE)) {
  message("This example requires the 'processx' package.\n",
          "Install it with: install.packages(\"processx\")")
  quit(status = 1L, save = "no")
}

`%||%` <- function(a, b) if (is.null(a)) b else a
flush_now <- function() { try(flush.console(), silent = TRUE); invisible() }
T0 <- Sys.time()
ts <- function(...) {
  dt <- as.numeric(Sys.time() - T0, units = "secs")
  cat(sprintf("[t=%6.3fs] ", dt), ..., "\n", sep = "")
  flush_now()
}

PORT_PLUMBER <- 28960L
PORT_DROGON  <- 28961L

# ---------------------------------------------------------------------
# The shared plumber.R. This is the file that exists once and gets
# served two different ways. Anything you'd write in a real plumber
# project goes here unchanged — that's the whole point of the shim.
# ---------------------------------------------------------------------
PLUMBER_R <- '
#* Health check (used to detect server readiness).
#* @get /__ping__
function() "pong"

#* Plain text response.
#* @get /hello
function() "hello world"

#* Path parameter — type annotation is honored by plumber, ignored by
#* drogonR (the value arrives as a string under drogonR; pr_run() warns
#* once at startup so this never surprises).
#* @get /users/<id:int>
function(id) {
  list(id = id, type = class(id))
}

#* Query parameters resolved by name from the handler signature.
#* @get /search
function(q, n) {
  list(q = q, n = n)
}

#* JSON body — args matched by name out of the parsed body.
#* @post /echo
function(name, age) {
  list(name = name, age = age)
}

#* data.frame return — both backends serialize via jsonlite as an array
#* of row-objects.
#* @put /df
function() {
  data.frame(x = 1:3, y = c("a", "b", "c"))
}
'

# ---------------------------------------------------------------------
# Child Rscript drivers. Two tiny inline scripts — one for each backend
# — written into tempfiles and launched via processx.
# ---------------------------------------------------------------------
write_runner <- function(plumber_path, port, backend) {
  body <- switch(backend,
    plumber = sprintf(
      "suppressPackageStartupMessages(library(plumber))\n\
pr <- plumber::pr(%s)\n\
plumber::pr_run(pr, host = \"127.0.0.1\", port = %dL)\n",
      shQuote(plumber_path), port),
    drogonR = sprintf(
      "suppressPackageStartupMessages({\n\
  library(plumber); library(drogonR)\n\
})\n\
pr <- plumber::pr(%s)\n\
drogonR::pr_run(pr, host = \"127.0.0.1\", port = %dL)\n",
      shQuote(plumber_path), port))
  out <- tempfile(paste0("runner-", backend, "-"), fileext = ".R")
  writeLines(body, out)
  out
}

start_proc <- function(script) {
  processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script),
    stdout  = "|", stderr = "|")
}

wait_ready <- function(port, path = "/__ping__", timeout = 15) {
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
      stop(sprintf("server on :%d did not respond within %ds",
                   port, timeout))
    }
    Sys.sleep(0.1)
  }
}

stop_proc <- function(proc) {
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
}

hit <- function(port, method, path, body = NULL,
                headers = character()) {
  url  <- sprintf("http://127.0.0.1:%d%s", port, path)
  args <- c("-s", "-X", method, "--max-time", "5",
            "-w", "\n%{http_code}")
  for (h in headers) args <- c(args, "-H", h)
  if (!is.null(body)) args <- c(args, "--data-binary", body)
  args <- c(args, url)
  raw  <- tryCatch(system2("curl", args = shQuote(args),
                           stdout = TRUE, stderr = FALSE),
                   error = function(e) c("", "ERR"))
  # Last line is the status code (-w prefixed with \n); rest is the body.
  if (length(raw) == 0L) return(list(status = "ERR", body = ""))
  status <- raw[length(raw)]
  body_  <- if (length(raw) > 1L)
    paste(raw[seq_len(length(raw) - 1L)], collapse = "\n") else ""
  list(status = status, body = body_)
}

section <- function(n, title) {
  cat("\n", strrep("=", 76), "\n", sep = "")
  cat(sprintf("[%02d] %s\n", n, title))
  cat(strrep("=", 76), "\n", sep = "")
  flush_now()
}

# Print a plumber/drogonR result pair side-by-side and flag divergence.
compare <- function(p, d) {
  cat(sprintf("  plumber  [%s]: %s\n", p$status, p$body))
  cat(sprintf("  drogonR  [%s]: %s\n", d$status, d$body))
  same_status <- identical(p$status, d$status)
  same_body   <- identical(p$body, d$body)
  if (same_status && same_body) {
    cat("  -> identical\n")
  } else {
    if (!same_status) cat("  -> DIVERGED on status\n")
    if (!same_body)   cat("  -> DIVERGED on body  ",
                          "(plumber-style serialization differences are ",
                          "expected for some shapes)\n", sep = "")
  }
  flush_now()
}

# ---------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------
plumber_file <- tempfile("plumber-", fileext = ".R")
writeLines(PLUMBER_R, plumber_file)

ts("wrote shared plumber.R to ", plumber_file)

cat("\n--- before / after (the only line you change) ---\n")
cat("# before:  plumber::pr_run(pr, port = 8000)\n")
cat("# after :  drogonR::pr_run(pr, port = 8000)\n")

ts("starting plumber on  :", PORT_PLUMBER)
runner_p <- write_runner(plumber_file, PORT_PLUMBER, "plumber")
proc_p   <- start_proc(runner_p)

ts("starting drogonR on  :", PORT_DROGON)
runner_d <- write_runner(plumber_file, PORT_DROGON, "drogonR")
proc_d   <- start_proc(runner_d)

on.exit({
  ts("stopping both servers")
  stop_proc(proc_p)
  stop_proc(proc_d)
  unlink(c(plumber_file, runner_p, runner_d), force = TRUE)
}, add = TRUE)

wait_ready(PORT_PLUMBER, "/__ping__")
wait_ready(PORT_DROGON,  "/__ping__")
ts("both servers ready")

cases <- list(
  list(n = 1, title = "GET /hello — plain text",
       method = "GET", path = "/hello"),
  list(n = 2, title = "GET /users/42 — typed path param coerced to <id:int>",
       method = "GET", path = "/users/42"),
  list(n = 3, title = "GET /search?q=cats&n=10 — query parameters",
       method = "GET", path = "/search?q=cats&n=10"),
  list(n = 4, title = "POST /echo — JSON body matched by handler args",
       method = "POST", path = "/echo",
       body = '{"name":"jane","age":30}',
       headers = "Content-Type: application/json"),
  list(n = 5, title = "PUT /df — data.frame -> JSON array of row-objects",
       method = "PUT", path = "/df"))

for (c in cases) {
  section(c$n, c$title)
  cat(sprintf("$ %s %s\n", c$method, c$path))
  if (!is.null(c$body)) cat(sprintf("  body: %s\n", c$body))
  p <- hit(PORT_PLUMBER, c$method, c$path,
           body = c$body, headers = c$headers %||% character())
  d <- hit(PORT_DROGON,  c$method, c$path,
           body = c$body, headers = c$headers %||% character())
  compare(p, d)
}

cat("\n", strrep("=", 76), "\n", sep = "")
cat("Migration recipe\n")
cat(strrep("=", 76), "\n", sep = "")
cat("1. Install drogonR (one-time).\n")
cat("2. Replace `plumber::pr_run(pr, ...)` with `drogonR::pr_run(pr, ...)`.\n")
cat("   Same args, same plumber.R, same handlers.\n")
cat("3. <name:type> path-param annotations are honoured: int / integer,\n")
cat("   dbl / double / numeric, bool / logical. Unknown types pass\n")
cat("   through as character. Query / body args are not coerced (same\n")
cat("   as plumber's default serializer).\n")
cat("4. @filter / pr_hook() / pr_mount() are not supported and will\n")
cat("   error at startup, not silently. Migrate filters to dr_use()\n")
cat("   middleware via the native dr_app() API.\n\n")

ts("done")
