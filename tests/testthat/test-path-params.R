# End-to-end path parameter tests.
#
# Path-pattern parser accepts three placeholder syntaxes:
#   :name   <name>   {name}
# The R-side translates each into a Drogon regex with positional
# captures and a parallel param_names vector; the C++ dispatcher
# rebuilds a named character vector for `req$params`.

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

GET <- function(port, path) {
  httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

test_that("all three placeholder syntaxes capture the same value", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_get("/colon/:id",  function(req) req$params[["id"]]) |>
      dr_get("/angle/<id>", function(req) req$params[["id"]]) |>
      dr_get("/brace/{id}", function(req) req$params[["id"]])
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/colon/x")

  for (kind in c("colon", "angle", "brace")) {
    r <- GET(port, sprintf("/%s/42", kind))
    expect_equal(httr2::resp_status(r), 200L)
    expect_equal(httr2::resp_body_string(r), "42")
  }
})

test_that("multiple path parameters in one route", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_get("/a/:x/b/:y", function(req) {
        sprintf("%s|%s", req$params[["x"]], req$params[["y"]])
      })
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/a/x/b/y")

  r <- GET(port, "/a/foo/b/bar")
  expect_equal(httr2::resp_status(r), 200L)
  expect_equal(httr2::resp_body_string(r), "foo|bar")
})

test_that("regex metacharacters in literal segments are escaped", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_get("/v1.0/users/:id", function(req) req$params[["id"]])
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/v1.0/users/x")

  # Exact path matches and literal dot is treated literally.
  r_ok <- GET(port, "/v1.0/users/abc")
  expect_equal(httr2::resp_status(r_ok), 200L)
  expect_equal(httr2::resp_body_string(r_ok), "abc")

  # /v1X0/... must NOT match (would only match if '.' were a regex wildcard).
  r_no <- GET(port, "/v1X0/users/abc")
  expect_equal(httr2::resp_status(r_no), 404L)
})

test_that("non-matching paths return 404", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |> dr_get("/users/:id", function(req) req$params[["id"]])
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/users/x")

  # Wrong prefix.
  expect_equal(httr2::resp_status(GET(port, "/nope/x")), 404L)
  # Trailing extra segment must not match a single-segment placeholder.
  expect_equal(httr2::resp_status(GET(port, "/users/x/extra")), 404L)
})

test_that("static route exposes empty named character for req$params", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_get("/static", function(req) {
        # Encode the structure so we can assert on it from outside.
        sprintf("type=%s|len=%d|named=%s",
                typeof(req$params),
                length(req$params),
                as.character(!is.null(names(req$params))))
      })
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/static")

  r <- GET(port, "/static")
  expect_equal(httr2::resp_status(r), 200L)
  # Empty STRSXP with names attribute set in C++.
  expect_equal(httr2::resp_body_string(r),
               "type=character|len=0|named=TRUE")
})

test_that("duplicate parameter names raise at registration", {
  # R-side parser check; no server needed.
  app <- dr_app()
  expect_error(dr_get(app, "/a/:x/b/:x", function(req) "x"),
               "duplicate path parameter")
})
