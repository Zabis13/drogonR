# drogonR

[![R-hub](https://github.com/Zabis13/drogonR/actions/workflows/rhub.yaml/badge.svg)](https://github.com/Zabis13/drogonR/actions/workflows/rhub.yaml)
[![R-hub check on the R Consortium cluster](https://github.com/r-hub2/separate-jaguar-drogonR/actions/workflows/rhub-rc.yaml/badge.svg)](https://github.com/r-hub2/separate-jaguar-drogonR/actions/workflows/rhub-rc.yaml)

High-performance HTTP server for R, powered by the
[Drogon](https://github.com/drogonframework/drogon) C++ framework.

drogonR provides a `plumber`-style API for building REST services and
APIs from R, with substantially higher throughput. The Drogon, Trantor
and JsonCpp sources are bundled and built statically — no external
installation of Drogon is required.

> **Status:** 0.1.8, in development. Builds and passes `R CMD check` on
> Linux, Windows, and macOS (CRAN check farm, all green).

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

Same workload (`GET /ping` returning `{"ok":true}`, and `GET
/ping-text` returning `"ok"`), four servers running side by side, one
at a time, measured with `wrk -t4 -c50 -d30s` on AMD Ryzen 5 5600
(6 cores). drogonR runs with `threads=4`, single worker; plumber is
single-threaded by design. The four columns are the three drogonR
serving paths plus the plumber baseline:

* **cpp-shared** — `dr_get_cpp()`, handler is a C function in another
  R package, R is not in the request hot path.
* **native** — `dr_app() + dr_get()`, handler is an R closure.
* **plumber-shim** — `drogonR::pr_run(plumber_obj)`, plumber router
  served via drogonR's dispatcher.
* **plumber** — vanilla `plumber::pr_run()`, baseline.

|                                 | drogonR cpp-shared | drogonR native | drogonR plumber-shim | plumber |
|---------------------------------|-------------------:|---------------:|---------------------:|--------:|
| `/ping`      requests/sec       |        **239 428** |        116 159 |               94 400 |   1 078 |
| `/ping`      avg latency        |             200 µs |         822 µs |               591 µs | 44.5 ms |
| `/ping-text` requests/sec       |        **234 753** |        218 163 |               99 276 |   1 069 |
| `/ping-text` avg latency        |             202 µs |         252 µs |               583 µs | 44.9 ms |

Two things to read out of this:

* The cpp-shared path leaves R entirely — its throughput is bounded
  by Drogon and the kernel, ~240k rps for a trivial handler.
* Even when an R closure runs per request (native, shim), drogonR is
  ~90–220× plumber, because the I/O loop is C++ and requests are
  marshaled onto the main R thread once per dispatch tick instead of
  per request.

The bench scripts live at `tools/bench/run.sh` (all four servers) and
`tools/bench/profile.sh` (single-route `perf record -g` flame).
Reproduce with `bash tools/bench/run.sh` and `ROUTE=/ping bash
tools/bench/profile.sh`. For an in-depth look at the three drogonR
variants see `vignette("drogonR", package = "drogonR")`.

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

### Streaming responses

For Server-Sent-Events feeds, LLM token streams, or any endpoint
where the client cares about first-byte time more than last-byte
time, return a `dr_stream()` (or the SSE convenience wrapper
`dr_stream_sse()`) instead of a normal response. The dispatcher
opens a chunked response and pumps the generator on the main R
thread one chunk at a time. On client disconnect the generator is
called once with `cancelled = TRUE` so it can release per-stream
state.

```r
app <- dr_app() |>
  dr_get("/sse", function(req) {
    dr_stream_sse(
      state = list(i = 0L, n = 5L),
      generator = function(state, cancelled) {
        if (cancelled || state$i >= state$n) {
          return(list(data = "", state = state, done = TRUE))
        }
        state$i <- state$i + 1L
        list(data  = sprintf("tick %d", state$i),
             state = state, done = FALSE)
      })
  })
```

See `vignette("streaming", package = "drogonR")` for the full API,
threading caveats, and cancellation contract.

### Rate limiting

Cap how many requests are allowed in a rolling window. The check
runs on the I/O thread before R is invoked; over-budget requests
get HTTP 429 with a `Retry-After` header.

```r
app <- dr_app() |>
  dr_get("/health",    function(req) "ok") |>
  dr_get("/api/users", function(req) dr_json(list(...))) |>
  # 100 req / 60 s, per-route, applied to anything under /api/
  dr_rate_limit(capacity = 100L, window = 60, routes = "/api/")
```

Algorithms: `"sliding_window"` (default), `"fixed_window"`,
`"token_bucket"`. Scope: `"per_route"` (default — each matched route
gets its own bucket) or `"global"` (one bucket shared across the
match set). Per-IP throttling is intentionally out of scope — do
that in a reverse proxy. See `vignette("rate-limiting",
package = "drogonR")`.

### WebSocket

Register a full-duplex WebSocket endpoint with `dr_ws()`. Unlike the
request/response routes, a connection is long-lived: the server can
push to the client at any time with `dr_ws_send()`, and every frame
from the client arrives at `on_message`. The hooks run on the main R
thread, so they may touch R state freely.

```r
app <- dr_app() |>
  dr_ws("/ws/echo",
        on_connect = function(conn) dr_ws_send(conn, "welcome"),
        on_message = function(conn, msg, binary) dr_ws_send(conn, msg),
        on_close   = function(conn) message("gone"))
```

Broadcast rooms fan a message out to many connections at once, so you
don't have to track handles yourself:

```r
app <- dr_app() |>
  dr_ws("/chat",
        on_connect = function(conn) dr_ws_join(conn, "lobby"),
        on_message = function(conn, msg, binary)
          dr_ws_broadcast("lobby", msg))
```

For a backend that owns the socket and streams from C/C++ (e.g. an LLM
emitting tokens), `dr_ws_cpp(app, path, package, callable)` serves
every frame with a compiled handler on Drogon's I/O thread, bypassing
R entirely. The handler signature is `drogonr_ws_handler_t` in
`inst/include/drogonR.h`; its `send` callback is thread-safe and may be
called from a detached backend thread.

`dr_ws_cpp()` also accepts three optional guards for backends that
batch many connections into one decode loop (the way `llama-server`
uses `-np N` and its slot timeouts):

```r
app <- dr_app() |>
  dr_ws_cpp("/ws/llm", "myllm", "handler",
            max_conns    = 32,   # refuse the 33rd with WS close 1013
            idle_timeout = 60,   # close after 60s with no outgoing frame
            max_lifetime = 600)  # hard ceiling regardless of activity
```

They are the transport's safety net — a stalled decode thread can't
leak connections, and a scheduler can't oversubscribe the KV-cache —
so a scheduler layered on this ABI doesn't have to re-implement them
itself. All three default to `0` (off).

## License

drogonR itself is released under the MIT license.

The package bundles the following third-party libraries, all under the
MIT license, with their original copyright notices preserved:

* **Drogon** © an-tao and contributors
* **Trantor** © an-tao and contributors
* **JsonCpp** © Baptiste Lepilleur and contributors

See `LICENSE.note` for details.
