# Happy-path WebSocket: server echoes each message back with an "echo:"
# prefix; client sends two messages and verifies both round-trip in
# order. Heavy: real server in a child Rscript, real WS client via the
# `websocket` package.

free_port <- function() sample(20000:65000, 1)

wait_ready <- function(port, path = "/__ping__", timeout = 10) {
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

spawn_server <- function(setup, port) {
  script <- testthat::test_path("server-script.R")
  rds    <- tempfile("drogonR-test-", fileext = ".rds")
  saveRDS(list(setup = setup, port = port), rds)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script, rds),
    stdout  = "|", stderr = "|")
  attr(proc, "rds") <- rds
  proc
}

stop_server <- function(proc) {
  rds <- attr(proc, "rds")
  if (proc$is_alive()) {
    tryCatch(proc$kill(), error = function(e) NULL)
  }
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

# Drive the websocket client's event loop until `pred()` is TRUE or we
# time out. The websocket package dispatches callbacks via later, so we
# have to run the loop ourselves in a non-interactive session.
pump_until <- function(pred, timeout = 10) {
  deadline <- Sys.time() + timeout
  while (!isTRUE(pred())) {
    later::run_now(timeoutSecs = 0.1)
    if (Sys.time() > deadline) return(FALSE)
  }
  TRUE
}

test_that("dr_ws echoes messages back to the client", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")

  port <- free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws/echo",
            on_message = function(conn, msg, binary) {
              dr_ws_send(conn, paste0("echo:", msg))
            })
  }

  failed <- new.env(parent = emptyenv()); failed$any <- FALSE
  proc <- spawn_server(setup, port)
  on.exit({
    if (failed$any) {
      out <- tryCatch(proc$read_output(), error = function(e) "")
      err <- tryCatch(proc$read_error(),  error = function(e) "")
      if (nzchar(out)) message("---- child stdout ----\n", out)
      if (nzchar(err)) message("---- child stderr ----\n", err)
    }
    stop_server(proc)
  }, add = TRUE)

  wait_ready(port, "/__ping__")

  received <- character(0)
  opened   <- FALSE
  url <- sprintf("ws://127.0.0.1:%d/ws/echo", port)
  ws <- websocket::WebSocket$new(url, autoConnect = FALSE)
  ws$onOpen(function(event) opened <<- TRUE)
  ws$onMessage(function(event) received[[length(received) + 1L]] <<- event$data)
  ws$connect()

  if (!pump_until(function() opened)) failed$any <- TRUE
  expect_true(opened)

  ws$send("hello")
  ws$send("world")

  ok <- pump_until(function() length(received) >= 2L)
  if (!ok) failed$any <- TRUE
  expect_true(ok)
  expect_equal(received, c("echo:hello", "echo:world"))

  ws$close()
  pump_until(function() FALSE, timeout = 0.5)  # let close flush
})
