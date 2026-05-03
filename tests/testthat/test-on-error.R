# dr_on_error() unit tests. Like the middleware tests, these exercise
# .dr_wrap_handler() directly so they stay light and CRAN-safe — no
# server, no sockets.

run <- function(app, handler) {
  drogonR:::.dr_wrap_handler(handler, app)(list(
    method = "GET", path = "/x", body = "", headers = character(),
    query = character()))
}

test_that("dr_on_error validates inputs", {
  app <- dr_app()
  expect_error(dr_on_error(app, "nope"), "must be NULL or a function")
  expect_error(dr_on_error("not an app", function(req, err) "x"),
               "drogon_app object")
})

test_that("dr_on_error accepts NULL to clear", {
  app <- dr_app() |>
    dr_on_error(function(req, err) dr_response("x", status = 500L))
  expect_false(is.null(app$on_error))
  app <- dr_on_error(app, NULL)
  expect_null(app$on_error)
})

test_that("without on_error, a handler error becomes the default 500", {
  app <- dr_app()
  res <- run(app, function(req) stop("kaboom"))
  expect_equal(res$status, 500L)
  expect_match(res$body, "kaboom")
  expect_equal(res$headers[["Content-Type"]], "text/plain")
})

test_that("on_error builds a custom response from (req, err)", {
  seen <- list()
  app <- dr_app() |>
    dr_on_error(function(req, err) {
      seen <<- list(path = req$path, msg = conditionMessage(err))
      dr_response(paste0("custom: ", conditionMessage(err)),
                  status = 503L,
                  headers = list("X-Source" = "on-error"))
    })
  res <- run(app, function(req) stop("nope"))
  expect_equal(res$status, 503L)
  expect_equal(res$body, "custom: nope")
  expect_equal(res$headers[["X-Source"]], "on-error")
  expect_equal(seen$path, "/x")
  expect_equal(seen$msg,  "nope")
})

test_that("on_error fires when middleware throws", {
  fired <- FALSE
  app <- dr_app() |>
    dr_use(function(req, nxt) stop("mw exploded")) |>
    dr_on_error(function(req, err) {
      fired <<- TRUE
      dr_response("from on_error", status = 500L)
    })
  res <- run(app, function(req) "never reached")
  expect_true(fired)
  expect_equal(res$body, "from on_error")
})

test_that("on_error returning a string normalises to text/plain 200 default", {
  # The user can return a bare string; we still want 200 unless they
  # explicitly use dr_response(). This matches handler return semantics.
  app <- dr_app() |>
    dr_on_error(function(req, err) "just a string")
  res <- run(app, function(req) stop("x"))
  expect_equal(res$status, 200L)
  expect_equal(res$body, "just a string")
})

test_that("on_error throwing falls back to default 500 and logs both errors", {
  app <- dr_app() |>
    dr_on_error(function(req, err) stop("on_error itself failed"))
  msgs <- character()
  withCallingHandlers(
    res <- run(app, function(req) stop("original boom")),
    message = function(m) {
      msgs <<- c(msgs, conditionMessage(m))
      invokeRestart("muffleMessage")
    })
  expect_equal(res$status, 500L)
  expect_match(res$body, "original boom")
  # Both errors must surface in stderr/messages so the user can debug.
  expect_true(any(grepl("original boom",          msgs)))
  expect_true(any(grepl("on_error itself failed", msgs)))
  expect_true(any(grepl("falling back",            msgs)))
})
