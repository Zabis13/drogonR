# Pure-R unit tests for dr_header / dr_query / dr_body. These don't
# need a running server — they exercise the accessor functions directly
# against a synthetic drogon_request built from a list, the same shape
# the C++ bridge passes to handlers.

make_req <- function(headers = character(),
                     query   = character(),
                     body    = NULL) {
  drogonR:::.dr_make_request(list(
    method  = "GET",
    path    = "/",
    body    = body,
    headers = headers,
    query   = query
  ))
}

test_that("dr_header is case-insensitive and returns NULL when absent", {
  req <- make_req(headers = c("Content-Type" = "application/json",
                              "X-Auth"       = "secret"))

  expect_equal(dr_header(req, "Content-Type"), "application/json")
  expect_equal(dr_header(req, "content-type"), "application/json")
  expect_equal(dr_header(req, "CONTENT-TYPE"), "application/json")
  expect_equal(dr_header(req, "X-Auth"),       "secret")
  expect_null(dr_header(req, "X-Missing"))
})

test_that("dr_header on a request with no headers returns NULL", {
  req <- make_req()
  expect_null(dr_header(req, "anything"))
})

test_that("dr_header rejects non-drogon_request input", {
  expect_error(dr_header(list(), "x"), "drogon_request")
})

test_that("dr_query returns the full named vector when name is NULL", {
  req <- make_req(query = c(page = "2", q = "drogon"))
  out <- dr_query(req)
  expect_equal(out[["page"]], "2")
  expect_equal(out[["q"]],    "drogon")
})

test_that("dr_query returns a single value or NULL by name", {
  req <- make_req(query = c(page = "2", q = "drogon"))
  expect_equal(dr_query(req, "page"), "2")
  expect_equal(dr_query(req, "q"),    "drogon")
  expect_null(dr_query(req, "missing"))
})

test_that("dr_query on a request with no query returns NULL by name", {
  req <- make_req()
  expect_null(dr_query(req, "x"))
})

test_that("dr_query rejects non-drogon_request input", {
  expect_error(dr_query(list()), "drogon_request")
})

test_that("dr_body default returns the raw text body", {
  req <- make_req(body = "hello world")
  expect_equal(dr_body(req), "hello world")
  expect_equal(dr_body(req, "text"), "hello world")
})

test_that("dr_body(as = 'raw') returns a raw vector of the body bytes", {
  req <- make_req(body = "abc")
  out <- dr_body(req, "raw")
  expect_type(out, "raw")
  expect_equal(out, charToRaw("abc"))
})

test_that("dr_body(as = 'raw') on empty body returns raw(0)", {
  req <- make_req(body = NULL)
  expect_equal(dr_body(req, "raw"), raw(0))
})

test_that("dr_body(as = 'json') parses JSON when jsonlite is available", {
  skip_if_not_installed("jsonlite")
  req <- make_req(body = '{"ok":true,"n":42}')
  out <- dr_body(req, "json")
  expect_true(out$ok)
  expect_equal(out$n, 42L)
})

test_that("dr_body rejects non-drogon_request input and unknown 'as'", {
  expect_error(dr_body(list()), "drogon_request")
  req <- make_req(body = "x")
  expect_error(dr_body(req, "yaml"))
})
