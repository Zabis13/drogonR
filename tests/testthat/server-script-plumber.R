# Helper Rscript launched by test-plumber-shim-server.R via processx.
#
# Like server-script.R but loads a plumber.R file and runs it through
# drogonR::pr_run() so the integration test exercises the real
# pr_run() entry point in a fresh R session (avoids inherited later
# state / drogon globals from the supervisor).
#
# Invocation: Rscript --vanilla server-script-plumber.R <plumber_R_path> <port>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  writeLines("server-script-plumber: expected 2 args (plumber.R, port)",
             con = stderr())
  quit(status = 2L, save = "no", runLast = FALSE)
}
plumber_path <- args[[1L]]
port         <- as.integer(args[[2L]])

suppressPackageStartupMessages({
  library(drogonR)
  library(plumber)
})

pr <- plumber::pr(plumber_path)
drogonR::pr_run(pr, host = "0.0.0.0", port = port)
