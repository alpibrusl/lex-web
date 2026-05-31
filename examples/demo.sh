#!/usr/bin/env bash
# Theatrical demo — lex-web: HTTP + WebSocket, actor-model chat
# Prereqs: websocat  (brew install websocat)
# Usage:   bash examples/demo.sh
#          asciinema rec examples/demo.cast -c "bash examples/demo.sh" --overwrite
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
LEX="${LEX:-lex}"

BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'
GREEN=$'\033[32m'; BLUE=$'\033[34m'; RESET=$'\033[0m'

slow() { echo "$@" | pv -qL 55; }
pause() { sleep "${1:-1.2}"; }
hr()  { printf '%s' "$DIM"; printf '─%.0s' {1..72}; printf '%s\n' "$RESET"; }
hdr() { echo; hr; echo "  ${BOLD}${CYAN}$*${RESET}"; hr; echo; }
cmd() { echo "${BOLD}${BLUE}\$${RESET}  $*"; pause 0.6; }

TMP=$(mktemp -d)
ALICE_PIPE="$TMP/alice.in"
ALICE_OUT="$TMP/alice.out"
SERVER_PID=""
ALICE_PID=""

cleanup() {
  exec 3>&- 2>/dev/null || true
  [ -n "$ALICE_PID" ] && kill "$ALICE_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Wait until file has at least N lines, then print line N
wait_line() {
  local f="$1" n="$2" i=0
  while [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -lt "$n" ] && [ $i -lt 25 ]; do
    sleep 0.3; i=$((i+1))
  done
  sed -n "${n}p" "$f" 2>/dev/null
}

clear
echo
echo "  ${BOLD}lex-web${RESET}  ·  HTTP + WebSocket, actor-model real-time chat"
echo "  ${DIM}One process. Two listeners. Named actors. Effect-typed.${RESET}"
echo
sleep 2

# ── Effect row ───────────────────────────────────────────────────────────
hdr "Effect row — every capability declared up front"
slow "  main() lists all 9 effects it touches."
slow "  The type checker verifies them before a byte runs."
echo
pause 0.8

cmd "grep 'fn main' examples/chat_app.lex"
grep 'fn main' examples/chat_app.lex
echo
pause 0.8

cmd "lex check examples/chat_app.lex"
pause 0.4
"$LEX" check examples/chat_app.lex
echo "${GREEN}${BOLD}✓  ok${RESET}  — 9 effects verified at compile time"
echo
pause 1.5

# ── Boot ────────────────────────────────────────────────────────────────
hdr "Boot — HTTP :9000  +  WebSocket :9100  in one process"
slow "  Two listeners, one effect graph, zero boilerplate."
echo
pause 0.8

cmd "lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time \\"
echo "        examples/chat_app.lex main  &"
pause 0.5
"$LEX" run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time \
  examples/chat_app.lex main >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
sleep 2.5
echo "  ${GREEN}✓${RESET}  HTTP  on :9000"
echo "  ${GREEN}✓${RESET}  WebSocket on :9100"
echo
pause 1.2

# ── WebSocket actor ──────────────────────────────────────────────────────
hdr "WebSocket — named actor, room join, receive broadcast"
slow "  Each WS connection registers as  user:<name>  in the process actor registry."
slow "  /join <room>  tracks membership in a singleton conc actor."
slow "  HTTP POST /say  broadcasts by looking up every actor in the room."
echo
pause 0.8

mkfifo "$ALICE_PIPE"
websocat ws://127.0.0.1:9100/ws/alice < "$ALICE_PIPE" > "$ALICE_OUT" 2>/dev/null &
ALICE_PID=$!
exec 3>"$ALICE_PIPE"
sleep 0.8

cmd "# alice  →  ws://127.0.0.1:9100/ws/alice"
echo "/join general" >&3
pause 0.4
echo "  alice  →  ${BOLD}/join general${RESET}"
resp=$(wait_line "$ALICE_OUT" 1)
echo "  alice  ←  $resp"
echo
pause 1.0

# ── REST ────────────────────────────────────────────────────────────────
hdr "REST — rooms, users, broadcast, DM, server-rendered history"
echo
pause 0.5

cmd "curl -s http://127.0.0.1:9000/rooms | jq"
pause 0.4
curl -s http://127.0.0.1:9000/rooms | jq
echo
pause 0.8

cmd "curl -s http://127.0.0.1:9000/users | jq"
pause 0.4
curl -s http://127.0.0.1:9000/users | jq
echo
pause 0.8

# Broadcast via HTTP → alice receives it over WS
cmd "curl -sX POST http://127.0.0.1:9000/say \\"
echo "     -H 'content-type: application/json' \\"
echo "     -d '{\"room\":\"general\",\"from\":\"ops\",\"body\":\"deploy in 5 min\"}' | jq"
pause 0.4
curl -sX POST http://127.0.0.1:9000/say \
  -H 'content-type: application/json' \
  -d '{"room":"general","from":"ops","body":"deploy in 5 min"}' | jq
echo
resp=$(wait_line "$ALICE_OUT" 2)
echo "  alice  ←  $resp"
echo
pause 0.8

# Direct message
cmd "curl -sX POST http://127.0.0.1:9000/dm/alice \\"
echo "     -H 'content-type: application/json' \\"
echo "     -d '{\"from\":\"system\",\"body\":\"session ends in 1h\"}' | jq"
pause 0.4
curl -sX POST http://127.0.0.1:9000/dm/alice \
  -H 'content-type: application/json' \
  -d '{"from":"system","body":"session ends in 1h"}' | jq
echo
resp=$(wait_line "$ALICE_OUT" 3)
echo "  alice  ←  $resp"
echo
pause 0.8

# Server-rendered history
cmd "curl -s http://127.0.0.1:9000/history.html"
pause 0.4
curl -s http://127.0.0.1:9000/history.html
echo
pause 1.5

exec 3>&-

# ── Summary ─────────────────────────────────────────────────────────────
hr
echo
echo "  ${BOLD}${GREEN}DONE${RESET}"
echo
echo "  HTTP :9000  +  WebSocket :9100  in one process."
echo "  Named actors. Room membership. HTTP→WS broadcast. DM. Server-rendered HTML."
echo "  9 effects declared and verified before a byte ran."
echo
hr
echo
