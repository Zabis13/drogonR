# Helper for the dr_*_cpp() integration test (test-cpp-routes.R).
#
# Builds and installs the dev-tree dummy backend at
# inst/test-backend/drogonRtestbackend into a tempdir() user library
# the first time it is needed, and returns that library path so test
# subprocesses can find the package via R_LIBS_USER.
#
# inst/test-backend/ is in .Rbuildignore, so this helper only works in
# the dev tree. Tests must skip on CRAN before calling it.

.cpp_backend_libdir <- local({
  cached <- NULL
  function() {
    if (!is.null(cached)) return(cached)

    src <- testthat::test_path("..", "..", "inst", "test-backend",
                               "drogonRtestbackend")
    if (!dir.exists(src)) {
      testthat::skip("test-backend source tree not found (likely a built tarball)")
    }

    lib <- file.path(tempdir(), "drogonR-test-backend-lib")
    dir.create(lib, showWarnings = FALSE, recursive = TRUE)

    if (!dir.exists(file.path(lib, "drogonRtestbackend"))) {
      r_bin <- file.path(R.home("bin"), "R")
      res <- suppressWarnings(system2(
        r_bin,
        args = c("CMD", "INSTALL", "--no-multiarch", "--no-test-load",
                 paste0("--library=", lib),
                 src),
        stdout = TRUE, stderr = TRUE))
      if (!is.null(attr(res, "status")) && attr(res, "status") != 0L) {
        message("R CMD INSTALL drogonRtestbackend failed:\n",
                paste(res, collapse = "\n"))
        testthat::skip("could not build drogonRtestbackend dummy")
      }
    }

    # Make the freshly-built backend importable from the supervisor
    # session too, not just from spawned children — last-test below
    # calls dr_get_cpp() directly here.
    if (!(lib %in% .libPaths())) {
      .libPaths(c(lib, .libPaths()))
    }

    cached <<- lib
    lib
  }
})

# Make sure the dummy backend is available; return its libdir.
ensure_cpp_backend <- function() {
  skip_on_cran_strict()
  testthat::skip_if_not_installed("processx")
  testthat::skip_if_not_installed("httr2")
  .cpp_backend_libdir()
}
