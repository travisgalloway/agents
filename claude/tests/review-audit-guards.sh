#!/usr/bin/env bash
# review-audit-guards.sh — the invariants the review lenses and /audit cannot be allowed to lose.
#
# The four lens commands (/design-audit, /api-audit, /requirements-audit, /ux-audit) and the
# umbrella /audit create issues in bulk behind one gate, as /closure-audit does. Four failure shapes
# are specific to them, and each one reads as success:
#
#   1. An UNSTABLE finding ID. An ID hashed over a line number changes after any edit above the
#      finding, so every rerun files a duplicate issue for a defect already ticketed.
#   2. A LEAKED dev server. /ux-audit starts the app. A PID taken any way other than `$!` on the
#      starting line, or a kill aimed at the process group, either misses the server or ends the
#      shell that runs the stop block.
#   3. A TRUNCATED fetch. `gh issue list` defaults to --limit 30, so a requirements pass silently
#      verifies 30 closures and reports the rest as fine.
#   4. A LOST DISPOSITION. The lenses never close or reopen an issue and never create a label
#      outside the gate.
#
# Blocks are extracted from the markdown and run under zsh, the shell that actually runs them.
# No network: nothing here calls gh.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
REFS="$ROOT/skills/audit/references"
METHOD="$REFS/review-method.md"
UMBRELLA="$ROOT/skills/audit/SKILL.md"
LENSES="design api requirements ux"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/review-audit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

strip_comments() { sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#[[:space:]].*$//'; }

section "The interpreter these blocks are checked under"
assert_block_shell "$BLOCK_SHELL"

section "The files exist"
MISSING=0
for f in "$UMBRELLA" "$METHOD"; do
  if [ -f "$f" ]; then ok "present: ${f#$ROOT/}"; else bad "MISSING: ${f#$ROOT/}"; MISSING=1; fi
done
for l in $LENSES; do
  for f in "$ROOT/skills/$l-audit/SKILL.md" "$REFS/$l.md"; do
    if [ -f "$f" ]; then ok "present: ${f#$ROOT/}"; else bad "MISSING: ${f#$ROOT/}"; MISSING=1; fi
  done
done
[ "$MISSING" -eq 0 ] || { summary; exit 1; }

MSRC=$(cat "$METHOD")
USRC=$(cat "$UMBRELLA")

# ---------------------------------------------------------------- 1. stable finding ID
section "The finding ID survives an unrelated edit"

IDB=$(extract_block "$METHOD" 'shasum')
if [ -n "$IDB" ]; then
  ok "extracted the finding-ID fence"
  IDCODE=$(printf '%s' "$IDB" | strip_comments)
  assert_contains "hash input is rule|file|symbol" "$IDCODE" '"${rule}|${file}|${symbol}"'
  # The needle is the word, not a variable name, so `$line`, `$lineno` and `${line}` all fail it.
  assert_not_contains "hash input carries no line number" "$IDCODE" 'line'
  printf '%s\n' "$IDB" > "$WORK/id.sh"
  run_id() { "$BLOCK_SHELL" -c "prefix=DSN rule=$1 file=$2 symbol=$3; . '$WORK/id.sh'; print -r -- \$id"; }
  a=$(run_id layering-violation src/ui/list.ts renderList)
  b=$(run_id layering-violation src/ui/list.ts renderList)
  c=$(run_id layering-violation src/ui/list.ts renderGrid)
  assert_eq "same inputs give the same ID" "$a" "$b"
  if printf '%s' "$a" | grep -qE '^DSN-[0-9a-f]{8}$'; then ok "ID has the prefix-8hex shape: $a"
  else bad "ID shape is wrong" "$a"; fi
  if [ "$a" != "$c" ]; then ok "a different symbol gives a different ID"
  else bad "two symbols collided on one ID" "$a"; fi
else
  bad "no finding-ID fence found — every check in this section is void"
fi
assert_contains "the method names the ID as the idempotency key" "$MSRC" \
  "The finding ID is what makes a rerun idempotent"

# ---------------------------------------------------------------- 2. the dev server
section "The UX live pass ends the server it starts"

UX="$REFS/ux.md"
START=$(extract_block "$UX" 'nohup')
STOP=$(extract_block "$UX" 'pgrep -P')
if [ -n "$START" ]; then
  SCODE=$(printf '%s' "$START" | strip_comments)
  assert_contains "PID comes from \$! on the starting line" "$SCODE" '& srv_pid=$!'
  assert_not_contains "start fence never uses jobs -p" "$SCODE" 'jobs -p'
else
  bad "no server-start fence found"
fi
if [ -n "$STOP" ]; then
  TCODE=$(printf '%s' "$STOP" | strip_comments)
  # Without job control the background job shares the caller's process group, so a group kill
  # ends the shell running this block along with the server.
  assert_not_contains "stop fence never signals a process group" "$TCODE" 'kill -TERM -- "-'
  assert_not_contains "stop fence never uses jobs -p" "$TCODE" 'jobs -p'

  # Behavioral: a server that spawns a grandchild, as `npm run dev` does. Every PID must be gone.
  "$BLOCK_SHELL" -c '
    nohup sh -c "sleep 300 & sleep 300; wait" >/dev/null 2>&1 & srv_pid=$!
    sleep 1
    printf "%s\n" "$srv_pid" > "'"$WORK"'/srv.pid"
    pgrep -P "$srv_pid" | tr "\n" " " > "'"$WORK"'/kids"
  '
  srv_pid=$(cat "$WORK/srv.pid"); kids=$(cat "$WORK/kids")
  if [ -n "$kids" ]; then ok "fixture spawned children: $kids"
  else bad "fixture spawned no children — the behavioral check below is void"; fi
  printf '%s\n' "$STOP" > "$WORK/stop.sh"
  "$BLOCK_SHELL" -c "srv_pid=$srv_pid; . '$WORK/stop.sh'" >/dev/null 2>&1
  left=""
  for p in $srv_pid $kids; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
  if [ -z "$left" ]; then ok "stop fence ended the server and its children"
  else bad "processes survived the stop fence" "$left"; for p in $left; do kill -KILL "$p" 2>/dev/null; done; fi
else
  bad "no server-stop fence found"
fi
assert_contains "ux-audit ends the server on every path" "$(cat "$ROOT/skills/ux-audit/SKILL.md")" \
  "End the server before returning, on every path."
assert_contains "the umbrella carries the same rule" "$USRC" \
  "the server ended before it returns, on every path."
assert_contains "an unreachable app makes U2 BLIND" "$(cat "$UX")" "U2 is BLIND"
assert_contains "auth-gated routes are UNAUDITED" "$(cat "$UX")" "is UNAUDITED, never clean"

# ---------------------------------------------------------------- 3. truncation
section "No backlog fetch can silently truncate"

check_fetch() {   # check_fetch <file> <label> <state>
  local fb code
  fb=$(extract_block "$1" 'gh issue list')
  if [ -z "$fb" ]; then bad "$2: no gh issue list fence found"; return; fi
  code=$(printf '%s' "$fb" | strip_comments)
  assert_contains "$2: fetch raises the limit off gh's default 30" "$code" "--limit 1000"
  assert_contains "$2: fetch is --state $3" "$code" "--state $3"
  assert_contains "$2: fetch asks for stateReason" "$code" "stateReason"
}
check_fetch "$METHOD" "review-method" all
check_fetch "$REFS/requirements.md" "requirements" closed
assert_contains "review-method states the truncation rule" "$MSRC" \
  "A result exactly equal to \`--limit\` is truncation."
assert_contains "requirements states the truncation rule" "$(cat "$REFS/requirements.md")" \
  "A result exactly equal to \`--limit\` is truncation."
assert_contains "requirements filters after the fetch" "$(cat "$REFS/requirements.md")" \
  "after the fetch, never before it"
assert_contains "umbrella states the truncation rule" "$USRC" \
  "A result exactly equal to \`--limit\` is truncation."

# ---------------------------------------------------------------- 4. dispositions, per command
section "Every command keeps the gate invariants"

for f in "$UMBRELLA" "$ROOT"/skills/{design,api,requirements,ux}-audit/SKILL.md; do
  n=$(basename "$(dirname "$f")"); S=$(cat "$f")
  assert_contains "$n: user-invoked only" "$S" "disable-model-invocation: true"
  assert_contains "$n: BLIND rule" "$S" "reports BLIND, never clean"
  assert_contains "$n: one gate" "$S" "This is the only gate."
  assert_contains "$n: dry-run stops before the gate" "$S" "\`dry-run\` stops after Step 5."
  assert_contains "$n: never closes or reopens" "$S" "**Never closes or reopens an issue.**"
  assert_contains "$n: no label outside the gate" "$S" "**Never creates a label outside the gate.**"
  assert_contains "$n: idempotency is the acceptance test" "$S" "must propose **zero creates**"
  assert_contains "$n: no blind retry" "$S" "Do not retry the whole batch."
  assert_contains "$n: unknown tokens are errors" "$S" "hard usage error"
  assert_contains "$n: unverified, never none" "$S" "**unverified**, never \`none\`"
  SB=$(extract_block "$f" 'status --porcelain')
  if [ -n "$SB" ]; then assert_not_contains "$n: summary fence keeps exit status" "$SB" "|| true"
  else bad "$n: no summary fence found"; fi
done

# A bare needle, never scoped to fences: prose that tells the model to close is as bad as code.
for f in "$UMBRELLA" "$ROOT"/skills/{design,api,requirements,ux}-audit/SKILL.md "$REFS"/*.md; do
  n=${f#$ROOT/skills/}
  assert_not_contains "$n: no gh issue close" "$(cat "$f")" "gh issue close"
  assert_not_contains "$n: no gh issue reopen" "$(cat "$f")" "gh issue reopen"
done

section "Each lens command loads its own method"
for l in $LENSES; do
  S=$(cat "$ROOT/skills/$l-audit/SKILL.md")
  assert_contains "$l-audit reads review-method.md" "$S" "skills/audit/references/review-method.md"
  assert_contains "$l-audit reads $l.md" "$S" "skills/audit/references/$l.md\` first."
done

# ---------------------------------------------------------------- 5. the umbrella's waves
section "The umbrella stays within five agents per wave"

assert_contains "wave cap is stated" "$USRC" "At most five parallel \`Agent\` calls per wave"
for w in 1 2; do
  row=$(printf '%s\n' "$USRC" | grep -E "^\| \*\*$w\*\* \|" | head -1)
  if [ -z "$row" ]; then bad "wave $w: no table row found"; continue; fi
  # Second cell, parentheticals removed, then count the comma-separated items.
  cell=$(printf '%s' "$row" | awk -F'|' '{print $3}' | sed -E 's/\([^)]*\)//g')
  items=$(printf '%s' "$cell" | tr ',' '\n' | grep -c '[A-Za-z]')
  if [ "$items" -ge 1 ] && [ "$items" -le 5 ]; then ok "wave $w dispatches $items agents"
  else bad "wave $w dispatches $items agents, cap is 5" "$cell"; fi
done
assert_contains "closure runs before the lenses that read it" "$USRC" \
  "requirements and design D1 read closure's results"
assert_contains "cross-lens dedupe is stated" "$USRC" "Dedupe across lenses by \`file\` + \`symbol\`."

# ---------------------------------------------------------------- 6. every fence parses
section "Every fence in the new files parses under $BLOCK_SHELL"
i=0; PARSE_FAIL=0
for f in "$UMBRELLA" "$ROOT"/skills/{design,api,requirements,ux}-audit/SKILL.md "$REFS"/*.md; do
  rm -f "$WORK"/b_*.sh
  awk -v dir="$WORK" '
    /^[ \t]*```bash[ \t]*$/ { inb=1; nb++; fn=sprintf("%s/b_%02d.sh", dir, nb); next }
    /^[ \t]*```[ \t]*$/ { inb=0; next }
    inb { print > fn }
  ' "$f"
  for b in "$WORK"/b_*.sh; do
    [ -f "$b" ] || continue
    i=$((i+1))
    sed -E -e 's/<[A-Za-z_][^ >]*>/PLACEHOLDER/g' -e 's/\{[A-Za-z_][A-Za-z_0-9]*\}/PLACEHOLDER/g' \
      "$b" > "$b.norm"
    "$BLOCK_SHELL" -n "$b.norm" 2>/dev/null || { PARSE_FAIL=$((PARSE_FAIL+1)); bad "fence does not parse" "${f#$ROOT/}"; }
  done
done
if [ "$i" -eq 0 ]; then bad "extracted NO fences — the check is void"
else [ "$PARSE_FAIL" -eq 0 ] && ok "all $i fences parse under $BLOCK_SHELL"; fi

summary
