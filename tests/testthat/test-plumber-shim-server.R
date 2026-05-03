# End-to-end integration tests for drogonR::pr_run().
#
# Spawns a fresh Rscript that loads a real plumber.R file via
# `plumber::pr()` and serves it through `drogonR::pr_run()`. The
# parent process drives requests with httr2. Heavy by design — gated
# behind NOT_CRAN in tests/testthat.R.

skip_if_no_deps <- function() {
  testthat::skip_if_not_installed("plumber")
  testthat::skip_if_not_installed("httr2")
  testthat::skip_if_not_installed("processx")
}

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
      stop(sprintf("plumber-shim server did not respond on :%d within %ds",
                   port, timeout))
    }
    Sys.sleep(0.1)
  }
}

spawn_plumber <- function(plumber_R, port) {
  script <- testthat::test_path("server-script-plumber.R")
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script, plumber_R, as.character(port)),
    stdout  = "|", stderr = "|")
  proc
}

stop_proc <- function(proc) {
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
}

# Write a plumber.R that exercises every supported feature: GETs with
# typed and untyped path params, POST with JSON body, query params,
# req injection, list/df/string return shapes.
write_plumber_app <- function() {
  tmp <- tempfile(fileext = ".R")
  writeLines(c(
    "#* @get /__ping__",
    "function() 'pong'",
    "",
    "#* @get /hello",
    "function() 'hello world'",
    "",
    "#* @get /users/<id>",
    "function(id) list(id = id)",
    "",
    "#* @get /typed/<id:int>",
    "function(id) list(id = id, type = class(id))",
    "",
    "#* @get /search",
    "function(q, n) list(q = q, n = n)",
    "",
    "#* @get /method",
    "function(req) list(method = req$method, path = req$path)",
    "",
    "#* @post /echo",
    "function(name, age) list(name = name, age = age)",
    "",
    "#* @put /df",
    "function() data.frame(x = 1:2, y = c('a','b'))",
    ""), tmp)
  tmp
}

GET <- function(port, path) {
  httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

POST_json <- function(port, path, body) {
  httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_method("POST") |>
    httr2::req_headers("Content-Type" = "application/json") |>
    httr2::req_body_raw(body) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

PUT <- function(port, path) {
  httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_method("PUT") |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

test_that("pr_run serves plumber routes end-to-end", {
  skip_if_no_deps()
  port <- free_port()
  app  <- write_plumber_app()
  proc <- suppressWarnings(spawn_plumber(app, port))
  on.exit({ stop_proc(proc); unlink(app) }, add = TRUE)
  wait_ready(port, "/__ping__")

  # Bare-string return — plumber wraps as ["..."] via its default
  # JSON serializer; the shim must do the same to stay drop-in.
  r <- GET(port, "/hello")
  expect_equal(httr2::resp_status(r), 200L)
  expect_equal(httr2::resp_body_string(r), '["hello world"]')
  expect_match(httr2::resp_header(r, "Content-Type"),
               "^application/json")

  # Path param (untyped) → JSON list, length-1 vectors NOT unboxed.
  r <- GET(port, "/users/42")
  expect_equal(httr2::resp_status(r), 200L)
  expect_match(httr2::resp_body_string(r), '"id":\\["42"\\]')

  # Typed path param: drogonR coerces per the <name:type> annotation,
  # so /typed/<id:int> hands the handler an integer (matching plumber).
  r <- GET(port, "/typed/7")
  expect_equal(httr2::resp_status(r), 200L)
  body <- httr2::resp_body_string(r)
  expect_match(body, '"id":\\[7\\]')
  expect_match(body, '"type":\\["integer"\\]')

  # Query string params
  r <- GET(port, "/search?q=cats&n=10")
  expect_equal(httr2::resp_status(r), 200L)
  body <- httr2::resp_body_string(r)
  expect_match(body, '"q":\\["cats"\\]')
  expect_match(body, '"n":\\["10"\\]')

  # req injection
  r <- GET(port, "/method")
  expect_equal(httr2::resp_status(r), 200L)
  body <- httr2::resp_body_string(r)
  expect_match(body, '"method":\\["GET"\\]')
  expect_match(body, '"path":\\["/method"\\]')

  # POST JSON body → handler args matched by name from body
  r <- POST_json(port, "/echo", '{"name":"jane","age":30}')
  expect_equal(httr2::resp_status(r), 200L)
  body <- httr2::resp_body_string(r)
  expect_match(body, '"name":\\["jane"\\]')
  expect_match(body, '"age":\\[30\\]')

  # data.frame return → JSON array of row-objects, scalars per row
  # are NOT wrapped in arrays (plumber-style).
  r <- PUT(port, "/df")
  expect_equal(httr2::resp_status(r), 200L)
  body <- httr2::resp_body_string(r)
  expect_match(body, '"x":1')
  expect_match(body, '"y":"a"')
})
