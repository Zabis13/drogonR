# End-to-end test for native (R-bypass) routes registered via
# dr_*_cpp(). Drives a forked server through the dummy backend at
# inst/test-backend/drogonRtestbackend.
#
# This is gated as a heavy test (see tests/testthat.R) — it spawns a
# real Rscript, opens a TCP port, and does HTTP round-trips.

free_port_cpp <- function() sample(20000:65000, 1)

wait_ready_cpp <- function(port, timeout = 10) {
  Sys.sleep(0.5)
  deadline <- Sys.time() + timeout
  repeat {
    ok <- tryCatch({
      con <- socketConnection("127.0.0.1", port = port,
                              blocking = TRUE, open = "r+", timeout = 1)
      close(con)
      TRUE
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(invisible(TRUE))
    if (Sys.time() > deadline) {
      stop(sprintf("cpp server did not open :%d within %ds", port, timeout))
    }
    Sys.sleep(0.1)
  }
}

spawn_cpp_server <- function(routes, port, libdir) {
  script <- testthat::test_path("server-script-cpp.R")
  rds    <- tempfile("drogonR-cpp-test-", fileext = ".rds")
  saveRDS(list(port = port, routes = routes), rds)

  # Prepend our test libdir so the child Rscript can load
  # drogonRtestbackend. We can't use --vanilla (it strips env vars);
  # use the equivalent flags minus --no-environ so R_LIBS survives.
  # R_LIBS (not R_LIBS_USER) is the right knob here — it has higher
  # priority and isn't overridden by a user's ~/.Renviron.
  child_libs <- paste(c(libdir, .libPaths()), collapse = .Platform$path.sep)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--no-save", "--no-restore",
                "--no-init-file", "--no-site-file",
                script, rds),
    env     = c(Sys.getenv(), R_LIBS = child_libs),
    stdout  = "|", stderr = "|")
  attr(proc, "rds") <- rds
  proc
}

stop_cpp_server <- function(proc) {
  rds <- attr(proc, "rds")
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

cpp_GET <- function(port, path) {
  httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

cpp_POST <- function(port, path, body, ctype = "text/plain", headers = NULL) {
  req <- httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_method("POST") |>
    httr2::req_body_raw(charToRaw(body), type = ctype) |>
    httr2::req_error(is_error = function(resp) FALSE)
  if (!is.null(headers)) req <- httr2::req_headers(req, !!!headers)
  httr2::req_perform(req)
}

# ---- Fixture ---------------------------------------------------------------

setup_cpp_server <- function() {
  libdir <- ensure_cpp_backend()
  port <- free_port_cpp()
  routes <- list(
    list(method = "POST",   path = "/echo",
         package = "drogonRtestbackend", callable = "echo"),
    list(method = "GET",    path = "/status",
         package = "drogonRtestbackend", callable = "status"),
    list(method = "GET",    path = "/header",
         package = "drogonRtestbackend", callable = "header"),
    list(method = "GET",    path = "/items/:id/sub/:slug",
         package = "drogonRtestbackend", callable = "path"),
    list(method = "GET",    path = "/boom",
         package = "drogonRtestbackend", callable = "boom")
  )
  proc <- spawn_cpp_server(routes, port, libdir)
  wait_ready_cpp(port)
  list(port = port, proc = proc)
}

# ---- Tests -----------------------------------------------------------------

test_that("dr_post_cpp echoes request body bytes verbatim", {
  skip_on_os("windows")
  s <- setup_cpp_server()
  on.exit(stop_cpp_server(s$proc), add = TRUE)

  payload <- "hello cpp ABI \xE2\x98\x83"  # snowman, 3-byte UTF-8
  r <- cpp_POST(s$port, "/echo", payload, ctype = "application/octet-stream")
  expect_equal(httr2::resp_status(r), 200L)
  expect_equal(httr2::resp_body_string(r), payload)
  expect_match(httr2::resp_content_type(r), "text/plain")
})

test_that("dr_get_cpp uses backend-provided HTTP status", {
  skip_on_os("windows")
  s <- setup_cpp_server()
  on.exit(stop_cpp_server(s$proc), add = TRUE)

  r <- cpp_GET(s$port, "/status?code=418")
  expect_equal(httr2::resp_status(r), 418L)
  expect_equal(httr2::resp_body_string(r), "set status to 418")
})

test_that("dr_get_cpp passes request headers (lowercased) through", {
  skip_on_os("windows")
  s <- setup_cpp_server()
  on.exit(stop_cpp_server(s$proc), add = TRUE)

  r <- httr2::request(sprintf("http://127.0.0.1:%d/header", s$port)) |>
    httr2::req_headers(`X-Trace` = "abc-123") |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r), 200L)
  expect_equal(httr2::resp_body_string(r), "abc-123")

  r2 <- cpp_GET(s$port, "/header")
  expect_equal(httr2::resp_body_string(r2), "(missing)")
})

test_that("dr_get_cpp passes positional path params to the backend", {
  skip_on_os("windows")
  s <- setup_cpp_server()
  on.exit(stop_cpp_server(s$proc), add = TRUE)

  r <- cpp_GET(s$port, "/items/42/sub/widget")
  expect_equal(httr2::resp_status(r), 200L)
  expect_equal(httr2::resp_body_string(r), "id=42 slug=widget")
})

test_that("non-zero return from native handler yields a 500", {
  skip_on_os("windows")
  s <- setup_cpp_server()
  on.exit(stop_cpp_server(s$proc), add = TRUE)

  r <- cpp_GET(s$port, "/boom")
  expect_equal(httr2::resp_status(r), 500L)
})

test_that("dr_get_cpp errors at registration if the callable does not exist", {
  ensure_cpp_backend()  # makes drogonRtestbackend importable in this session
  app <- dr_app()
  expect_error(
    dr_get_cpp(app, "/no-such", "drogonRtestbackend", "definitely_not_a_symbol"),
    "R_GetCCallable"
  )
})
