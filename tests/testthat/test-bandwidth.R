# End-to-end checks for dr_serve(bandwidth =): per-connection egress
# shaping enforced on the Drogon I/O thread.
#
# Heavy: spawns a real Rscript server per test.
#
# Sizes are kept small deliberately -- the point is to observe the delay
# a token bucket imposes, and a payload just past the burst does that as
# well as a huge one while keeping the suite fast.

bw_port <- function() sample(20000:65000, 1)

bw_wait_ready <- function(port, timeout = 10) {
  deadline <- Sys.time() + timeout
  url <- sprintf("http://127.0.0.1:%d/small", port)
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
      stop(sprintf("server not reachable on :%d within %ds", port, timeout))
    }
    Sys.sleep(0.1)
  }
}

# 256 KiB of payload behind a 64 KiB/s bucket: the burst covers the
# first 64 KiB, the remaining 192 KiB take ~3s.
KIB       <- 1024L
PAYLOAD_N <- 256L * KIB
RATE      <- 64L * KIB

bw_spawn <- function(port, bandwidth = 0, burst = NULL) {
  setup <- function(app) {
    # Random bytes, not a run of 'x': a compressible body would be gzipped
    # down to a few hundred bytes, fit entirely inside the burst, and the
    # shaping under test would never engage.
    set.seed(42)
    body <- rawToChar(as.raw(sample(33:126, 256L * 1024L, replace = TRUE)))
    dr_get(app, "/big",   function(req) dr_response(body))
    dr_get(app, "/small", function(req) dr_response("ok"))
    app
  }
  rds <- tempfile("drogonR-bw-test-", fileext = ".rds")
  saveRDS(list(setup = setup, port = port,
               bandwidth = bandwidth, bandwidth_burst = burst), rds)
  processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", testthat::test_path("server-script.R"), rds),
    stdout  = "|", stderr = "|")
}

bw_fetch <- function(port, path = "/big", timeout = 30) {
  t0 <- Sys.time()
  resp <- httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_timeout(timeout) |>
    # Ask for the body verbatim. httr2 defaults to Accept-Encoding: gzip,
    # and shaping the compressed stream is not what these tests measure.
    httr2::req_headers(`Accept-Encoding` = "identity") |>
    httr2::req_perform()
  list(elapsed = as.numeric(difftime(Sys.time(), t0, units = "secs")),
       size    = length(httr2::resp_body_raw(resp)))
}

test_that("an unshaped server returns the whole body promptly", {
  skip_on_cran_strict()
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- bw_port()
  proc <- bw_spawn(port)
  on.exit(proc$kill(), add = TRUE)
  bw_wait_ready(port)

  r <- bw_fetch(port)
  expect_equal(r$size, PAYLOAD_N)
  # No shaping: this is a loopback transfer, well under a second.
  expect_lt(r$elapsed, 2)
})

test_that("bandwidth shaping delays a body larger than the burst", {
  skip_on_cran_strict()
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- bw_port()
  proc <- bw_spawn(port, bandwidth = RATE, burst = RATE)
  on.exit(proc$kill(), add = TRUE)
  bw_wait_ready(port)

  r <- bw_fetch(port)

  # The body must still arrive intact -- shaping delays bytes, it never
  # drops them. A truncated read here is the regression that matters.
  expect_equal(r$size, PAYLOAD_N)

  # 256 KiB through a 64 KiB bucket refilling at 64 KiB/s: 64 KiB is free,
  # the other 192 KiB cost ~3s. Bounds are loose enough for a loaded CI
  # box but tight enough to fail if shaping silently does nothing.
  expect_gt(r$elapsed, 1.5)
  expect_lt(r$elapsed, 10)
})

test_that("a body within the burst is not delayed", {
  skip_on_cran_strict()
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- bw_port()
  # Bucket larger than the payload: shaping is configured but never bites.
  proc <- bw_spawn(port, bandwidth = RATE, burst = PAYLOAD_N * 2)
  on.exit(proc$kill(), add = TRUE)
  bw_wait_ready(port)

  r <- bw_fetch(port)
  expect_equal(r$size, PAYLOAD_N)
  expect_lt(r$elapsed, 2)
})
