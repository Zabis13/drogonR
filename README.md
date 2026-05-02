# drogonR

High-performance HTTP server for R, powered by the
[Drogon](https://github.com/drogonframework/drogon) C++ framework.

drogonR provides a `plumber`-style API for building REST services and
APIs from R, with substantially higher throughput. The Drogon, Trantor
and JsonCpp sources are bundled and built statically — no external
installation of Drogon is required.

> **Status:** 0.1.4, in development. Linux only. Windows source
> portability is in place; full Windows build is pending.

## Architecture

```
[Drogon I/O threads]  →  [Lock-free queue]  →  [R main thread]
        ↑                                              ↓
  Accept HTTP                                  Execute R handler
  Parse request                                Build R response
  TLS / HTTP/2                                       ↓
        ←──────────── [Response callback] ←───────────
```

* Drogon runs in its own C++ thread; R handlers are dispatched on the
  main R thread via a thread-safe queue.
* C++-only routes can bypass the queue entirely.
* Multi-process scaling is provided via forked workers (each worker has
  its own R session listening on the same port via `SO_REUSEPORT`).

## Benchmarks

`GET /ping` returning `{"ok":true}`, measured with
`wrk -t4 -c100 -d30s` on AMD Ryzen 5 5600 (6 cores). drogonR runs
with `threads=4`, single worker; plumber is single-threaded by design.

|                       | Requests/sec | Avg latency | Throughput |
|-----------------------|-------------:|------------:|-----------:|
| drogonR `/ping`       |    118 388   |    0.89 ms  |  16.0 MB/s |
| drogonR `/ping-text`  |    147 077   |    0.70 ms  |  19.8 MB/s |
| plumber `/ping`       |      1 087   |   44.12 ms  |   129 KB/s |

drogonR serves ~100× the requests of plumber on the same JSON
handler. `/ping-text` (a handler returning a plain string) shows the
floor overhead of the bridge — almost all remaining CPU is spent in
the kernel TCP send path. The bench scripts live at
`tools/bench/run.sh` (drogonR vs plumber) and `tools/bench/profile.sh`
(single-route `perf record -g` flame). Reproduce with
`bash tools/bench/run.sh` and
`ROUTE=/ping bash tools/bench/profile.sh`.

## Installation

### From source (development)

```r
# Once published:
# install.packages("drogonR")

# From a local checkout:
install.packages("/path/to/drogonR", repos = NULL, type = "source")
```

### Build requirements

* C++17 compiler (GCC ≥ 7, Clang ≥ 5)
* GNU make
* (optional) OpenSSL development headers for HTTPS support

The configure script auto-detects OpenSSL via `pkg-config` and falls
back to a plain-HTTP build if it is not found. To force the choice:

```bash
R CMD INSTALL --configure-args="--with-openssl"    drogonR
R CMD INSTALL --configure-args="--without-openssl" drogonR
```

## Quick start

```r
library(drogonR)

app <- dr_app() |>
  dr_get("/health", function(req) {
    dr_json(list(status = "ok"))
  }) |>
  dr_get("/users/:id", function(req) {
    # Path parameters: req$params is a named character vector.
    # `:id`, `<id>` and `{id}` are accepted interchangeably.
    dr_json(list(user_id = req$params[["id"]]))
  }) |>
  dr_post("/predict", function(req) {
    body <- dr_body(req, as = "json")
    dr_json(list(prediction = model_predict(body$data)))
  }) |>
  dr_get("/login", function(req) dr_redirect("/auth/sso")) |>
  dr_get("/report.csv", function(req) {
    dr_file("/srv/reports/latest.csv", download_as = "Q3-report.csv")
  })

# Single-process serve.
dr_serve(app, port = 8080L, threads = 4L)

# When done:
dr_stop()
```

### Response helpers

* `dr_text(body)` — `text/plain; charset=utf-8`
* `dr_html(body)` — `text/html; charset=utf-8`
* `dr_json(x)`   — `application/json`, with a fast C++ path for the
  common shapes
* `dr_redirect(location, status = 302L)` — sets `Location:` and an
  empty body
* `dr_file(path, download_as = NULL)` — reads a file, auto-detects
  the MIME from a built-in table, optionally adds
  `Content-Disposition: attachment`

### Multi-process workers

For inference-bound APIs, fork N R worker processes that share the
listening port via `SO_REUSEPORT`. Each worker has its own R session,
so per-worker state (models, caches) can be loaded once in
`on_worker_start`:

```r
dr_serve(app, port = 8080L, workers = 8L,
         on_worker_start = function() {
           model <<- readRDS("model.rds")
         })

dr_status()   # data frame of worker pids and liveness
```

`dr_stop()` SIGTERMs every worker (with SIGKILL fallback after 2s) and
reaps them.

### Backpressure

Under overload, the request queue between Drogon and R is bounded by
`max_queue` (default `1024`). Once full, incoming requests are
rejected with `503 Service Unavailable` directly from a Drogon I/O
thread — no R-side cost — instead of growing memory unboundedly:

```r
dr_serve(app, port = 8080L, max_queue = 256L)
```

## License

drogonR itself is released under the MIT license.

The package bundles the following third-party libraries, all under the
MIT license, with their original copyright notices preserved:

* **Drogon** © an-tao and contributors
* **Trantor** © an-tao and contributors
* **JsonCpp** © Baptiste Lepilleur and contributors

See `LICENSE.note` for details.
