# drogonR worker entry point.
#
# Invocation: Rscript --vanilla worker.R <rds_path> <worker_id>
#
# Started by dr_serve(workers > N) as a fresh R process via system2(Rscript).
# This is intentionally NOT a forked child: parallel::mcparallel() inherits
# the supervisor's sink stack, later::current_loop() fds, open connections,
# and partially initialised C++ globals — under test_dir() the inherited
# message-sink stack alone kills the worker before it can start Drogon.
# Going through Rscript+exec gives us a clean R + clean process state, at
# the cost of having to serialize `app` and friends into an rds.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  writeLines("drogonR worker: expected 2 arguments (rds_path, worker_id)",
             con = stderr())
  quit(status = 2L, save = "no", runLast = FALSE)
}
rds_path  <- args[[1L]]
worker_id <- as.integer(args[[2L]])

cfg <- readRDS(rds_path)

# Distinct PRNG stream per worker. Under fork+mcparallel, parallel did this
# for us via L'Ecuyer-CMRG; with Rscript we have to do it ourselves so two
# workers with the same handler don't produce identical "random" output.
set.seed(Sys.getpid() + worker_id * 1009L)

suppressPackageStartupMessages(library(drogonR))

if (!is.null(cfg$on_worker_start)) {
  ok <- tryCatch({ cfg$on_worker_start(); TRUE },
                 error = function(e) {
                   writeLines(
                     paste0("drogonR worker ", worker_id,
                            " on_worker_start failed: ",
                            conditionMessage(e)),
                     con = stderr())
                   FALSE
                 })
  if (!isTRUE(ok)) {
    quit(status = 1L, save = "no", runLast = FALSE)
  }
}

# Rscript's --file mode auto-prints top-level expression values; .Call
# returning NULL would otherwise leak `NULL` lines onto the supervisor's
# stdout. Wrap the bring-up in invisible().
invisible({
  has_mw    <- length(cfg$app$middleware) > 0L
  has_onerr <- !is.null(cfg$app$on_error)
  .Call(drogonR:::drogonR_clear_routes)
  for (r in cfg$app$routes) {
    reg <- if (has_mw || has_onerr)
      drogonR:::.dr_wrap_handler(r$handler, cfg$app) else r$handler
    .Call(drogonR:::drogonR_register_route, r$method, r$path, r$regex,
          r$param_names, reg)
  }
  for (sm in cfg$app$static_mounts) {
    abs_dir <- normalizePath(sm$dir, mustWork = TRUE)
    .Call(drogonR:::drogonR_register_static, sm$mount, abs_dir)
  }
  # Re-resolve C-callables in this fresh worker R session — the
  # externalptr we serialised in the supervisor is invalid here
  # (different DLL load address; the externalptr's payload becomes
  # a dangling pointer after RDS round-trip).
  for (cr in cfg$app$cpp_routes) {
    ptr <- .Call(drogonR:::drogonR_resolve_ccallable,
                 cr$package, cr$callable)
    .Call(drogonR:::drogonR_register_cpp_route, cr$method, cr$path,
          cr$regex, cr$param_names, ptr)
  }
  .Call(drogonR:::drogonR_server_start,
        as.integer(cfg$port), as.integer(cfg$threads),
        cfg$upload_path, as.integer(cfg$max_queue),
        as.integer(cfg$cpp_workers))
})

# No REPL in the worker — drive later's loop ourselves so the dispatcher
# fires when Drogon enqueues a request.
repeat later::run_now(timeoutSecs = 3600)
