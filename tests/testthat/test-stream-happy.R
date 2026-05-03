# Happy-path SSE: server streams N chunks; client reads the whole body
# and verifies every chunk arrived in order. Heavy: real server in a
# child Rscript.

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
  rds    <- tempfile("drogonR-test-", fileext = ".rds")
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

test_that("dr_stream pumps N chunks and closes with done = TRUE", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- free_port()
  N    <- 5L

  setup <- local({
    n <- N
    function(app) {
      app |>
        dr_get("/__ping__", function(req) "pong") |>
        dr_get("/sse", function(req) {
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
  resp <- tryCatch(
    httr2::request(url) |>
      httr2::req_timeout(10) |>
      httr2::req_perform(),
    error = function(e) { failed$any <- TRUE; stop(e) })

  status <- httr2::resp_status(resp)
  if (status != 200L) failed$any <- TRUE
  expect_equal(status, 200L)
  ct <- httr2::resp_content_type(resp)
  if (!grepl("text/event-stream", ct, fixed = TRUE)) failed$any <- TRUE
  expect_match(ct, "text/event-stream", fixed = TRUE)

  body <- httr2::resp_body_string(resp)
  for (i in seq_len(N)) {
    if (!grepl(sprintf("data: %d", i), body, fixed = TRUE)) failed$any <- TRUE
    expect_match(body, sprintf("data: %d", i), fixed = TRUE,
                 info = sprintf("missing chunk #%d in body:\n%s", i, body))
  }
})

test_that("dr_stream_sse formats SSE frames and splits multi-line data", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  port <- free_port()

  setup <- function(app) {
    app |>
      dr_get("/__ping__", function(req) "pong") |>
      dr_get("/sse", function(req) {
        dr_stream_sse(
          state = list(i = 0L),
          generator = function(state, cancelled) {
            if (cancelled || state$i >= 3L) {
              return(list(data = "", state = state, done = TRUE))
            }
            state$i <- state$i + 1L
            # Tick #2 carries a multi-line payload to verify the
            # spec-mandated split into multiple `data:` lines.
            d <- if (state$i == 2L) "line one\nline two" else
                 sprintf("tick %d", state$i)
            list(data = d, state = state, done = FALSE)
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

  resp <- tryCatch(
    httr2::request(sprintf("http://127.0.0.1:%d/sse", port)) |>
      httr2::req_timeout(10) |>
      httr2::req_perform(),
    error = function(e) { failed$any <- TRUE; stop(e) })

  status <- httr2::resp_status(resp)
  if (status != 200L) failed$any <- TRUE
  expect_equal(status, 200L)
  ct <- httr2::resp_content_type(resp)
  if (!grepl("text/event-stream", ct, fixed = TRUE)) failed$any <- TRUE
  expect_match(ct, "text/event-stream", fixed = TRUE)
  cc <- httr2::resp_header(resp, "Cache-Control")
  if (!identical(cc, "no-cache")) failed$any <- TRUE
  expect_equal(cc, "no-cache")
  xab <- httr2::resp_header(resp, "X-Accel-Buffering")
  if (!identical(xab, "no")) failed$any <- TRUE
  expect_equal(xab, "no")

  body <- httr2::resp_body_string(resp)
  needles <- c("data: tick 1\n\n",
               # Multi-line frame: each \n becomes its own `data:` line,
               # frame terminated by a blank line.
               "data: line one\ndata: line two\n\n",
               "data: tick 3\n\n")
  for (n in needles) {
    if (!grepl(n, body, fixed = TRUE)) failed$any <- TRUE
    expect_match(body, n, fixed = TRUE)
  }
})
