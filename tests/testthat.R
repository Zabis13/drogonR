library(testthat)
library(drogonR)

# Heavy tests — anything that starts a real server, opens sockets, or
# does end-to-end HTTP. These run only outside of CRAN (NOT_CRAN=true)
# so the CRAN check farm doesn't block on networking.
heavy <- c(
  "server-lifecycle",
  "workers",
  "backpressure",
  "path-params",
  "response-helpers",
  "static",
  "plumber-shim-server",
  "cpp-routes",
  "stream-happy",
  "stream-cancel",
  "stream-edge",
  "cpp-stream-routes",
  "rate-limit",
  "ws-happy",
  "ws-routes",
  "ws-room",
  "ws-cpp",
  "ws-batching",
  "ws-client"
)

on_cran <- !identical(Sys.getenv("NOT_CRAN"), "true")

test_dir <- if (dir.exists("testthat")) "testthat" else "tests/testthat"

if (on_cran) {
  message("--- RUNNING LIGHT TESTS ONLY ---")

  all_tests <- list.files(test_dir, pattern = "^test-.*\\.R$")
  all_names <- sub("^test-(.*)\\.R$", "\\1", all_tests)

  light_tests <- setdiff(all_names, heavy)

  if (length(light_tests) == 0) {
    test_check("drogonR")
  } else {
    # Anchor each name so a light filter can't match a heavy file as a
    # substring (e.g. "plumber-shim" must not select "plumber-shim-server").
    filter_regex <- paste0("^(", paste(light_tests, collapse = "|"), ")$")
    test_check("drogonR", filter = filter_regex)
  }
} else {
  test_check("drogonR")
}
