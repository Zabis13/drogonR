# Helper Rscript launched by test-server-lifecycle.R via processx.
#
# Lives in tests/testthat/ but with a non-`helper-` prefix so testthat
# does NOT auto-source it into the supervisor R session. Tests resolve
# the path via testthat::test_path("server-script.R").
#
# Invocation: Rscript --vanilla server-script.R <rds_path>
#
# The rds payload is list(setup = function(app), port = int) where
# `setup` registers routes / middleware on a fresh app. Running in a
# fresh Rscript ensures geterrmessage() in the C bridge sees only this
# request's error, not stale state inherited via fork() from the
# testthat supervisor.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
  writeLines("server-script: expected 1 argument (rds_path)",
             con = stderr())
  quit(status = 2L, save = "no", runLast = FALSE)
}
cfg <- readRDS(args[[1L]])

suppressPackageStartupMessages(library(drogonR))

app <- cfg$setup(dr_app())
dr_serve(app, port = as.integer(cfg$port), threads = 1L)

repeat later::run_now(timeoutSecs = 3600)
