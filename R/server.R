#' @importFrom later current_loop
#' @keywords internal
.onLoad <- function(libname, pkgname) {
  # Force later's namespace + DLL to load before resolving its
  # C-callables. We can't use a static initializer in our .so for this
  # (it would race R CMD check phases that load drogonR's namespace
  # without first loading later), so we resolve lazily here.
  loadNamespace("later")
  later::current_loop()
  .Call(drogonR_init_later)
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
  app$routes            <- list()
  app$cpp_routes        <- list()
  app$cpp_stream_routes <- list()
  app$middleware        <- list()
  app$static_mounts     <- list()
  app$rate_limits       <- list()
  app$on_error      <- NULL
  app$port          <- NULL
  app$handle        <- NULL
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

# Translate a user-facing path pattern to a Drogon-side regex and the
# ordered list of parameter names. Accepts three placeholder syntaxes
# interchangeably:
#   /users/:id         (express/Rails style)
#   /users/<id>        (plumber style)
#   /users/{id}        (Drogon native style)
# A placeholder matches a single path segment ([^/]+). Regex metacharacters
# in the surrounding literal text are escaped so paths like "/v1.0/x" work
# unchanged. The resulting regex anchors the full path implicitly — Drogon
# requires a complete match.
.dr_compile_path <- function(path) {
  # Tokenise: alternating literal chunks and placeholders.
  re_placeholder <- "(:([A-Za-z_][A-Za-z0-9_]*))|<([A-Za-z_][A-Za-z0-9_]*)>|\\{([A-Za-z_][A-Za-z0-9_]*)\\}"
  m <- gregexpr(re_placeholder, path, perl = TRUE)[[1]]
  if (length(m) == 1L && m == -1L) {
    # No placeholders: regex == escaped path, no params.
    return(list(regex = .dr_escape_regex(path), param_names = character()))
  }
  starts <- as.integer(m)
  lens   <- attr(m, "match.length")
  out_parts  <- character()
  param_nms  <- character()
  pos <- 1L
  for (i in seq_along(starts)) {
    s <- starts[i]; e <- s + lens[i] - 1L
    if (s > pos) {
      out_parts <- c(out_parts, .dr_escape_regex(substr(path, pos, s - 1L)))
    }
    tok <- substr(path, s, e)
    nm <- sub(re_placeholder, "\\2\\3\\4", tok, perl = TRUE)
    param_nms  <- c(param_nms, nm)
    out_parts  <- c(out_parts, "([^/]+)")
    pos <- e + 1L
  }
  if (pos <= nchar(path)) {
    out_parts <- c(out_parts, .dr_escape_regex(substr(path, pos, nchar(path))))
  }
  if (anyDuplicated(param_nms)) {
    stop("duplicate path parameter names in '", path, "': ",
         paste(param_nms[duplicated(param_nms)], collapse = ", "),
         call. = FALSE)
  }
  list(regex = paste(out_parts, collapse = ""), param_names = param_nms)
}

.dr_escape_regex <- function(s) {
  gsub("([.\\+*?\\[\\](){}^$|])", "\\\\\\1", s, perl = TRUE)
}

.dr_add_route <- function(app, method, path, handler) {
  .dr_check_app(app)
  if (!is.function(handler)) {
    stop("`handler` must be a function", call. = FALSE)
  }
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single string", call. = FALSE)
  }
  compiled <- .dr_compile_path(path)
  key <- .dr_route_key(method, path)
  if (!is.null(app$routes[[key]])) {
    warning("overwriting existing route ", key, call. = FALSE)
  }
  app$routes[[key]] <- list(method      = toupper(method),
                            path        = path,
                            regex       = compiled$regex,
                            param_names = compiled$param_names,
                            handler     = handler)
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

#' Register a native C / C++ route handler
#'
#' Bind a path to a handler implemented in another R package's C / C++
#' code, looked up via [base::getNativeSymbolInfo()]-style
#' `R_RegisterCCallable` / `R_GetCCallable`. The handler runs on
#' Drogon's worker thread pool — **never** on the R main thread — so
#' its hot path bypasses the R dispatcher entirely. Use this for
#' inference-bound APIs (embeddings, classifiers, GGML/llama.cpp
#' wrappers) where SEXP allocation and `R_tryEval` per request would
#' dominate latency.
#'
#' The handler signature is `drogonr_unary_handler_t`, defined in
#' `<drogonR.h>` (shipped under `inst/include/`). Backend packages
#' should `LinkingTo: drogonR` in their DESCRIPTION, `#include
#' <drogonR.h>` in their C / C++ sources, and call
#' `R_RegisterCCallable("<package>", "<callable>", ...)` in their
#' `R_init_<package>` to expose the function.
#'
#' Lookup is eager: `dr_get_cpp()` calls `requireNamespace(package)`
#' immediately and resolves `<callable>` against the loaded DLL. If
#' the package is not installed or the callable is unregistered, the
#' error fires here (during route registration), not silently at
#' request time.
#'
#' @section Threading and the R API:
#' Native handlers are invoked on Drogon worker threads. They MUST
#' NOT touch any `SEXP` or call any function in the R API (`Rf_*`,
#' `R_*`, `Rprintf`, etc.) — doing so is undefined behaviour. Load
#' models, allocate caches, and read configuration from R BEFORE
#' [dr_serve()] is called; per-request work runs in pure C / C++.
#'
#' @section Middleware and error handler:
#' R-side [dr_use()] middleware and the [dr_on_error()] hook are
#' **not** invoked for native routes — they require the request to
#' enter R, which is exactly what this path avoids. Authentication,
#' logging, header injection, etc. must be done either inside the
#' backend handler itself or in front of drogonR (e.g. in a reverse
#' proxy). Per-route [dr_rate_limit()] rules **are** applied (the
#' check runs on the I/O thread before dispatch).
#'
#' @param app A `drogon_app` created by [dr_app()].
#' @param path Request path, with the same `:name` / `<name>` /
#'   `\{name\}` placeholder syntaxes as [dr_get()]. Path parameter
#'   values are passed positionally to the handler.
#' @param package Name of the backend R package that registered the
#'   callable.
#' @param callable Name passed to the backend's
#'   `R_RegisterCCallable("<package>", "<callable>", ...)` call.
#'
#' @return The `app`, invisibly.
#' @examples
#' \dontrun{
#' # In package ggmlR, R_init_ggmlR() does:
#' #   R_RegisterCCallable("ggmlR", "embed",
#' #                       (DL_FUNC) ggmlr_embed);
#' app <- dr_app() |>
#'   dr_post_cpp("/embed", package = "ggmlR", callable = "embed")
#' dr_serve(app, port = 8080L)
#' }
#' @name dr_routes_cpp
NULL

.dr_add_cpp_route <- function(app, method, path, package, callable) {
  .dr_check_app(app)
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single string", call. = FALSE)
  }
  if (!is.character(package) || length(package) != 1L || is.na(package) ||
      !nzchar(package)) {
    stop("`package` must be a single non-empty string", call. = FALSE)
  }
  if (!is.character(callable) || length(callable) != 1L ||
      is.na(callable) || !nzchar(callable)) {
    stop("`callable` must be a single non-empty string", call. = FALSE)
  }
  if (!requireNamespace(package, quietly = TRUE)) {
    stop("dr_*_cpp: package '", package, "' is not installed; ",
         "install it before registering native handlers", call. = FALSE)
  }
  # Resolve the C-callable now (eager) — getting the externalptr here
  # means a typo or an unregistered symbol surfaces during route
  # registration, not on the first request.
  ptr <- tryCatch(
    .Call(drogonR_resolve_ccallable, package, callable),
    error = function(e) {
      stop("dr_*_cpp: R_GetCCallable(\"", package, "\", \"", callable,
           "\") failed: ", conditionMessage(e),
           ". Make sure the package's R_init_", package,
           "() registers the callable.", call. = FALSE)
    })
  compiled <- .dr_compile_path(path)
  key <- .dr_route_key(method, path)
  if (!is.null(app$cpp_routes[[key]]) || !is.null(app$routes[[key]])) {
    warning("overwriting existing route ", key, call. = FALSE)
  }
  app$cpp_routes[[key]] <- list(method      = toupper(method),
                                path        = path,
                                regex       = compiled$regex,
                                param_names = compiled$param_names,
                                package     = package,
                                callable    = callable,
                                ptr         = ptr)
  invisible(app)
}

#' @rdname dr_routes_cpp
#' @export
dr_get_cpp <- function(app, path, package, callable) {
  .dr_add_cpp_route(app, "GET", path, package, callable)
}

#' @rdname dr_routes_cpp
#' @export
dr_post_cpp <- function(app, path, package, callable) {
  .dr_add_cpp_route(app, "POST", path, package, callable)
}

#' @rdname dr_routes_cpp
#' @export
dr_put_cpp <- function(app, path, package, callable) {
  .dr_add_cpp_route(app, "PUT", path, package, callable)
}

#' @rdname dr_routes_cpp
#' @export
dr_delete_cpp <- function(app, path, package, callable) {
  .dr_add_cpp_route(app, "DELETE", path, package, callable)
}

# Internal: shared body for streaming cpp-routes.
.dr_add_cpp_stream_route <- function(app, method, path, package, callable,
                                     content_type = NA_character_) {
  .dr_check_app(app)
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single string", call. = FALSE)
  }
  if (!is.character(package) || length(package) != 1L || is.na(package) ||
      !nzchar(package)) {
    stop("`package` must be a single non-empty string", call. = FALSE)
  }
  if (!is.character(callable) || length(callable) != 1L ||
      is.na(callable) || !nzchar(callable)) {
    stop("`callable` must be a single non-empty string", call. = FALSE)
  }
  if (!is.character(content_type) || length(content_type) != 1L) {
    stop("`content_type` must be a single string or NA", call. = FALSE)
  }
  if (!requireNamespace(package, quietly = TRUE)) {
    stop("dr_*_cpp_stream: package '", package, "' is not installed; ",
         "install it before registering native handlers", call. = FALSE)
  }
  ptr <- tryCatch(
    .Call(drogonR_resolve_ccallable, package, callable),
    error = function(e) {
      stop("dr_*_cpp_stream: R_GetCCallable(\"", package, "\", \"",
           callable, "\") failed: ", conditionMessage(e),
           ". Make sure the package's R_init_", package,
           "() registers the callable.", call. = FALSE)
    })
  compiled <- .dr_compile_path(path)
  key <- .dr_route_key(method, path)
  if (!is.null(app$cpp_stream_routes[[key]]) ||
      !is.null(app$cpp_routes[[key]]) ||
      !is.null(app$routes[[key]])) {
    warning("overwriting existing route ", key, call. = FALSE)
  }
  app$cpp_stream_routes[[key]] <- list(method       = toupper(method),
                                       path         = path,
                                       regex        = compiled$regex,
                                       param_names  = compiled$param_names,
                                       package      = package,
                                       callable     = callable,
                                       content_type = content_type,
                                       ptr          = ptr)
  invisible(app)
}

#' Register a streaming native (R-bypass) handler
#'
#' Like [dr_get_cpp()] but for streaming responses (HTTP chunked / SSE
#' / LLM token streams). The backend handler runs on a drogonR worker
#' thread and pushes chunks via the C callbacks declared in
#' `<drogonR.h>` (`drogonr_stream_handler_t`).
#'
#' The backend is responsible for `R_RegisterCCallable("<package>",
#' "<callable>", ...)` with a `drogonr_stream_handler_t` signature.
#' Mismatched signatures are undefined behavior — there is no runtime
#' type check on the function pointer.
#'
#' @section Middleware and error handler:
#' R-side [dr_use()] middleware and the [dr_on_error()] hook are
#' **not** invoked for native streaming routes — the request never
#' enters R. Cross-cutting concerns belong in the backend or in a
#' reverse proxy. Per-route [dr_rate_limit()] rules **are** applied
#' on the I/O thread before the worker is dispatched.
#'
#' @param app A `drogon_app` from [dr_app()].
#' @param path URL path; same syntax as [dr_get()].
#' @param package R package that exposes the handler.
#' @param callable Symbol name registered via `R_RegisterCCallable`.
#' @param content_type Default `Content-Type` for the response.
#'   Defaults to `"text/event-stream"`. The backend may override this
#'   per call by writing to `*out_content_type`.
#'
#' @return `app`, invisibly.
#' @name dr_routes_cpp_stream
#' @export
dr_get_cpp_stream <- function(app, path, package, callable,
                              content_type = "text/event-stream") {
  .dr_add_cpp_stream_route(app, "GET", path, package, callable, content_type)
}

#' @rdname dr_routes_cpp_stream
#' @export
dr_post_cpp_stream <- function(app, path, package, callable,
                               content_type = "text/event-stream") {
  .dr_add_cpp_stream_route(app, "POST", path, package, callable, content_type)
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
#' @param cpp_workers Size of the worker thread pool that runs native
#'   (R-bypass) handlers registered via `dr_*_cpp()` and
#'   `dr_*_cpp_stream()`. Each in-flight cpp request occupies one
#'   thread; streaming handlers hold their thread for the full
#'   duration of the response. Default `4L`. Increase if you have many
#'   concurrent long-running cpp-stream sessions (e.g. LLM token
#'   streams). Has no effect on R-side handlers.
#' @param upload_path Directory where Drogon stores uploaded files.
#'   Defaults to `NULL`, in which case a fresh subdirectory inside
#'   [tempdir()] is created so the package never writes to the user's
#'   home filespace or the installation directory. Pass an explicit
#'   path to override.
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
                     cpp_workers = 4L,
                     upload_path = NULL) {
  .dr_check_app(app)
  if (isTRUE(.Call(drogonR_server_running))) {
    stop("a drogonR server is already running in this process; ",
         "call dr_stop() first", call. = FALSE)
  }
  port        <- as.integer(port)
  threads     <- as.integer(threads)
  workers     <- as.integer(workers)
  max_queue   <- as.integer(max_queue)
  cpp_workers <- as.integer(cpp_workers)
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
  if (length(cpp_workers) != 1L || is.na(cpp_workers) || cpp_workers < 1L) {
    stop("`cpp_workers` must be a single integer >= 1", call. = FALSE)
  }
  if (workers > 1L && .Platform$OS.type == "windows") {
    stop("workers > 1 is not supported on Windows (no fork())",
         call. = FALSE)
  }
  if (!is.null(on_worker_start) && !is.function(on_worker_start)) {
    stop("`on_worker_start` must be NULL or a function", call. = FALSE)
  }
  if (is.null(upload_path)) {
    upload_path <- file.path(tempdir(), "drogonR-uploads")
  }
  if (!is.character(upload_path) || length(upload_path) != 1L ||
      is.na(upload_path)) {
    stop("`upload_path` must be a single string or NULL", call. = FALSE)
  }
  dir.create(upload_path, showWarnings = FALSE, recursive = TRUE)
  upload_path <- normalizePath(upload_path, mustWork = TRUE)
  n_routes <- length(app$routes) + length(app$cpp_routes) +
              length(app$cpp_stream_routes) +
              length(app$static_mounts)
  if (n_routes == 0L) {
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
    has_mw     <- length(app$middleware) > 0L
    has_onerr  <- !is.null(app$on_error)
    .Call(drogonR_clear_routes)
    .Call(drogonR_register_rate_limits, app$rate_limits)
    for (r in app$routes) {
      reg <- if (has_mw || has_onerr)
        .dr_wrap_handler(r$handler, app) else r$handler
      .Call(drogonR_register_route, r$method, r$path, r$regex,
            r$param_names, reg)
    }
    for (sm in app$static_mounts) {
      abs_dir <- normalizePath(sm$dir, mustWork = TRUE)
      .Call(drogonR_register_static, sm$mount, abs_dir)
    }
    for (cr in app$cpp_routes) {
      .Call(drogonR_register_cpp_route, cr$method, cr$path, cr$regex,
            cr$param_names, cr$ptr)
    }
    for (cr in app$cpp_stream_routes) {
      .Call(drogonR_register_cpp_stream_route, cr$method, cr$path,
            cr$regex, cr$param_names, cr$ptr,
            as.character(cr$content_type))
    }
    app$port <- port
    .Call(drogonR_server_start, port, threads, upload_path, max_queue,
          cpp_workers)
    message("drogonR listening on http://0.0.0.0:", port,
            " (threads=", threads, ", workers=1, routes=",
            length(app$routes),
            ", cpp_routes=", length(app$cpp_routes),
            ", cpp_stream_routes=", length(app$cpp_stream_routes),
            ", static=", length(app$static_mounts), ")")
    return(invisible(NULL))
  }

  # Multi-process: this R process becomes a thin supervisor. Each
  # worker is a fresh Rscript process running its own Drogon listener
  # on the same port via SO_REUSEPORT. The supervisor never registers
  # routes locally and never calls drogonR_server_start.
  worker_script <- system.file("worker", "worker.R", package = "drogonR")
  if (!nzchar(worker_script)) {
    stop("internal error: inst/worker/worker.R not installed with drogonR",
         call. = FALSE)
  }
  rscript <- file.path(R.home("bin"), "Rscript")
  rds_path <- tempfile("drogonR-worker-", fileext = ".rds")
  saveRDS(list(app             = app,
               port            = port,
               threads         = threads,
               upload_path     = upload_path,
               on_worker_start = on_worker_start,
               max_queue       = max_queue,
               cpp_workers     = cpp_workers),
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
          ", routes=", length(app$routes),
          ", cpp_routes=", length(app$cpp_routes),
          ", cpp_stream_routes=", length(app$cpp_stream_routes),
          ", static=", length(app$static_mounts), ")")
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
                    error = function(e) .dr_handle_error(app, req, e))
    .dr_normalize_response(res)
  }
}

# Build the 500 response when the user handler / middleware chain throws.
# If the app has a custom on_error hook, invoke it; if THAT throws, surface
# both the original handler error and the on_error error to stderr so the
# user can see why their custom 500 path is broken — silently swallowing
# either one makes this nearly undebuggable.
.dr_handle_error <- function(app, req, err) {
  if (is.null(app$on_error)) {
    return(.dr_response(500L,
                        paste0("R handler error: ", conditionMessage(err)),
                        list("Content-Type" = "text/plain")))
  }
  tryCatch(app$on_error(req, err),
           error = function(e2) {
             message("drogonR: dr_on_error() handler itself threw; ",
                     "falling back to default 500.")
             message("  original handler error: ", conditionMessage(err))
             message("  on_error error: ",         conditionMessage(e2))
             .dr_response(500L,
                          paste0("R handler error: ", conditionMessage(err)),
                          list("Content-Type" = "text/plain"))
           })
}

#' Register a custom error handler
#'
#' Install a function that builds the response when a route handler or
#' middleware throws an R error. The function receives `(req, err)` —
#' the request object and the captured `condition` — and must return a
#' response (string, [dr_response()], [dr_json()], etc.). It is called
#' on the main R thread, after the handler / middleware chain has
#' already failed; returning normally short-circuits the default 500.
#'
#' If the on-error function itself throws, drogonR logs **both** the
#' original handler error and the on-error error to stderr (via
#' [message()]) and falls back to the default plain-text 500 — the
#' client never sees a hung connection. Only one on-error handler is
#' active per app; calling `dr_on_error()` again replaces it.
#'
#' @param app A `drogon_app` created by [dr_app()].
#' @param fn A function of two arguments, `function(req, err)`. Pass
#'   `NULL` to clear a previously-registered handler.
#'
#' @return The `app`, invisibly.
#' @examples
#' app <- dr_app() |>
#'   dr_on_error(function(req, err) {
#'     dr_json(list(error = conditionMessage(err),
#'                  path  = req$path),
#'             status = 500L)
#'   }) |>
#'   dr_get("/boom", function(req) stop("nope"))
#' @export
dr_on_error <- function(app, fn) {
  .dr_check_app(app)
  if (!is.null(fn) && !is.function(fn)) {
    stop("`fn` must be NULL or a function(req, err)", call. = FALSE)
  }
  app$on_error <- fn
  invisible(app)
}

#' Mount a directory as static files
#'
#' Serve every file under `dir` at URLs starting with `mount`. The
#' files are streamed by Drogon directly from a C++ I/O thread (R is
#' never invoked), so this path supports `Range` requests and
#' auto-detects `Content-Type`. Both `GET` and `HEAD` are accepted;
#' missing files return 404, attempted path traversal returns 403.
#'
#' @section Path traversal:
#' The handler resolves the requested path against `dir` and rejects
#' (HTTP 403) any request whose normalised target escapes `dir` —
#' a `..` segment, an absolute path, or anything else that would
#' otherwise let a remote caller read files outside the mount.
#'
#' @section Middleware and error handler:
#' Static files are served entirely from a C++ I/O thread, so R-side
#' [dr_use()] middleware and the [dr_on_error()] hook do **not**
#' apply — they only run for requests that enter R. If you need
#' authentication, custom headers, or per-file logging on assets,
#' put a reverse proxy in front of drogonR or expose the files
#' through a regular [dr_get()] handler instead.
#'
#' @param app A `drogon_app` created by [dr_app()].
#' @param mount URL prefix to mount under, e.g. `"/assets"`. Must start
#'   with `/`. A trailing `/` is stripped.
#' @param dir Local directory to serve from. Must exist at
#'   [dr_serve()] time.
#'
#' @return The `app`, invisibly.
#' @examples
#' \dontrun{
#' app <- dr_app() |>
#'   dr_static("/assets", "./public") |>
#'   dr_get("/api/ping", function(req) "pong")
#' dr_serve(app, port = 8080L)
#' # GET /assets/logo.png streams ./public/logo.png from C++.
#' }
#' @export
dr_static <- function(app, mount, dir) {
  .dr_check_app(app)
  if (!is.character(mount) || length(mount) != 1L || is.na(mount) ||
      !nzchar(mount) || substr(mount, 1L, 1L) != "/") {
    stop("`mount` must be a single string starting with '/'", call. = FALSE)
  }
  if (!is.character(dir) || length(dir) != 1L || is.na(dir) ||
      !nzchar(dir)) {
    stop("`dir` must be a single non-empty string", call. = FALSE)
  }
  mount <- sub("/+$", "", mount)
  if (!nzchar(mount)) {
    stop("`mount` must not be just '/'; use a non-empty prefix", call. = FALSE)
  }
  app$static_mounts[[length(app$static_mounts) + 1L]] <-
    list(mount = mount, dir = dir)
  invisible(app)
}

#' Apply a rate limit to one or more routes
#'
#' Adds a rate-limit rule to `app`. On each matching request, the
#' Drogon I/O thread checks the rule's bucket *before* dispatching to
#' R; if the bucket is empty the request is rejected with HTTP 429
#' (Too Many Requests) and a `Retry-After` header. Multiple
#' `dr_rate_limit()` calls add independent rules — a request must
#' satisfy *all* of them to pass.
#'
#' Per-IP limiting is intentionally not provided: do that in a reverse
#' proxy (nginx, Caddy, Cloudflare). This API is for shaping load on
#' specific endpoints from the application side.
#'
#' Call `dr_rate_limit()` *after* registering routes (so prefix
#' matches resolve correctly) and *before* [dr_serve()].
#'
#' @param app A `drogon_app` from [dr_app()].
#' @param capacity Maximum number of requests allowed in `window`
#'   seconds (per-bucket; see `scope`). Integer `>= 1`.
#' @param window Time window for the bucket, in seconds. Default `60`.
#' @param type One of `"sliding_window"` (default — counts requests
#'   in the trailing `window` seconds), `"fixed_window"` (resets at
#'   wall-clock boundaries), or `"token_bucket"` (constant refill rate
#'   with burst capacity).
#' @param scope `"per_route"` (default) gives every matched route its
#'   own bucket. `"global"` makes one bucket shared across all routes
#'   matched by this rule.
#' @param routes Either `NULL` (the default — applies to every
#'   registered route) or a character vector of path **prefixes**
#'   (e.g. `c("/api/", "/stream/")`). A route matches if its path
#'   starts with any of the given prefixes.
#'
#' @return The `app`, invisibly.
#' @examples
#' \dontrun{
#' app <- dr_app() |>
#'   dr_get("/health", function(req) "ok") |>
#'   dr_get("/api/users", function(req) "users") |>
#'   # 100 req/min per route under /api/, health excluded
#'   dr_rate_limit(capacity = 100L, window = 60, routes = "/api/")
#' dr_serve(app, port = 8080L)
#' }
#' @export
dr_rate_limit <- function(app,
                          capacity,
                          window = 60,
                          type   = c("sliding_window", "fixed_window",
                                     "token_bucket"),
                          scope  = c("per_route", "global"),
                          routes = NULL) {
  .dr_check_app(app)
  type  <- match.arg(type)
  scope <- match.arg(scope)
  if (missing(capacity) || !is.numeric(capacity) ||
      length(capacity) != 1L || is.na(capacity) || capacity < 1) {
    stop("`capacity` must be a single integer >= 1", call. = FALSE)
  }
  if (!is.numeric(window) || length(window) != 1L ||
      is.na(window) || window <= 0) {
    stop("`window` must be a single positive number (seconds)",
         call. = FALSE)
  }
  if (!is.null(routes)) {
    if (!is.character(routes) || anyNA(routes) || any(!nzchar(routes))) {
      stop("`routes` must be NULL or a character vector of non-empty ",
           "path prefixes", call. = FALSE)
    }
    if (!all(substr(routes, 1L, 1L) == "/")) {
      stop("every entry of `routes` must start with '/'", call. = FALSE)
    }
  }
  app$rate_limits[[length(app$rate_limits) + 1L]] <-
    list(capacity = as.integer(capacity),
         window   = as.numeric(window),
         type     = type,
         scope    = scope,
         routes   = routes)
  invisible(app)
}
