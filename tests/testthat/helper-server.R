# Helpers for end-to-end server tests.
#
# These are placeholders — they become useful once the C++ bridge and the
# R-facing dr_serve()/dr_stop() API exist (tasks #3 and #4).

# Find a free TCP port on localhost by binding port 0 and reading back the
# kernel-assigned port number.
random_port <- function() {
  con <- socketConnection("localhost", port = 0L, server = TRUE,
                          blocking = FALSE, open = "a+", timeout = 1)
  on.exit(close(con), add = TRUE)
  # The R sockets API does not expose getsockname(); fall back to a random
  # high port and let the caller retry on collision. Good enough for tests.
  sample(20000:65000, 1)
}

# Poll until something is listening on `host:port`, or fail after `timeout` s.
wait_for_port <- function(port, host = "127.0.0.1", timeout = 5) {
  deadline <- Sys.time() + timeout
  repeat {
    ok <- tryCatch({
      con <- socketConnection(host, port = port, blocking = TRUE,
                              open = "r+", timeout = 1)
      close(con)
      TRUE
    }, error = function(e) FALSE)
    if (ok) return(invisible(TRUE))
    if (Sys.time() > deadline) {
      stop(sprintf("Port %s on %s did not open within %ds", port, host, timeout))
    }
    Sys.sleep(0.05)
  }
}

# Skip a test on CRAN (heavy / networking tests should call this).
skip_on_cran_strict <- function() {
  testthat::skip_if(identical(Sys.getenv("NOT_CRAN"), ""),
                    "skipping on CRAN")
}
