# WebSocket client (dr_ws_connect): drogonR connecting *outward* to an
# external WS server. The server is a real drogonR instance in a child
# Rscript that echoes each message with an "echo:" prefix; the client is
# drogonR's own dr_ws_connect() running in this test process. We verify
# on_open fires, a message round-trips, on_close fires on disconnect, and
# that a wss:// URL is rejected up front on a non-OpenSSL build.
#
# Heavy: real server in a child process. Gated in tests/testthat.R.

wsc_free_port <- function() sample(20000:65000, 1)

wsc_wait_ready <- function(port, path = "/__ping__", timeout = 10) {
  Sys.sleep(0.5)
  deadline <- Sys.time() + timeout
  url <- sprintf("http://127.0.0.1:%d%s", port, path)
  repeat {
    ok <- tryCatch({
      r <- httr2::request(url) |>
        httr2::req_timeout(1) |>
        httr2::req_error(is_error = function(resp) FALSE) |>
        httr2::req_perform()
      !is.null(r)
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(invisible(TRUE))
    if (Sys.time() > deadline) {
      stop(sprintf("server did not become reachable on :%d within %ds",
                   port, timeout))
    }
    Sys.sleep(0.1)
  }
}

wsc_spawn_server <- function(setup, port) {
  script <- testthat::test_path("server-script.R")
  rds    <- tempfile("drogonR-wsc-", fileext = ".rds")
  saveRDS(list(setup = setup, port = port), rds)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script, rds),
    stdout  = "|", stderr = "|")
  attr(proc, "rds") <- rds
  proc
}

wsc_stop_server <- function(proc) {
  rds <- attr(proc, "rds")
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

test_that("dr_ws_connect opens, round-trips a message, and closes", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- wsc_free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws/echo",
            on_message = function(conn, msg, binary) {
              dr_ws_send(conn, paste0("echo:", msg))
            })
  }

  failed <- new.env(parent = emptyenv()); failed$any <- FALSE
  proc <- wsc_spawn_server(setup, port)
  on.exit({
    if (failed$any) {
      out <- tryCatch(proc$read_output(), error = function(e) "")
      err <- tryCatch(proc$read_error(),  error = function(e) "")
      if (nzchar(out)) message("---- child stdout ----\n", out)
      if (nzchar(err)) message("---- child stderr ----\n", err)
    }
    dr_ws_shutdown()
    wsc_stop_server(proc)
  }, add = TRUE)

  wsc_wait_ready(port, "/__ping__")

  st <- new.env(parent = emptyenv())
  st$opened   <- FALSE
  st$closed   <- FALSE
  st$reason   <- NA_character_
  st$messages <- character(0)

  cl <- dr_ws_connect(
    sprintf("ws://127.0.0.1:%d/ws/echo", port),
    on_message = function(msg, binary) {
      st$messages[[length(st$messages) + 1L]] <- msg
    },
    on_open  = function() st$opened <- TRUE,
    on_close = function(reason, code) {
      st$closed <- TRUE
      st$reason <- reason
    })

  # Connection establishes.
  ok_open <- wsc_pump_until(function() st$opened, 10)
  failed$any <- failed$any || !ok_open
  expect_true(ok_open)

  # Message round-trips with the server's echo: prefix.
  dr_ws_client_send(cl, "hello")
  ok_msg <- wsc_pump_until(function() length(st$messages) >= 1L, 10)
  failed$any <- failed$any || !ok_msg
  expect_true(ok_msg)
  expect_identical(st$messages[[1]], "echo:hello")

  # Client-initiated close fires on_close with reason "closed".
  dr_ws_client_close(cl)
  ok_close <- wsc_pump_until(function() st$closed, 10)
  failed$any <- failed$any || !ok_close
  expect_true(ok_close)
  expect_identical(st$reason, "closed")
})

test_that("dr_ws_connect reports a failed connection via on_close", {
  skip_on_os("windows")

  # Nothing is listening on this port; the connect must fail and surface
  # through on_close(reason = "connect_failed"), not a silent hang.
  port <- wsc_free_port()

  st <- new.env(parent = emptyenv())
  st$closed <- FALSE
  st$reason <- NA_character_

  on.exit(dr_ws_shutdown(), add = TRUE)

  dr_ws_connect(
    sprintf("ws://127.0.0.1:%d/nope", port),
    on_message = function(msg, binary) {},
    on_close   = function(reason, code) {
      st$closed <- TRUE
      st$reason <- reason
    })

  ok <- wsc_pump_until(function() st$closed, 10)
  expect_true(ok)
  expect_identical(st$reason, "connect_failed")
})
