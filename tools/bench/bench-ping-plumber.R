#!/usr/bin/env Rscript
# plumber ping server for bench. Single arg: port.
suppressPackageStartupMessages(library(plumber))

args <- commandArgs(trailingOnly = TRUE)
port <- if (length(args) >= 1L) as.integer(args[[1]]) else 8081L

pr <- pr() |>
  pr_get("/ping", function() list(ok = TRUE))

pr_run(pr, host = "0.0.0.0", port = port, docs = FALSE)
