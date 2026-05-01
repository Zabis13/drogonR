test_that("Drogon singleton is reachable", {
  threads <- .Call("drogonR_smoke")
  expect_type(threads, "integer")
  # Default thread count is 1 until the user calls dr_serve(threads = ...).
  expect_gte(threads, 1L)
})

test_that("bundled Drogon version matches", {
  ver <- .Call("drogonR_drogon_version")
  expect_type(ver, "character")
  expect_equal(ver, "1.9.12")
})
