# Helper Rscript launched by test-cpp-routes.R via processx.
# Lives in tests/testthat/ but with a non-`helper-` prefix so testthat
# does NOT auto-source it into the supervisor R session.
#
# Invocation: Rscript ... server-script-cpp.R <rds_path>
#
# rds payload: list(port = int,
#                   routes = list(list(method, path, package, callable), ...))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
  writeLines("server-script-cpp: expected 1 argument (rds_path)",
             con = stderr())
  quit(status = 2L, save = "no", runLast = FALSE)
}
cfg <- readRDS(args[[1L]])

suppressPackageStartupMessages(library(drogonR))

app <- dr_app()
add_one <- function(method, path, package, callable, kind = "unary",
                    max_conns = 0, idle_timeout = 0, max_lifetime = 0) {
  if (identical(kind, "ws")) {
    return(drogonR::dr_ws_cpp(app, path, package, callable,
                              max_conns    = max_conns,
                              idle_timeout = idle_timeout,
                              max_lifetime = max_lifetime))
  }
  if (identical(kind, "stream")) {
    fn <- switch(method,
                 GET  = drogonR::dr_get_cpp_stream,
                 POST = drogonR::dr_post_cpp_stream,
                 stop("unsupported stream method ", method))
    return(fn(app, path, package, callable))
  }
  fn <- switch(method,
               GET    = drogonR::dr_get_cpp,
               POST   = drogonR::dr_post_cpp,
               PUT    = drogonR::dr_put_cpp,
               DELETE = drogonR::dr_delete_cpp,
               stop("unknown method ", method))
  fn(app, path, package, callable)
}
for (r in cfg$routes) {
  app <- add_one(r$method, r$path, r$package, r$callable,
                 kind = if (is.null(r$kind)) "unary" else r$kind,
                 max_conns    = if (is.null(r$max_conns))    0 else r$max_conns,
                 idle_timeout = if (is.null(r$idle_timeout)) 0 else r$idle_timeout,
                 max_lifetime = if (is.null(r$max_lifetime)) 0 else r$max_lifetime)
}

cpp_workers <- if (is.null(cfg$cpp_workers)) 4L else as.integer(cfg$cpp_workers)
dr_serve(app, port = as.integer(cfg$port), threads = 1L,
         cpp_workers = cpp_workers)
repeat later::run_now(timeoutSecs = 3600)
