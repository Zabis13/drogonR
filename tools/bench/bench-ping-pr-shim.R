#!/usr/bin/env Rscript
# Bench server for variant 3 — drogonR as a drop-in replacement for
# plumber. Identical plumber object as bench-ping-plumber.R, but
# served via drogonR::pr_run() (the shim parses the plumber object
# and dispatches through dr_serve).
#
# Args: port.
suppressPackageStartupMessages({
  library(plumber)
  library(drogonR)
})

args <- commandArgs(trailingOnly = TRUE)
port <- if (length(args) >= 1L) as.integer(args[[1]]) else 8083L

pr <- pr() |>
  pr_get("/ping",      function() list(ok = TRUE)) |>
  pr_get("/ping-text", function() "ok")

# Important: this is drogonR::pr_run, NOT plumber::pr_run.
# `docs = FALSE` is plumber-specific (swagger off); the shim silently
# accepts and ignores it — the whole point of variant 3 is that
# existing plumber call sites work unchanged.
drogonR::pr_run(pr, host = "0.0.0.0", port = port, docs = FALSE)

repeat later::run_now(timeoutSecs = 3600)
