# drogonR 0.1.3

* Fast-path handlers: bypass R-side tryCatch/middleware, registering
  directly in C++. Hits 147k req/s (2.5x boost).
* `dr_json()`: new C++ walker for basic types replaces jsonlite. Hits
  118k req/s (12x boost) with silent fallback.
* Stable workers: switched from `mcparallel` (fork) to `processx`
  (spawn). Fixes `later` fds and sink stack issues in tests; ensures
  a clean R state for each worker.


# drogonR 0.1.2

* Multi-process workers: `dr_serve(workers = N)` spawns N forked R
  workers sharing the listening port via `SO_REUSEPORT`.
* `on_worker_start` callback in `dr_serve()` for per-worker
  initialization (load models, open per-worker resources).
* `dr_status()` reports the live worker pids of a multi-process serve.
* `dr_serve(max_queue = N)` bounds the request queue and rejects
  excess requests with HTTP 503, providing backpressure under
  overload.

# drogonR 0.1.0

Initial development release.

* High-performance HTTP server for R, backed by the Drogon C++ framework.
* Bundled, statically-linked Drogon, Trantor and JsonCpp sources — no
  external installation of Drogon is required.
* Optional HTTPS support: when OpenSSL development headers are detected
  by the configure script (via `pkg-config` or a manual search), the
  package is built with TLS enabled. Otherwise it falls back to a
  plain-HTTP build with a single message at install time.
* `--with-openssl` / `--without-openssl` flags can force the choice
  (passed via `R CMD INSTALL --configure-args=...`).
* Portable UUID generation using `<random>` instead of `libuuid`,
  removing the system dependency on Linux.
