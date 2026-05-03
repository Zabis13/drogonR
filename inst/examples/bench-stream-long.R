# Long-stream throughput bench for drogonR.
#
# Streams N SSE chunks from a child Rscript to a single httr2 client
# and reports time-to-first-byte, total duration, and effective
# chunk/byte rates. Optionally has the generator write one line per
# tick to disk to measure with file I/O in the hot loop (off by
# default — set FILE_LOG=1 to enable).
#
# Usage:
#   Rscript inst/examples/bench-stream-long.R                       # default 10000
#   N_CHUNKS=100000 Rscript inst/examples/bench-stream-long.R
#   N_CHUNKS=100000 FILE_LOG=1 Rscript inst/examples/bench-stream-long.R

suppressPackageStartupMessages({
  library(drogonR)
  library(httr2)
  library(processx)
})

n_chunks <- as.integer(Sys.getenv("N_CHUNKS", "10000"))
port     <- as.integer(Sys.getenv("PORT",     sample(20000:65000, 1)))
file_log <- identical(Sys.getenv("FILE_LOG"), "1")
log_path <- if (file_log) {
  tempfile("drogonR-bench-long-", fileext = ".log")
} else {
  ""
}

server_script <- tempfile("drogonR-bench-long-server-", fileext = ".R")
writeLines(sprintf('
suppressPackageStartupMessages(library(drogonR))
N        <- %dL
LOG      <- "%s"
file_log <- nzchar(LOG)
app <- dr_app() |>
  dr_get("/__ping__", function(req) "pong") |>
  dr_get("/sse", function(req) {
    dr_stream(
      state = list(i = 0L),
      next_chunk = function(state, cancelled) {
        if (cancelled || state$i >= N) {
          return(list(chunk = "", state = state, done = TRUE))
        }
        state$i <- state$i + 1L
        if (file_log) {
          cat("TICK ", state$i, "\n", sep = "", file = LOG, append = TRUE)
        }
        list(chunk = sprintf("data: %%d\n\n", state$i),
             state = state, done = FALSE)
      })
  })
dr_serve(app, port = %dL)
repeat later::run_now(timeoutSecs = 3600)
', n_chunks, log_path, port), server_script)

proc <- processx::process$new(
  command = file.path(R.home("bin"), "Rscript"),
  args    = c("--vanilla", server_script),
  stdout  = "|", stderr = "|")

on.exit({
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  out <- tryCatch(proc$read_all_output(), error = function(e) "")
  err <- tryCatch(proc$read_all_error(),  error = function(e) "")
  if (nzchar(out)) cat("---- child stdout ----\n", out, "\n", sep = "")
  if (nzchar(err)) cat("---- child stderr ----\n", err, "\n", sep = "")
  unlink(server_script, force = TRUE)
  if (file_log && file.exists(log_path)) unlink(log_path, force = TRUE)
}, add = TRUE)

# Wait for /__ping__ to come up.
ping_url <- sprintf("http://127.0.0.1:%d/__ping__", port)
deadline <- Sys.time() + 30
repeat {
  ok <- tryCatch({
    httr2::request(ping_url) |>
      httr2::req_timeout(1) |>
      httr2::req_error(is_error = function(r) FALSE) |>
      httr2::req_perform()
    TRUE
  }, error = function(e) FALSE)
  if (isTRUE(ok)) break
  if (!proc$is_alive()) stop("server died before becoming reachable")
  if (Sys.time() > deadline) stop("server never came up on :", port)
  Sys.sleep(0.1)
}

cat(sprintf("benchmarking: N=%d chunks, port=%d, file_log=%s\n",
            n_chunks, port, file_log))

ttfb  <- NA_real_
bytes <- 0L
t0    <- proc.time()[["elapsed"]]
httr2::request(sprintf("http://127.0.0.1:%d/sse", port)) |>
  httr2::req_timeout(600) |>
  httr2::req_perform_stream(
    callback = function(buf) {
      if (is.na(ttfb)) ttfb <<- proc.time()[["elapsed"]] - t0
      bytes <<- bytes + length(buf)
      TRUE
    },
    buffer_kb = 64)
total <- proc.time()[["elapsed"]] - t0

cat(sprintf("\n=== drogonR long-stream bench ===\n"))
cat(sprintf("  ttfb              : %7.3f s\n", ttfb))
cat(sprintf("  total             : %7.3f s\n", total))
cat(sprintf("  bytes received    : %d\n", bytes))
cat(sprintf("  chunks/s          : %.0f\n", n_chunks / total))
cat(sprintf("  bytes/s           : %.0f\n", bytes    / total))
