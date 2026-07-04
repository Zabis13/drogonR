# Helpers for WebSocket end-to-end tests. The `websocket` client is
# event-driven and dispatches via later, so in a non-interactive session
# we must drive the loop ourselves.

# Drive later's loop until pred() is TRUE or timeout. Returns pred's final
# value (so callers can assert on it).
ws_pump_until <- function(pred, timeout = 10) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(pred())) return(TRUE)
    later::run_now(timeoutSecs = 0.05)
    if (Sys.time() > deadline) return(FALSE)
  }
}

# Open a WS connection and return a small handle collecting lifecycle
# state. `record` accumulates every received message in order; `state`
# tracks open/closed and any error. Call ws_pump_until() on the handle's
# predicates to wait for events.
ws_open <- function(port, path, timeout = 10) {
  url <- sprintf("ws://127.0.0.1:%d%s", port, path)
  h <- new.env(parent = emptyenv())
  h$open       <- FALSE
  h$closed     <- FALSE
  h$error      <- FALSE
  h$close_code <- NA_integer_
  h$messages   <- character(0)
  h$ws <- websocket::WebSocket$new(url, autoConnect = FALSE)
  h$ws$onOpen(function(event)  h$open   <- TRUE)
  h$ws$onClose(function(event) {
    h$closed     <- TRUE
    # event$code carries the WebSocket close status (RFC6455). Captured
    # so tests can assert the reason (e.g. 1013 for an over-capacity
    # reject) rather than just "it closed".
    if (!is.null(event$code)) h$close_code <- as.integer(event$code)
  })
  h$ws$onError(function(event) h$error  <- TRUE)
  h$ws$onMessage(function(event)
    h$messages[[length(h$messages) + 1L]] <- event$data)
  h$ws$connect()
  if (!ws_pump_until(function() h$open || h$error, timeout)) {
    stop(sprintf("WS did not open on %s within %ds", url, timeout))
  }
  h
}

# Wait until the handle has collected at least `n` messages.
ws_wait_messages <- function(h, n, timeout = 10) {
  ws_pump_until(function() length(h$messages) >= n, timeout)
}

# Like ws_open, but tolerant of a connection that is refused/closed by
# the server instead of opening (e.g. an over-capacity reject). Returns
# the handle once it has either opened, errored, or closed — the caller
# inspects h$open / h$closed / h$close_code. Never stops the test.
ws_open_maybe <- function(port, path, timeout = 10) {
  url <- sprintf("ws://127.0.0.1:%d%s", port, path)
  h <- new.env(parent = emptyenv())
  h$open       <- FALSE
  h$closed     <- FALSE
  h$error      <- FALSE
  h$close_code <- NA_integer_
  h$messages   <- character(0)
  h$ws <- websocket::WebSocket$new(url, autoConnect = FALSE)
  h$ws$onOpen(function(event)  h$open   <- TRUE)
  h$ws$onClose(function(event) {
    h$closed <- TRUE
    if (!is.null(event$code)) h$close_code <- as.integer(event$code)
  })
  h$ws$onError(function(event) h$error <- TRUE)
  h$ws$onMessage(function(event)
    h$messages[[length(h$messages) + 1L]] <- event$data)
  h$ws$connect()
  ws_pump_until(function() h$open || h$error || h$closed, timeout)
  h
}

# --- cpp WS server spawn helpers -------------------------------------
# Shared by test-ws-cpp.R and test-ws-batching.R. Spawn a real drogonR
# server in a child Rscript serving cpp WS routes from drogonRtestbackend.

free_port <- function() sample(20000:65000, 1)

# Spawn the cpp WS server via the shared cpp server-script, passing the
# backend libdir so the child can load drogonRtestbackend. Each route in
# `ws_routes` is a list(kind="ws", method, path, package, callable) and
# may carry max_conns / idle_timeout / max_lifetime for the batching
# guards.
spawn_ws_cpp_server <- function(ws_routes, port, libdir) {
  script <- testthat::test_path("server-script-cpp.R")
  rds    <- tempfile("drogonR-wscpp-", fileext = ".rds")
  # server-script-cpp.R has no HTTP ping route by itself for WS-only
  # configs, so include a trivial one via the unary echo backend.
  routes <- c(
    list(list(method = "POST", path = "/__ping__",
              package = "drogonRtestbackend", callable = "echo")),
    ws_routes)
  saveRDS(list(port = port, routes = routes), rds)
  child_libs <- paste(c(libdir, .libPaths()), collapse = .Platform$path.sep)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--no-save", "--no-restore",
                "--no-init-file", "--no-site-file", script, rds),
    env     = c(Sys.getenv(), R_LIBS = child_libs),
    stdout  = "|", stderr = "|")
  attr(proc, "rds") <- rds
  proc
}

stop_ws_cpp_server <- function(proc) {
  rds <- attr(proc, "rds")
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

# Wait for the cpp server: its ping is a POST /__ping__, so probe with a
# short HTTP POST.
wait_ready_post <- function(port, timeout = 10) {
  Sys.sleep(0.5)
  deadline <- Sys.time() + timeout
  url <- sprintf("http://127.0.0.1:%d/__ping__", port)
  repeat {
    ok <- tryCatch({
      httr2::request(url) |>
        httr2::req_method("POST") |>
        httr2::req_body_raw(charToRaw("x"), type = "text/plain") |>
        httr2::req_timeout(1) |>
        httr2::req_error(is_error = function(resp) FALSE) |>
        httr2::req_perform()
      TRUE
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(invisible(TRUE))
    if (Sys.time() > deadline) {
      stop(sprintf("cpp server did not come up on :%d within %ds",
                   port, timeout))
    }
    Sys.sleep(0.1)
  }
}
