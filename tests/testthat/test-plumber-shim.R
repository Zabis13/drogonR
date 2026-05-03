# Unit tests for the plumber shim's pure-R helpers — no server, no
# sockets, no network. Heavy end-to-end coverage lives in
# test-plumber-shim-server.R.

skip_if_no_plumber <- function() {
  testthat::skip_if_not_installed("plumber")
}

test_that("path conversion rewrites <name:type> to :name", {
  expect_equal(drogonR:::.dr_plumber_path_to_dr("/users/<id>"),
               "/users/:id")
  expect_equal(drogonR:::.dr_plumber_path_to_dr("/users/<id:int>"),
               "/users/:id")
  expect_equal(
    drogonR:::.dr_plumber_path_to_dr("/a/<x:double>/b/<y>"),
    "/a/:x/b/:y")
})

test_that("path-param type extraction returns typed names only", {
  expect_equal(drogonR:::.dr_plumber_path_param_types("/a"), list())
  expect_equal(drogonR:::.dr_plumber_path_param_types("/a/<x>"), list())
  expect_equal(drogonR:::.dr_plumber_path_param_types("/a/<x:int>"),
               list(x = "int"))
  expect_equal(
    drogonR:::.dr_plumber_path_param_types("/a/<x:int>/b/<y:double>/c/<z>"),
    list(x = "int", y = "double"))
})

test_that("path-param coercion handles known types and falls through", {
  coerce <- drogonR:::.dr_coerce_plumber_param
  expect_identical(coerce("42",  "int"),     42L)
  expect_identical(coerce("42",  "integer"), 42L)
  expect_identical(coerce("3.5", "dbl"),     3.5)
  expect_identical(coerce("3.5", "double"),  3.5)
  expect_identical(coerce("3.5", "numeric"), 3.5)
  expect_identical(coerce("true",  "bool"),    TRUE)
  expect_identical(coerce("FALSE", "logical"), FALSE)
  # Unknown type — left as character (plumber would too).
  expect_identical(coerce("xyz", "uuid"), "xyz")
  # No type — pass-through.
  expect_identical(coerce("xyz", NULL), "xyz")
  # Coercion failure -> NA, matching as.integer() behaviour.
  expect_identical(coerce("abc", "int"), NA_integer_)
})

test_that("default plumber filters are not flagged as user filters", {
  skip_if_no_plumber()
  pr <- plumber::pr()
  # Should not throw — only the canonical built-in filters are active.
  expect_silent(drogonR:::.dr_reject_unsupported_plumber(pr))
})

test_that("user @filter triggers an explicit error", {
  skip_if_no_plumber()
  src <- c(
    "#* @filter logger",
    "function(req) { plumber::forward() }",
    "",
    "#* @get /ping",
    "function() 'pong'")
  tmp <- tempfile(fileext = ".R"); writeLines(src, tmp)
  pr <- plumber::pr(tmp)
  expect_error(drogonR:::.dr_reject_unsupported_plumber(pr),
               "filter.*not supported")
})

test_that("pr_mount() triggers an explicit error", {
  skip_if_no_plumber()
  child  <- tempfile(fileext = ".R")
  writeLines(c("#* @get /child", "function() 'c'"), child)
  parent <- tempfile(fileext = ".R")
  writeLines(c("#* @get /root", "function() 'r'"), parent)
  pr <- plumber::pr(parent) |>
    plumber::pr_mount("/sub", plumber::pr(child))
  expect_error(drogonR:::.dr_reject_unsupported_plumber(pr),
               "mount.*not supported")
})

test_that("translation builds drogonR routes for each verb", {
  skip_if_no_plumber()
  src <- c(
    "#* @get /a",
    "function() 'a'",
    "",
    "#* @post /b",
    "function(req) 'b'",
    "",
    "#* @put /c/<id>",
    "function(id) list(id = id)",
    "",
    "#* @delete /d",
    "function() 'd'")
  tmp <- tempfile(fileext = ".R"); writeLines(src, tmp)
  pr <- plumber::pr(tmp)

  app <- drogonR:::.dr_plumber_to_app(pr)
  keys <- names(app$routes)
  expect_true("GET /a"      %in% keys)
  expect_true("POST /b"     %in% keys)
  expect_true("PUT /c/:id"  %in% keys)
  expect_true("DELETE /d"   %in% keys)
})

test_that("typed path parameter is registered without any warning", {
  skip_if_no_plumber()
  src <- c("#* @get /users/<id:int>", "function(id) list(id=id)")
  tmp <- tempfile(fileext = ".R"); writeLines(src, tmp)
  pr <- plumber::pr(tmp)
  # We coerce path types now — registration must be silent.
  expect_silent(drogonR:::.dr_plumber_to_app(pr))
})

test_that("res-parameter handler emits a one-time warning", {
  skip_if_no_plumber()
  src <- c("#* @get /x",
           "function(req, res) { res$status <- 201; 'ok' }")
  tmp <- tempfile(fileext = ".R"); writeLines(src, tmp)
  pr <- plumber::pr(tmp)
  expect_warning(drogonR:::.dr_plumber_to_app(pr),
                 "'res' parameter.*not supported")
})

test_that("formals matching: path > query > body, with defaults respected", {
  fn <- function(id, q, b, missing_with_default = "DEF") {
    list(id = id, q = q, b = b, m = missing_with_default)
  }
  param_names <- names(formals(fn))

  req <- drogonR:::.dr_make_request(list(
    method = "POST", path = "/x",
    body   = '{"b": "from-body"}',
    headers = c("content-type" = "application/json"),
    query  = c(q = "from-query")))
  req$params <- list(id = "from-path")

  args <- drogonR:::.dr_resolve_plumber_args(
    fn, req, param_names, has_req = FALSE, has_res = FALSE)
  out <- do.call(fn, args)
  expect_equal(out$id, "from-path")
  expect_equal(out$q,  "from-query")
  expect_equal(out$b,  "from-body")
  expect_equal(out$m,  "DEF")
})

test_that("path-param coercion runs in resolve_plumber_args", {
  fn <- function(id, ratio) list(id = id, ratio = ratio,
                                 cls = c(class(id), class(ratio)))
  param_names <- names(formals(fn))
  req <- drogonR:::.dr_make_request(list(
    method = "GET", path = "/x", body = "",
    headers = character(), query = character()))
  req$params <- list(id = "42", ratio = "0.5")
  args <- drogonR:::.dr_resolve_plumber_args(
    fn, req, param_names,
    has_req = FALSE, has_res = FALSE,
    param_type = list(id = "int", ratio = "double"))
  expect_identical(args$id,    42L)
  expect_identical(args$ratio, 0.5)
})

test_that("missing required param without default arrives as NULL", {
  # plumber 1.x passes NULL for absent required args; mirror that so
  # handlers that treat 'missing == optional' keep working.
  fn <- function(absent) list(got = absent)
  param_names <- names(formals(fn))
  req <- drogonR:::.dr_make_request(list(
    method = "GET", path = "/x", body = "",
    headers = character(), query = character()))
  args <- drogonR:::.dr_resolve_plumber_args(
    fn, req, param_names, has_req = FALSE, has_res = FALSE)
  expect_named(args, "absent")
  expect_null(args$absent)
})

test_that("req parameter is injected when handler asks for it", {
  fn <- function(req, x) list(method = req$method, x = x)
  param_names <- names(formals(fn))
  req <- drogonR:::.dr_make_request(list(
    method = "GET", path = "/x", body = "",
    headers = character(), query = c(x = "1")))
  args <- drogonR:::.dr_resolve_plumber_args(
    fn, req, param_names, has_req = TRUE, has_res = FALSE)
  expect_identical(args$req, req)
  expect_equal(args$x, "1")
})

test_that("default serializer matches plumber 1.x: JSON with auto_unbox=FALSE", {
  # list -> JSON object, no unboxing
  res_list <- drogonR:::.dr_plumber_serialize(list(a = 1, b = "x"))
  expect_equal(res_list$headers[["Content-Type"]], "application/json")
  expect_match(res_list$body, '"a":\\[1\\]')
  expect_match(res_list$body, '"b":\\["x"\\]')

  # bare string -> JSON array (plumber wraps it), NOT text/plain
  res_txt <- drogonR:::.dr_plumber_serialize("hello")
  expect_equal(res_txt$headers[["Content-Type"]], "application/json")
  expect_equal(res_txt$body, '["hello"]')

  # data.frame -> JSON array of row-objects
  res_df <- drogonR:::.dr_plumber_serialize(
    data.frame(x = 1:2, y = c("a","b")))
  expect_equal(res_df$headers[["Content-Type"]], "application/json")
  expect_match(res_df$body, '"x":1')
  expect_match(res_df$body, '"y":"a"')

  # numeric scalar -> JSON array (no unbox)
  res_num <- drogonR:::.dr_plumber_serialize(42)
  expect_equal(res_num$body, "[42]")
})

test_that("class-'json' return values pass through verbatim", {
  skip_if_not_installed("jsonlite")
  pre <- jsonlite::toJSON(list(already = TRUE), auto_unbox = TRUE)
  out <- drogonR:::.dr_plumber_serialize(pre)
  expect_equal(out$headers[["Content-Type"]], "application/json")
  # No double-encoding — body equals the pre-serialized string exactly.
  expect_equal(out$body, as.character(pre))
})

test_that("dr_response-shaped return value passes through unchanged", {
  r <- dr_response("ok", status = 201L,
                   headers = list("X-A" = "1"))
  out <- drogonR:::.dr_plumber_serialize(r)
  expect_identical(out, r)
})

test_that("PlumberResponse / PlumberFile return values fail loudly", {
  # We don't need real instances — class() check is enough.
  fake_resp <- structure(list(), class = "PlumberResponse")
  fake_file <- structure(list(), class = "PlumberFile")
  expect_error(drogonR:::.dr_plumber_serialize(fake_resp),
               "PlumberResponse.*not supported")
  expect_error(drogonR:::.dr_plumber_serialize(fake_file),
               "PlumberResponse/PlumberFile.*not supported")
})

test_that("pr_run validates host and emits warning for non-wildcard", {
  skip_if_no_plumber()
  src <- c("#* @get /a", "function() 'a'")
  tmp <- tempfile(fileext = ".R"); writeLines(src, tmp)
  pr <- plumber::pr(tmp)
  # Don't actually start the server — exercise input validation by
  # passing an invalid type so we error before dr_serve() is called.
  expect_error(pr_run(pr, host = NA_character_), "single string")
  expect_error(pr_run("not a router"), "Plumber router")
  # Non-wildcard host → warning. Use a port we never bind by erroring
  # afterwards via an obviously bad port.
  expect_warning(
    tryCatch(pr_run(pr, host = "10.0.0.1", port = 0L), error = function(e) NULL),
    "host.*ignored")
})
