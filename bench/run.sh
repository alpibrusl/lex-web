#!/usr/bin/env bash
#
# Drive every server in bench/servers with wrk and capture
# results/{server}_{endpoint}.txt + results/summary.tsv.
#
# Usage:
#   bench/run.sh              # full matrix
#   bench/run.sh lex-web      # one server (matches a server key below)
#
# Servers (key -> port -> start-command) live in `start_<key>()`.
# Each server is started, given a warm-up GET, hammered by wrk, then
# killed. Same wrk invocation everywhere — DURATION, THREADS,
# CONNECTIONS are env-overridable for re-runs.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DURATION="${DURATION:-15s}"
THREADS="${THREADS:-2}"
CONNECTIONS="${CONNECTIONS:-64}"
WARMUP="${WARMUP:-3}"
TRIALS="${TRIALS:-3}"

LEX_BIN="${LEX_BIN:-$ROOT/../lex-lang/target/release/lex}"
RESULTS="$ROOT/bench/results"
mkdir -p "$RESULTS"

LEX_PORT=8080
FASTAPI_PORT=8081
EXPRESS_PORT=8082
AXUM_PORT=8083

ENDPOINTS=(
  "plaintext:/plaintext"
  "json:/json"
  "user_id:/users/usr_001"
)

log() { printf '[bench] %s\n' "$*" >&2; }

wait_for() {
  local url="$1" tries=80
  while ((tries-- > 0)); do
    if curl -sf -o /dev/null --max-time 1 "$url"; then return 0; fi
    sleep 0.25
  done
  return 1
}

TASKSET="${TASKSET:-taskset -c 0-1}"

start_lex_web() {
  if [[ ! -x "$LEX_BIN" ]]; then
    log "skip lex-web: $LEX_BIN not built"; return 1
  fi
  $TASKSET "$LEX_BIN" run --allow-effects io,net,time,crypto,random \
    bench/servers/lex_web_bench.lex main \
    > "$RESULTS/lex-web.stdout" 2> "$RESULTS/lex-web.stderr" &
  echo $! > "$RESULTS/lex-web.pid"
  wait_for "http://127.0.0.1:$LEX_PORT/plaintext"
}

start_fastapi() {
  $TASKSET python3 -m uvicorn bench.servers.fastapi_bench:app \
    --host 127.0.0.1 --port "$FASTAPI_PORT" \
    --workers 1 --no-access-log --log-level warning \
    > "$RESULTS/fastapi.stdout" 2> "$RESULTS/fastapi.stderr" &
  echo $! > "$RESULTS/fastapi.pid"
  wait_for "http://127.0.0.1:$FASTAPI_PORT/plaintext"
}

start_express() {
  if ! command -v node >/dev/null; then
    log "skip express: node missing"; return 1
  fi
  ( cd bench/servers && $TASKSET node express_bench.js ) \
    > "$RESULTS/express.stdout" 2> "$RESULTS/express.stderr" &
  echo $! > "$RESULTS/express.pid"
  wait_for "http://127.0.0.1:$EXPRESS_PORT/plaintext"
}

start_axum() {
  local bin="bench/servers/axum_bench/target/release/axum-bench"
  if [[ ! -x "$bin" ]]; then
    log "skip axum: $bin not built (run: cargo build --release --manifest-path bench/servers/axum_bench/Cargo.toml)"
    return 1
  fi
  $TASKSET "$bin" \
    > "$RESULTS/axum.stdout" 2> "$RESULTS/axum.stderr" &
  echo $! > "$RESULTS/axum.pid"
  wait_for "http://127.0.0.1:$AXUM_PORT/plaintext"
}

kill_pidfile() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local pid; pid=$(cat "$f" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    # SIGTERM, give it a second, then SIGKILL the process group.
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    # uvicorn forks workers; clean stragglers.
    pkill -KILL -P "$pid" 2>/dev/null || true
  fi
  rm -f "$f"
}

# Parse the four numbers we care about out of wrk's output.
# Echoes: "<req_per_sec>\t<p50_ms>\t<p99_ms>\t<latency_avg_ms>"
parse_wrk() {
  awk '
    /Requests\/sec:/ { rps=$2 }
    # Match the "    Latency   <avg> <stdev> <max> <±stdev>" row (5 cols),
    # not the "  Latency Distribution" header (2 cols).
    /^[[:space:]]*Latency[[:space:]]/ && NF >= 5 { lat_avg=$2 }
    /^[[:space:]]*50%/ { p50=$2 }
    /^[[:space:]]*99%/ { p99=$2 }
    END { printf "%s\t%s\t%s\t%s\n", rps, p50, p99, lat_avg }
  ' "$1"
}

bench_one() {
  local server="$1" port="$2"
  log "warm-up: $server on :$port"
  for _ in $(seq 1 "$WARMUP"); do
    curl -sf "http://127.0.0.1:$port/plaintext" >/dev/null || true
  done
  for entry in "${ENDPOINTS[@]}"; do
    local name="${entry%%:*}" path="${entry#*:}"
    for trial in $(seq 1 "$TRIALS"); do
      local out="$RESULTS/${server}_${name}_t${trial}.txt"
      log "wrk: $server $name ($path) trial $trial/$TRIALS"
      wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency \
          "http://127.0.0.1:$port$path" > "$out"
      local row; row=$(parse_wrk "$out")
      printf '%s\t%s\t%d\t%s\n' "$server" "$name" "$trial" "$row" \
        >> "$RESULTS/trials.tsv"
    done
  done
}

run_server() {
  local key="$1"
  case "$key" in
    lex-web)  start_lex_web  && bench_one lex-web  "$LEX_PORT"     ;;
    fastapi)  start_fastapi  && bench_one fastapi  "$FASTAPI_PORT" ;;
    express)  start_express  && bench_one express  "$EXPRESS_PORT" ;;
    axum)     start_axum     && bench_one axum     "$AXUM_PORT"    ;;
    *) log "unknown server: $key"; return 1 ;;
  esac
  kill_pidfile "$RESULTS/$key.pid"
  # extra grace so the OS releases the port before the next server binds
  sleep 1
}

summarize() {
  awk -F'\t' '
    NR == 1 { next }  # skip header
    {
      # ts is the time-unit on req/sec — wrk always reports raw req/s; just take numeric
      key = $1 "\t" $2
      n[key]++
      vals[key, n[key]] = $4 + 0
    }
    END {
      printf "server\tendpoint\ttrials\trps_median\trps_min\trps_max\n"
      for (k in n) {
        cnt = n[k]
        # bubble sort (cnt is small, typically 3)
        for (i = 1; i <= cnt; i++)
          for (j = i+1; j <= cnt; j++)
            if (vals[k,j] < vals[k,i]) {
              t = vals[k,i]; vals[k,i] = vals[k,j]; vals[k,j] = t
            }
        med = (cnt % 2 == 1) ? vals[k, (cnt+1)/2] \
                              : (vals[k, cnt/2] + vals[k, cnt/2+1]) / 2
        printf "%s\t%d\t%.2f\t%.2f\t%.2f\n", k, cnt, med, vals[k,1], vals[k,cnt]
      }
    }
  ' "$RESULTS/trials.tsv" | (read header; echo "$header"; sort)
}

main() {
  printf 'server\tendpoint\ttrial\treq_per_sec\tp50_ms\tp99_ms\tlatency_avg\n' > "$RESULTS/trials.tsv"
  local servers=("lex-web" "fastapi" "express" "axum")
  if (($# > 0)); then servers=("$@"); fi
  for s in "${servers[@]}"; do
    run_server "$s" || log "server $s failed/skipped"
  done
  summarize > "$RESULTS/summary.tsv"
  log "done. summary: $RESULTS/summary.tsv"
  cat "$RESULTS/summary.tsv"
}

trap 'for f in "$RESULTS"/*.pid; do kill_pidfile "$f"; done' EXIT
main "$@"
