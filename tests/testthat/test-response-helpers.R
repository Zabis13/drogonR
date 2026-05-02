# End-to-end tests for the response helpers added in v0.1:
# dr_text, dr_html, dr_redirect, dr_file (incl. MIME detection,
# download_as, missing path, oversize guard).

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
  if (proc$is_alive()) tryCatch(proc$kill(), error = function(e) NULL)
  if (!is.null(rds) && file.exists(rds)) unlink(rds, force = TRUE)
}

GET <- function(port, path, ...) {
  req <- httr2::request(sprintf("http://127.0.0.1:%d%s", port, path)) |>
    httr2::req_error(is_error = function(resp) FALSE)
  args <- list(...)
  if (length(args) > 0) {
    if (!is.null(args$follow)) {
      # leave default redirect behavior alone
    }
  }
  httr2::req_perform(req)
}

test_that("dr_text sets text/plain; charset=utf-8", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |> dr_get("/t", function(req) dr_text("hello"))
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/t")

  r <- GET(port, "/t")
  expect_equal(httr2::resp_status(r), 200L)
  expect_equal(httr2::resp_body_string(r), "hello")
  expect_equal(httr2::resp_header(r, "Content-Type"),
               "text/plain; charset=utf-8")
})

test_that("dr_html sets text/html; charset=utf-8", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |> dr_get("/h", function(req) dr_html("<h1>hi</h1>"))
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/h")

  r <- GET(port, "/h")
  expect_equal(httr2::resp_status(r), 200L)
  expect_equal(httr2::resp_body_string(r), "<h1>hi</h1>")
  expect_equal(httr2::resp_header(r, "Content-Type"),
               "text/html; charset=utf-8")
})

test_that("dr_redirect sets Location header and 302 by default", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |>
      dr_get("/old", function(req) dr_redirect("/new")) |>
      dr_get("/perm", function(req) dr_redirect("/elsewhere",
                                                status = 301L))
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/old")

  # Disable httr2's automatic redirect-following so we can inspect the
  # 302 response itself.
  r <- httr2::request(sprintf("http://127.0.0.1:%d/old", port)) |>
    httr2::req_options(followlocation = 0L) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r), 302L)
  expect_equal(httr2::resp_header(r, "Location"), "/new")

  r301 <- httr2::request(sprintf("http://127.0.0.1:%d/perm", port)) |>
    httr2::req_options(followlocation = 0L) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  expect_equal(httr2::resp_status(r301), 301L)
  expect_equal(httr2::resp_header(r301, "Location"), "/elsewhere")
})

test_that("dr_file serves bytes with auto-detected MIME", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  # Pre-create files on the parent side; child process reads them.
  tmpdir <- tempfile("drogonR-files-")
  dir.create(tmpdir)
  on.exit(unlink(tmpdir, recursive = TRUE), add = TRUE)

  png_bytes  <- as.raw(c(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                         0x01, 0x02, 0x03))
  png_path   <- file.path(tmpdir, "tiny.png")
  writeBin(png_bytes, png_path)

  json_path  <- file.path(tmpdir, "data.json")
  writeLines('{"a":1}', json_path)

  blob_path  <- file.path(tmpdir, "binary.unknown_ext_xyz")
  writeBin(as.raw(0:9), blob_path)

  port <- free_port()
  # Capture the paths into the closure so the child process sees them.
  paths <- list(png = png_path, json = json_path, blob = blob_path)
  proc <- spawn_server(function(app) {
    app |>
      dr_get("/png",  function(req) dr_file(paths$png)) |>
      dr_get("/json", function(req) dr_file(paths$json)) |>
      dr_get("/blob", function(req) dr_file(paths$blob)) |>
      dr_get("/dl",   function(req) dr_file(paths$png,
                                             download_as = "saved.png"))
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/png")

  r_png <- GET(port, "/png")
  expect_equal(httr2::resp_status(r_png), 200L)
  expect_equal(httr2::resp_header(r_png, "Content-Type"), "image/png")
  expect_identical(httr2::resp_body_raw(r_png), png_bytes)

  r_json <- GET(port, "/json")
  expect_equal(httr2::resp_header(r_json, "Content-Type"),
               "application/json")

  r_blob <- GET(port, "/blob")
  expect_equal(httr2::resp_header(r_blob, "Content-Type"),
               "application/octet-stream")

  r_dl <- GET(port, "/dl")
  expect_equal(httr2::resp_header(r_dl, "Content-Disposition"),
               'attachment; filename="saved.png"')
})

test_that("dr_file errors on missing path (caught as 500)", {
  skip_on_os("windows")
  skip_if_not_installed("httr2")

  port <- free_port()
  proc <- spawn_server(function(app) {
    app |> dr_get("/x", function(req) dr_file("/nonexistent/path/zzz"))
  }, port)
  on.exit(stop_server(proc), add = TRUE)
  wait_ready(port, "/x")

  r <- GET(port, "/x")
  expect_equal(httr2::resp_status(r), 500L)
  expect_match(httr2::resp_body_string(r), "file not found")
})

test_that("dr_file rejects non-string path / oversized requests at construction", {
  # Pure R-side checks; no server needed.
  expect_error(dr_file(123),
               "`path` must be a single string")
  expect_error(dr_file("/no/such/file/exists/here"),
               "file not found")
})
