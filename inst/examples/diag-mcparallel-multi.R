#!/usr/bin/env Rscript
# Diagnostic: bring up N workers via parallel::mcparallel(), each on
# the SAME port via SO_REUSEPORT. Mirrors what dr_serve(workers = N)
# does — but inline, with logging between stages, so we can identify
# which worker(s) actually bind and answer.
#
# Usage:
#   Rscript inst/examples/diag-mcparallel-multi.R [N]
# Default N = 3.
#
# Successful run: every worker logs A..E, every worker has its own
# socket fd, curl distributes hits across multiple PIDs.

args <- commandArgs(trailingOnly = TRUE)
N <- if (length(args) >= 1) as.integer(args[[1]]) else 3L

LOG <- tempfile("drogon-diag-multi-", fileext = ".log")
file.create(LOG)
PORT <- 28812L
cat("[diag] log =", LOG, "\n")
cat("[diag] port =", PORT, "  N =", N, "\n")

logf <- function(stage, where, ...) {
  msg <- paste0(format(Sys.time(), "%H:%M:%OS3"), " [", where, " pid=",
                Sys.getpid(), "] ", stage, " ", paste(...), "\n")
  cat(msg, file = LOG, append = TRUE)
}

status_of <- function(x) { s <- attr(x, "status"); if (is.null(s)) 0L else s }

library(drogonR)
logf("parent: library(drogonR) ok", "P")

run_worker <- function(worker_id) {
  logf("A: child entered mcparallel body", paste0("W", worker_id))
  loop <- tryCatch(later::current_loop(),
                   error = function(e) {
                     logf("B: later FAIL", paste0("W", worker_id),
                          conditionMessage(e)); NULL
                   })
  logf("B: later loop ok", paste0("W", worker_id))

  app <- dr_app() |>
    dr_get("/pid", function(req) as.character(Sys.getpid()))
  logf("C: app built", paste0("W", worker_id))

  .Call("drogonR_clear_routes")
  for (r in app$routes) {
    .Call("drogonR_register_route", r$method, r$path,
          drogonR:::.dr_wrap_handler(r$handler, app))
  }
  logf("D1: about to start Drogon", paste0("W", worker_id))
  .Call("drogonR_server_start", PORT, 1L,
        normalizePath(tempdir(), mustWork = TRUE), 1024L)
  logf("D2: Drogon started", paste0("W", worker_id))

  logf("E: entering run_now loop", paste0("W", worker_id))
  iter <- 0L
  repeat {
    iter <- iter + 1L
    later::run_now(timeoutSecs = 5)
    logf("E.tick", paste0("W", worker_id), "iter=", iter)
  }
}

jobs <- vector("list", N)
for (i in seq_len(N)) {
  jobs[[i]] <- parallel::mcparallel(run_worker(i),
                                     name = paste0("diag-w-", i))
  cat("[diag] spawned worker", i, "pid =", jobs[[i]]$pid, "\n")
}

Sys.sleep(2)

cat("\n--- log after 2s ---\n")
writeLines(readLines(LOG))

cat("\n--- per-worker /proc inspection ---\n")
for (j in jobs) {
  if (file.exists(paste0("/proc/", j$pid))) {
    wchan <- tryCatch(readLines(paste0("/proc/", j$pid, "/wchan"),
                                warn = FALSE), error = function(e) "?")
    fds <- tryCatch(list.files(paste0("/proc/", j$pid, "/fd")),
                    error = function(e) character())
    sockets <- 0L
    for (f in fds) {
      target <- tryCatch(Sys.readlink(paste0("/proc/", j$pid, "/fd/", f)),
                         error = function(e) "")
      if (grepl("^socket:", target)) sockets <- sockets + 1L
    }
    cat(sprintf("  pid=%d  wchan=%s  fds=%d  sockets=%d\n",
                j$pid, paste(wchan, collapse = ""),
                length(fds), sockets))
  } else {
    cat(sprintf("  pid=%d  GONE\n", j$pid))
  }
}

cat("\n--- F: nc -z ---\n")
rc <- suppressWarnings(system2("nc", c("-z", "-w", "2", "127.0.0.1", PORT),
                               stdout = TRUE, stderr = TRUE))
cat("nc rc =", status_of(rc), "\n")

cat("\n--- 30 curl hits ---\n")
seen <- character(30)
for (i in seq_along(seen)) {
  out <- suppressWarnings(
    system2("curl", c("-sS", "--max-time", "2",
                      paste0("http://127.0.0.1:", PORT, "/pid")),
            stdout = TRUE, stderr = TRUE))
  seen[i] <- if (status_of(out) == 0) paste(out, collapse = "") else "ERR"
}
tab <- table(seen)
cat("response distribution:\n"); print(tab)
cat("unique pids:", length(unique(seen[seen != "ERR"])), "\n")

cat("\n--- final log dump ---\n")
writeLines(readLines(LOG))

for (j in jobs) {
  suppressWarnings(tools::pskill(j$pid, tools::SIGKILL))
}
parallel::mccollect(jobs, wait = TRUE, timeout = 3)
