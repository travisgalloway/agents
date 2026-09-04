#!/usr/bin/env bash
# Shared assertions for ~/.claude/tests/*.sh
# Source this; do not execute it.

PASS=0; FAIL=0
_g() { printf '\033[32m%s\033[0m' "$1"; }
_r() { printf '\033[31m%s\033[0m' "$1"; }
_d() { printf '\033[2m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS+1)); printf '  %s %s\n' "$(_g ✓)" "$1"; }
# Detail is truncated: assertions often compare against whole files, and an untruncated
# haystack buries every other result in the run.
bad()  {
  FAIL=$((FAIL+1)); printf '  %s %s\n' "$(_r ✗)" "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$(_d "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-160)")"
  return 0
}

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# assert_rc <label> <expected_rc> <cmd...>
assert_rc() {
  local label="$1" want="$2"; shift 2
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "expected rc=$want got rc=$got — $out"; fi
}

# assert_contains <label> <haystack> <needle>
assert_contains() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac
}

# assert_not_contains <label> <haystack> <needle>
assert_not_contains() {
  case "$2" in *"$3"*) bad "$1" "still present: $3" ;; *) ok "$1" ;; esac
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# extract_block <file> <needle> — the first ```bash fence whose body contains <needle>,
# de-indented. Lets a suite run the very script the model reads, so a doc/behavior
# divergence fails here instead of in production. Fences nested inside numbered lists are
# indented, hence the de-indent.
# BLOCK_SHELL — the interpreter a ```bash fence in a SKILL.md actually runs under. Claude Code's
# Bash tool runs the user's LOGIN SHELL (zsh here), not bash. The two disagree: `[ "$a" \> "$b" ]`
# is a string comparison in bash and `condition expected: >` (rc=2) in zsh. A suite that extracts
# the block the model reads and then runs it with `bash` tests the right file under an interpreter
# it never sees — which is exactly how the /automerge §2.4 review wait shipped green while every
# real run rode to its 15-minute cap. hooks/*.sh and lib/*.sh are exempt: they carry a shebang.
BLOCK_SHELL=${BLOCK_SHELL:-zsh}

# assert_block_shell <shell> — a missing interpreter is a FAILED assertion, never a silent skip;
# "could not check" must not read the same as "checked and clean".
assert_block_shell() {
  if command -v "$1" >/dev/null 2>&1; then ok "block interpreter available: $1"
  else bad "block interpreter MISSING: $1 — markdown blocks go untested under the runtime shell"; fi
}

extract_block() {
  awk -v needle="$2" '
    /^[ \t]*```bash[ \t]*$/ { inb=1; buf=""; match($0, /^[ \t]*/); ind=RLENGTH; next }
    /^[ \t]*```[ \t]*$/ {
      if (inb) { if (index(buf, needle)) { printf "%s", buf; exit } inb=0; buf="" }
      next
    }
    inb { line=$0; if (ind>0) line=substr($0, ind+1); buf = buf line "\n" }
  ' "$1"
}

summary() {
  printf '\n'
  if [ "$FAIL" -eq 0 ]; then
    printf '%s %d passed\n' "$(_g PASS)" "$PASS"; return 0
  else
    printf '%s %d passed, %d failed\n' "$(_r FAIL)" "$PASS" "$FAIL"; return 1
  fi
}
