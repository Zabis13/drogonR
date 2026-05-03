# End-to-end tests for dr_static(): files are served straight from a
# C++ I/O thread (R never sees the request), so this needs a real
# Drogon listener — heavy test, gated behind NOT_CRAN in tests/testthat.R.

free_port <- function() sample(20000:65000, 1)

wait_ready <- function(port, path = "/__ping__", timeout = 10) {
  Sys.sleep(0.5)
  deadline <- Sys.time() + timeout
  url <- sprintf("http://127.0.0.1:%d%s", port, path)
  repeat {
    ok <- tryCatch({
      httr2::request(url) |>
        httr2::req_timeout(1) |>
        httr2::req_error(is_error = function(resp) FALSE) |>
        httr2::req_perform()
      TRUE
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
  rds    <- tempfile("drogonR-test-static-", fileext = ".rds")
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

GET <- function(port, path) {
  httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

# Setup function used by every test below. Built once per test in the
# child Rscript so we don't share a tempdir between cases.
make_setup <- function() {
  function(app) {
    asset_dir <- file.path(tempdir(), "drogonR-static-assets")
    dir.create(asset_dir, showWarnings = FALSE, recursive = TRUE)
    writeLines("body { color: red; }",       file.path(asset_dir, "site.css"))
    writeLines("hello from static",          file.path(asset_dir, "hello.txt"))
    sub_dir <- file.path(asset_dir, "sub")
    dir.create(sub_dir, showWarnings = FALSE)
    writeLines("nested",                     file.path(sub_dir, "nested.txt"))
    # A "secret" file outside the mount so traversal tests have a real
    # target the rejection must protect.
    writeLines("DO NOT LEAK",                file.path(tempdir(), "secret.txt"))

    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_get("/api", function(req) "from R") |>
      dr_static("/assets", asset_dir)
  }
}

test_that("dr_static input validation rejects bad mount/dir", {
  app <- dr_app()
  expect_error(dr_static(app, "assets", "/tmp"), "starting with '/'")
  expect_error(dr_static(app, "/", "/tmp"),      "must not be just")
  expect_error(dr_static(app, "/x", ""),         "non-empty")
  expect_error(dr_static(app, "/x", c("a","b")), "single non-empty")
  expect_error(dr_static("nope", "/x", "/tmp"),  "drogon_app object")
})

test_that("dr_static stores mounts on the app and strips trailing slash", {
  app <- dr_app() |>
    dr_static("/assets/", "./public") |>
    dr_static("/files",   "./other")
  expect_length(app$static_mounts, 2L)
  expect_equal(app$static_mounts[[1]]$mount, "/assets")
  expect_equal(app$static_mounts[[1]]$dir,   "./public")
  expect_equal(app$static_mounts[[2]]$mount, "/files")
})

test_that("dr_static serves a file from the mounted directory", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(make_setup(), port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/__ping__")

  r <- GET(port, "/assets/hello.txt")
  expect_equal(httr2::resp_status(r), 200L)
  expect_match(httr2::resp_body_string(r), "hello from static")
})

test_that("dr_static auto-detects Content-Type from extension", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(make_setup(), port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/__ping__")

  r <- GET(port, "/assets/site.css")
  expect_equal(httr2::resp_status(r), 200L)
  expect_match(httr2::resp_header(r, "Content-Type"), "^text/css")
})

test_that("dr_static serves nested paths under the mount", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(make_setup(), port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/__ping__")

  r <- GET(port, "/assets/sub/nested.txt")
  expect_equal(httr2::resp_status(r), 200L)
  expect_match(httr2::resp_body_string(r), "nested")
})

test_that("dr_static returns 404 for files that don't exist", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(make_setup(), port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/__ping__")

  r <- GET(port, "/assets/missing.txt")
  expect_equal(httr2::resp_status(r), 404L)
})

test_that("dr_static rejects path traversal with 403", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(make_setup(), port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/__ping__")

  # Drogon's request parser usually rejects /../ in the path itself
  # before our handler runs (HTTP 400). The traversal check matters
  # for percent-encoded variants and for relative segments that slip
  # past parsing — try a URL-encoded one.
  r <- GET(port, "/assets/%2e%2e/secret.txt")
  expect_true(httr2::resp_status(r) %in% c(400L, 403L, 404L))
  if (httr2::resp_status(r) == 200L) {
    fail("path traversal succeeded — secret.txt was served")
  }
})

test_that("dynamic routes coexist with static mounts", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(make_setup(), port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/__ping__")

  r1 <- GET(port, "/api")
  expect_equal(httr2::resp_status(r1), 200L)
  expect_equal(httr2::resp_body_string(r1), "from R")

  r2 <- GET(port, "/assets/hello.txt")
  expect_equal(httr2::resp_status(r2), 200L)
})
