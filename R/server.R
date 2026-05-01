.onLoad <- function(libname, pkgname) {
  # Force later's event loop to initialize so the C++ dispatcher can
  # call later_fd() / R_GetCCallable("later", "apiVersion") on the
  # main R thread without racing the namespace load.
  later::current_loop()
  invisible(NULL)
}

# Process-wide state for the parent of a multi-process serve. Workers are
# launched as fresh R processes via processx::process$new(Rscript, ...);
# we hold on to the process objects (so we can SIGTERM/SIGKILL them and
# read pids reliably) and the rds file holding the serialized app config.
.drogonR_state <- new.env(parent = emptyenv())
.drogonR_state$worker_procs <- list()
.drogonR_state$worker_rds   <- NULL

#' Create a drogonR application
#'
#' Creates a fresh, empty `drogon_app` object that holds the route table
#' and configuration for a server. Routes are added with [dr_get()],
#' [dr_post()], [dr_put()], [dr_delete()], and the server is started
#' with [dr_serve()].
#'
#' The returned object is a mutable [environment] (so route-registration
#' calls modify it in place and return it invisibly for use with `|>`).
#'
#' @return An object of class `drogon_app`.
#' @examples
#' app <- dr_app()
#' app <- dr_get(app, "/", function(req) "hello")
#' @export
dr_app <- function() {
  app <- new.env(parent = emptyenv())
  app$routes     <- list()
  app$middleware <- list()
  app$port       <- NULL
  app$handle     <- NULL
  class(app) <- "drogon_app"
  app
}

.dr_check_app <- function(app) {
  if (!inherits(app, "drogon_app")) {
    stop("`app` must be a drogon_app object (see dr_app())", call. = FALSE)
  }
}

.dr_route_key <- function(method, path) {
  paste0(toupper(method), " ", path)
}

.dr_add_route <- function(app, method, path, handler) {
  .dr_check_app(app)
  if (!is.function(handler)) {
    stop("`handler` must be a function", call. = FALSE)
  }
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single string", call. = FALSE)
  }
  key <- .dr_route_key(method, path)
  if (!is.null(app$routes[[key]])) {
    warning("overwriting existing route ", key, call. = FALSE)
  }
  app$routes[[key]] <- list(method = toupper(method),
                            path    = path,
                            handler = handler)
  invisible(app)
}

#' Register HTTP route handlers
#'
#' Register an R function as the handler for a given HTTP method and path.
#' The handler is called for every matching request with a single argument
#' `req` — a `drogon_request` object. The handler must return either a
#' single character string (sent as `text/plain`, status 200) or the result
#' of [dr_response()] / [dr_json()].
#'
#' Routes must be registered *before* calling [dr_serve()]. Each call
#' returns the `app` invisibly so calls can be chained with `|>`.
#'
#' @param app A `drogon_app` created by [dr_app()].
#' @param path Request path, e.g. `"/users"`.
#' @param handler A function of one argument (the request object).
#'
#' @return The `app` (modified in place), invisibly.
#' @examples
#' app <- dr_app()
#' app <- dr_get(app, "/ping", function(req) "pong")
#' app <- dr_post(app, "/echo", function(req) req$body)
#' @name dr_routes
NULL

#' @rdname dr_routes
#' @export
dr_get <- function(app, path, handler) {
  .dr_add_route(app, "GET", path, handler)
}

#' @rdname dr_routes
#' @export
dr_post <- function(app, path, handler) {
  .dr_add_route(app, "POST", path, handler)
}

#' @rdname dr_routes
#' @export
dr_put <- function(app, path, handler) {
  .dr_add_route(app, "PUT", path, handler)
}

#' @rdname dr_routes
#' @export
dr_delete <- function(app, path, handler) {
  .dr_add_route(app, "DELETE", path, handler)
}

#' Register a C++ route handler (planned)
#'
#' Placeholder for v0.2: register a route whose handler runs entirely in
#' C++ without dispatching to R. Currently raises an error.
#'
#' @inheritParams dr_routes
#'
#' @return Currently raises an error; will return `app` (invisibly) in v0.2.
#' @export
dr_get_cpp <- function(app, path, handler) {
  stop("dr_get_cpp() is not yet implemented (planned for v0.2)",
       call. = FALSE)
}

#' Start the HTTP server
#'
#' Starts the bundled Drogon HTTP server on the given port and number of
#' I/O threads. The Drogon event loop runs in dedicated C++ threads;
#' incoming requests are dispatched to R handlers on the main R thread
#' via [later::later_fd()].
#'
#' When `workers > 1`, drogonR spawns `workers` fresh R processes via
#' `Rscript` (not `fork()`); each worker runs its own Drogon listener on
#' the same port (Linux/macOS use `SO_REUSEPORT` for kernel-side load
#' balancing). The calling process is a thin **supervisor** — it does
#' not serve requests itself, only tracks worker pids and reaps them at
#' [dr_stop()]. `on_worker_start` runs in each worker immediately
#' before its Drogon listener starts, so per-worker state (models,
#' caches) is loaded before the first request lands. Going through
#' `Rscript`+`exec` (rather than `parallel::mcparallel()`) costs ~200ms
#' of startup per worker but gives each worker a clean R: no inherited
#' sink stack, no inherited `later` event-loop fds, no half-initialised
#' C++ globals from the supervisor.
#'
#' If `on_worker_start` throws in a child, that child exits with status
#' 1 after writing the error to stderr; the supervisor notices it on
#' the next [dr_status()] call and continues with the surviving
#' workers. There is no auto-restart in v0.1.
#'
#' @section Lifetime:
#' Drogon's event loop cannot be restarted in the same R session. After
#' calling [dr_stop()], a new [dr_serve()] in the same process will raise
#' an error — start a fresh R session instead.
#'
#' @param app A `drogon_app` with at least one registered route.
#' @param port TCP port to bind, integer in `1..65535`. Defaults to 8080.
#' @param threads Number of Drogon I/O threads per worker, integer `>= 1`.
#'   Defaults to 1.
#' @param workers Number of OS-level worker processes. `1L` (default)
#'   serves in-process. `> 1` spawns workers as fresh `Rscript` processes
#'   and the calling process becomes a thin supervisor. Not supported
#'   on Windows.
#' @param on_worker_start Optional `function()` run once per worker
#'   before its Drogon listener starts. Use it to load models or open
#'   per-worker resources. Errors abort that worker (exit status 1).
#' @param max_queue Maximum number of pending requests waiting for an R
#'   handler before incoming requests are rejected with HTTP 503
#'   (Service Unavailable). Acts as backpressure when handlers are
#'   slower than the arrival rate, preventing unbounded memory growth.
#'   503 responses are sent directly from a Drogon I/O thread without
#'   touching R, so overload has no R-side cost. Default `1024L`.
#' @param upload_path Directory where Drogon stores uploaded files. By
#'   default, a fresh subdirectory inside [tempdir()] is created so the
#'   package never writes to its installation directory.
#'
#' @return `NULL`, invisibly. Prints a one-line listening message.
#' @examples
#' \dontrun{
#' app <- dr_app() |>
#'   dr_get("/hello", function(req) "hi")
#' dr_serve(app, port = 8080L)
#'
#' # Multi-process, each worker loads its own model copy
#' dr_serve(app, port = 8080L, workers = 4L,
#'          on_worker_start = function() {
#'            model <<- readRDS("model.rds")
#'          })
#' }
#' @export
dr_serve <- function(app, port = 8080L, threads = 1L,
                     workers = 1L,
                     on_worker_start = NULL,
                     max_queue = 1024L,
                     upload_path = file.path(tempdir(), "drogonR-uploads")) {
  .dr_check_app(app)
  if (isTRUE(.Call(drogonR_server_running))) {
    stop("a drogonR server is already running in this process; ",
         "call dr_stop() first", call. = FALSE)
  }
  port      <- as.integer(port)
  threads   <- as.integer(threads)
  workers   <- as.integer(workers)
  max_queue <- as.integer(max_queue)
  if (length(port) != 1L || is.na(port) || port < 1L || port > 65535L) {
    stop("`port` must be a single integer in 1..65535", call. = FALSE)
  }
  if (length(threads) != 1L || is.na(threads) || threads < 1L) {
    stop("`threads` must be a single integer >= 1", call. = FALSE)
  }
  if (length(workers) != 1L || is.na(workers) || workers < 1L) {
    stop("`workers` must be a single integer >= 1", call. = FALSE)
  }
  if (length(max_queue) != 1L || is.na(max_queue) || max_queue < 1L) {
    stop("`max_queue` must be a single integer >= 1", call. = FALSE)
  }
  if (workers > 1L && .Platform$OS.type == "windows") {
    stop("workers > 1 is not supported on Windows (no fork())",
         call. = FALSE)
  }
  if (!is.null(on_worker_start) && !is.function(on_worker_start)) {
    stop("`on_worker_start` must be NULL or a function", call. = FALSE)
  }
  if (!is.character(upload_path) || length(upload_path) != 1L ||
      is.na(upload_path)) {
    stop("`upload_path` must be a single string", call. = FALSE)
  }
  dir.create(upload_path, showWarnings = FALSE, recursive = TRUE)
  upload_path <- normalizePath(upload_path, mustWork = TRUE)
  if (length(app$routes) == 0L) {
    warning("no routes registered on this app", call. = FALSE)
  }

  if (workers == 1L) {
    # In-process serve. on_worker_start runs in this very R session;
    # if it fails we surface a normal R error and never start Drogon.
    if (!is.null(on_worker_start)) {
      tryCatch(on_worker_start(),
               error = function(e) {
                 stop("on_worker_start failed: ", conditionMessage(e),
                      call. = FALSE)
               })
    }
    has_mw <- length(app$middleware) > 0L
    .Call(drogonR_clear_routes)
    for (r in app$routes) {
      reg <- if (has_mw) .dr_wrap_handler(r$handler, app) else r$handler
      .Call(drogonR_register_route, r$method, r$path, reg)
    }
    app$port <- port
    .Call(drogonR_server_start, port, threads, upload_path, max_queue)
    message("drogonR listening on http://0.0.0.0:", port,
            " (threads=", threads, ", workers=1, routes=",
            length(app$routes), ")")
    return(invisible(NULL))
  }

  # Multi-process: this R process becomes a thin supervisor. Each
  # worker is a fresh Rscript process running its own Drogon listener
  # on the same port via SO_REUSEPORT. The supervisor never registers
  # routes locally and never calls drogonR_server_start.
  worker_script <- system.file("exec", "worker.R", package = "drogonR")
  if (!nzchar(worker_script)) {
    stop("internal error: inst/exec/worker.R not installed with drogonR",
         call. = FALSE)
  }
  rscript <- file.path(R.home("bin"), "Rscript")
  rds_path <- tempfile("drogonR-worker-", fileext = ".rds")
  saveRDS(list(app             = app,
               port            = port,
               threads         = threads,
               upload_path     = upload_path,
               on_worker_start = on_worker_start,
               max_queue       = max_queue),
          rds_path)
  procs <- vector("list", workers)
  for (i in seq_len(workers)) {
    procs[[i]] <- processx::process$new(
      command = rscript,
      args    = c("--vanilla", worker_script, rds_path, as.character(i)),
      stdout  = "",
      stderr  = "")
  }
  .drogonR_state$worker_procs <- procs
  .drogonR_state$worker_rds   <- rds_path
  message("drogonR supervisor: ", workers, " workers on ",
          "http://0.0.0.0:", port, " (threads=", threads,
          ", routes=", length(app$routes), ")")
  invisible(NULL)
}

#' Stop the HTTP server
#'
#' Stops the in-process Drogon event loop (when `workers == 1L`) and
#' joins the I/O threads. In supervisor mode (`workers > 1L`), sends
#' `SIGTERM` to every tracked worker, waits up to ~2s for them to exit,
#' then `SIGKILL`s any survivor. No-op if no server is running and no
#' workers are tracked.
#'
#' Drogon cannot be restarted in the same R session — see [dr_serve()].
#'
#' @return `NULL`, invisibly.
#' @export
dr_stop <- function() {
  .Call(drogonR_server_stop)
  .dr_kill_workers()
  invisible(NULL)
}

# SIGTERM every tracked worker, give them up to 2s to exit gracefully,
# then SIGKILL any survivor. processx::process owns the worker fds, so
# the kernel reaps the child for us — we just need to drop the R object
# (which happens implicitly when worker_procs is reset).
.dr_kill_workers <- function() {
  procs <- .drogonR_state$worker_procs
  rds   <- .drogonR_state$worker_rds
  on.exit({
    .drogonR_state$worker_procs <- list()
    .drogonR_state$worker_rds   <- NULL
    if (!is.null(rds) && file.exists(rds)) {
      unlink(rds, force = TRUE)
    }
  }, add = TRUE)
  if (length(procs) == 0L) return(invisible(NULL))

  for (p in procs) {
    if (p$is_alive()) {
      tryCatch(p$signal(tools::SIGTERM), error = function(e) NULL)
    }
  }
  deadline <- Sys.time() + 2
  repeat {
    if (!any(vapply(procs, function(p) p$is_alive(), logical(1)))) break
    if (Sys.time() > deadline) break
    Sys.sleep(0.05)
  }
  for (p in procs) {
    if (p$is_alive()) {
      tryCatch(p$kill(), error = function(e) NULL)
    }
  }
  invisible(NULL)
}

#' Status of forked worker processes
#'
#' Reports which workers forked by [dr_serve()] are still alive.
#' Polls only when called — there is no background supervisor in v0.1,
#' so dead workers are noticed only here or at [dr_stop()] time. Returns
#' an empty data frame in single-process mode.
#'
#' @return A data frame with columns `pid` (integer) and `alive`
#'   (logical), one row per tracked worker child.
#' @export
dr_status <- function() {
  procs <- .drogonR_state$worker_procs
  if (length(procs) == 0L) {
    return(data.frame(pid   = integer(),
                      alive = logical()))
  }
  pids  <- vapply(procs, function(p) as.integer(p$get_pid()), integer(1))
  alive <- vapply(procs, function(p) p$is_alive(), logical(1))
  for (i in seq_along(pids)) {
    if (!alive[i]) {
      message("drogonR worker pid=", pids[i], " has exited")
    }
  }
  data.frame(pid = pids, alive = alive)
}

#' Is the drogonR server currently running?
#'
#' @return `TRUE` if a server is running in this process, `FALSE` otherwise.
#' @export
dr_running <- function() {
  isTRUE(.Call(drogonR_server_running))
}

.dr_wrap_handler <- function(handler, app) {
  force(handler); force(app)
  function(req_list) {
    req <- .dr_make_request(req_list)
    middleware <- app$middleware
    res <- tryCatch(.dr_run_chain(middleware, handler, req),
                    error = function(e) {
                      .dr_response(500L,
                                   paste0("R handler error: ",
                                          conditionMessage(e)),
                                   list("Content-Type" = "text/plain"))
                    })
    .dr_normalize_response(res)
  }
}
