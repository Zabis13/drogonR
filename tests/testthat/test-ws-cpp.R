# dr_ws_cpp: WebSocket routes served entirely by a compiled C backend
# (drogonRtestbackend) with no per-frame trip through R. Covers the
# IO-thread echo path and a detached-thread streaming path (which
# exercises the conn_id handle staying valid for lookup across threads).
# Heavy: builds the backend, spawns a real server, uses a real WS client.
# The spawn/wait helpers (free_port, spawn_ws_cpp_server,
# stop_ws_cpp_server, wait_ready_post) live in helper-ws.R so both this
# file and test-ws-batching.R can use them when run in isolation.

test_that("dr_ws_cpp: C backend echoes frames and greets on connect", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")
  libdir <- ensure_cpp_backend()

  port <- free_port()
  proc <- spawn_ws_cpp_server(
    list(list(kind = "ws", method = "GET", path = "/ws/echo",
              package = "drogonRtestbackend", callable = "ws_echo")),
    port, libdir)
  on.exit(stop_ws_cpp_server(proc), add = TRUE)
  wait_ready_post(port)

  h <- ws_open(port, "/ws/echo")
  # backend greets on connect
  expect_true(ws_wait_messages(h, 1L))
  expect_equal(h$messages[[1]], "cpp-welcome")

  # and echoes each frame
  h$ws$send("hello-cpp")
  expect_true(ws_wait_messages(h, 2L))
  expect_equal(h$messages[[2]], "hello-cpp")

  h$ws$close()
})

test_that("dr_ws_cpp: detached backend thread streams multiple frames", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("websocket")
  libdir <- ensure_cpp_backend()

  port <- free_port()
  proc <- spawn_ws_cpp_server(
    list(list(kind = "ws", method = "GET", path = "/ws/stream",
              package = "drogonRtestbackend", callable = "ws_stream")),
    port, libdir)
  on.exit(stop_ws_cpp_server(proc), add = TRUE)
  wait_ready_post(port)

  h <- ws_open(port, "/ws/stream")
  # one message kicks off a detached thread that emits tok-1..tok-3;
  # this proves the conn_id handle stays valid across threads.
  h$ws$send("go")
  expect_true(ws_wait_messages(h, 3L, timeout = 10))
  expect_equal(h$messages, c("tok-1", "tok-2", "tok-3"))

  h$ws$close()
})
