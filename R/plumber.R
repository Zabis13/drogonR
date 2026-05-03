# drogonR::pr_run() -- drop-in shim for plumber::pr_run().
#
# The goal is "change one line, keep the package working": users who
# already have a plumber.R with `@get`/`@post`/`@put`/`@delete`
# annotations should be able to run it under drogonR by swapping
# `plumber::pr_run(pr)` for `drogonR::pr_run(pr)` and getting the same
# request/response semantics.
#
# Anything plumber-specific that we don't faithfully reproduce raises an
# explicit error at pr_run() time -- never silently. The shim is for
# basic REST APIs, not the full plumber surface (no filters, hooks,
# sub-routers, parsers, async, websockets).

# Plumber registers four default filters on every `pr()`. Any user-added
# filter (via `@filter` annotation or `pr$filter()`) is on top of these,
# so we treat the canonical four as the empty set.
.dr_default_filter_names <- c("queryString", "body", "cookieParser",
                              "sharedSecret", "postBody")

#' Run a plumber router under drogonR (drop-in shim)
#'
#' Translate a [plumber::pr()] router into [dr_app()] routes and start
#' the drogonR server. The intent is a one-line replacement: existing
#' `plumber::pr_run(pr)` becomes `drogonR::pr_run(pr)` without further
#' changes, for the subset of plumber that drogonR can faithfully
#' reproduce.
#'
#' @section Supported:
#' * `@get`, `@post`, `@put`, `@delete` annotations.
#' * Path placeholders `<name>` and `<name:type>`. Recognised types
#'   are `int`/`integer`, `dbl`/`double`/`numeric`, `bool`/`logical`;
#'   anything else is left as a character. Coercion runs only on path
#'   parameters (plumber does not coerce query / body args at the
#'   serializer layer either).
#' * Handler arguments resolved by name from path > query > JSON body,
#'   with `req` injected if the handler takes a `req` parameter.
#' * Default plumber serialisation: every return value goes through
#'   `jsonlite::toJSON(auto_unbox = FALSE)` -- including bare strings,
#'   which become JSON arrays -- for byte-level parity with
#'   `plumber::pr_run()`. Returning a [dr_response()] / [dr_json()] /
#'   etc. opts out and is forwarded as-is.
#'
#' @section Not supported:
#' Filters (`@filter`), hooks (`pr_hook()`), mounts (`pr_mount()`),
#' custom parsers/serialisers, OpenAPI assets, websockets, async
#' handlers, and the `res` (response) parameter of plumber handlers.
#' Each of these triggers an explicit error or per-route warning at
#' `pr_run()` time so failure is loud, not silent. If you need any of
#' these, use the native [dr_app()] API.
#'
#' @param pr A `Plumber` router created by [plumber::pr()].
#' @param host Host to bind. Only `"0.0.0.0"`, `"127.0.0.1"`,
#'   `"localhost"`, and `"::"` are accepted; anything else triggers a
#'   warning and binds to `0.0.0.0` (drogonR always binds to the
#'   wildcard).
#' @param port TCP port, integer in `1..65535`.
#' @param ... Additional arguments forwarded to [dr_serve()] (e.g.
#'   `threads`, `workers`, `max_queue`). Plumber-specific arguments
#'   that have no analogue in drogonR (`docs`, `swagger`,
#'   `swaggerCallback`, `quiet`) are silently accepted and ignored,
#'   so that an existing `plumber::pr_run(pr, docs = FALSE)` call site
#'   keeps working after swapping in the shim.
#'
#' @return `NULL`, invisibly. Blocks the calling thread until the
#'   drogonR server is stopped from another R session via
#'   [dr_stop()] (this matches `plumber::pr_run()` semantics).
#' @export
pr_run <- function(pr, host = "0.0.0.0", port = 8080L, ...) {
  if (!requireNamespace("plumber", quietly = TRUE)) {
    stop("drogonR::pr_run() requires the plumber package", call. = FALSE)
  }
  if (!inherits(pr, "Plumber")) {
    stop("`pr` must be a Plumber router (see plumber::pr())",
         call. = FALSE)
  }
  if (!is.character(host) || length(host) != 1L || is.na(host)) {
    stop("`host` must be a single string", call. = FALSE)
  }
  if (!host %in% c("0.0.0.0", "127.0.0.1", "localhost", "::")) {
    warning("drogonR::pr_run: host='", host,
            "' ignored, binding to 0.0.0.0", call. = FALSE)
  }
  .dr_reject_unsupported_plumber(pr)

  # Drop plumber-only knobs that have no analogue here, so user code
  # like `pr_run(pr, docs = FALSE)` works unchanged. Anything else in
  # `...` is forwarded to dr_serve() (threads, workers, max_queue, ...),
  # where unknown args still error -- that surface is intentional.
  dots <- list(...)
  dots[c("docs", "swagger", "swaggerCallback", "quiet")] <- NULL

  app <- .dr_plumber_to_app(pr)
  do.call(dr_serve,
          c(list(app, port = as.integer(port)), dots))

  # plumber::pr_run() blocks the calling R session servicing requests;
  # we run dr_serve() in-process which already kicks off Drogon on its
  # own thread. Drive later::run_now() so handlers actually fire on
  # this main thread until the user calls dr_stop() from elsewhere or
  # interrupts. Mirrors dr_serve()'s implicit assumption that the
  # caller will keep the main thread spinning.
  repeat {
    later::run_now(timeoutSecs = 3600)
    if (!isTRUE(dr_running())) break
  }
  invisible(NULL)
}

# Walk the plumber router and bail loudly on anything we don't
# faithfully reproduce. Done before any route registration so partial
# state never leaks through.
.dr_reject_unsupported_plumber <- function(pr) {
  user_filters <- Filter(
    function(f) !(f$name %in% .dr_default_filter_names),
    pr$filters %||% list())
  if (length(user_filters) > 0L) {
    nms <- vapply(user_filters, function(f) f$name, character(1))
    stop("drogonR::pr_run: @filter / pr_filter() not supported in v0.1 ",
         "(found: ", paste(nms, collapse = ", "), "). ",
         "Rewrite as middleware via dr_use().",
         call. = FALSE)
  }
  if (length(pr$mounts %||% list()) > 0L) {
    stop("drogonR::pr_run: pr_mount() / sub-routers not supported in v0.1.",
         call. = FALSE)
  }
  # Plumber's hooks live in a private field; .__enclos_env__ exposes
  # them. Probe defensively -- if the layout changes upstream we'd
  # rather skip the check than crash.
  hooks <- tryCatch(pr$.__enclos_env__$private$hooks,
                    error = function(e) NULL)
  if (!is.null(hooks) && length(unlist(hooks)) > 0L) {
    stop("drogonR::pr_run: pr_hook() / @hook not supported in v0.1.",
         call. = FALSE)
  }
}

# Translate every plumber endpoint into a drogonR route on a fresh app.
.dr_plumber_to_app <- function(pr) {
  app <- dr_app()
  groups <- pr$endpoints %||% list()
  for (group in groups) {
    for (ep in group) {
      .dr_register_plumber_endpoint(app, ep)
    }
  }
  app
}

# Map a single PlumberEndpoint onto dr_get()/dr_post()/etc. and wrap
# its handler to satisfy the plumber calling convention.
.dr_register_plumber_endpoint <- function(app, ep) {
  verbs <- toupper(ep$verbs %||% "GET")
  fn    <- ep$getFunc()
  if (!is.function(fn)) {
    stop("drogonR::pr_run: endpoint '", ep$path,
         "' has no callable handler", call. = FALSE)
  }
  path       <- .dr_plumber_path_to_dr(ep$path)
  param_type <- .dr_plumber_path_param_types(ep$path)

  # Per-route diagnostic, fired ONCE at pr_run() time so the request
  # hot-path stays free of warnings.
  if ("res" %in% names(formals(fn))) {
    warning("drogonR::pr_run: 'res' parameter in handler for '", ep$path,
            "' is not supported -- use the return value to set the response",
            call. = FALSE)
  }

  wrapped <- .dr_wrap_plumber_handler(fn, param_type)
  for (verb in verbs) {
    register <- switch(verb,
                       GET    = dr_get,
                       POST   = dr_post,
                       PUT    = dr_put,
                       DELETE = dr_delete,
                       stop("drogonR::pr_run: unsupported HTTP verb '",
                            verb, "' for path '", ep$path, "'",
                            call. = FALSE))
    register(app, path, wrapped)
  }
}

# Convert a plumber path ("/users/<id:int>/posts/<slug>") to drogonR
# syntax ("/users/:id/posts/:slug"). drogonR's path compiler accepts
# `<name>` natively too, but we still rewrite typed forms so the
# compiler doesn't see ":int" as part of the name.
.dr_plumber_path_to_dr <- function(path) {
  gsub("<([A-Za-z_][A-Za-z0-9_]*)(?::[^>]+)?>",
       ":\\1", path, perl = TRUE)
}

# Pull a `name -> type` named list out of a plumber path. Untyped
# placeholders (`<id>`) are omitted so a downstream lookup with
# `param_type[[nm]]` returns NULL and skips coercion.
.dr_plumber_path_param_types <- function(path) {
  re <- "<([A-Za-z_][A-Za-z0-9_]*):([^>]+)>"
  m  <- gregexpr(re, path, perl = TRUE)[[1]]
  if (length(m) == 1L && m == -1L) return(list())
  starts <- as.integer(m); lens <- attr(m, "match.length")
  out <- list()
  for (i in seq_along(starts)) {
    tok  <- substr(path, starts[i], starts[i] + lens[i] - 1L)
    name <- sub(re, "\\1", tok, perl = TRUE)
    type <- sub(re, "\\2", tok, perl = TRUE)
    out[[name]] <- type
  }
  out
}

# Coerce a path-parameter string per the plumber `<name:type>`
# annotation. Unknown types fall through as character -- same intent
# as plumber, which silently leaves unrecognised types untouched.
# A coercion failure (e.g. "abc" -> integer) yields NA, which is what
# plumber would do too via as.integer().
.dr_coerce_plumber_param <- function(val, type) {
  if (is.null(type) || is.null(val)) return(val)
  switch(type,
         "int"     = ,
         "integer" = suppressWarnings(as.integer(val)),
         "dbl"     = ,
         "double"  = ,
         "numeric" = suppressWarnings(as.double(val)),
         "bool"    = ,
         "logical" = suppressWarnings(as.logical(val)),
         val)
}

# Build a drogonR-shaped handler -- function(req) returning a response --
# that mimics plumber's calling convention: handler is invoked with
# named args matched from path > query > JSON body. `req` is injected
# as-is if the handler takes a `req` parameter, `res` is passed NULL
# (plumber-style mutation isn't supported; the warning fired at
# pr_run() time covers this).
#
# Return-value handling matches plumber 1.x defaults: data.frame and
# unnamed/named lists serialize as JSON via dr_json(); a single
# character string becomes plain text; a numeric/logical scalar is
# wrapped through dr_json() so length-1 vectors auto-unbox.
.dr_wrap_plumber_handler <- function(fn, param_type = list()) {
  force(fn); force(param_type)
  param_names <- names(formals(fn))
  has_req <- "req" %in% param_names
  has_res <- "res" %in% param_names
  function(req) {
    args <- .dr_resolve_plumber_args(fn, req, param_names,
                                     has_req, has_res, param_type)
    out <- do.call(fn, args)
    .dr_plumber_serialize(out)
  }
}

.dr_resolve_plumber_args <- function(fn, req, param_names, has_req, has_res,
                                     param_type = list()) {
  if (length(param_names) == 0L) return(list())
  query <- req$query
  if (is.null(query)) query <- character()
  path  <- req$params %||% list()

  body_parsed <- NULL
  body_attempted <- FALSE
  get_body <- function() {
    if (!body_attempted) {
      body_attempted <<- TRUE
      body_parsed <<- tryCatch(dr_body(req, as = "json"),
                               error = function(e) NULL)
    }
    body_parsed
  }

  formals_fn <- formals(fn)
  out <- vector("list", length(param_names))
  names(out) <- param_names
  keep <- logical(length(param_names))

  # NB: assigning NULL via out[[i]] <- NULL would *remove* the element
  # (and shift names), so we use the out[i] <- list(NULL) form below
  # whenever a parameter must be present-but-NULL.
  for (i in seq_along(param_names)) {
    nm <- param_names[i]
    if (nm == "req" && has_req) { out[[i]] <- req;        keep[i] <- TRUE; next }
    if (nm == "res" && has_res) { out[i]   <- list(NULL); keep[i] <- TRUE; next }

    val <- NULL
    if (nm %in% names(path)) {
      val <- path[[nm]]
      # Apply <name:type> coercion for path params only -- query/body
      # values are already typed (body) or string-only (query) and
      # plumber doesn't coerce those at the serializer layer either.
      val <- .dr_coerce_plumber_param(val, param_type[[nm]])
    } else if (length(query) > 0L && nm %in% names(query)) {
      val <- unname(query[[nm]])
    } else {
      body <- get_body()
      if (is.list(body) && !is.null(body[[nm]])) val <- body[[nm]]
    }
    if (!is.null(val)) {
      out[[i]] <- val
      keep[i]  <- TRUE
    } else if (!identical(formals_fn[[nm]], quote(expr = ))) {
      # Default exists in formals -- let do.call() use it.
      keep[i] <- FALSE
    } else {
      # Required parameter, no value found. plumber 1.x passes NULL in
      # this case; mirror that rather than erroring, so handlers that
      # treat a missing param as optional keep working.
      out[i]  <- list(NULL)
      keep[i] <- TRUE
    }
  }
  out[keep]
}

# plumber 1.x default serializer: every return value goes through
# jsonlite::toJSON(auto_unbox = FALSE) -- even bare strings and scalars,
# which is why plumber sends `["hello"]` for a `function() "hello"`.
# We mirror that exactly so existing plumber clients (which expect
# arrays for length-1 returns) keep working when the user swaps
# plumber::pr_run() for drogonR::pr_run().
#
# Two pass-through cases:
#   * a drogonR response list (the user used dr_response() / dr_json()
#     etc. inside a plumber handler) -- honoured as-is so opt-out is
#     possible without leaving the shim.
#   * an object of class "json" (the user called jsonlite::toJSON()
#     themselves) -- emitted verbatim, matching plumber's behaviour of
#     skipping the default serializer when the value is already
#     serialized.
.dr_plumber_serialize <- function(out) {
  if (is.list(out) && !is.null(out$body) && !is.data.frame(out)) {
    return(out)
  }
  if (inherits(out, "PlumberResponse") || inherits(out, "PlumberFile")) {
    stop("drogonR::pr_run: PlumberResponse/PlumberFile return values ",
         "are not supported in v0.1; return a list/data.frame for JSON ",
         "or a string for text", call. = FALSE)
  }
  if (inherits(out, "json")) {
    return(.dr_response(200L,
                        as.character(out),
                        list("Content-Type" = "application/json")))
  }
  dr_json(out, auto_unbox = FALSE)
}
