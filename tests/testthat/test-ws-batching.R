# Continuous-batching guards on dr_ws_cpp(): max_conns concurrency cap,
# idle_timeout reaping, and the absolute max_lifetime ceiling. These are
# the transport-side safety nets an LLM scheduler layers on this ABI.
#
# Heavy: builds the backend, spawns a real server, uses a real WS client.
# Reuses the cpp WS spawn helpers defined in test-ws-cpp.R (same file
# dir, both sourced), and the ws_open* / ws_pump helpers in helper-ws.R.

test_that("dr_ws_cpp max_conns: the over-capacity connection is refused 1013", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")
  libdir <- ensure_cpp_backend()

  port <- free_port()
  proc <- spawn_ws_cpp_server(
    list(list(kind = "ws", method = "GET", path = "/ws/cap",
              package = "drogonRtestbackend", callable = "ws_echo",
              max_conns = 2)),
    port, libdir)
  on.exit(stop_ws_cpp_server(proc), add = TRUE)
  wait_ready_post(port)

  # Fill the two slots. Each greets on connect, proving it's live.
  h1 <- ws_open(port, "/ws/cap")
  expect_true(ws_wait_messages(h1, 1L))
  h2 <- ws_open(port, "/ws/cap")
  expect_true(ws_wait_messages(h2, 1L))

  # The third connection is over capacity: the handshake completes (so a
  # WS close frame is possible) and the server shuts it with code 1013.
  h3 <- ws_open_maybe(port, "/ws/cap")
  expect_true(ws_pump_until(function() h3$closed, timeout = 5))
  expect_equal(h3$close_code, 1013L)
  # It never got the backend's connect greeting — reject happens before
  # the CONNECT event is dispatched.
  expect_length(h3$messages, 0L)

  # Freeing a slot lets a new connection in again.
  h1$ws$close()
  expect_true(ws_pump_until(function() h1$closed, timeout = 5))
  h4 <- ws_open(port, "/ws/cap")
  expect_true(ws_wait_messages(h4, 1L))
  expect_equal(h4$messages[[1]], "cpp-welcome")

  h2$ws$close(); h4$ws$close()
})

test_that("dr_ws_cpp idle_timeout: a silent connection is reaped", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")
  libdir <- ensure_cpp_backend()

  port <- free_port()
  # ws_echo greets once on connect, then stays silent unless the client
  # sends. With no client frames, no further send() happens, so the idle
  # clock (0.5s) expires and the reaper closes the connection.
  proc <- spawn_ws_cpp_server(
    list(list(kind = "ws", method = "GET", path = "/ws/idle",
              package = "drogonRtestbackend", callable = "ws_echo",
              idle_timeout = 0.5)),
    port, libdir)
  on.exit(stop_ws_cpp_server(proc), add = TRUE)
  wait_ready_post(port)

  h <- ws_open(port, "/ws/idle")
  expect_true(ws_wait_messages(h, 1L))   # connect greeting
  expect_false(h$closed)

  # Stay silent; within a few seconds the server-side idle reaper closes.
  expect_true(ws_pump_until(function() h$closed, timeout = 6))
})

test_that("dr_ws_cpp max_lifetime: reaped despite steady activity", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")
  libdir <- ensure_cpp_backend()

  port <- free_port()
  # Long idle window (never trips) but a hard 1s lifetime ceiling. The
  # client keeps the connection busy (echoes reset the idle clock), so a
  # close proves the lifetime cap is independent of activity.
  proc <- spawn_ws_cpp_server(
    list(list(kind = "ws", method = "GET", path = "/ws/life",
              package = "drogonRtestbackend", callable = "ws_echo",
              idle_timeout = 30, max_lifetime = 1)),
    port, libdir)
  on.exit(stop_ws_cpp_server(proc), add = TRUE)
  wait_ready_post(port)

  h <- ws_open(port, "/ws/life")
  expect_true(ws_wait_messages(h, 1L))

  # Ping every ~150ms to keep resetting the idle timer while the 1s
  # lifetime ceiling runs down underneath us.
  start <- Sys.time()
  closed <- ws_pump_until(function() {
    if (h$closed) return(TRUE)
    if (h$ws$readyState() == 1L) h$ws$send("ping")
    Sys.sleep(0.15)
    FALSE
  }, timeout = 8)
  expect_true(closed)
  # Should have lived past the idle window's reach but be gone well
  # before it: closed on the lifetime ceiling, not idle.
  expect_lt(as.numeric(Sys.time() - start, units = "secs"), 6)
})
