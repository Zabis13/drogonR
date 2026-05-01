# Argument validation for dr_serve(). These tests must NOT actually
# start the server (Drogon can only run once per R session and we need
# the slot for heavy tests). Every assertion below is expected to fail
# during validation, before .Call(drogonR_server_start) is reached.

skip_if_running <- function() {
  if (isTRUE(dr_running())) skip("a drogonR server is already running")
}

test_that("workers must be a single positive integer", {
  skip_if_running()
  app <- dr_app() |> dr_get("/", function(req) "ok")
  expect_error(dr_serve(app, workers = 0L),     ">= 1")
  expect_error(dr_serve(app, workers = NA),     ">= 1")
  expect_error(dr_serve(app, workers = c(1, 2)),">= 1")
  expect_error(dr_serve(app, workers = -1L),    ">= 1")
})

test_that("on_worker_start must be NULL or a function", {
  skip_if_running()
  app <- dr_app() |> dr_get("/", function(req) "ok")
  expect_error(dr_serve(app, on_worker_start = "not a function"),
               "must be NULL or a function")
  expect_error(dr_serve(app, on_worker_start = 42),
               "must be NULL or a function")
})

test_that("threads must be a single positive integer", {
  skip_if_running()
  app <- dr_app() |> dr_get("/", function(req) "ok")
  expect_error(dr_serve(app, threads = 0L), ">= 1")
  expect_error(dr_serve(app, threads = NA), ">= 1")
})

test_that("port must be in 1..65535", {
  skip_if_running()
  app <- dr_app() |> dr_get("/", function(req) "ok")
  expect_error(dr_serve(app, port = 0L),     "1..65535")
  expect_error(dr_serve(app, port = 70000L), "1..65535")
  expect_error(dr_serve(app, port = NA),     "1..65535")
})

test_that("dr_status returns empty data frame in single-process mode", {
  s <- dr_status()
  expect_s3_class(s, "data.frame")
  expect_equal(nrow(s), 0L)
  expect_named(s, c("pid", "alive"))
})
