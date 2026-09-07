#!/usr/bin/env bash
# skill-blocks-portability.sh — every ```bash fence in the locally-authored skills and agents
# must be runnable by the shell that actually runs it.
#
# THE BUG: Claude Code's Bash tool runs the user's LOGIN SHELL — zsh — not bash. A fence
# written in bash-only dialect is not a style problem; it is a runtime error in production.
# `/automerge` §2.4 once decided "the review is newer than the push" with
# `[ "$latest" \> "$pushed_at" ]`. zsh's `[` has no `>` operator, so that line was rc=2 on
# every iteration, the "done" branch never fired, and every run rode to the 15-minute cap and
# stopped. It read as correct, and the suite that extracts and runs that very block ran it
# under bash, where it works.
#
# `automerge-merge-gate.sh` and `work-probes.sh` now run their extracted blocks under zsh, but
# they only cover three fences. This suite covers the rest, with two checks that catch
# different halves of the problem:
#
#   1. a grep lint for constructs that PARSE in zsh and misbehave at runtime — `zsh -n` cannot
#      see these, and the run-killer above is one of them;
#   2. `zsh -n` on every block, which catches the parse-level bashisms the grep list misses.
#
# Vendored skills (cloudflare*, wrangler, agents-sdk, …) are out of scope: their fences are
# documentation snippets, not scripts anyone runs from here.
#
# No network. Nothing is executed — only parsed.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

# CLAUDE_ROOT is overridable so the suite can be pointed at a scratch copy — that is how you
# prove the lint still bites (reintroduce the bad form in a copy, watch this fail).
ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
# A DENYLIST, not an allowlist: a new locally-authored skill is covered the day it lands. Only
# vendored skills are skipped — their fences are documentation snippets (`wrangler deploy
# <VERSION_ID>`), not scripts run from here, and linting them is pure noise.
VENDORED="agents-sdk cloudflare cloudflare-email-service cloudflare-one cloudflare-one-migrations
durable-objects sandbox-sdk turnstile-spin web-perf workers-best-practices wrangler"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/skill-blocks.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

section "The interpreter these blocks are checked under"
assert_block_shell "$BLOCK_SHELL"

# ---------------------------------------------------------------- collect the source files
FILES=""; SKIPPED=""
for d in "$ROOT"/skills/*/; do
  s=$(basename "$d")
  case " $(echo $VENDORED) " in *" $s "*) SKIPPED="$SKIPPED $s"; continue ;; esac
  f="$d/SKILL.md"
  if [ -f "$f" ]; then FILES="$FILES $f"; else bad "skill dir with no SKILL.md: $d"; fi
  # Progressively-disclosed reference files count too. `feature-closure` is the first local
  # skill with a references/ dir, and without this glob its markdown would be the only prose
  # in the tree no suite lints — a fence added there later would ship unchecked. The glob is
  # nullglob-unsafe in the general case, hence the -f guard: an absent references/ leaves the
  # literal pattern, which is not a file and is skipped.
  for r in "$d"references/*.md; do
    [ -f "$r" ] && FILES="$FILES $r"
  done
done
for f in "$ROOT"/agents/*.md; do
  [ -f "$f" ] && FILES="$FILES $f"
done

# ---------------------------------------------------------------- extract every ```bash fence
# Same fence shape as extract_block in lib.sh, but every block, and each one carries its
# source file and starting line so a failure names a place in the markdown, not a temp path.
i=0
for f in $FILES; do
  i=$((i+1))
  awk -v out="$WORK" -v pre="$i" -v src="$f" '
    /^[ \t]*```bash[ \t]*$/ {
      inb=1; match($0, /^[ \t]*/); ind=RLENGTH; nb++
      fn=sprintf("%s/%03d_%02d.sh", out, pre, nb)
      printf "%s:%d", src, NR+1 > (fn ".src")
      next
    }
    /^[ \t]*```[ \t]*$/ { inb=0; next }
    inb { line=$0; if (ind>0) line=substr($0, ind+1); print line > fn }
  ' "$f"
done

BLOCKS=0
for b in "$WORK"/*.sh; do [ -f "$b" ] && BLOCKS=$((BLOCKS+1)); done

# A glob that matches nothing runs zero checks and reports success — count and assert.
if [ "$BLOCKS" -gt 0 ]; then
  ok "extracted $BLOCKS bash blocks from $(echo $FILES | wc -w | tr -d ' ') files"
  ok "skipped $(echo $SKIPPED | wc -w | tr -d ' ') vendored skills:$SKIPPED"
else bad "extracted NO blocks — the fence pattern broke; every check below is void"; summary; exit 1; fi

# Sentinels: two fences known to exist. If the extractor silently starts missing bodies, the
# lint below goes quiet and reads as clean.
FOUND_MERGE=0; FOUND_PROBE=0
for b in "$WORK"/*.sh; do
  grep -q 'gh pr merge {number} --squash' "$b" && FOUND_MERGE=1
  grep -q 'rev-parse --git-dir' "$b" && FOUND_PROBE=1
done
assert_eq "found the /automerge merge fence" "1" "$FOUND_MERGE"
assert_eq "found the /work arm-time probe fence" "1" "$FOUND_PROBE"

# ---------------------------------------------------------------- 1. runtime-trap grep lint
# pattern<TAB>why. Each of these parses fine under zsh and then does the wrong thing, so
# `zsh -n` below will never catch them.
cat > "$WORK/traps.tsv" <<'EOF'
\[[^]]*\\[<>]	[ a \> b ] — zsh has no > / < operator in [ ] (rc=2); use [[ a > b ]]
\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^)	${v,,} / ${v^^} case modification is bash-only
\b(mapfile|readarray)\b	mapfile/readarray do not exist in zsh
\bshopt\b	shopt does not exist in zsh (setopt)
\bread -a\b	read -a is read -A in zsh
BASH_SOURCE	BASH_SOURCE is unset in zsh
\$\{[A-Za-z_][A-Za-z_0-9]*\[0\]\}	zsh arrays are 1-indexed — ${a[0]} is empty
EOF

section "Runtime traps zsh -n cannot see"
# Whole-line comments are stripped first: these blocks document their own traps in prose, and
# a construct that is commented out never runs. Line numbers stay aligned (blanked, not removed).
for b in "$WORK"/*.sh; do sed -E 's/^[[:space:]]*#.*$//' "$b" > "$b.code"; done

HITS=0
while IFS="$(printf '\t')" read -r pat why; do
  [ -n "$pat" ] || continue
  for b in "$WORK"/*.sh; do
    m=$(grep -nE "$pat" "$b.code" 2>/dev/null) || continue
    HITS=$((HITS+1))
    # .src is file:first-body-line, so the true line is that plus the in-block offset.
    src=$(cat "$b.src" 2>/dev/null); text=$(printf '%s' "$m" | head -1)
    printf -v where '%s:%d' "${src%:*}" "$(( ${src##*:} + ${text%%:*} - 1 ))"
    bad "$why" "$where → ${text#*:}"
  done
done < "$WORK/traps.tsv"
[ "$HITS" -eq 0 ] && ok "no bash-only runtime constructs in $BLOCKS blocks"

# ------------------------------------------------- 1b. unquoted {branch}/{tree} placeholders
# NOT a traps.tsv row: POSIX ERE has no lookbehind, so it cannot tell `"{branch}"` from
# `{branch}` and every correctly-quoted site reports as a violation. Blank out double-quoted
# spans first, then anything left is genuinely unquoted.
#
# THE BUG THIS CATCHES: zsh glob-expands parentheses. A scoped conventional branch name —
# `feat(api)/42-x` — substituted into an unquoted placeholder is `no matches found`, rc=1.
# `zsh -n` returns clean because it is a RUNTIME failure, and the worst site is /work's
# arm-time monitor probe: rc=1 there means the monitor refuses to arm and every stage on that
# branch is a blocker that reads like a healthy refusal.
section "Branch placeholders are quoted (zsh globs the ( ) in feat(api)/42-x)"
PH=0
for b in "$WORK"/*.sh; do
  sed -e 's/"[^"]*"/QQ/g' "$b.code" > "$b.unq"
  m=$(grep -nE '\{(branch|branch_name|tree|plan_file)\}' "$b.unq" 2>/dev/null) || continue
  PH=$((PH+1))
  src=$(cat "$b.src" 2>/dev/null); text=$(printf '%s' "$m" | head -1)
  printf -v where '%s:%d' "${src%:*}" "$(( ${src##*:} + ${text%%:*} - 1 ))"
  bad "unquoted branch placeholder — quote it" "$where → ${text#*:}"
done
[ "$PH" -eq 0 ] && ok "all {branch}/{tree}/{plan_file} placeholders are quoted"

# ---------------------------------------------------------------- 2. zsh -n on every block
# Doc placeholders first: zsh parses `<branch>` as a redirection, and `{number}` is not a word
# it can evaluate. Both are documentation, not dialect.
section "Every block parses under $BLOCK_SHELL"
PARSE_FAILS=0
for b in "$WORK"/*.sh; do
  sed -E -e 's/<[A-Za-z_][^ >]*>/PLACEHOLDER/g' \
         -e 's/\{[A-Za-z_][A-Za-z_0-9]*\}/PLACEHOLDER/g' "$b" > "$b.norm"
  err=$("$BLOCK_SHELL" -n "$b.norm" 2>&1) && continue
  PARSE_FAILS=$((PARSE_FAILS+1))
  bad "parse error under $BLOCK_SHELL" "$(cat "$b.src" 2>/dev/null) → $err"
done
[ "$PARSE_FAILS" -eq 0 ] && ok "all $BLOCKS blocks parse under $BLOCK_SHELL"

summary
