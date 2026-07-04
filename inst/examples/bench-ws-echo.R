#!/usr/bin/env Rscript
# WebSocket echo latency: drogonR vs. httpuv (raw R WS) vs. FastAPI (uvicorn).
#
# NB on plumber: plumber does NOT serve WebSockets itself — its onWSOpen()
# is a stub that warns "WebSockets not supported" and defers to the
# underlying httpuv app. So the fair R-side WS opponent is httpuv directly,
# which is what a plumber user would drop down to for a WS endpoint anyway.
#
# Every backend serves the same trivial endpoint: a WebSocket at /ws that
# echoes each text frame straight back. We measure the round-trip time of
# a send -> echo -> receive cycle, which is the honest, apples-to-apples
# "how fast is the WebSocket path" number: no application logic, just the
# framework's read/parse/dispatch/write loop.
#
# Two client paths measure two different things:
#   * R client       — drogonR's own dr_ws_connect() in this process
#                      (also a demo of the client API). One R event loop,
#                      so it is client-bound: numbers converge across
#                      backends and are a *relative* comparison.
#   * external client — a concurrent asyncio client outside R, run when
#                      python3 + websockets is available. This one
#                      actually stresses the server, so it reflects the
#                      server's throughput rather than the R client's.
# Both report p50/p95/p99 latency and aggregate messages/second.
#
# Backends are optional and skipped gracefully when their dependency is
# absent, so this runs anywhere drogonR is installed:
#   * drogonR   — always (R on_message hook over Drogon's C++ I/O loop)
#   * httpuv    — if the 'httpuv' package is installed (raw R WebSocket;
#                 this is the WS layer under plumber/Shiny)
#   * FastAPI   — if python3 + fastapi + uvicorn are on the machine
#
# Usage:
#   Rscript inst/examples/bench-ws-echo.R
#   N_MSGS=5000 N_CONNS=16 Rscript inst/examples/bench-ws-echo.R
#
# At the default N_MSGS=2000 the per-run wall-time variance is large
# enough that the external-client throughput of two fast servers can look
# tied; use N_MSGS=5000 or more for a stable server-bound comparison.
#
# Requires: drogonR + processx; curl on PATH for readiness checks.
# Optional: httpuv; python3 with fastapi + uvicorn + websockets.
#   (the external load generator needs only python3 + websockets, which
#    is a subset of the FastAPI backend's requirements.)

suppressPackageStartupMessages({
  library(drogonR)
})

if (!requireNamespace("processx", quietly = TRUE)) {
  message("This example requires the 'processx' package.\n",
          "Install it with: install.packages(\"processx\")")
  quit(status = 1L, save = "no")
}

# ---- knobs -----------------------------------------------------------
N_MSGS   <- as.integer(Sys.getenv("N_MSGS",  "2000"))  # echoes per connection
N_CONNS  <- as.integer(Sys.getenv("N_CONNS", "8"))     # concurrent connections
PAYLOAD  <- Sys.getenv("PAYLOAD", "ping")              # message body
TIMEOUT  <- as.integer(Sys.getenv("TIMEOUT", "60"))    # per-phase budget, secs

# The client-side WS subsystem (dr_ws_connect) runs Drogon in THIS
# process; without this it logs the expected "give up sending" DEBUG on
# every client close. Set the level before the first connect so
# ensureDispatcherRunning() picks it up. Respect an explicit override.
if (!nzchar(Sys.getenv("DROGONR_LOG_LEVEL"))) {
  Sys.setenv(DROGONR_LOG_LEVEL = "warn")
}

`%||%` <- function(a, b) if (is.null(a)) b else a
flush_now <- function() { try(flush.console(), silent = TRUE); invisible() }
T0 <- Sys.time()
ts <- function(...) {
  dt <- as.numeric(Sys.time() - T0, units = "secs")
  cat(sprintf("[t=%6.3fs] ", dt), ..., "\n", sep = "")
  flush_now()
}

# Free-ish port. Good enough for an example; collisions just re-roll on
# the next run.
free_port <- function() sample(20000:65000, 1)

# ---- generic child-process helpers -----------------------------------
start_proc <- function(command, args, env = NULL) {
  # env = NULL inherits the parent environment; a named character vector
  # (with "" first, via processx's convention) adds/overrides variables.
  processx::process$new(command = command, args = args,
                        env = env, stdout = "|", stderr = "|")
}

stop_proc <- function(proc) {
  if (!is.null(proc) && proc$is_alive()) {
    tryCatch(proc$kill(), error = function(e) NULL)
  }
}

# Wait until an HTTP GET on the readiness path returns any status code.
# Both R backends expose /__ping__; FastAPI exposes /ping.
wait_http_ready <- function(port, path, timeout = 15) {
  deadline <- Sys.time() + timeout
  url <- sprintf("http://127.0.0.1:%d%s", port, path)
  Sys.sleep(0.3)
  repeat {
    code <- suppressWarnings(system2(
      "curl", args = shQuote(c("-s", "-o", "/dev/null",
                               "-w", "%{http_code}",
                               "--max-time", "1", url)),
      stdout = TRUE, stderr = TRUE))
    if (length(code) == 1L && nzchar(code) && code != "000") {
      return(TRUE)
    }
    if (Sys.time() > deadline) return(FALSE)
    Sys.sleep(0.1)
  }
}

# ---- drogonR client-side driver --------------------------------------
# Pump drogonR's later loop until pred() or timeout.
pump_until <- function(pred, timeout = TIMEOUT) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(pred())) return(TRUE)
    later::run_now(timeoutSecs = 0.02)
    if (Sys.time() > deadline) return(FALSE)
  }
}

# Run a ping-pong latency loop against a WS server over one connection:
# send a message, wait for the echo, record the round-trip, repeat.
# Returns a numeric vector of per-message round-trip times in seconds
# (length == n on success, shorter if it timed out).
bench_one_conn <- function(url, n) {
  st <- new.env(parent = emptyenv())
  st$open   <- FALSE
  st$closed <- FALSE
  st$got    <- 0L
  st$times  <- numeric(n)
  st$sent_at <- NA_real_
  st$err    <- FALSE

  cl <- dr_ws_connect(
    url,
    on_message = function(msg, binary) {
      now <- as.numeric(Sys.time())
      st$got <- st$got + 1L
      st$times[st$got] <- now - st$sent_at
    },
    on_open  = function() st$open <- TRUE,
    on_close = function(reason, code) {
      st$closed <- TRUE
      if (identical(reason, "connect_failed")) st$err <- TRUE
    })

  if (!pump_until(function() st$open || st$err) || st$err) {
    dr_ws_client_close(cl)
    return(numeric(0))
  }

  # Sequential ping-pong: one in flight at a time so each timing is a
  # clean round-trip.
  send_one <- function() {
    st$sent_at <- as.numeric(Sys.time())
    dr_ws_client_send(cl, PAYLOAD)
  }
  target <- 0L
  send_one(); target <- 1L
  ok <- pump_until(function() {
    if (st$got >= target && target < n) {
      send_one(); target <- target + 1L
    }
    st$got >= n
  })

  dr_ws_client_close(cl)
  pump_until(function() st$closed, timeout = 5)
  if (!ok) st$times[seq_len(st$got)] else st$times
}

# Run N connections "concurrently": open them all, then interleave their
# ping-pongs on the single later loop. Returns list(times=<all rtts>,
# wall=<seconds for the whole batch>).
bench_conns <- function(url, n_conns, n_msgs) {
  conns <- vector("list", n_conns)
  for (i in seq_len(n_conns)) {
    e <- new.env(parent = emptyenv())
    e$open <- FALSE; e$closed <- FALSE; e$err <- FALSE
    e$got <- 0L; e$target <- 0L
    e$sent_at <- numeric(n_msgs); e$times <- numeric(n_msgs)
    conns[[i]] <- e
  }

  # dr_ws_connect wants the hooks bound to each connection's env.
  for (i in seq_len(n_conns)) {
    local({
      e <- conns[[i]]
      e$cl <- dr_ws_connect(
        url,
        on_message = function(msg, binary) {
          e$got <- e$got + 1L
          e$times[e$got] <- as.numeric(Sys.time()) - e$sent_at[e$got]
        },
        on_open  = function() e$open <- TRUE,
        on_close = function(reason, code) {
          e$closed <- TRUE
          if (identical(reason, "connect_failed")) e$err <- TRUE
        })
    })
  }

  all_open <- pump_until(function()
    all(vapply(conns, function(e) e$open || e$err, logical(1))))
  if (!all_open || any(vapply(conns, function(e) e$err, logical(1)))) {
    for (e in conns) dr_ws_client_close(e$cl)
    return(list(times = numeric(0), wall = NA_real_))
  }

  send_next <- function(e) {
    e$target <- e$target + 1L
    e$sent_at[e$target] <- as.numeric(Sys.time())
    dr_ws_client_send(e$cl, PAYLOAD)
  }

  wall0 <- as.numeric(Sys.time())
  for (e in conns) send_next(e)   # prime one in flight per connection
  ok <- pump_until(function() {
    done <- TRUE
    for (e in conns) {
      if (e$got >= e$target && e$target < n_msgs) send_next(e)
      if (e$got < n_msgs) done <- FALSE
    }
    done
  })
  wall <- as.numeric(Sys.time()) - wall0

  for (e in conns) dr_ws_client_close(e$cl)
  pump_until(function()
    all(vapply(conns, function(e) e$closed, logical(1))), timeout = 5)

  times <- unlist(lapply(conns, function(e) e$times[seq_len(e$got)]))
  list(times = times, wall = wall)
}

# ---- reporting -------------------------------------------------------
pctile <- function(x, p) if (length(x)) as.numeric(quantile(x, p, names = FALSE)) else NA_real_

report <- function(label, single, multi, external = NULL) {
  cat(sprintf("\n%s\n", label))
  cat(strrep("-", 60), "\n", sep = "")
  if (!length(single)) {
    cat("  (single-connection run failed/timed out)\n")
  } else {
    cat(sprintf("  1 conn : n=%d  p50=%.3fms  p95=%.3fms  p99=%.3fms  %.0f msg/s\n",
                length(single),
                pctile(single, 0.50) * 1e3,
                pctile(single, 0.95) * 1e3,
                pctile(single, 0.99) * 1e3,
                length(single) / sum(single)))
  }
  if (is.null(multi) || !length(multi$times)) {
    cat("  (concurrent run failed/timed out)\n")
  } else {
    cat(sprintf("  %d conn: n=%d  p50=%.3fms  p95=%.3fms  p99=%.3fms  %.0f msg/s (aggregate)\n",
                N_CONNS,
                length(multi$times),
                pctile(multi$times, 0.50) * 1e3,
                pctile(multi$times, 0.95) * 1e3,
                pctile(multi$times, 0.99) * 1e3,
                length(multi$times) / multi$wall))
  }
  if (!is.null(external)) {
    if (!length(external$times)) {
      cat("  (external client run failed/timed out)\n")
    } else {
      cat(sprintf("  %d conn: n=%d  p50=%.3fms  p95=%.3fms  p99=%.3fms  %.0f msg/s (external client)\n",
                  N_CONNS,
                  length(external$times),
                  pctile(external$times, 0.50) * 1e3,
                  pctile(external$times, 0.95) * 1e3,
                  pctile(external$times, 0.99) * 1e3,
                  length(external$times) / external$wall))
    }
  }
  flush_now()
}

# ---- external load generator (Python asyncio) ------------------------
# The pure-R path above is client-bound: dr_ws_connect + later::run_now
# in one process caps throughput at the R client's speed, so the server
# numbers converge regardless of backend. To measure the *server*, drive
# it from outside R with a genuinely concurrent client.
#
# We use a small asyncio script (N coroutines, each doing a sequential
# ping-pong loop and recording per-message round-trips) rather than
# websocat: websocat is a pipe client with no latency mode, so it could
# only report throughput, not the p50/p95/p99 this example is built on.
# The dependency (python3 + websockets) is the same one FastAPI already
# needs, so no new requirement is added. Skipped gracefully when absent.

have_py_client <- function() {
  py <- Sys.which("python3")
  if (!nzchar(py)) return(FALSE)
  code <- suppressWarnings(system2(
    py, c("-c", shQuote("import websockets, asyncio")),
    stdout = FALSE, stderr = FALSE))
  identical(code, 0L)
}

# Write the loader script once; it prints one round-trip time (seconds)
# per line to stdout, so R can read them back as a numeric vector.
py_loader_path <- NULL
ensure_py_loader <- function() {
  if (!is.null(py_loader_path)) return(py_loader_path)
  path <- file.path(scratch, "ws_load.py")
  writeLines('
import asyncio, sys, time, websockets

async def one(url, payload, n, out):
    async with websockets.connect(url, max_queue=None) as ws:
        for _ in range(n):
            t0 = time.perf_counter()
            await ws.send(payload)
            await ws.recv()
            out.append(time.perf_counter() - t0)

async def main():
    url, payload = sys.argv[1], sys.argv[2]
    n, conns = int(sys.argv[3]), int(sys.argv[4])
    buckets = [[] for _ in range(conns)]
    await asyncio.gather(*(one(url, payload, n, buckets[i])
                           for i in range(conns)))
    # One round-trip per line; the parent reads these as a numeric vector.
    w = sys.stdout.write
    for b in buckets:
        for t in b:
            w(f"{t:.9f}\\n")

asyncio.run(main())
', path)
  py_loader_path <<- path
  path
}

# Run the external loader against a live server; returns list(times, wall).
bench_external <- function(url, n_msgs, n_conns) {
  py     <- Sys.which("python3")
  script <- ensure_py_loader()
  wall0  <- as.numeric(Sys.time())
  out <- suppressWarnings(tryCatch(
    system2(py, args = shQuote(c(script, url, PAYLOAD,
                                 as.character(n_msgs),
                                 as.character(n_conns))),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0)))
  wall <- as.numeric(Sys.time()) - wall0
  times <- suppressWarnings(as.numeric(out))
  times <- times[!is.na(times)]
  list(times = times, wall = wall)
}

# Run the full single + concurrent bench against one already-running
# server, then return the numbers. The external (server-bound) run is
# added only when a Python client is available.
run_bench <- function(name, port, ws_path, ready_path) {
  url <- sprintf("ws://127.0.0.1:%d%s", port, ws_path)
  ts(sprintf("[%s] warmup + single-connection latency (n=%d)", name, N_MSGS))
  invisible(bench_one_conn(url, min(50L, N_MSGS)))   # warmup, discarded
  single <- bench_one_conn(url, N_MSGS)
  ts(sprintf("[%s] %d concurrent connections x %d msgs (R client)",
             name, N_CONNS, N_MSGS))
  multi <- bench_conns(url, N_CONNS, N_MSGS)

  external <- NULL
  if (have_py_client()) {
    ts(sprintf("[%s] %d concurrent connections x %d msgs (external client)",
               name, N_CONNS, N_MSGS))
    external <- bench_external(url, N_MSGS, N_CONNS)
  }
  list(single = single, multi = multi, external = external)
}

# =====================================================================
# Backend definitions. Each returns a started process + its ports/paths,
# or NULL if its dependency is missing.
# =====================================================================
scratch <- tempfile("bench-ws-"); dir.create(scratch)
on.exit(unlink(scratch, recursive = TRUE, force = TRUE), add = TRUE)

# ---- drogonR (R on_message hook) -------------------------------------
start_drogonr <- function(port) {
  script <- file.path(scratch, "drogonr-server.R")
  writeLines(sprintf('
suppressPackageStartupMessages(library(drogonR))
app <- dr_app() |>
  dr_get("/__ping__", function(req) "pong") |>
  dr_ws("/ws", on_message = function(conn, msg, binary) dr_ws_send(conn, msg))
dr_serve(app, port = %dL, threads = 2L)
repeat later::run_now(timeoutSecs = 3600)
', port), script)
  # Quiet Drogon down to warnings: the per-connection "give up sending"
  # DEBUG on client close is expected noise, not a fault.
  start_proc(file.path(R.home("bin"), "Rscript"),
             c("--vanilla", script),
             env = c("current", DROGONR_LOG_LEVEL = "warn"))
}

# ---- httpuv (raw R WebSocket) ----------------------------------------
# The WebSocket server under plumber and Shiny. An httpuv app is a list
# with `call` (HTTP) and `onWSOpen` (WebSocket) handlers; the echo lives
# in the per-connection onMessage. httpuv's own event loop services it,
# so nothing extra is needed to keep the process alive.
start_httpuv <- function(port) {
  if (!requireNamespace("httpuv", quietly = TRUE)) return(NULL)
  script <- file.path(scratch, "httpuv-server.R")
  writeLines(sprintf('
suppressPackageStartupMessages(library(httpuv))
app <- list(
  call = function(req) {
    list(status = 200L,
         headers = list("Content-Type" = "text/plain"),
         body = "pong")
  },
  onWSOpen = function(ws) {
    ws$onMessage(function(binary, message) ws$send(message))
  })
srv <- httpuv::startServer("127.0.0.1", %dL, app)
httpuv::service(0)
repeat httpuv::service(100)
', port), script)
  start_proc(file.path(R.home("bin"), "Rscript"),
             c("--vanilla", script))
}

# ---- FastAPI (uvicorn) -----------------------------------------------
have_fastapi <- function() {
  py <- Sys.which("python3")
  if (!nzchar(py)) return(FALSE)
  code <- suppressWarnings(system2(
    py, c("-c", shQuote("import fastapi, uvicorn, websockets")),
    stdout = FALSE, stderr = FALSE))
  identical(code, 0L)
}

start_fastapi <- function(port) {
  if (!have_fastapi()) return(NULL)
  app_py <- file.path(scratch, "fastapi_app.py")
  writeLines('
from fastapi import FastAPI, WebSocket
from fastapi.responses import PlainTextResponse

app = FastAPI()

@app.get("/ping")
def ping():
    return PlainTextResponse("pong")

@app.websocket("/ws")
async def ws(sock: WebSocket):
    await sock.accept()
    try:
        while True:
            msg = await sock.receive_text()
            await sock.send_text(msg)
    except Exception:
        return
', app_py)
  start_proc(Sys.which("python3"),
             c("-m", "uvicorn", "fastapi_app:app",
               "--host", "127.0.0.1", "--port", as.character(port),
               "--app-dir", scratch, "--log-level", "warning"))
}

# =====================================================================
# Run.
# =====================================================================
cat(strrep("=", 60), "\n", sep = "")
cat("WebSocket echo latency benchmark\n")
cat(sprintf("  messages/conn = %d   concurrent conns = %d   payload = %dB\n",
            N_MSGS, N_CONNS, nchar(PAYLOAD)))
cat("  client = drogonR::dr_ws_connect() (this process)\n")
cat(strrep("=", 60), "\n", sep = "")

backends <- list(
  list(name = "drogonR (R hook)", start = start_drogonr,
       ws = "/ws", ready = "/__ping__"),
  list(name = "httpuv (raw R WS)", start = start_httpuv,
       ws = "/ws", ready = "/__ping__"),
  list(name = "FastAPI (uvicorn)", start = start_fastapi,
       ws = "/ws", ready = "/ping"))

results <- list()
procs   <- list()
on.exit({ for (p in procs) stop_proc(p); dr_ws_shutdown() }, add = TRUE)

for (b in backends) {
  port <- free_port()
  ts(sprintf("starting %s on :%d", b$name, port))
  proc <- tryCatch(b$start(port), error = function(e) NULL)
  if (is.null(proc)) {
    ts(sprintf("  SKIP %s (dependency not available)", b$name))
    next
  }
  procs[[b$name]] <- proc
  if (!wait_http_ready(port, b$ready, TIMEOUT)) {
    ts(sprintf("  SKIP %s (server did not become ready)", b$name))
    out <- tryCatch(proc$read_output(), error = function(e) "")
    err <- tryCatch(proc$read_error(),  error = function(e) "")
    if (nzchar(out)) message("---- ", b$name, " stdout ----\n", out)
    if (nzchar(err)) message("---- ", b$name, " stderr ----\n", err)
    stop_proc(proc)
    next
  }
  results[[b$name]] <- tryCatch(
    run_bench(b$name, port, b$ws, b$ready),
    error = function(e) { ts(sprintf("  ERROR in %s: %s", b$name,
                                     conditionMessage(e))); NULL })
  stop_proc(proc)
}

# ---- summary ---------------------------------------------------------
cat("\n", strrep("=", 60), "\n", sep = "")
cat("Results\n")
cat(strrep("=", 60), "\n", sep = "")
if (!length(results)) {
  cat("No backend produced results. Install httpuv and/or ",
      "python3+fastapi+uvicorn to compare.\n", sep = "")
} else {
  for (nm in names(results)) {
    r <- results[[nm]]
    if (is.null(r)) next
    report(nm, r$single, r$multi, r$external)
  }
  cat("\nLower latency and higher msg/s are better. Numbers are the\n")
  cat("framework's read/dispatch/write loop only (echo, no app logic).\n")
  cat("\n")
  cat("  R client rows      : measured from this single R process\n")
  cat("                       (dr_ws_connect + later), so they are\n")
  cat("                       client-bound and converge across backends —\n")
  cat("                       read them as a relative comparison only.\n")
  cat("  external client row: driven by a concurrent asyncio client\n")
  cat("                       outside R, so it reflects the server's own\n")
  cat("                       throughput. Present only when python3 +\n")
  cat("                       websockets is installed.\n")
}

ts("done")
