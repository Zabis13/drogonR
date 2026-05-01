#!/usr/bin/env bash
# Profile drogonR under wrk load with perf record -g, single worker.
#
# Why one worker / no plumber: we're chasing drogonR's floor overhead,
# not comparing to plumber. Single Rscript pid keeps perf record simple.
#
# Routes profiled (override with ROUTE env var):
#   /ping-text  (default)  — plain "ok", no jsonlite, pure bridge floor
#   /ping                  — dr_json(list(ok=TRUE)), shows JSON cost on top
#
# Output: tools/bench/results/profile-<route>-<stamp>.{report,wrk,Rprof}
#
# Requirements:
#   - perf binary (we look for /usr/lib/linux-tools/<kver>/perf, falling
#     back to PATH). On Ubuntu OEM 6.17 the matching kernel package may
#     not ship perf — perf from a 6.8 generic kernel works for userspace
#     samples (kernel-side symbols won't resolve unless kptr_restrict=0).
#   - kernel.perf_event_paranoid <= 2 (use `sudo sysctl -w
#     kernel.perf_event_paranoid=1`).
#   - wrk on PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"

PORT=${PORT:-8080}
THREADS=${THREADS:-4}
ROUTE=${ROUTE:-/ping-text}
WRK_DURATION=${WRK_DURATION:-30s}
WRK_THREADS=${WRK_THREADS:-4}
WRK_CONNS=${WRK_CONNS:-100}
PERF_FREQ=${PERF_FREQ:-999}      # samples/sec; 999 avoids perf's own 1kHz aliasing
PERF_DURATION=${PERF_DURATION:-25}  # < WRK_DURATION so perf samples a steady-state window

# perf binary discovery: prefer kernel-matching, fall back to any
# usable one.
PERF_BIN=""
for cand in \
  "/usr/lib/linux-tools/$(uname -r)/perf" \
  "/usr/lib/linux-tools/6.8.0-100-generic/perf" \
  "$(command -v perf || true)"
do
  if [[ -x "$cand" ]] && "$cand" --version >/dev/null 2>&1; then
    PERF_BIN="$cand"; break
  fi
done
if [[ -z "$PERF_BIN" ]]; then
  echo "ERROR: no working perf found. Install linux-tools-\$(uname -r)" >&2
  exit 1
fi
echo "perf:   $PERF_BIN"

PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
if (( PARANOID > 2 )); then
  echo "WARNING: kernel.perf_event_paranoid=$PARANOID — perf record -p may fail." >&2
  echo "         sudo sysctl -w kernel.perf_event_paranoid=1" >&2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
TAG="${ROUTE//\//_}"; TAG="${TAG#_}"
SERVER_LOG="$RESULTS/profile-${TAG}-${STAMP}.server.log"
PERF_DATA="$RESULTS/profile-${TAG}-${STAMP}.perf.data"
PERF_REPORT="$RESULTS/profile-${TAG}-${STAMP}.report"
WRK_OUT="$RESULTS/profile-${TAG}-${STAMP}.wrk"

SERVER_PID=""
PERF_PID=""

cleanup() {
  [[ -n "$PERF_PID"   ]] && kill "$PERF_PID"   2>/dev/null || true
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  sleep 0.3
  [[ -n "$SERVER_PID" ]] && kill -9 "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

wait_ready() {
  local url=$1
  for _ in $(seq 1 40); do
    curl -fs "$url" > /dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "TIMEOUT: $url did not answer in 10s" >&2
  exit 1
}

echo "==> starting drogonR on :$PORT (threads=$THREADS)"
Rscript "$HERE/bench-ping.R" "$PORT" "$THREADS" \
  > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
wait_ready "http://127.0.0.1:${PORT}${ROUTE}"
echo "    pid=$SERVER_PID, route=$ROUTE"

# Warm up — let the JIT-ish caches settle and the OS page in symbols
# before perf samples a steady-state window.
echo "==> warmup 3s"
wrk -t2 -c20 -d3s "http://127.0.0.1:${PORT}${ROUTE}" > /dev/null 2>&1 || true

echo "==> perf record -F $PERF_FREQ -g -p $SERVER_PID, ${PERF_DURATION}s"
"$PERF_BIN" record -F "$PERF_FREQ" -g -p "$SERVER_PID" \
  -o "$PERF_DATA" -- sleep "$PERF_DURATION" \
  > "$RESULTS/profile-${TAG}-${STAMP}.perf.log" 2>&1 &
PERF_PID=$!

echo "==> wrk -t$WRK_THREADS -c$WRK_CONNS -d$WRK_DURATION http://127.0.0.1:${PORT}${ROUTE}"
{
  echo "# drogonR profile  $(date -Iseconds)"
  echo "# route=$ROUTE  threads=$THREADS  connections=$WRK_CONNS"
  wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"$WRK_DURATION" \
      "http://127.0.0.1:${PORT}${ROUTE}"
} | tee "$WRK_OUT"

echo "==> waiting for perf to finalise"
wait "$PERF_PID" || true
PERF_PID=""

echo "==> perf report → $PERF_REPORT"
"$PERF_BIN" report --stdio --no-children -i "$PERF_DATA" \
  > "$PERF_REPORT" 2>&1 || true

echo
echo "==> top 30 self-time symbols:"
"$PERF_BIN" report --stdio --no-children -i "$PERF_DATA" 2>/dev/null \
  | awk '/^# Overhead/{flag=1; print; next} flag && /^[ \t]/{print}' \
  | head -30 || true

echo
echo "results:"
echo "  perf data:    $PERF_DATA"
echo "  perf report:  $PERF_REPORT"
echo "  wrk:          $WRK_OUT"
echo "  server log:   $SERVER_LOG"
