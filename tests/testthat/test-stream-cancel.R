# End-to-end: client disconnects mid-stream, generator gets one final
# call with cancelled = TRUE, and the dispatcher tears the session
# down. Heavy: real server in a child Rscript, raw socket client.

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

test_that("stream generator sees cancelled = TRUE after client disconnect", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("processx")

  log_path <- tempfile("drogonR-stream-cancel-", fileext = ".log")
  on.exit(if (file.exists(log_path)) unlink(log_path), add = TRUE)

  port <- free_port()

  # `setup` closes over log_path; saveRDS preserves it for the child.
  setup <- local({
    log <- log_path
    function(app) {
      app |>
        dr_get("/__ping__", function(req) "pong") |>
        dr_get("/sse", function(req) {
          dr_stream(
            state = list(i = 0L),
            next_chunk = function(state, cancelled) {
              if (cancelled) {
                cat("CANCEL ", state$i, "\n", sep = "",
                    file = log, append = TRUE)
                return(list(chunk = "", state = state, done = TRUE))
              }
              state$i <- state$i + 1L
              cat("TICK ", state$i, "\n", sep = "",
                  file = log, append = TRUE)
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

  # Raw socket: send a minimal HTTP/1.1 GET, read just enough to know
  # at least two SSE frames have arrived, then close abruptly. Using
  # httr2 here is awkward because we want to forcibly drop the
  # connection mid-stream.
  con <- socketConnection("127.0.0.1", port = port,
                          blocking = TRUE, open = "r+b", timeout = 5)
  # NB: no `Connection: close` — Drogon won't start chunked streaming
  # for a connection it's already going to close, so the dispatcher
  # never pumps next_chunk(). Default is keep-alive on HTTP/1.1.
  writeLines(
    c("GET /sse HTTP/1.1",
      sprintf("Host: 127.0.0.1:%d", port),
      "", ""),
    con, sep = "\r\n")

  # Drain bytes until we've seen "data: 2" go by (= two frames sent).
  # Then close. SSE bodies are chunked; we don't need to parse the
  # chunked framing — substring search on the raw bytes is enough.
  buf <- raw(0)
  deadline <- Sys.time() + 5
  saw_two <- FALSE
  while (Sys.time() < deadline) {
    chunk <- readBin(con, what = "raw", n = 4096L)
    if (length(chunk) > 0L) {
      buf <- c(buf, chunk)
      txt <- rawToChar(buf)
      if (grepl("data: 2", txt, fixed = TRUE)) {
        saw_two <- TRUE
        break
      }
    } else {
      Sys.sleep(0.02)
    }
  }
  close(con)
  if (!saw_two) {
    failed$any <- TRUE
    message("saw_two=FALSE bytes_read=", length(buf),
            " log_exists=", file.exists(log_path))
    if (file.exists(log_path)) {
      message("---- log after read ----\n",
              paste(readLines(log_path, warn = FALSE), collapse = "\n"))
    }
    if (length(buf) > 0L) {
      message("---- first 400 bytes of response ----\n",
              substr(rawToChar(buf), 1L, 400L))
    }
  }
  expect_true(saw_two, info = "did not receive two SSE frames in time")

  # Server detects disconnect on the next send() after our close. Poll
  # the log until the CANCEL line appears, or fail.
  deadline <- Sys.time() + 5
  cancel_seen <- FALSE
  cancel_at   <- NA_integer_
  while (Sys.time() < deadline) {
    if (file.exists(log_path)) {
      lines <- readLines(log_path, warn = FALSE)
      cancel_lines <- grep("^CANCEL ", lines, value = TRUE)
      if (length(cancel_lines) >= 1L) {
        cancel_seen <- TRUE
        cancel_at   <- as.integer(sub("^CANCEL ", "", cancel_lines[[1L]]))
        break
      }
    }
    Sys.sleep(0.05)
  }
  if (!cancel_seen) failed$any <- TRUE
  expect_true(cancel_seen, info = "generator never saw cancelled = TRUE")

  # After teardown the generator must not run again. Wait a bit, then
  # confirm the tick count is frozen.
  Sys.sleep(0.5)
  if (!file.exists(log_path)) {
    failed$any <- TRUE
    message("log_path missing at final check: ", log_path)
    lines_after <- character(0)
  } else {
    lines_after <- readLines(log_path, warn = FALSE)
  }
  ticks_after <- sum(grepl("^TICK ", lines_after))
  cancels     <- sum(grepl("^CANCEL ", lines_after))
  if (cancels != 1L || ticks_after > cancel_at + 1L) failed$any <- TRUE
  expect_equal(cancels, 1L, info = "CANCEL must fire exactly once")
  # Tick count after a brief wait should not exceed cancel_at + a small
  # tolerance: at most one in-flight tick may have run between send()
  # failing and the pump observing the flag.
  expect_lte(ticks_after, cancel_at + 1L)
})
