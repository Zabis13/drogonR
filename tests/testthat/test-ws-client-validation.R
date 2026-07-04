# Light validation tests for the WS client API: argument checks, URL
# parsing, and the wss:// gate on a non-OpenSSL build. No server, no
# sockets — safe to run on CRAN.

test_that("dr_ws_connect validates its arguments", {
  expect_error(dr_ws_connect(123, function(m, b) NULL),
               "url.*single non-empty string")
  expect_error(dr_ws_connect("ws://x", "not a function"),
               "on_message.*function")
  expect_error(
    dr_ws_connect("ws://x", function(m, b) NULL, on_open = 1),
    "on_open.*function")
  expect_error(
    dr_ws_connect("ws://x", function(m, b) NULL, on_close = "x"),
    "on_close.*function")
})

test_that("malformed WS URLs are rejected before connecting", {
  f <- function(m, b) NULL
  expect_error(dr_ws_connect("http://host/x", f), "ws://host")
  expect_error(dr_ws_connect("host:9000", f),     "ws://host")
  expect_error(dr_ws_connect("://host", f),       "ws://host")
})

test_that(".dr_parse_ws_url splits scheme/host/port/path", {
  parse <- drogonR:::.dr_parse_ws_url

  p <- parse("ws://127.0.0.1:9000/chat?x=1")
  expect_identical(p$host, "ws://127.0.0.1:9000")
  expect_identical(p$path, "/chat?x=1")
  expect_false(p$ssl)

  # Default ports are made explicit for newWebSocketClient.
  expect_identical(parse("ws://localhost")$host,  "ws://localhost:80")
  expect_identical(parse("wss://example.com")$host, "wss://example.com:443")

  # No path -> "/".
  expect_identical(parse("ws://h:1")$path, "/")

  # wss:// sets the ssl flag.
  expect_true(parse("wss://api/x")$ssl)
})

test_that("wss:// is rejected on a non-OpenSSL build", {
  # Only meaningful when this build has no TLS; on an OpenSSL build wss://
  # is allowed to proceed (and would fail later on a bad host, not here).
  skip_if(isTRUE(.Call(drogonR:::drogonR_has_ssl)),
          "build has OpenSSL; wss:// gate not exercised")
  expect_error(
    dr_ws_connect("wss://example.com/x", function(m, b) NULL),
    "wss:// requires .* OpenSSL")
})
