#!/usr/bin/env Rscript
# Diagnostic: bring up ONE worker via parallel::mcparallel() and find
# exactly where the chain breaks. Replicates the child-side flow of
# dr_serve(workers > 1) inline, so we can log between stages.
#
# Stages (mirrors README "Architecture"):
#   A: child entered mcparallel body
#   B: later::current_loop() reachable in child after fork
#   C: dr_app + route registration (pure R)
#   D: .Call(drogonR_server_start) returns (Drogon thread spawned)
#   E: later::run_now() loop is being driven
#   F: external TCP connect to listening socket (nc -z)
#   G..J: full HTTP roundtrip (curl) — exercises Drogon parse, queue,
#         dispatcher wakeup pipe, R handler invocation, response cb
#
# Usage:
#   Rscript inst/examples/diag-mcparallel-worker.R
#
# Output: prints the per-stage log + parent-side probes (nc, curl,
# /proc inspection, ss). The point is to identify which stage breaks,
# not to exercise dr_serve() itself.

LOG <- tempfile("drogon-diag-", fileext = ".log")
file.create(LOG)
PORT <- 28811L
cat("[diag] log =", LOG, "\n")
cat("[diag] port =", PORT, "\n")

logf <- function(stage, where, ...) {
  msg <- paste0(format(Sys.time(), "%H:%M:%OS3"), " [", where, " pid=",
                Sys.getpid(), "] ", stage, " ", paste(...), "\n")
  cat(msg, file = LOG, append = TRUE)
}

# Helper: extract the exit status from a system2() result. base R 4.3
# does not export `%||%` so we open-code it.
status_of <- function(x) {
  s <- attr(x, "status")
  if (is.null(s)) 0L else s
}

library(drogonR)
logf("parent: library(drogonR) ok", "P")

job <- parallel::mcparallel({
  logf("A: child entered mcparallel body", "C")

  # B: later's loop after fork. .onLoad already ran in the parent
  # before fork, so the child inherited a (possibly stale) loop fd.
  loop <- tryCatch(later::current_loop(),
                   error = function(e) {
                     logf("B: later FAIL", "C", conditionMessage(e))
                     NULL
                   })
  logf("B: later::current_loop()", "C", "loop=",
       paste(capture.output(print(loop)), collapse = " | "))

  # C: pure-R app construction.
  app <- dr_app() |>
    dr_get("/pid", function(req) as.character(Sys.getpid()))
  logf("C: app built", "C", "routes=", length(app$routes))

  # D: register routes + start Drogon. This is the .Call path that
  # spawns Drogon's I/O thread and binds the listener.
  # C entry points are exported via useDynLib(.registration = TRUE),
  # which makes their symbols available as bare names *inside* the
  # package namespace only. From a free-standing script we must
  # resolve them by string name.
  .Call("drogonR_clear_routes")
  for (r in app$routes) {
    .Call("drogonR_register_route", r$method, r$path,
          drogonR:::.dr_wrap_handler(r$handler, app))
  }
  logf("D1: routes registered, calling drogonR_server_start", "C")
  .Call("drogonR_server_start", PORT, 1L,
        normalizePath(tempdir(), mustWork = TRUE), 1024L)
  logf("D2: drogonR_server_start returned", "C")

  # E: drive later's loop. Short timeout on purpose so we get
  # periodic heartbeats; if run_now() never returns we'll see no
  # ticks and know the wakeup pipe / loop is broken.
  logf("E: entering run_now loop", "C")
  iter <- 0L
  repeat {
    iter <- iter + 1L
    later::run_now(timeoutSecs = 5)
    logf("E.tick", "C", "iter=", iter)
  }
}, name = "diag-worker")

cat("[diag] worker pid =", job$pid, "\n")
Sys.sleep(2)

cat("\n--- log after 2s ---\n")
writeLines(readLines(LOG))

# F: can we even open a TCP connection?
cat("\n--- F: TCP connect (nc -z) ---\n")
rc <- suppressWarnings(system2("nc", c("-z", "-w", "2", "127.0.0.1", PORT),
                               stdout = TRUE, stderr = TRUE))
cat("nc rc =", status_of(rc), " out =", paste(rc, collapse = "|"), "\n")

# G..J: full HTTP roundtrip.
cat("\n--- G..J: curl /pid ---\n")
out <- suppressWarnings(
  system2("curl", c("-sS", "--max-time", "3",
                    paste0("http://127.0.0.1:", PORT, "/pid")),
          stdout = TRUE, stderr = TRUE))
cat("curl rc =", status_of(out), "\n")
cat("curl out: [", paste(out, collapse = "|"), "]\n", sep = "")

cat("\n--- child wchan (what kernel call is it in) ---\n")
cat(readLines(paste0("/proc/", job$pid, "/wchan")), "\n", sep = "")

cat("\n--- child fd table ---\n")
fds <- list.files(paste0("/proc/", job$pid, "/fd"), full.names = TRUE)
for (f in fds) {
  target <- tryCatch(Sys.readlink(f), error = function(e) "?")
  cat(basename(f), "->", target, "\n")
}

cat("\n--- listening sockets owned by child ---\n")
print(system2("ss", c("-ltnp", "sport", paste0("=:", PORT)),
              stdout = TRUE, stderr = TRUE))

cat("\n--- final log dump ---\n")
writeLines(readLines(LOG))

suppressWarnings(tools::pskill(job$pid, tools::SIGKILL))
parallel::mccollect(job, wait = TRUE, timeout = 3)
