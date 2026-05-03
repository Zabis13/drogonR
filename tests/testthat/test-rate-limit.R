# End-to-end checks for dr_rate_limit(): the I/O thread must reject
# over-budget requests with 429 + Retry-After before they hit R, and the
# matching/scope rules must behave as documented.
#
# Heavy: spawns a real Rscript server per test.

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
  rds    <- tempfile("drogonR-rl-test-", fileext = ".rds")
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

# Hit `path` `n` times sequentially and return the response status codes.
hit_n <- function(port, path, n, timeout = 2) {
  vapply(seq_len(n), function(i) {
    r <- httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
      httr2::req_timeout(timeout) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform()
    httr2::resp_status(r)
  }, integer(1))
}

# --- per_route scope: bucket is per-route, prefix-matched ----------------

test_that("per_route RL: capacity exhausted → 429 with Retry-After, prefix-matched", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__",   function(req) "pong") |>
      dr_get("/api/limited", function(req) "u") |>
      dr_get("/health",      function(req) "ok") |>
      # window deliberately long so the 4 hits in this test stay inside
      # the same sliding window — flake-proof on slow CI.
      dr_rate_limit(capacity = 2L, window = 30, routes = "/api/")
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

  codes <- hit_n(port, "/api/limited", 4L)
  if (!identical(codes, c(200L, 200L, 429L, 429L))) failed$any <- TRUE
  expect_equal(codes, c(200L, 200L, 429L, 429L))

  # Retry-After must be present on the 429 and parse as a positive int.
  r <- httr2::request(sprintf("http://127.0.0.1:%d/api/limited", port)) |>
    httr2::req_timeout(2) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  if (httr2::resp_status(r) != 429L) failed$any <- TRUE
  expect_equal(httr2::resp_status(r), 429L)
  ra <- httr2::resp_header(r, "Retry-After")
  if (is.null(ra) || is.na(suppressWarnings(as.integer(ra))) ||
      as.integer(ra) <= 0L) failed$any <- TRUE
  expect_false(is.null(ra))
  expect_gt(as.integer(ra), 0L)

  # /health is outside the /api/ prefix → unaffected.
  health_codes <- hit_n(port, "/health", 5L)
  if (!all(health_codes == 200L)) failed$any <- TRUE
  expect_true(all(health_codes == 200L))
})

# --- per_route scope: each matched route owns its own bucket -------------

test_that("per_route scope: two prefix-matched routes have independent buckets", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_get("/api/a",    function(req) "a") |>
      dr_get("/api/b",    function(req) "b") |>
      dr_rate_limit(capacity = 2L, window = 30, routes = "/api/",
                    scope = "per_route")
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

  # Drain /api/a's bucket. /api/b should still be fully available.
  a_codes <- hit_n(port, "/api/a", 3L)
  b_codes <- hit_n(port, "/api/b", 2L)
  if (!identical(a_codes, c(200L, 200L, 429L))) failed$any <- TRUE
  if (!identical(b_codes, c(200L, 200L)))       failed$any <- TRUE
  expect_equal(a_codes, c(200L, 200L, 429L))
  expect_equal(b_codes, c(200L, 200L))
})

# --- global scope: one bucket shared across matched routes ---------------

test_that("global scope: one shared bucket across all matched routes", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_get("/api/a",    function(req) "a") |>
      dr_get("/api/b",    function(req) "b") |>
      dr_rate_limit(capacity = 2L, window = 30, routes = "/api/",
                    scope = "global")
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

  # 1 hit on /api/a, 1 hit on /api/b → bucket exhausted; both routes 429.
  a1 <- hit_n(port, "/api/a", 1L)
  b1 <- hit_n(port, "/api/b", 1L)
  a2 <- hit_n(port, "/api/a", 1L)
  b2 <- hit_n(port, "/api/b", 1L)
  if (a1 != 200L || b1 != 200L || a2 != 429L || b2 != 429L) failed$any <- TRUE
  expect_equal(a1, 200L)
  expect_equal(b1, 200L)
  expect_equal(a2, 429L)
  expect_equal(b2, 429L)
})

# --- fixed_window: bucket refills after the window elapses ---------------

test_that("fixed_window: bucket refills after window elapses", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_get("/refills",  function(req) "ok") |>
      dr_rate_limit(capacity = 1L, window = 1, type = "fixed_window")
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

  first  <- hit_n(port, "/refills", 1L)
  second <- hit_n(port, "/refills", 1L)
  if (first != 200L || second != 429L) failed$any <- TRUE
  expect_equal(first,  200L)
  expect_equal(second, 429L)

  # Wait past the window, then a new request should be admitted.
  Sys.sleep(1.6)
  third <- hit_n(port, "/refills", 1L)
  if (third != 200L) failed$any <- TRUE
  expect_equal(third, 200L)
})
