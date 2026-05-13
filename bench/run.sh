#!/usr/bin/env bash
# bench/run.sh — TFB-shaped wrk runner for the lex-web bench server.
#
# Boot the server in another terminal first:
#   lex run --allow-effects io,net,time,sql,fs_write bench/server.lex main
#
# Then:
#   bench/run.sh
#
# Override the defaults with env vars:
#   THREADS=8 CONNECTIONS=512 DURATION=30s ./bench/run.sh
#   HOST=http://localhost:8080 ./bench/run.sh
#
# What it does:
#   * 5-second warmup against /plaintext (caches connections, JITs hot paths)
#   * 15-second wrk run against each of /plaintext, /json, /db, /queries?queries=20
#   * Parses the wrk output and prints a one-row-per-endpoint summary
#
# What it doesn't do:
#   * HTTP/1.1 pipelining for /plaintext (TFB pipelines 16). Add `-s pipeline.lua`
#     to the wrk call when std.net supports it; numbers will jump 5-10x.
#   * Multiple connection counts. Real TFB sweeps 16/32/64/128/256/512.

set -euo pipefail

HOST="${HOST:-http://localhost:8080}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-256}"
DURATION="${DURATION:-15s}"
WARMUP="${WARMUP:-5s}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk not installed. apt: sudo apt-get install wrk | brew: brew install wrk" >&2
  exit 1
fi

run_one() {
  local label="$1" path="$2"
  local out
  out=$(wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" "$HOST$path" 2>&1)

  # Parse wrk's text output. We pull RPS + p50/p99 latency.
  local rps
  rps=$(printf '%s\n' "$out" | awk '/Requests\/sec:/ {print $2}')
  local p50 p99
  p50=$(printf '%s\n' "$out" | awk '/Latency Distribution/{found=1; next} found && /^[ ]+50%/ {print $2; exit}')
  p99=$(printf '%s\n' "$out" | awk '/Latency Distribution/{found=1; next} found && /^[ ]+99%/ {print $2; exit}')
  local mean_lat
  mean_lat=$(printf '%s\n' "$out" | awk '/^    Latency/ {print $2; exit}')

  printf '%-26s %14s %12s %10s %10s\n' "$label" "${rps:-?}" "${mean_lat:-?}" "${p50:-?}" "${p99:-?}"
}

printf 'lex-web bench — wrk -t%s -c%s -d%s @ %s\n\n' \
       "$THREADS" "$CONNECTIONS" "$DURATION" "$HOST"

# Warmup — connection caching + any JIT/cache effects in std.sql.
printf 'warming up (%s on /plaintext)…\n' "$WARMUP"
wrk -t"$THREADS" -c"$CONNECTIONS" -d"$WARMUP" "$HOST/plaintext" >/dev/null 2>&1 || true

printf '\n%-26s %14s %12s %10s %10s\n' "endpoint" "req/sec" "mean lat" "p50" "p99"
printf -- '-%.0s' {1..78}; echo

run_one "/plaintext"          "/plaintext"
run_one "/json"               "/json"
run_one "/db (1 query)"       "/db"
run_one "/queries (20 q/req)" "/queries?queries=20"

echo
echo "Compare to TechEmpower's public numbers as a rough scale:"
echo "  https://www.techempower.com/benchmarks/  (filter by 'plaintext', 'json', 'db')"
