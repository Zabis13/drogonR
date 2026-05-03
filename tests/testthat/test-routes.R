# Pure-R unit tests for route registration. No server needed — we
# inspect the app$routes table directly. These cover dr_put / dr_delete
# (otherwise untouched) plus the input-validation paths shared across
# all four methods, plus dr_*_cpp argument validation.

test_that("dr_get / dr_post / dr_put / dr_delete each register under the right key", {
  app <- dr_app() |>
    dr_get   ("/items",     function(req) "g") |>
    dr_post  ("/items",     function(req) "p") |>
    dr_put   ("/items/:id", function(req) "u") |>
    dr_delete("/items/:id", function(req) "d")

  expect_named(app$routes,
               c("GET /items", "POST /items",
                 "PUT /items/:id", "DELETE /items/:id"),
               ignore.order = TRUE)
  expect_equal(app$routes[["PUT /items/:id"]]$method,    "PUT")
  expect_equal(app$routes[["DELETE /items/:id"]]$method, "DELETE")
})

test_that("registering the same method+path twice warns and overwrites", {
  app <- dr_app() |> dr_get("/x", function(req) "first")
  expect_warning(
    app <- dr_get(app, "/x", function(req) "second"),
    "overwriting"
  )
  # Same key, but the handler must be the new one. Smoke-test by calling.
  expect_equal(app$routes[["GET /x"]]$handler(NULL), "second")
})

test_that("dr_put / dr_delete reject non-app, non-function, non-string inputs", {
  app <- dr_app()
  expect_error(dr_put(list(), "/x", function(req) ""), "drogon_app")
  expect_error(dr_put(app, "/x", "not a function"),    "function")
  expect_error(dr_put(app, c("/a", "/b"), function(req) ""), "single string")

  expect_error(dr_delete(list(), "/x", function(req) ""), "drogon_app")
  expect_error(dr_delete(app, "/x", 42),                  "function")
  expect_error(dr_delete(app, NA_character_, function(req) ""), "single string")
})

test_that("dr_*_cpp validate inputs", {
  app <- dr_app()

  expect_error(dr_get_cpp(list(), "/x", "pkg", "sym"), "drogon_app")

  expect_error(dr_get_cpp(app, c("/a", "/b"), "pkg", "sym"), "single string")
  expect_error(dr_get_cpp(app, NA_character_,  "pkg", "sym"), "single string")

  expect_error(dr_get_cpp(app, "/x", "",            "sym"), "non-empty string")
  expect_error(dr_get_cpp(app, "/x", NA_character_, "sym"), "non-empty string")
  expect_error(dr_get_cpp(app, "/x", c("a", "b"),   "sym"), "non-empty string")

  expect_error(dr_get_cpp(app, "/x", "pkg", ""),            "non-empty string")
  expect_error(dr_get_cpp(app, "/x", "pkg", NA_character_), "non-empty string")
})

test_that("dr_*_cpp errors when package is not installed", {
  app <- dr_app()
  pkg <- "drogonR.nonexistent.pkg.zzz"
  expect_error(dr_get_cpp   (app, "/a", pkg, "sym"), "not installed")
  expect_error(dr_post_cpp  (app, "/b", pkg, "sym"), "not installed")
  expect_error(dr_put_cpp   (app, "/c", pkg, "sym"), "not installed")
  expect_error(dr_delete_cpp(app, "/d", pkg, "sym"), "not installed")
})
