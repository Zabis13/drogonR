# drogonR 0.1.8

* WebSocket support (full-duplex, long-lived connections):
    * `dr_ws(app, path, on_message, on_connect, on_close)` — register a
      WebSocket endpoint served by R hooks. Hooks run on the main R
      thread; each receives a `drogon_ws_conn` handle.
    * `dr_ws_send(conn, msg, binary)` / `dr_ws_close(conn)` — push a
      message to, or close, a live connection from any hook.
    * `dr_ws_join(conn, room)` / `dr_ws_leave(conn, room)` /
      `dr_ws_broadcast(room, msg, binary)` — named broadcast rooms, so a
      message can fan out to every member without tracking handles.
    * `dr_ws_cpp(app, path, package, callable)` — R-bypass fast path: a
      compiled C handler (ABI `drogonr_ws_handler_t` in
      `inst/include/drogonR.h`) services every frame on Drogon's I/O
      thread, with a thread-safe `send`/`close`/`is_connected` callback
      set usable from a detached backend thread (e.g. an LLM streaming
      tokens from C++ without a per-token round-trip through R).
    * `dr_ws_cpp()` gains continuous-batching guards for scheduler
      backends: `max_conns` (refuse an over-capacity connection with WS
      close 1013), `idle_timeout` (reap a connection with no outgoing
      frame for that long), and `max_lifetime` (absolute duration
      ceiling). All default to off.

# drogonR 0.1.7

* Build portability and CRAN check fixes: WebAssembly/webR build (`htonll` under Emscripten), a `[[nodiscard]]` warning under clang, and two rchk PROTECT-balance findings in the JSON writer and response builder.

# drogonR 0.1.6

* `dr_rate_limit(app, capacity, window, type, scope, routes)` —
  per-route or shared rate limit (sliding / fixed window or token
  bucket); over-budget requests get HTTP 429 + `Retry-After` from the
  I/O thread before R is involved.
* New vignette `rate-limiting.Rmd`.

# drogonR 0.1.5

* Streaming responses: `dr_stream(next_chunk, state, ...)` returns
  HTTP chunked responses driven by an R generator pumped on the main
  R thread, with a `cancelled = TRUE` cleanup contract on client
  disconnect.
* `dr_stream_sse(generator, ...)` convenience wrapper that formats
  Server-Sent Events frames (multi-line `data` is split per the SSE
  spec) and adds the `Cache-Control: no-cache` /
  `X-Accel-Buffering: no` headers expected by typical SSE clients.
* New vignette `streaming.Rmd` with the threading caveats and end-to-
  end examples.

# drogonR 0.1.4

* Path parameters in routes: `dr_get("/users/:id", ...)`. Three
  placeholder syntaxes are accepted interchangeably — `:name`,
  `<name>`, `{name}` — and exposed to handlers as a named character
  vector in `req$params`.
* Response helpers: `dr_text()`, `dr_html()`, `dr_redirect()`,
  `dr_file()`. `dr_file()` auto-detects the MIME type from a built-in
  table covering ~25 common extensions, supports `download_as = ...`
  for `Content-Disposition: attachment`, and warns/errors on
  oversized loads (>50MB / >500MB).
* Windows source-portability: replaced the POSIX `pipe(2)` /
  `fcntl(2)` wakeup mechanism with a loopback TCP `socketpair`
  on Windows. (Full Windows binary build is still pending.)

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
