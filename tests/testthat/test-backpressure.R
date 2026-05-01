# End-to-end stress on the C++ request queue. Send N concurrent
# requests at a deliberately-slow handler so that many of them sit in
# the queue at once, then assert the invariants that request_queue.cpp
# is supposed to guarantee:
#
#   - completeness:   every request gets a response (no drops)
#   - no duplicates:  each id appears exactly once (no double-pop /
#                     double-notify)
#   - FIFO (threads=1 only): with one Drogon I/O thread the dispatcher
#     pulls in submission order, so response order must match
#
# threads >= 2 makes response order non-deterministic — only the first
# two invariants are meaningful there.

free_port <- function() sample(20000:65000, 1)

wait_ready <- function(port, path = "/__ping__", timeout = 10) {
  Sys.sleep(0.5)
  deadline <- Sys.time() + timeout
  url <- sprintf("http://127.0.0.1:%d%s", port, path)
  repeat {
    ok <- tryCatch({
      r <- httr2::request(url) |>
        httr2::req_timeout(1) |>
        httr2::req_error(is_error = function(resp) FALSE) |>
        httr2::req_perform()
      !is.null(r)
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(invisible(TRUE))
    if (Sys.time() > deadline) {
      stop(sprintf("server did not become reachable on :%d within %ds",
                   port, timeout))
    }
    Sys.sleep(0.1)
  }
}

hard_kill <- function(pid) {
  suppressWarnings(system2("pkill", c("-KILL", "-P", pid),
                           stdout = FALSE, stderr = FALSE))
  suppressWarnings(tools::pskill(pid, tools::SIGKILL))
  Sys.sleep(0.2)
}

# Spawn a server in a forked child with a single slow route. The
# 50 ms sleep is well above the loopback RTT, so by the time request
# k is being dispatched, requests k+1..N are already enqueued.
spawn_slow_server <- function(port, threads, max_queue = 1024L,
                              sleep_s = 0.05) {
  force(port); force(threads); force(max_queue); force(sleep_s)
  parallel::mcparallel({
    library(drogonR)
    app <- dr_app() |>
      dr_get("/slow", function(req) {
        Sys.sleep(sleep_s)
        dr_query(req, "id")
      })
    dr_serve(app, port = port, threads = threads, max_queue = max_queue)
    repeat later::run_now(timeoutSecs = 3600)
  })
}

# Hammer the server with N concurrent /slow?id=k requests using
# httr2's libcurl-multi backend. Returns a data frame with one row
# per submitted request, in submission order. `status` is NA when
# the request itself errored (network / timeout).
hammer <- function(port, n) {
  reqs <- lapply(seq_len(n), function(i) {
    httr2::request(sprintf("http://127.0.0.1:%d/slow?id=%d", port, i)) |>
      httr2::req_timeout(15) |>
      httr2::req_error(is_error = function(resp) FALSE)
  })
  # httr2's default parallel pool caps concurrency at 10 — too low to
  # push more than 10 requests into our queue at once. Bump max_active
  # to n so the bounded-queue test can actually exceed max_queue.
  resps <- httr2::req_perform_parallel(reqs, on_error = "continue",
                                       max_active = n, progress = FALSE)
  data.frame(
    id     = seq_len(n),
    status = vapply(resps, function(r) {
      if (inherits(r, "httr2_response")) httr2::resp_status(r) else NA_integer_
    }, integer(1)),
    body   = vapply(resps, function(r) {
      if (inherits(r, "httr2_response")) httr2::resp_body_string(r) else NA_character_
    }, character(1)),
    stringsAsFactors = FALSE
  )
}

test_that("threads=1: all requests answered, no duplicates, FIFO preserved", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  job  <- spawn_slow_server(port, threads = 1L)
  on.exit(hard_kill(job$pid), add = TRUE)
  wait_ready(port, "/slow?id=0")

  n   <- 30L
  res <- hammer(port, n)

  expect_equal(nrow(res), n)
  expect_true(all(res$status == 200L))
  expect_equal(length(unique(res$body)), n)        # no duplicates
  expect_equal(res$body, as.character(seq_len(n))) # FIFO
})

test_that("threads=2: all requests answered, no duplicates (order not asserted)", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  job  <- spawn_slow_server(port, threads = 2L)
  on.exit(hard_kill(job$pid), add = TRUE)
  wait_ready(port, "/slow?id=0")

  n   <- 30L
  res <- hammer(port, n)

  expect_equal(nrow(res), n)
  expect_true(all(res$status == 200L))
  expect_equal(length(unique(res$body)), n)             # no duplicates
  expect_setequal(res$body, as.character(seq_len(n)))   # all ids, any order
})

test_that("max_queue=10 sheds excess load with HTTP 503", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  n    <- 30L
  # max_queue = 1 plus a slow handler (0.5 s) is a deliberately
  # extreme overload. Three invariants matter, in order of importance:
  #   1. ok + shed == n — the system lost no request and hung no
  #      connection. This is the real backpressure invariant: under
  #      overload we may reject, but never drop or hang.
  #   2. shed >= 20    — the bound actually fired at scale. A
  #      regression that re-introduces an unbounded queue would push
  #      shed to 0.
  #   3. ok >= 1       — at least one request got through (otherwise
  #      we'd be testing a broken server, not backpressure).
  job <- spawn_slow_server(port, threads = 1L,
                           max_queue = 1L, sleep_s = 0.5)
  on.exit(hard_kill(job$pid), add = TRUE)
  wait_ready(port, "/slow?id=0")

  res <- hammer(port, n)

  expect_equal(nrow(res), n)
  expect_false(any(is.na(res$status)))

  ok   <- sum(res$status == 200L)
  shed <- sum(res$status == 503L)

  expect_equal(ok + shed, n)        # invariant 1: no losses, no hangs
  expect_gte(shed, 20L)              # invariant 2: bound fired at scale
  expect_gte(ok,   1L)               # invariant 3: server is alive

  # Sanity-check the 503 body so a future change can't accidentally
  # answer with the wrong status text but still tally as "shed".
  expect_match(res$body[res$status == 503L][[1]],
               "queue is full")
})
