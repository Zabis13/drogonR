#!/usr/bin/env bash
# Bench drogonR vs plumber on GET /ping with wrk.
# Each server runs in its own Rscript process; this script orchestrates.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"

DROGON_PORT=8080
PLUMBER_PORT=8081
WRK_ARGS=(-t4 -c50 -d30s)

STAMP="$(date +%Y%m%d-%H%M%S)"
DROGON_PID=""
PLUMBER_PID=""

cleanup() {
  [[ -n "$DROGON_PID"  ]] && kill "$DROGON_PID"  2>/dev/null || true
  [[ -n "$PLUMBER_PID" ]] && kill "$PLUMBER_PID" 2>/dev/null || true
  sleep 0.5
  [[ -n "$DROGON_PID"  ]] && kill -9 "$DROGON_PID"  2>/dev/null || true
  [[ -n "$PLUMBER_PID" ]] && kill -9 "$PLUMBER_PID" 2>/dev/null || true
}
trap cleanup EXIT

wait_ready() {
  local url=$1
  for i in $(seq 1 20); do
    curl -fs "$url" > /dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "TIMEOUT: $url не ответил за 10s" >&2
  exit 1
}

run_bench() {
  local name=$1 port=$2
  local out="$RESULTS/${name}-${STAMP}.txt"
  echo "==> wrk ${WRK_ARGS[*]} http://127.0.0.1:${port}/ping  ($name)"
  {
    echo "# $name  $(date -Iseconds)"
    echo "# wrk ${WRK_ARGS[*]} http://127.0.0.1:${port}/ping"
    wrk "${WRK_ARGS[@]}" "http://127.0.0.1:${port}/ping"
  } | tee "$out"
  echo
}

echo "==> starting drogonR on :$DROGON_PORT"
Rscript "$HERE/bench-ping.R" "$DROGON_PORT" \
  > "$RESULTS/drogonR-server-${STAMP}.log" 2>&1 &
DROGON_PID=$!
wait_ready "http://127.0.0.1:${DROGON_PORT}/ping"

echo "==> starting plumber on :$PLUMBER_PORT"
Rscript "$HERE/bench-ping-plumber.R" "$PLUMBER_PORT" \
  > "$RESULTS/plumber-server-${STAMP}.log" 2>&1 &
PLUMBER_PID=$!
wait_ready "http://127.0.0.1:${PLUMBER_PORT}/ping"

run_bench drogonR "$DROGON_PORT"
run_bench plumber "$PLUMBER_PORT"

echo "==> results in $RESULTS"
