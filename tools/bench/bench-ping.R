#!/usr/bin/env Rscript
# drogonR ping server for bench/profile. Args: port [threads].
#
# Routes:
#   GET /ping       — JSON {"ok":true}; matches plumber bench for parity
#   GET /ping-text  — plain "ok"; floor overhead, no jsonlite call
suppressPackageStartupMessages(library(drogonR))

args <- commandArgs(trailingOnly = TRUE)
port    <- if (length(args) >= 1L) as.integer(args[[1]]) else 8080L
threads <- if (length(args) >= 2L) as.integer(args[[2]]) else 4L

app <- dr_app() |>
  dr_get("/ping",      function(req) dr_json(list(ok = TRUE))) |>
  dr_get("/ping-text", function(req) "ok")

dr_serve(app, port = port, threads = threads)

# Drive later's loop on the main thread so the dispatcher fires.
repeat later::run_now(timeoutSecs = 3600)
