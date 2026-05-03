#!/usr/bin/env bash
# Bench four HTTP serving variants on the same /ping (JSON) and
# /ping-text (plain) routes:
#
#   1. drogonR-cpp     — variant 1: native C handler via dr_get_cpp(),
#                        R is not in the hot path (drogonRtestbackend).
#   2. drogonR-native  — variant 2: dr_app() + dr_get() with R handlers.
#   3. drogonR-shim    — variant 3: plumber object served via
#                        drogonR::pr_run() shim.
#   4. plumber         — baseline: vanilla plumber::pr_run().
#
# All four start in their own Rscript, on their own port. wrk runs
# strictly sequentially across servers — concurrent benches on one
# host produce noise that swamps the cpp variant's tiny latency.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"

CPP_PORT=8082
DROGON_PORT=8080
SHIM_PORT=8083
PLUMBER_PORT=8081
WRK_ARGS=(-t4 -c50 -d30s)

STAMP="$(date +%Y%m%d-%H%M%S)"
declare -A PIDS=()

cleanup() {
  for name in "${!PIDS[@]}"; do
    local pid="${PIDS[$name]}"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  sleep 0.5
  for name in "${!PIDS[@]}"; do
    local pid="${PIDS[$name]}"
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

wait_ready() {
  local url=$1
  for _ in $(seq 1 40); do
    curl -fs "$url" > /dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "TIMEOUT: $url did not respond within 20s" >&2
  exit 1
}

start_server() {
  local name=$1 script=$2 port=$3
  echo "==> starting $name on :$port"
  Rscript "$HERE/$script" "$port" \
    > "$RESULTS/${name}-server-${STAMP}.log" 2>&1 &
  PIDS["$name"]=$!
  wait_ready "http://127.0.0.1:${port}/ping"
}

run_one() {
  local name=$1 port=$2 path=$3 tag=$4
  local out="$RESULTS/${name}-${tag}-${STAMP}.txt"
  echo "==> wrk ${WRK_ARGS[*]} http://127.0.0.1:${port}${path}  ($name $tag)"
  {
    echo "# $name $tag  $(date -Iseconds)"
    echo "# wrk ${WRK_ARGS[*]} http://127.0.0.1:${port}${path}"
    wrk "${WRK_ARGS[@]}" "http://127.0.0.1:${port}${path}"
  } | tee "$out"
  echo
}

# Start all four (cheap; each just initialises an event loop). Bench
# runs are still strictly sequential — see run_all below.
start_server drogonR-cpp    bench-ping-cpp.R     "$CPP_PORT"
start_server drogonR-native bench-ping.R         "$DROGON_PORT"
start_server drogonR-shim   bench-ping-pr-shim.R "$SHIM_PORT"
start_server plumber        bench-ping-plumber.R "$PLUMBER_PORT"

# Sequential benches — one wrk run at a time, no overlap.
run_one drogonR-cpp    "$CPP_PORT"     /ping       json
run_one drogonR-cpp    "$CPP_PORT"     /ping-text  text
run_one drogonR-native "$DROGON_PORT"  /ping       json
run_one drogonR-native "$DROGON_PORT"  /ping-text  text
run_one drogonR-shim   "$SHIM_PORT"    /ping       json
run_one drogonR-shim   "$SHIM_PORT"    /ping-text  text
run_one plumber        "$PLUMBER_PORT" /ping       json
run_one plumber        "$PLUMBER_PORT" /ping-text  text

echo "==> results in $RESULTS"
