# End-to-end test for streaming native (R-bypass) routes registered
# via dr_get_cpp_stream(). Uses the dummy backend at
# inst/test-backend/drogonRtestbackend (handlers `tick` and
# `tick_long`).
#
# Heavy: real Rscript server, real TCP, real HTTP round-trips.

free_port_cs <- function() sample(20000:65000, 1)

wait_ready_cs <- function(port, timeout = 10) {
  Sys.sleep(0.5)
  deadline <- Sys.time() + timeout
  repeat {
    ok <- tryCatch({
      con <- socketConnection("127.0.0.1", port = port,
                              blocking = TRUE, open = "r+", timeout = 1)
      close(con)
      TRUE
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(invisible(TRUE))
    if (Sys.time() > deadline) {
      stop(sprintf("cpp-stream server did not open :%d within %ds",
                   port, timeout))
    }
    Sys.sleep(0.1)
  }
}

spawn_cs_server <- function(routes, port, libdir, cpp_workers = 4L) {
  script <- testthat::test_path("server-script-cpp.R")
  rds    <- tempfile("drogonR-cpp-stream-test-", fileext = ".rds")
  saveRDS(list(port = port, routes = routes,
               cpp_workers = cpp_workers), rds)

  child_libs <- paste(c(libdir, .libPaths()), collapse = .Platform$path.sep)
  proc <- processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args    = c("--no-save", "--no-restore",
                "--no-init-file", "--no-site-file",
                script, rds),
    env     = c(Sys.getenv(), R_LIBS = child_libs),
    stdout  = "|", stderr = "|")
  attr(proc, "rds") <- rds
  proc
}

stop_cs_server <- function(proc) {
  rds <- attr(proc, "rds")
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

test_that("cpp-stream handler pushes N chunks via send()", {
  libdir <- ensure_cpp_backend()
  port <- free_port_cs()

  routes <- list(list(method = "POST", path = "/tick",
                      package = "drogonRtestbackend", callable = "tick",
                      kind = "stream"))
  failed <- new.env(parent = emptyenv()); failed$any <- FALSE
  proc <- spawn_cs_server(routes, port, libdir)
  on.exit({
    if (failed$any) {
      out <- tryCatch(proc$read_output(), error = function(e) "")
      err <- tryCatch(proc$read_error(),  error = function(e) "")
      if (nzchar(out)) message("---- child stdout ----\n", out)
      if (nzchar(err)) message("---- child stderr ----\n", err)
    }
    stop_cs_server(proc)
  }, add = TRUE)

  wait_ready_cs(port)

  resp <- tryCatch(
    httr2::request(sprintf("http://127.0.0.1:%d/tick", port)) |>
      httr2::req_method("POST") |>
      httr2::req_body_raw(charToRaw("8")) |>
      httr2::req_timeout(15) |>
      httr2::req_perform(),
    error = function(e) { failed$any <- TRUE; stop(e) })

  status <- httr2::resp_status(resp)
  if (status != 200L) failed$any <- TRUE
  expect_equal(status, 200L)
  ct <- httr2::resp_content_type(resp)
  if (!grepl("text/event-stream", ct, fixed = TRUE)) failed$any <- TRUE
  expect_match(ct, "text/event-stream", fixed = TRUE)
  body <- httr2::resp_body_string(resp)
  for (i in seq_len(8L)) {
    if (!grepl(sprintf("data: %d", i), body, fixed = TRUE)) failed$any <- TRUE
    expect_match(body, sprintf("data: %d", i), fixed = TRUE,
                 info = sprintf("missing chunk #%d in body:\n%s", i, body))
  }
})

test_that("cpp-stream cancel: client disconnect frees the worker promptly", {
  # tick_long sleeps 50ms × 100 between is_cancelled() polls (= ~5s if
  # never cancelled). With cpp_workers = 1 the only worker is busy
  # holding tick_long; if disconnect doesn't reach is_cancelled(), the
  # follow-up /tick request enqueues behind it and times out at 2s.
  # If cancel works, the worker is released within one 50ms tick and
  # /tick replies in milliseconds.
  libdir <- ensure_cpp_backend()
  port <- free_port_cs()

  routes <- list(
    list(method = "POST", path = "/tick",
         package = "drogonRtestbackend", callable = "tick",
         kind = "stream"),
    list(method = "GET",  path = "/tick_long",
         package = "drogonRtestbackend", callable = "tick_long",
         kind = "stream"))
  proc <- spawn_cs_server(routes, port, libdir, cpp_workers = 1L)
  failed <- new.env(parent = emptyenv()); failed$any <- FALSE
  on.exit({
    if (failed$any) {
      out <- tryCatch(proc$read_output(), error = function(e) "")
      err <- tryCatch(proc$read_error(),  error = function(e) "")
      if (nzchar(out)) message("---- child stdout ----\n", out)
      if (nzchar(err)) message("---- child stderr ----\n", err)
    }
    stop_cs_server(proc)
  }, add = TRUE)

  wait_ready_cs(port)

  # Open raw socket, fire GET /tick_long, read just enough to confirm
  # the worker has picked up the task, then close abruptly.
  con <- socketConnection("127.0.0.1", port = port,
                          blocking = TRUE, open = "r+b", timeout = 5)
  writeLines(
    c("GET /tick_long HTTP/1.1",
      sprintf("Host: 127.0.0.1:%d", port),
      "", ""),
    con, sep = "\r\n")
  # Drain a few bytes so we know the response is in flight (worker has
  # been dispatched). 200ms is plenty for the worker to enter sh_tick_long.
  Sys.sleep(0.2)
  invisible(readBin(con, what = "raw", n = 1024L))
  close(con)

  # Now hit the fast /tick route. With cpp_workers = 1, this only
  # returns quickly if the long handler observed cancellation.
  t0 <- Sys.time()
  resp <- tryCatch(
    httr2::request(sprintf("http://127.0.0.1:%d/tick", port)) |>
      httr2::req_method("POST") |>
      httr2::req_body_raw(charToRaw("4")) |>
      httr2::req_timeout(2) |>
      httr2::req_perform(),
    error = function(e) { failed$any <- TRUE; stop(e) })
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  status <- httr2::resp_status(resp)
  if (status != 200L) failed$any <- TRUE
  expect_equal(status, 200L)
  if (elapsed >= 1.5) failed$any <- TRUE
  expect_lt(elapsed, 1.5)
})

