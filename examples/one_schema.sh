#!/usr/bin/env bash
# Theatrical demo -- lex-web: one schema, every artifact
#
# Shows a single lex-schema ModelSchema driving validation, query
# building, DDL generation, TypeScript codegen, and Python codegen --
# vs the Python stack where each artifact requires its own file.
#
# Usage:   bash examples/one_schema.sh
#          asciinema rec examples/one_schema.cast -c "bash examples/one_schema.sh" --overwrite
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
LEX="${LEX:-lex}"

BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'

slow() { echo "$@" | pv -qL 55 2>/dev/null || echo "$@"; }
pause() { sleep "${1:-1.2}"; }
hr()  { printf '%s' "$DIM"; printf -- '-%.0s' {1..72}; printf '%s\n' "$RESET"; }
hdr() { echo; hr; echo "  ${BOLD}${CYAN}$*${RESET}"; hr; echo; }
cmd() { echo "${BOLD}${BLUE}\$${RESET}  $*"; pause 0.4; }

# Write the formatter to a temp file so it can receive pipe input.
TMP_FMT=$(mktemp /tmp/lex_fmt_XXXXXX.py)
cat > "$TMP_FMT" <<'PYEOF'
import sys, re

data = sys.stdin.read()

# lex's ln() helper outputs "text\n"; io.print separates calls with
# two trailing spaces. Since we use ln(), the output has proper \n.
# This formatter just adds blank lines around key markers for
# visual breathing room.

lines = data.split('\n')

out = []
for line in lines:
    stripped = line.strip()
    # Strip the trailing "null" lex appends at end of main
    if stripped == 'null':
        continue
    # Add blank line before section headings
    if re.match(r'\s+--\s+\S', line) and out and out[-1] != '':
        out.append('')
    # Add blank line before arrow lines
    if stripped.startswith('->') and out and out[-1] != '':
        out.append('')
    out.append(line)

# Collapse triple+ blank lines to at most two
collapsed = []
blank_run = 0
for l in out:
    if l.strip() == '':
        blank_run += 1
        if blank_run <= 2:
            collapsed.append(l)
    else:
        blank_run = 0
        collapsed.append(l)

# Strip trailing blanks
while collapsed and collapsed[-1].strip() == '':
    collapsed.pop()

sys.stdout.write('\n'.join(collapsed) + '\n')
PYEOF

cleanup() { rm -f "$TMP_FMT"; }
trap cleanup EXIT

fmt() { python3 "$TMP_FMT"; }

clear
echo
echo "  ${BOLD}lex-web${RESET}  .  one schema, every artifact"
echo "  ${DIM}One ModelSchema. Six artifacts. Zero duplication.${RESET}"
echo
sleep 1.5

# ── The schema ───────────────────────────────────────────────────────
hdr "The Order schema -- defined exactly once"
slow "  Six fields. Constraints inline. No separate Pydantic model,"
slow "  no SQLAlchemy class, no Alembic migration, no tsc plugin."
echo
pause 0.8

cmd "grep -A14 'fn order_schema()' examples/one_schema.lex"
pause 0.3
grep -A14 'fn order_schema()' examples/one_schema.lex | head -14
echo
pause 1.5

# ── lex check ────────────────────────────────────────────────────────
hdr "lex check -- type + effect verification at compile time"
echo
pause 0.5
cmd "lex check examples/one_schema.lex"
pause 0.4
"$LEX" check examples/one_schema.lex
echo "${GREEN}${BOLD}ok${RESET}  -- schema, queries, DDL, codegen: all verified"
echo
pause 1.5

# ── Run the demo ─────────────────────────────────────────────────────
hdr "lex run -- all six artifacts from one schema"
slow "  No HTTP server. Pure io output."
slow "  All ORM builders and codegen emitters are pure functions."
echo
pause 0.8

cmd "lex run --allow-effects fs_write,io,sql examples/one_schema.lex main"
echo
pause 0.4
"$LEX" run --allow-effects fs_write,io,sql examples/one_schema.lex main 2>&1 | fmt
echo
pause 2.0

# ── Summary ──────────────────────────────────────────────────────────
hr
echo
echo "  ${BOLD}${GREEN}DONE${RESET}"
echo
echo "  One schema. In Python: Pydantic model + SQLAlchemy class +"
echo "  Alembic migration + manual TypeScript types + FastAPI auto-gen."
echo "  In Lex: order_schema() -- written once, derived everywhere."
echo
hr
echo
