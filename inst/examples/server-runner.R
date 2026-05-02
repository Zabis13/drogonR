#!/usr/bin/env Rscript
# Helper Rscript launched by inst/examples/diag-api-walkthrough.R via
# processx. Same shape as tests/testthat/server-script.R: read an rds
# payload describing how to set up the app, start the server, then
# crank later::run_now() forever so the dispatcher can fire.
#
# Invocation: Rscript --vanilla server-runner.R <rds_path>
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
  writeLines("server-runner: expected 1 argument (rds_path)",
             con = stderr())
  quit(status = 2L, save = "no", runLast = FALSE)
}
cfg <- readRDS(args[[1L]])

suppressPackageStartupMessages(library(drogonR))

app <- cfg$setup(dr_app())
dr_serve(app, port = as.integer(cfg$port), threads = 1L)

repeat later::run_now(timeoutSecs = 3600)
