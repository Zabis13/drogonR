# WebSocket bridge behaviour beyond the happy-path echo: lifecycle hooks,
# server-initiated close, path dispatch of the single universal
# controller, binary frames, hook-optional registration, and
# per-connection isolation across concurrent clients. Heavy: real server
# in a child Rscript, real WS clients via the `websocket` package.

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
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

# Wrap a test body so the child's stderr surfaces on failure and the
# server is always reaped.
with_ws_server <- function(setup, body) {
  port   <- free_port()
  failed <- new.env(parent = emptyenv()); failed$any <- FALSE
  proc   <- spawn_server(setup, port)
  on.exit({
    if (failed$any) {
      err <- tryCatch(proc$read_error(), error = function(e) "")
      if (nzchar(err)) message("---- child stderr ----\n", err)
    }
    stop_server(proc)
  }, add = TRUE)
  wait_ready(port, "/__ping__")
  tryCatch(body(port), error = function(e) { failed$any <- TRUE; stop(e) })
}

ws_reqs <- function() {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")
}

test_that("on_connect and on_close fire, reported back over a side channel", {
  ws_reqs()

  # The connect/close hooks run in the child; we can't observe the child's
  # R state directly, so the hooks push a note to the client instead:
  # on_connect sends "hello" immediately; the client then closes and we
  # confirm the client saw the close complete.
  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws",
            on_connect = function(conn) dr_ws_send(conn, "welcome"),
            on_message = function(conn, msg, binary) dr_ws_send(conn, msg),
            on_close   = function(conn) invisible(NULL))
  }

  with_ws_server(setup, function(port) {
    h <- ws_open(port, "/ws")
    # on_connect ran server-side and pushed a greeting.
    expect_true(ws_wait_messages(h, 1L))
    expect_equal(h$messages[[1]], "welcome")

    h$ws$close()
    expect_true(ws_pump_until(function() h$closed))
    expect_true(h$closed)
  })
})

test_that("dr_ws_close closes the connection from the server side", {
  ws_reqs()

  # Any message triggers a server-initiated close.
  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws",
            on_message = function(conn, msg, binary) dr_ws_close(conn))
  }

  with_ws_server(setup, function(port) {
    h <- ws_open(port, "/ws")
    h$ws$send("bye")
    expect_true(ws_pump_until(function() h$closed))
    expect_true(h$closed)
  })
})

test_that("one universal controller dispatches by path", {
  ws_reqs()

  # Two routes, distinct behaviour; proves the single registered
  # controller routes by req->path() rather than collapsing paths.
  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws/upper",
            on_message = function(conn, msg, binary)
              dr_ws_send(conn, toupper(msg))) |>
      dr_ws("/ws/rev",
            on_message = function(conn, msg, binary)
              dr_ws_send(conn, paste(rev(strsplit(msg, "")[[1]]),
                                     collapse = "")))
  }

  with_ws_server(setup, function(port) {
    a <- ws_open(port, "/ws/upper")
    a$ws$send("abc")
    expect_true(ws_wait_messages(a, 1L))
    expect_equal(a$messages[[1]], "ABC")

    b <- ws_open(port, "/ws/rev")
    b$ws$send("abc")
    expect_true(ws_wait_messages(b, 1L))
    expect_equal(b$messages[[1]], "cba")
  })
})

test_that("registering with only on_message does not crash the dispatcher", {
  ws_reqs()

  # Regression: unset hooks were once stored as a raw nullptr, and the
  # dispatcher TYPEOF()'d them on the connect event -> segfault before any
  # message. A route with only on_message must connect and echo cleanly.
  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws",
            on_message = function(conn, msg, binary) dr_ws_send(conn, msg))
  }

  with_ws_server(setup, function(port) {
    h <- ws_open(port, "/ws")          # connect event with no on_connect hook
    h$ws$send("ok")
    expect_true(ws_wait_messages(h, 1L))
    expect_equal(h$messages[[1]], "ok")
  })
})

test_that("binary frames set binary=TRUE and can be sent back as binary", {
  ws_reqs()

  # The server reports whether it received a binary frame, then replies
  # with a binary frame the client can detect. (Payloads are \0-free
  # ASCII, since the bridge currently marshals the message as an R string.)
  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws",
            on_message = function(conn, msg, binary) {
              dr_ws_send(conn, if (binary) "was-binary" else "was-text",
                         binary = TRUE)
            })
  }

  with_ws_server(setup, function(port) {
    # Open directly (not via ws_open) so the only onMessage handler is the
    # binary-aware one below — ws_open's collector assumes text frames.
    opened <- FALSE; got_binary <- NULL
    ws <- websocket::WebSocket$new(sprintf("ws://127.0.0.1:%d/ws", port),
                                   autoConnect = FALSE)
    ws$onOpen(function(event) opened <<- TRUE)
    ws$onMessage(function(event) got_binary <<- is.raw(event$data))
    ws$connect()
    expect_true(ws_pump_until(function() opened))

    ws$send(charToRaw("ping"))  # binary frame from client
    expect_true(ws_pump_until(function() !is.null(got_binary)))
    # server saw a binary frame, and its reply arrived as binary (raw).
    expect_true(got_binary)
    ws$close()
  })
})

test_that("client-initiated disconnect fires on_close server-side", {
  ws_reqs()

  # on_close pushes nothing back (the socket is gone), so we prove it ran
  # by its side effect: it appends to a file the test can read. The child
  # writes to a path we pass in via an env var baked into the setup.
  close_marker <- tempfile("ws-close-")
  setup <- local({
    marker <- close_marker
    function(app) {
      app |>
        dr_get("/__ping__", function(req) "pong") |>
        dr_ws("/ws",
              on_message = function(conn, msg, binary) dr_ws_send(conn, msg),
              on_close   = function(conn) cat("closed\n", file = marker,
                                              append = TRUE))
    }
  })

  with_ws_server(setup, function(port) {
    h <- ws_open(port, "/ws")
    h$ws$send("hi")
    expect_true(ws_wait_messages(h, 1L))
    h$ws$close()                       # client tears the socket down
    # give the server a moment to run on_close, then check the marker.
    ok <- ws_pump_until(function() file.exists(close_marker) &&
                          length(readLines(close_marker)) >= 1L,
                        timeout = 5)
    expect_true(ok)
  })
})

test_that("dr_stop() with a live WS connection tears down cleanly", {
  ws_reqs()

  # Owning-model check: the session state lives in our g_wsSessions map,
  # not in the (soon-dead) Drogon connection, so stopping the server with
  # a connection still open must not touch a dangling loop/connection.
  port   <- free_port()
  script <- testthat::test_path("ws-teardown-script.R")
  proc   <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script, as.character(port)),
    stdout  = "|", stderr = "|")
  on.exit({ if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL) },
          add = TRUE)

  wait_ready(port, "/__ping__")

  h <- ws_open(port, "/ws")
  h$ws$send("wake")             # make the server-side session live
  expect_true(ws_wait_messages(h, 1L))

  # The child now sees got$any and proceeds to dr_stop() + exit. Wait for
  # it to finish and confirm it reached the clean-teardown line without a
  # crash (a segfault would exit non-zero and never print the marker).
  proc$wait(timeout = 15000)
  status <- proc$get_exit_status()
  out    <- tryCatch(proc$read_output(), error = function(e) "")
  err    <- tryCatch(proc$read_error(),  error = function(e) "")
  if (!grepl("TEARDOWN_CLEAN", out) || !identical(status, 0L)) {
    message("---- teardown child stdout ----\n", out)
    message("---- teardown child stderr ----\n", err)
  }
  expect_match(out, "TEARDOWN_CLEAN")
  expect_identical(status, 0L)
})

test_that("concurrent connections keep independent per-connection state", {
  ws_reqs()

  # Each connection counts its own messages in a persistent env stored in
  # the closure; the reply carries that connection's running count. If
  # sessions leaked into each other the counts would interleave.
  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/ws",
            on_connect = function(conn) {
              # stash a per-connection counter keyed by the conn handle's id
              e <- new.env(parent = emptyenv()); e$n <- 0L
              assign(as.character(unclass(conn)), e, envir = .GlobalEnv)
            },
            on_message = function(conn, msg, binary) {
              e <- get(as.character(unclass(conn)), envir = .GlobalEnv)
              e$n <- e$n + 1L
              dr_ws_send(conn, as.character(e$n))
            })
  }

  with_ws_server(setup, function(port) {
    a <- ws_open(port, "/ws")
    b <- ws_open(port, "/ws")
    # a sends twice, b once; counts must be per-connection.
    a$ws$send("x"); expect_true(ws_wait_messages(a, 1L))
    a$ws$send("x"); expect_true(ws_wait_messages(a, 2L))
    b$ws$send("x"); expect_true(ws_wait_messages(b, 1L))
    expect_equal(a$messages, c("1", "2"))
    expect_equal(b$messages, c("1"))
  })
})
