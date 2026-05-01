# End-to-end server lifecycle: start, hit a real port, stop.
#
# Drogon's event loop cannot be restarted in a single R session, so
# each scenario runs the server in its own fresh Rscript process via
# processx. The parent only drives the HTTP client and asserts on the
# result. Running the server out-of-process (rather than via
# parallel::mcparallel) means it does NOT inherit testthat's R-state —
# in particular the error-message buffer that geterrmessage() reads on
# the dispatcher fast path.

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

# Spawn server-script.R as a child Rscript; return the processx
# process. `setup` is a function(app) -> app that the child runs to
# register routes / middleware before dr_serve().
spawn_server <- function(setup, port) {
  script <- testthat::test_path("server-script.R")
  rds    <- tempfile("drogonR-test-", fileext = ".rds")
  saveRDS(list(setup = setup, port = port), rds)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script, rds),
    stdout  = "|", stderr = "|")
  # rds is read by the child within milliseconds; deletion is the
  # parent's responsibility — handled by the test's on.exit alongside
  # process kill.
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

test_that("single-process serve handles GET, POST, JSON", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_get ("/ping",  function(req) "pong") |>
      dr_post("/echo",  function(req) dr_response(req$body)) |>
      dr_get ("/json",  function(req) dr_json(list(ok = TRUE, n = 42L)))
  }, port)
  on.exit(stop_server(proc), add = TRUE)

  wait_ready(port, "/ping")

  r1 <- httr2::request(sprintf("http://127.0.0.1:%d/ping", port)) |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r1), 200L)
  expect_equal(httr2::resp_body_string(r1), "pong")

  r2 <- httr2::request(sprintf("http://127.0.0.1:%d/echo", port)) |>
    httr2::req_body_raw("hello world", type = "text/plain") |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r2), 200L)
  expect_equal(httr2::resp_body_string(r2), "hello world")

  r3 <- httr2::request(sprintf("http://127.0.0.1:%d/json", port)) |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r3), 200L)
  body <- httr2::resp_body_json(r3)
  expect_true(body$ok)
  expect_equal(body$n, 42L)
})

test_that("middleware short-circuits and post-processes end-to-end", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_use(function(req, nxt) {
        if (is.null(dr_header(req, "X-Auth"))) {
          return(dr_response("nope", status = 401L))
        }
        res <- nxt()
        res$headers[["X-Tagged"]] <- "yes"
        res
      }) |>
      dr_get("/secret", function(req) "shh")
  }, port)
  on.exit(stop_server(proc), add = TRUE)

  wait_ready(port, "/secret")

  r_blocked <- httr2::request(sprintf("http://127.0.0.1:%d/secret", port)) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r_blocked), 401L)
  expect_equal(httr2::resp_body_string(r_blocked), "nope")

  r_ok <- httr2::request(sprintf("http://127.0.0.1:%d/secret", port)) |>
    httr2::req_headers(`X-Auth` = "1") |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r_ok), 200L)
  expect_equal(httr2::resp_body_string(r_ok), "shh")
  expect_equal(httr2::resp_header(r_ok, "X-Tagged"), "yes")
})

test_that("R handler error becomes a 500 response", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_get("/boom", function(req) stop("kaboom"))
  }, port)
  on.exit(stop_server(proc), add = TRUE)

  wait_ready(port, "/boom")

  r <- httr2::request(sprintf("http://127.0.0.1:%d/boom", port)) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r), 500L)
  expect_match(httr2::resp_body_string(r), "kaboom")
})
