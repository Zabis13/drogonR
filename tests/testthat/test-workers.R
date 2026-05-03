# Multi-process worker tests. The test process itself is the
# supervisor — it calls dr_serve(workers > 1) directly, then drives
# real HTTP traffic, then dr_stop() to reap the children. This works
# in a single R session because the supervisor never starts Drogon
# locally (which can only run once per process); only worker children
# do, and each child is a fresh R session.

free_port <- function() sample(20000:65000, 1)

wait_ready <- function(port, path = "/__ping__", timeout = 20) {
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

count_listeners <- function(port) {
  # Count LISTEN sockets on a given port across /proc/net/tcp{,6}.
  # SO_REUSEPORT means each worker gets its own listening socket on the
  # same port, so this returns N for `workers = N`. We rely on the
  # invariant, not on observed traffic distribution (which the kernel
  # is free to skew).
  port_hex <- toupper(sprintf("%04X", port))
  n <- 0L
  for (f in c("/proc/net/tcp", "/proc/net/tcp6")) {
    if (!file.exists(f)) next
    lines <- readLines(f, warn = FALSE)
    if (length(lines) < 2L) next
    rows <- lines[-1]
    fields <- strsplit(trimws(rows), "\\s+")
    for (row in fields) {
      if (length(row) < 4L) next
      local <- row[2]                              # "ADDR:PORT"
      st <- row[4]                                 # state, 0A == LISTEN
      if (identical(st, "0A") &&
          identical(sub(".*:", "", local), port_hex)) {
        n <- n + 1L
      }
    }
  }
  n
}

test_that("workers > 1 binds N listeners on the same port (SO_REUSEPORT)", {
  skip_on_os("windows")
  skip_if(!file.exists("/proc/net/tcp"), "needs /proc/net/tcp (Linux)")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  app <- dr_app() |>
    dr_get("/ok", function(req) "ok")
  suppressMessages(dr_serve(app, port = port, threads = 1L, workers = 3L))
  on.exit(dr_stop(), add = TRUE)

  wait_ready(port, "/ok")

  expect_equal(count_listeners(port), 3L)
})

test_that("on_worker_start runs once per worker before serving", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  marker_dir <- tempfile("drogonR-mark-")
  dir.create(marker_dir)

  app <- dr_app() |>
    dr_get("/ok", function(req) "ok")
  suppressMessages(dr_serve(app, port = port, threads = 1L, workers = 2L,
           on_worker_start = function() {
             file.create(file.path(marker_dir, paste0(Sys.getpid())))
           }))
  on.exit(dr_stop(), add = TRUE)

  wait_ready(port, "/ok")
  Sys.sleep(0.5)

  markers <- list.files(marker_dir)
  expect_equal(length(markers), 2L)
})

test_that("on_worker_start failure: child exits, supervisor sees dead pids", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  app <- dr_app() |>
    dr_get("/x", function(req) "x")
  suppressMessages(dr_serve(app, port = port, threads = 1L, workers = 2L,
           on_worker_start = function() stop("nope")))
  on.exit(dr_stop(), add = TRUE)

  # Children should die almost immediately. Give them a moment, then
  # check via dr_status() — both must be dead, and nothing must be
  # listening on the port. dr_status() emits a `worker pid=... has
  # exited` message() per dead child — expected here, suppress.
  Sys.sleep(2)
  s <- suppressMessages(dr_status())
  expect_equal(nrow(s), 2L)
  expect_true(all(!s$alive))
})

test_that("dr_status reports live workers", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  app <- dr_app() |>
    dr_get("/ok", function(req) "ok")
  suppressMessages(dr_serve(app, port = port, threads = 1L, workers = 2L))
  on.exit(dr_stop(), add = TRUE)
  wait_ready(port, "/ok")

  s <- dr_status()
  expect_equal(nrow(s), 2L)
  expect_named(s, c("pid", "alive"))
  expect_true(all(s$alive))
  expect_type(s$pid, "integer")
})

test_that("dr_stop reaps workers and clears state", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")
  skip_if_not_installed("parallel")

  port <- free_port()
  app <- dr_app() |>
    dr_get("/ok", function(req) "ok")
  suppressMessages(dr_serve(app, port = port, threads = 1L, workers = 2L))
  wait_ready(port, "/ok")

  pids_before <- dr_status()$pid
  expect_length(pids_before, 2L)

  dr_stop()
  Sys.sleep(1)
  expect_equal(nrow(dr_status()), 0L)

  # Children should no longer exist on the OS. (kill -0 returns
  # nonzero for unknown / dead pids.)
  for (pid in pids_before) {
    rc <- suppressWarnings(system2("kill", c("-0", pid),
                                   stdout = FALSE, stderr = FALSE))
    expect_false(isTRUE(rc == 0L))
  }
})

test_that("workers > 1 errors on Windows", {
  skip_if(.Platform$OS.type != "windows",
          "only meaningful on Windows")
  app <- dr_app() |> dr_get("/", function(req) "ok")
  expect_error(dr_serve(app, workers = 2L),
               "not supported on Windows")
})
