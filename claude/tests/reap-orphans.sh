#!/usr/bin/env bash
# reap-orphans.sh (test) — pin the selection rules and the silence of hooks/reap-orphans.sh.
#
# Real orphans are made with `( cmd & )`: the subshell exits immediately and the child is
# reparented to init. macOS has no `setsid`, and this is equivalent for our purposes.
#
# Every fixture lives under a fake root in $TMPDIR. REAP_ROOTS is overridden to point there,
# so this suite can never select a real process from ~/github.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

HOOK="$HOME/.claude/hooks/reap-orphans.sh"
[ -f "$HOOK" ] || { bad "hook not found at $HOOK"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/reap.XXXXXX")
ROOT="$WORK/fakeproj"; mkdir -p "$ROOT/bin"
OUTSIDE="$WORK/elsewhere"; mkdir -p "$OUTSIDE/bin"

SPAWNED=""
cleanup() {
  # `disown` first: killing a still-tracked background job makes the shell print a
  # "Killed: 9" job-control line to stderr after the summary, which reads like a failure.
  for p in $SPAWNED; do
    disown "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Fixtures are SYMLINKS to a real system binary, invoked through the symlink path.
#
# Two dead ends this avoids:
#   - Copying /bin/sleep breaks its code signature and the kernel SIGKILLs it on exec, so the
#     fixture vanishes before the test can look at it.
#   - A wrapper script that `exec`s something replaces argv[0], losing the path under test.
#
# Executing a symlink keeps argv[0] as the symlink path while the kernel runs the real signed
# binary — which is precisely the shape of the workerd orphans this hook exists to catch
# (argv[0] = /Users/.../node_modules/.../bin/workerd). `tail -f` blocks forever with no child
# process, so nothing is left behind when the fixture is killed.
BLOCKER=/usr/bin/tail
ln -sf "$BLOCKER" "$ROOT/bin/fake-server"
ln -sf "$BLOCKER" "$ROOT/bin/claude"         # protected AND under a root: protect must win
ln -sf "$BLOCKER" "$OUTSIDE/bin/other-server"

# spawn_orphan <exe> [args...] -> pid. The subshell exits, so the child reparents to init.
#
# The >/dev/null 2>&1 on the child is REQUIRED, not tidiness: without it the background process
# inherits this function's stdout, which under `p=$(spawn_orphan …)` is the command-substitution
# pipe. Substitution reads until every writer closes, so the caller would block for the child's
# entire lifetime. That deadlock hung this suite until the redirect was added.
spawn_orphan() {
  local exe="$1"; shift
  ( "$exe" "$@" >/dev/null 2>&1 & echo $! > "$WORK/.pid" )
  local p; p=$(cat "$WORK/.pid"); SPAWNED="$SPAWNED $p"; echo "$p"
}

# Run the hook against our fake root only.
run() {
  REAP_CONF=/dev/null REAP_ROOTS="$ROOT $OUTSIDE" \
  REAP_PROTECT='claude|mcp@latest' REAP_MIN_AGE="${MIN_AGE:-0}" \
  bash "$HOOK" "$@" 2>/dev/null
}

alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

# ---------------------------------------------------------------------------------
section "Silence when there is nothing to reap (SessionStart context-cost guard)"
# Point at an empty root so nothing can match.
out=$(REAP_CONF=/dev/null REAP_ROOTS="$WORK/nothing-here" REAP_MIN_AGE=0 bash "$HOOK" 2>/dev/null)
assert_eq "dry run prints zero bytes"  "" "$out"
out=$(REAP_CONF=/dev/null REAP_ROOTS="$WORK/nothing-here" REAP_MIN_AGE=0 bash "$HOOK" --kill 2>/dev/null)
assert_eq "--kill prints zero bytes"   "" "$out"
assert_rc "exits 0 with nothing to do" 0 \
  env REAP_CONF=/dev/null REAP_ROOTS="$WORK/nothing-here" bash "$HOOK"

# ---------------------------------------------------------------------------------
section "Selects an orphan whose argv[0] is under a root (the workerd shape)"
p_exe=$(spawn_orphan "$ROOT/bin/fake-server" -f /dev/null)
sleep 1
assert_eq "reparented to init" "1" "$(ps -p "$p_exe" -o ppid= | tr -d ' ')"
assert_contains "listed in dry run" "$(run)" "$p_exe"
assert_eq "dry run did not kill it" "yes" "$(alive "$p_exe")"

section "Selects an orphan whose argv carries a root path (argv[0] outside)"
touch "$ROOT/server.log"
p_argv=$(spawn_orphan "$BLOCKER" -f "$ROOT/server.log")
sleep 1
assert_eq "argv[0] is genuinely outside the root" "$BLOCKER" \
  "$(ps -p "$p_argv" -o command= | awk '{print $1}')"
assert_contains "argv-matched orphan is listed" "$(run)" "$p_argv"

section "Ignores an orphan outside every root"
p_out=$(spawn_orphan "$OUTSIDE/bin/other-server" -f /dev/null)
sleep 1
out=$(REAP_CONF=/dev/null REAP_ROOTS="$ROOT" REAP_PROTECT='claude' REAP_MIN_AGE=0 \
      bash "$HOOK" 2>/dev/null)
assert_not_contains "not listed when its tree is not a root" "$out" "$p_out"

section "Protect list beats a root match"
p_prot=$(spawn_orphan "$ROOT/bin/claude" -f /dev/null)
sleep 1
assert_contains "fixture really is under a root" "$(ps -p "$p_prot" -o command=)" "$ROOT"
assert_not_contains "protected orphan is not listed" "$(run)" "$p_prot"

section "Ignores an orphan younger than REAP_MIN_AGE"
p_young=$(spawn_orphan "$ROOT/bin/fake-server" -f /dev/null)
sleep 1
out=$(REAP_CONF=/dev/null REAP_ROOTS="$ROOT" REAP_PROTECT='claude' REAP_MIN_AGE=3600 \
      bash "$HOOK" 2>/dev/null)
assert_not_contains "too-young orphan is not listed" "$out" "$p_young"

section "Ignores a process with a LIVE parent, even under a root"
"$ROOT/bin/fake-server" -f /dev/null >/dev/null 2>&1 &
p_child=$!; SPAWNED="$SPAWNED $p_child"
sleep 1
assert_eq "parent is this shell, not init" "$$" "$(ps -p "$p_child" -o ppid= | tr -d ' ')"
assert_not_contains "child of a live parent is not listed" "$(run)" "$p_child"

# ---------------------------------------------------------------------------------
section "--kill actually reaps, and leaves the protected/live ones alone"
before_live=$(alive "$p_child")
run --kill >/dev/null
sleep 1
assert_eq "argv[0]-matched orphan died" "no"  "$(alive "$p_exe")"
assert_eq "argv-matched orphan died"    "no"  "$(alive "$p_argv")"
assert_eq "protected orphan survived"   "yes" "$(alive "$p_prot")"
assert_eq "live-parent child survived"  "$before_live" "$(alive "$p_child")"

section "Reap reports exactly one line, only when it did something"
p2=$(spawn_orphan "$ROOT/bin/fake-server" -f /dev/null); sleep 1
out=$(run --kill)
assert_eq "one line of output" "1" "$(printf '%s' "$out" | grep -c .)"
assert_contains "names the process count" "$out" "reap-orphans: reaped"
# Threads are what the user sees in Activity Monitor, so the summary is denominated in them.
assert_contains "names a thread count" "$out" "threads"
printf '%s' "$out" | grep -qE '~[1-9][0-9]* threads' \
  && ok "thread count is a real non-zero number" \
  || bad "thread count is missing or zero" "$out"
out=$(run --kill)
assert_eq "second pass is silent" "" "$out"

section "--quiet suppresses the dry-run listing"
p3=$(spawn_orphan "$ROOT/bin/fake-server" -f /dev/null); sleep 1
assert_eq "quiet dry run prints nothing" "" "$(run --quiet)"
assert_eq "and still killed nothing"     "yes" "$(alive "$p3")"

summary
