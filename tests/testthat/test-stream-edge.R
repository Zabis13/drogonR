# Edge cases for dr_stream:
#   1. Error inside next_chunk after some chunks have been sent: stream
#      tears down cleanly, child stays alive, stderr carries the
#      diagnostic the dispatcher prints.
#   2. Two concurrent clients on the same /sse route get independent
#      state machines (each sees its own monotonic sequence end-to-end).
#
# Heavy: real server in a child Rscript.

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

spawn_server <- function(setup, port) {
  script <- testthat::test_path("server-script.R")
  rds    <- tempfile("drogonR-stream-edge-", fileext = ".rds")
  saveRDS(list(setup = setup, port = port), rds)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--vanilla", script, rds),
    stdout  = "|", stderr = "|")
  attr(proc, "rds") <- rds
  proc
}

stop_server <- function(proc) {
  rds <- attr(proc, "rds")
  if (proc$is_alive()) {
    tryCatch(proc$kill(), error = function(e) NULL)
  }
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

# --- 1. error inside next_chunk ------------------------------------------

test_that("error in next_chunk closes the stream cleanly without crashing the server", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_get("/sse", function(req) {
        dr_stream(
          state = list(i = 0L),
          next_chunk = function(state, cancelled) {
            if (cancelled) {
              return(list(chunk = "", state = state, done = TRUE))
            }
            state$i <- state$i + 1L
            # Send 2 frames, then blow up on the 3rd pump. The
            # dispatcher must catch this, log to stderr, and tear the
            # session down without taking the server with it.
            if (state$i >= 3L) {
              stop("synthetic generator failure for test")
            }
            list(chunk = sprintf("data: %d\n\n", state$i),
                 state = state, done = FALSE)
          })
      })
  }

  failed <- new.env(parent = emptyenv()); failed$any <- FALSE
  proc <- spawn_server(setup, port)
  on.exit({
    if (failed$any) {
      out <- tryCatch(proc$read_output(), error = function(e) "")
      err <- tryCatch(proc$read_error(),  error = function(e) "")
      if (nzchar(out)) message("---- child stdout ----\n", out)
      if (nzchar(err)) message("---- child stderr ----\n", err)
    }
    stop_server(proc)
  }, add = TRUE)

  wait_ready(port, "/__ping__")

  # Body completes (truncated chunked) instead of hanging.
  url <- sprintf("http://127.0.0.1:%d/sse", port)
  resp <- tryCatch(
    httr2::request(url) |>
      httr2::req_timeout(10) |>
      httr2::req_perform(),
    error = function(e) { failed$any <- TRUE; stop(e) })

  status <- httr2::resp_status(resp)
  if (status != 200L) failed$any <- TRUE
  expect_equal(status, 200L)

  body <- httr2::resp_body_string(resp)
  # Two frames must have made it before the generator threw.
  for (i in 1:2) {
    if (!grepl(sprintf("data: %d", i), body, fixed = TRUE)) failed$any <- TRUE
    expect_match(body, sprintf("data: %d", i), fixed = TRUE,
                 info = sprintf("missing chunk #%d in body:\n%s", i, body))
  }
  # The third must NOT appear — the throw happens before its send.
  if (grepl("data: 3", body, fixed = TRUE)) failed$any <- TRUE
  expect_false(grepl("data: 3", body, fixed = TRUE),
               info = paste0("body unexpectedly contains data: 3:\n", body))

  # Server must still be serving — fetch /__ping__ again.
  ping <- tryCatch(
    httr2::request(sprintf("http://127.0.0.1:%d/__ping__", port)) |>
      httr2::req_timeout(2) |>
      httr2::req_perform(),
    error = function(e) { failed$any <- TRUE; stop(e) })
  if (httr2::resp_status(ping) != 200L) failed$any <- TRUE
  expect_equal(httr2::resp_status(ping), 200L)
  if (!proc$is_alive()) failed$any <- TRUE
  expect_true(proc$is_alive(), info = "child server died after generator error")

  # Diagnostic should be in stderr. Read non-blockingly.
  Sys.sleep(0.2)
  err_text <- tryCatch(proc$read_error(), error = function(e) "")
  if (!grepl("next_chunk\\(\\) raised an error", err_text)) failed$any <- TRUE
  expect_match(err_text, "next_chunk\\(\\) raised an error",
               info = paste0("stderr was:\n", err_text))
})

# --- 2. concurrent clients keep independent state ------------------------

test_that("two concurrent clients on the same route get independent state", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")
  skip_if_not_installed("curl")

  port <- free_port()
  N    <- 6L

  setup <- local({
    n <- N
    function(app) {
      app |>
        dr_get("/__ping__", function(req) "pong") |>
        dr_get("/sse", function(req) {
          # Each request starts its own state object; if dispatcher
          # accidentally shared state across sessions the sequences would
          # interleave instead of each running 1..N.
          dr_stream(
            state = list(i = 0L),
            next_chunk = function(state, cancelled) {
              if (cancelled || state$i >= n) {
                return(list(chunk = "", state = state, done = TRUE))
              }
              state$i <- state$i + 1L
              list(chunk = sprintf("data: %d\n\n", state$i),
                   state = state, done = FALSE)
            })
        })
    }
  })

  failed <- new.env(parent = emptyenv()); failed$any <- FALSE
  proc <- spawn_server(setup, port)
  on.exit({
    if (failed$any) {
      out <- tryCatch(proc$read_output(), error = function(e) "")
      err <- tryCatch(proc$read_error(),  error = function(e) "")
      if (nzchar(out)) message("---- child stdout ----\n", out)
      if (nzchar(err)) message("---- child stderr ----\n", err)
    }
    stop_server(proc)
  }, add = TRUE)

  wait_ready(port, "/__ping__")

  url <- sprintf("http://127.0.0.1:%d/sse", port)

  # Fire two GETs in parallel via curl::multi_*. httr2's perform_parallel
  # serializes per-host by default; using curl directly avoids that.
  pool <- curl::new_pool()
  bodies <- list(NULL, NULL)
  statuses <- integer(2)
  errors <- character(2)
  for (k in 1:2) {
    local({
      idx <- k
      h <- curl::new_handle(timeout = 15)
      curl::curl_fetch_multi(
        url,
        done = function(resp) {
          bodies[[idx]]   <<- rawToChar(resp$content)
          statuses[idx]  <<- resp$status_code
        },
        fail = function(msg) {
          errors[idx] <<- as.character(msg)
        },
        pool   = pool,
        handle = h)
    })
  }
  curl::multi_run(pool = pool, timeout = 20)

  if (any(nzchar(errors))) {
    failed$any <- TRUE
    message("curl errors: ", paste(errors, collapse = " | "))
  }
  expect_true(all(!nzchar(errors)),
              info = paste("curl errors:", paste(errors, collapse = " | ")))
  if (!all(statuses == 200L)) failed$any <- TRUE
  expect_true(all(statuses == 200L),
              info = paste("statuses:", paste(statuses, collapse = ",")))

  # Each body must contain the full 1..N sequence in order. If sessions
  # were leaking state we'd see jumps or missing numbers.
  for (k in 1:2) {
    body <- bodies[[k]]
    seq_observed <- as.integer(
      regmatches(body, gregexpr("(?<=data: )\\d+", body, perl = TRUE))[[1L]])
    if (!identical(seq_observed, seq_len(N))) failed$any <- TRUE
    expect_equal(seq_observed, seq_len(N),
                 info = sprintf("client %d got sequence %s; body:\n%s",
                                k,
                                paste(seq_observed, collapse = ","),
                                body))
  }
})
