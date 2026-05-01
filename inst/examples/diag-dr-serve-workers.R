#!/usr/bin/env Rscript
# Diagnostic: actually call dr_serve(workers = N), with logging
# instrumentation injected into the worker via an environment variable
# the child reads before doing anything else. Output mirrors the
# multi-worker probe (per-worker /proc inspection + curl distribution).
#
# This is the "true" repro — if mcparallel-multi.R works but this
# script hangs, the bug is somewhere inside dr_serve()/dr_run_worker.

LOG <- tempfile("drogon-diag-serve-", fileext = ".log")
file.create(LOG)
PORT <- 28813L
N <- 3L
Sys.setenv(DROGONR_DIAG_LOG = LOG)

T0 <- Sys.time()
ts <- function(...) {
  dt <- as.numeric(Sys.time() - T0, units = "secs")
  cat(sprintf("[t=%6.3fs] ", dt), ..., "\n", sep = "")
}

ts("log = ", LOG)
ts("port = ", PORT, "  N = ", N)

status_of <- function(x) { s <- attr(x, "status"); if (is.null(s)) 0L else s }

ts("loading drogonR")
library(drogonR)
ts("drogonR loaded")

app <- dr_app() |>
  dr_get("/pid", function(req) as.character(Sys.getpid()))
ts("app built")

ts("calling dr_serve(workers = ", N, ")")
dr_serve(app, port = PORT, threads = 1L, workers = N)
ts("dr_serve returned")

ts("sleeping 2s for workers to bind")
Sys.sleep(2)
ts("sleep done")

ts("--- log after 2s ---")
if (file.exists(LOG) && file.info(LOG)$size > 0) {
  writeLines(readLines(LOG))
} else {
  cat("(log empty — workers never reached the instrumented path)\n")
}

ts("--- dr_status() ---")
print(dr_status())

ts("--- per-worker /proc inspection ---")
for (pid in dr_status()$pid) {
  if (file.exists(paste0("/proc/", pid))) {
    wchan <- tryCatch(readLines(paste0("/proc/", pid, "/wchan"), warn = FALSE),
                      error = function(e) "?")
    fds <- tryCatch(list.files(paste0("/proc/", pid, "/fd")),
                    error = function(e) character())
    sockets <- 0L
    for (f in fds) {
      target <- tryCatch(Sys.readlink(paste0("/proc/", pid, "/fd/", f)),
                         error = function(e) "")
      if (grepl("^socket:", target)) sockets <- sockets + 1L
    }
    cat(sprintf("  pid=%d  wchan=%s  fds=%d  sockets=%d\n",
                pid, paste(wchan, collapse=""),
                length(fds), sockets))
  } else {
    cat(sprintf("  pid=%d  GONE\n", pid))
  }
}

ts("--- F: nc -z ---")
rc <- suppressWarnings(system2("nc", c("-z", "-w", "2", "127.0.0.1", PORT),
                               stdout = TRUE, stderr = TRUE))
ts("nc returned rc=", status_of(rc))

ts("--- 30 curl hits ---")
seen <- character(30)
for (i in seq_along(seen)) {
  out <- suppressWarnings(
    system2("curl", c("-sS", "--max-time", "2",
                      paste0("http://127.0.0.1:", PORT, "/pid")),
            stdout = TRUE, stderr = TRUE))
  seen[i] <- if (status_of(out) == 0) paste(out, collapse="") else "ERR"
}
ts("curl hits done")
cat("response distribution:\n"); print(table(seen))
cat("unique pids:", length(unique(seen[seen != "ERR"])), "\n")

ts("--- final log dump ---")
if (file.exists(LOG)) writeLines(readLines(LOG))

ts("calling dr_stop()")
dr_stop()
ts("dr_stop returned")
