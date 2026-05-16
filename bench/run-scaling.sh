#!/usr/bin/env bash
#
# Route-count scaling A/B for lex-web — and against FastAPI for context.
#
# Each variant is a single bench server with the named route count and
# named dispatcher. Same wrk config as bench/run.sh. Output goes to
# bench/results/scaling.tsv plus per-(variant, endpoint, trial) raw
# wrk text.
#
# Variants:
#   lex-listfold-3   list.fold dispatcher, 3 routes (legacy baseline)
#   lex-trie-3       trie dispatcher, 3 routes (current default)
#   lex-listfold-20  list.fold dispatcher, 20 routes (the regression)
#   lex-trie-20      trie dispatcher, 20 routes (the win)
#   fastapi-3        FastAPI, 3 routes (matrix headline)
#   fastapi-20       FastAPI, 20 routes (context for lex-web's scaling)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DURATION="${DURATION:-15s}"
THREADS="${THREADS:-2}"
CONNECTIONS="${CONNECTIONS:-64}"
TRIALS="${TRIALS:-3}"
TASKSET="${TASKSET:-taskset -c 0-1}"

LEX_BIN="${LEX_BIN:-$ROOT/../lex-lang/target/release/lex}"
RESULTS="$ROOT/bench/results"
mkdir -p "$RESULTS"

log() { printf '[scaling] %s\n' "$*" >&2; }

wait_for() {
  local url="$1" tries=80
  while ((tries-- > 0)); do
    if curl -sf -o /dev/null --max-time 1 "$url"; then return 0; fi
    sleep 0.25
  done
  return 1
}

start_lex() {
  local file="$1"
  $TASKSET "$LEX_BIN" run --allow-effects io,net,time,crypto,random \
    "$file" main > "$RESULTS/scaling.stdout" 2> "$RESULTS/scaling.stderr" &
  echo $!
  wait_for "http://127.0.0.1:8080/plaintext"
}

start_fastapi() {
  local app="$1"
  $TASKSET python3 -m uvicorn "$app" \
    --host 127.0.0.1 --port 8081 \
    --workers 1 --no-access-log --log-level warning \
    > "$RESULTS/scaling.stdout" 2> "$RESULTS/scaling.stderr" &
  echo $!
  wait_for "http://127.0.0.1:8081/plaintext"
}

kill_pid() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    pkill -KILL -P "$pid" 2>/dev/null || true
  fi
}

bench_variant() {
  local label="$1" port="$2"
  for _ in 1 2 3; do
    curl -sf "http://127.0.0.1:$port/plaintext" >/dev/null || true
  done
  for ep in /plaintext /users/usr_001; do
    for trial in $(seq 1 "$TRIALS"); do
      local epname="${ep#/}"; epname="${epname%/*}"
      local out="$RESULTS/scaling_${label}_${epname//\//_}_t${trial}.txt"
      log "$label $ep trial $trial/$TRIALS"
      wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency \
          "http://127.0.0.1:$port$ep" > "$out"
      local rps; rps=$(awk '/Requests\/sec:/ {print $2}' "$out")
      printf '%s\t%s\t%d\t%s\n' "$label" "$ep" "$trial" "$rps" \
        >> "$RESULTS/scaling.tsv"
    done
  done
}

run_lex_variant() {
  local label="$1" file="$2"
  log "boot $label ($file)"
  local pid; pid=$(start_lex "$file" | tail -n 1)
  bench_variant "$label" 8080
  kill_pid "$pid"
  sleep 2
}

run_fastapi_variant() {
  local label="$1" app="$2"
  log "boot $label ($app)"
  local pid; pid=$(start_fastapi "$app" | tail -n 1)
  bench_variant "$label" 8081
  kill_pid "$pid"
  sleep 2
}

main() {
  : > "$RESULTS/scaling.tsv"
  printf 'variant\tendpoint\ttrial\treq_per_sec\n' > "$RESULTS/scaling.tsv"

  # Both 3-route lex variants are hoisted-`app()` so the only difference
  # is the dispatcher (listfold vs trie). lex_web_bench_per_req.lex is
  # kept for the separate per-request-app() A/B documented in REPORT.md.
  run_lex_variant     "lex-listfold-3"   bench/servers/lex_web_bench_listfold.lex
  run_lex_variant     "lex-trie-3"       bench/servers/lex_web_bench.lex
  run_lex_variant     "lex-listfold-20"  bench/servers/lex_web_bench_many_listfold.lex
  run_lex_variant     "lex-trie-20"      bench/servers/lex_web_bench_many.lex
  run_fastapi_variant "fastapi-3"        bench.servers.fastapi_bench:app
  run_fastapi_variant "fastapi-20"       bench.servers.fastapi_bench_many:app

  log "raw: $RESULTS/scaling.tsv"

  # Compute medians.
  awk -F'\t' '
    NR == 1 { next }
    { key = $1 "\t" $2; n[key]++; v[key, n[key]] = $4 + 0 }
    END {
      printf "variant\tendpoint\trps_median\trps_min\trps_max\n"
      for (k in n) {
        cnt = n[k]
        for (i = 1; i <= cnt; i++)
          for (j = i+1; j <= cnt; j++)
            if (v[k,j] < v[k,i]) { t = v[k,i]; v[k,i] = v[k,j]; v[k,j] = t }
        med = (cnt % 2 == 1) ? v[k, (cnt+1)/2] \
                              : (v[k, cnt/2] + v[k, cnt/2+1]) / 2
        printf "%s\t%.0f\t%.0f\t%.0f\n", k, med, v[k,1], v[k,cnt]
      }
    }
  ' "$RESULTS/scaling.tsv" | (read header; echo "$header"; sort) \
      | tee "$RESULTS/scaling-summary.tsv"
}

trap 'pkill -KILL -f "lex run.*lex_web_bench" 2>/dev/null; pkill -KILL -f "uvicorn.*fastapi_bench" 2>/dev/null; true' EXIT
main "$@"
