# Stream timings for drogonR.
#
# Runs a drogonR server in a child Rscript, streams N SSE chunks per
# request across S concurrent streams, and reports time-to-first-byte
# and total stream duration (p50/p95/p99). Pure-R client (httr2 +
# curl); no wrk/hey required.
#
# Usage:
#   Rscript inst/examples/bench-stream-timings.R
#   N_CHUNKS=200 N_STREAMS=16 Rscript inst/examples/bench-stream-timings.R

suppressPackageStartupMessages({
  library(drogonR)
  library(httr2)
  library(processx)
})

n_chunks  <- as.integer(Sys.getenv("N_CHUNKS",  "50"))
n_streams <- as.integer(Sys.getenv("N_STREAMS", "8"))
port      <- as.integer(Sys.getenv("PORT",      sample(20000:65000, 1)))

# ---- spawn server in a child process -----------------------------------

server_script <- tempfile("drogonR-bench-server-", fileext = ".R")
writeLines(sprintf('
suppressPackageStartupMessages(library(drogonR))
N <- %dL
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
        list(chunk = sprintf("data: %%d\n\n", state$i),
             state = state, done = FALSE)
      })
  })
dr_serve(app, port = %dL)
repeat later::run_now(timeoutSecs = 3600)
', n_chunks, port), server_script)

proc <- processx::process$new(
  command = file.path(R.home("bin"), "Rscript"),
  args    = c("--vanilla", server_script),
  stdout  = "|", stderr = "|")

on.exit({
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  unlink(server_script, force = TRUE)
}, add = TRUE)

# ---- wait until /__ping__ answers --------------------------------------

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
  if (!proc$is_alive()) {
    out <- tryCatch(proc$read_all_output(), error = function(e) "")
    err <- tryCatch(proc$read_all_error(),  error = function(e) "")
    stop("server child died before becoming reachable\n",
         "---- stdout ----\n", out,
         "\n---- stderr ----\n", err)
  }
  if (Sys.time() > deadline) {
    out <- tryCatch(proc$read_output(), error = function(e) "")
    err <- tryCatch(proc$read_error(),  error = function(e) "")
    stop("server never came up on :", port,
         "\n---- stdout ----\n", out,
         "\n---- stderr ----\n", err)
  }
  Sys.sleep(0.1)
}

# ---- one streamed request, returning (ttfb, total) seconds -------------

time_one_stream <- function() {
  url <- sprintf("http://127.0.0.1:%d/sse", port)
  ttfb <- NA_real_
  t0   <- proc.time()[["elapsed"]]

  resp <- httr2::request(url) |>
    httr2::req_timeout(60) |>
    httr2::req_perform_stream(
      callback = function(buf) {
        if (is.na(ttfb)) ttfb <<- proc.time()[["elapsed"]] - t0
        TRUE
      },
      buffer_kb = 1)

  total <- proc.time()[["elapsed"]] - t0
  c(ttfb = ttfb, total = total)
}

# ---- run S streams sequentially (concurrency via mclapply on Unix) -----

message(sprintf("benchmarking: %d streams × %d chunks each (port %d)",
                n_streams, n_chunks, port))

run_concurrent <- function(s) {
  if (.Platform$OS.type == "unix" && s > 1L) {
    parallel::mclapply(seq_len(s), function(i) time_one_stream(),
                       mc.cores = s)
  } else {
    lapply(seq_len(s), function(i) time_one_stream())
  }
}

t_wall <- proc.time()[["elapsed"]]
results <- run_concurrent(n_streams)
wall    <- proc.time()[["elapsed"]] - t_wall

mat   <- do.call(rbind, results)
ttfb  <- mat[, "ttfb"]
total <- mat[, "total"]

q <- function(x, p) unname(stats::quantile(x, p, na.rm = TRUE))

# ---- report ------------------------------------------------------------

cat(sprintf("\n=== drogonR stream timings (n_streams=%d, n_chunks=%d) ===\n",
            n_streams, n_chunks))
cat(sprintf("  wall clock        : %7.3f s\n", wall))
cat(sprintf("  streams completed : %d / %d\n", sum(!is.na(total)), n_streams))
cat("\n  time-to-first-byte (s):\n")
cat(sprintf("    p50 = %.4f   p95 = %.4f   p99 = %.4f   max = %.4f\n",
            q(ttfb, 0.5), q(ttfb, 0.95), q(ttfb, 0.99), max(ttfb, na.rm = TRUE)))
cat("\n  total stream duration (s):\n")
cat(sprintf("    p50 = %.4f   p95 = %.4f   p99 = %.4f   max = %.4f\n",
            q(total, 0.5), q(total, 0.95), q(total, 0.99),
            max(total, na.rm = TRUE)))
cat(sprintf("\n  effective chunks/s (per stream, p50): %.1f\n",
            n_chunks / q(total, 0.5)))
cat(sprintf("  effective chunks/s (aggregate)        : %.1f\n",
            (n_chunks * n_streams) / wall))
