#!/usr/bin/env Rscript
# drogonR cpp-route bench server (variant 1 — C++ shared path).
# Args: port [threads].
#
# Routes:
#   GET /ping       — JSON {"ok":true} produced by a C handler in
#                     drogonRtestbackend (resolved via R_GetCCallable);
#                     R is not in the hot path.
#   GET /ping-text  — plain "ok" via the same mechanism.
#
# The dummy backend (inst/test-backend/drogonRtestbackend) is built &
# installed on demand into tools/bench/.libs/ so this script is
# self-contained.
suppressPackageStartupMessages(library(drogonR))

script_dir <- function() {
  ca <- commandArgs(trailingOnly = FALSE)
  m  <- regmatches(ca, regexpr("^--file=", ca))
  if (length(m) == 1L) return(dirname(normalizePath(sub("^--file=", "", ca[grepl("^--file=", ca)]))))
  normalizePath(".")
}

ensure_backend <- function() {
  if (requireNamespace("drogonRtestbackend", quietly = TRUE)) return(invisible())

  bench <- script_dir()
  src   <- normalizePath(file.path(bench, "..", "..",
                                   "inst", "test-backend",
                                   "drogonRtestbackend"))
  if (!dir.exists(src)) stop("drogonRtestbackend source not found at ", src)

  lib <- file.path(bench, ".libs")
  dir.create(lib, showWarnings = FALSE, recursive = TRUE)
  .libPaths(c(lib, .libPaths()))

  if (!dir.exists(file.path(lib, "drogonRtestbackend"))) {
    r_bin <- file.path(R.home("bin"), "R")
    res <- system2(r_bin,
                   c("CMD", "INSTALL", "--no-multiarch", "--no-test-load",
                     paste0("--library=", lib), src),
                   stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(res, "status")) && attr(res, "status") != 0L) {
      stop("R CMD INSTALL drogonRtestbackend failed:\n",
           paste(res, collapse = "\n"))
    }
  }
  loadNamespace("drogonRtestbackend")
  invisible()
}

ensure_backend()

args <- commandArgs(trailingOnly = TRUE)
port    <- if (length(args) >= 1L) as.integer(args[[1]]) else 8082L
threads <- if (length(args) >= 2L) as.integer(args[[2]]) else 4L

app <- dr_app() |>
  dr_get_cpp("/ping",      "drogonRtestbackend", "ping_json") |>
  dr_get_cpp("/ping-text", "drogonRtestbackend", "ping_text")

dr_serve(app, port = port, threads = threads)

repeat later::run_now(timeoutSecs = 3600)
