# WebSocket broadcast rooms: a chat-room server joins every connection to
# one room on connect and broadcasts each incoming message to all members.
# Verifies every connected client receives a message sent by any one of
# them. Heavy: real server in a child Rscript, real WS clients.

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

ws_reqs <- function() {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")
}

test_that("a message from one client is broadcast to all room members", {
  ws_reqs()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/chat",
            on_connect = function(conn) dr_ws_join(conn, "lobby"),
            on_message = function(conn, msg, binary)
              dr_ws_broadcast("lobby", msg))
  }

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

  # Open three clients into the same room.
  clients <- lapply(1:3, function(i) ws_open(port, "/chat"))

  # Client 1 sends one message; every client (incl. the sender) should
  # receive exactly it, since all three are in the lobby.
  clients[[1]]$ws$send("hi-all")

  ok <- ws_pump_until(function()
    all(vapply(clients, function(h) length(h$messages) >= 1L, logical(1))),
    timeout = 10)
  if (!ok) failed$any <- TRUE
  expect_true(ok)

  for (h in clients) expect_equal(h$messages, "hi-all")

  for (h in clients) h$ws$close()
})

test_that("dr_ws_leave removes a connection from the broadcast set", {
  ws_reqs()

  # Server protocol: sending "join"/"leave" toggles room membership;
  # sending "ping" broadcasts "pong" to the room. A client that left must
  # not receive the pong.
  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_ws("/chat",
            on_connect = function(conn) dr_ws_join(conn, "lobby"),
            on_message = function(conn, msg, binary) {
              if (msg == "leave")      dr_ws_leave(conn, "lobby")
              else if (msg == "ping")  dr_ws_broadcast("lobby", "pong")
            })
  }

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

  a <- ws_open(port, "/chat")
  b <- ws_open(port, "/chat")

  # b leaves the room; give the server a beat to process it.
  b$ws$send("leave")
  ws_pump_until(function() FALSE, timeout = 0.5)

  # a triggers a broadcast. Only a (still in the room) should get "pong".
  a$ws$send("ping")
  ok <- ws_pump_until(function() length(a$messages) >= 1L, timeout = 10)
  if (!ok) failed$any <- TRUE
  expect_true(ok)
  # settle: let any (erroneous) delivery to b arrive too.
  ws_pump_until(function() FALSE, timeout = 0.5)

  expect_equal(a$messages, "pong")
  expect_equal(length(b$messages), 0L)

  a$ws$close(); b$ws$close()
})
