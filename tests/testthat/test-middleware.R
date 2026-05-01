# Middleware chain unit tests. No server, no sockets — just exercise
# the dr_use() / .dr_run_chain() / .dr_wrap_handler() composition
# directly, so these stay light and CRAN-safe.

mk_req <- function() drogonR:::.dr_make_request(list(
  method = "GET", path = "/", body = "", headers = character(),
  query = character()))

run <- function(app, handler) {
  drogonR:::.dr_wrap_handler(handler, app)(list(
    method = "GET", path = "/", body = "", headers = character(),
    query = character()))
}

test_that("dr_use validates inputs", {
  app <- dr_app()
  expect_error(dr_use(app, "not a function"), "must be a function")
  expect_error(dr_use("not an app", function(req, nxt) nxt()),
               "drogon_app object")
})

test_that("dr_use does not warn or message", {
  app <- dr_app()
  # The old stub printed a "not yet implemented" message; the live
  # version must be silent.
  expect_silent(dr_use(app, function(req, nxt) nxt()))
})

test_that("middleware chain reaches handler when each calls nxt()", {
  app <- dr_app() |>
    dr_use(function(req, nxt) nxt()) |>
    dr_use(function(req, nxt) nxt())
  res <- run(app, function(req) "ok")
  expect_equal(res$status, 200L)
  expect_equal(res$body, "ok")
})

test_that("middleware short-circuit prevents handler from running", {
  hit <- FALSE
  app <- dr_app() |>
    dr_use(function(req, nxt) dr_response("blocked", status = 401L))
  res <- run(app, function(req) { hit <<- TRUE; "should not be returned" })
  expect_false(hit)
  expect_equal(res$status, 401L)
  expect_equal(res$body, "blocked")
})

test_that("middleware runs in registration order", {
  trace <- character()
  app <- dr_app() |>
    dr_use(function(req, nxt) { trace <<- c(trace, "a"); nxt() }) |>
    dr_use(function(req, nxt) { trace <<- c(trace, "b"); nxt() }) |>
    dr_use(function(req, nxt) { trace <<- c(trace, "c"); nxt() })
  run(app, function(req) { trace <<- c(trace, "h"); "ok" })
  expect_equal(trace, c("a", "b", "c", "h"))
})

test_that("middleware can modify the downstream response", {
  app <- dr_app() |>
    dr_use(function(req, nxt) {
      res <- nxt()
      res$headers[["X-Tag"]] <- "wrapped"
      res
    })
  res <- run(app, function(req) dr_response("ok"))
  expect_equal(res$headers[["X-Tag"]], "wrapped")
  expect_equal(res$body, "ok")
})

test_that("error in middleware becomes a 500", {
  app <- dr_app() |>
    dr_use(function(req, nxt) stop("mw blew up"))
  res <- run(app, function(req) "unreached")
  expect_equal(res$status, 500L)
  expect_match(res$body, "mw blew up")
})

test_that("error in handler bubbles up; outer mw can catch via tryCatch", {
  caught <- NULL
  app <- dr_app() |>
    dr_use(function(req, nxt) {
      tryCatch(nxt(),
               error = function(e) {
                 caught <<- conditionMessage(e)
                 dr_response("recovered", status = 503L)
               })
    })
  res <- run(app, function(req) stop("handler boom"))
  expect_equal(caught, "handler boom")
  expect_equal(res$status, 503L)
  expect_equal(res$body, "recovered")
})

test_that("no middleware: handler runs directly", {
  app <- dr_app()
  res <- run(app, function(req) "bare")
  expect_equal(res$body, "bare")
})
