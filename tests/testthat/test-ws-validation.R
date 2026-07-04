# Argument validation for the WebSocket R API. These are light tests:
# no server, no sockets — they exercise the stop()/warning() branches of
# dr_ws() / dr_ws_send() / dr_ws_close() directly, so they run on CRAN.

test_that("dr_ws validates its arguments", {
  app <- dr_app()

  # path must be a single string
  expect_error(dr_ws(app, 1L, function(conn, msg, binary) NULL),
               "path.*single string")
  expect_error(dr_ws(app, c("/a", "/b"), function(conn, msg, binary) NULL),
               "path.*single string")

  # on_message is required and must be a function
  expect_error(dr_ws(app, "/ws", on_message = "nope"),
               "on_message.*function")

  # optional hooks, if given, must be functions
  expect_error(
    dr_ws(app, "/ws", function(conn, msg, binary) NULL, on_connect = 1),
    "on_connect.*function")
  expect_error(
    dr_ws(app, "/ws", function(conn, msg, binary) NULL, on_close = 1),
    "on_close.*function")

  # non-app first argument
  expect_error(dr_ws(list(), "/ws", function(conn, msg, binary) NULL),
               "drogon_app")
})

test_that("dr_ws_cpp validates its batching guard arguments", {
  app <- dr_app()
  # These fire before the package/callable resolution, so a dummy
  # package name is fine — the numeric checks reject first.
  expect_error(
    dr_ws_cpp(app, "/ws", "pkg", "fn", max_conns = -1),
    "max_conns.*non-negative")
  expect_error(
    dr_ws_cpp(app, "/ws", "pkg", "fn", idle_timeout = "x"),
    "idle_timeout.*non-negative")
  expect_error(
    dr_ws_cpp(app, "/ws", "pkg", "fn", max_lifetime = c(1, 2)),
    "max_lifetime.*non-negative")
  expect_error(
    dr_ws_cpp(app, "/ws", "pkg", "fn", idle_timeout = NA_real_),
    "idle_timeout.*non-negative")
})

test_that("dr_ws warns and overwrites on a duplicate path", {
  app <- dr_app()
  app <- dr_ws(app, "/ws", function(conn, msg, binary) dr_ws_send(conn, "a"))
  expect_warning(
    app <- dr_ws(app, "/ws", function(conn, msg, binary) dr_ws_send(conn, "b")),
    "overwriting.*WebSocket route")
  # still exactly one route, holding the second handler.
  expect_length(app$ws_routes, 1L)
})

test_that("dr_ws registers a route on the app", {
  app <- dr_app()
  app <- dr_ws(app, "/ws/a", function(conn, msg, binary) NULL)
  app <- dr_ws(app, "/ws/b", function(conn, msg, binary) NULL,
               on_connect = function(conn) NULL,
               on_close   = function(conn) NULL)
  expect_length(app$ws_routes, 2L)
  expect_equal(app$ws_routes[["/ws/a"]]$path, "/ws/a")
  expect_true(is.function(app$ws_routes[["/ws/b"]]$on_connect))
})

test_that("dr_ws_send validates conn and msg", {
  # conn must be a drogon_ws_conn
  expect_error(dr_ws_send(1, "hi"),
               "drogon_ws_conn")
  expect_error(dr_ws_send("not a conn", "hi"),
               "drogon_ws_conn")

  # a well-formed conn but a bad msg
  conn <- structure(42, class = "drogon_ws_conn")
  expect_error(dr_ws_send(conn, 123),
               "msg.*single string")
  expect_error(dr_ws_send(conn, c("a", "b")),
               "msg.*single string")
})

test_that("dr_ws_close validates conn", {
  expect_error(dr_ws_close(1), "drogon_ws_conn")
  expect_error(dr_ws_close("x"), "drogon_ws_conn")
})

test_that("room ops validate conn, room, and msg", {
  conn <- structure(42, class = "drogon_ws_conn")

  # conn must be a drogon_ws_conn
  expect_error(dr_ws_join(1, "room"), "drogon_ws_conn")
  expect_error(dr_ws_leave("x", "room"), "drogon_ws_conn")

  # room must be a single non-empty string
  expect_error(dr_ws_join(conn, ""), "room.*non-empty")
  expect_error(dr_ws_join(conn, c("a", "b")), "room.*non-empty")
  expect_error(dr_ws_leave(conn, NA_character_), "room.*non-empty")
  expect_error(dr_ws_broadcast("", "hi"), "room.*non-empty")

  # broadcast msg must be a single string
  expect_error(dr_ws_broadcast("room", 123), "msg.*single string")
})

test_that("room ops on unknown conns/rooms are no-ops", {
  conn <- structure(999999, class = "drogon_ws_conn")
  # join/leave a conn that never existed: no error.
  expect_silent(dr_ws_join(conn, "room"))
  expect_silent(dr_ws_leave(conn, "room"))
  # broadcast to an empty/unknown room queues to nobody -> 0.
  expect_equal(dr_ws_broadcast("nobody-here", "hi"), 0L)
})

test_that("dr_ws_send/close on an unknown conn are silent no-ops", {
  # A syntactically valid handle for a connection that never existed:
  # the C side looks it up, misses, and returns without error.
  conn <- structure(999999, class = "drogon_ws_conn")
  expect_silent(dr_ws_send(conn, "hi"))
  expect_null(dr_ws_send(conn, "hi"))
  expect_silent(dr_ws_close(conn))
  expect_null(dr_ws_close(conn))
})
