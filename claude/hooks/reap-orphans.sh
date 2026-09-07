#!/usr/bin/env bash
# reap-orphans.sh — sweep orphaned dev-server processes left behind by project tooling.
#
# THE LEAK: `pnpm dev:web` -> `turbo run dev` (persistent) -> `wrangler dev` -> `workerd`.
# workerd is a GRANDCHILD. When Claude Code stops the background Bash task, or the session is
# killed, or the terminal closes, the kill never reaches it: it reparents to init (ppid=1),
# holds its listening ports, and never exits. Measured on this machine before this script
# existed: 51 orphaned workerd, 1020 threads, 453 MB, 83 listening sockets, oldest 8 days.
#
# WHY ppid==1 MAKES BREADTH SAFE. Several claude sessions run at once, and this script has no
# way to know which one spawned what. It does not need to: a process whose parent is init has
# no living owner by definition. That single test is what lets the reaper be aggressive about
# scope without ever killing a process some other live session depends on.
#
# Registered on SessionStart (startup|resume) and SessionEnd in ~/.claude/settings.json.
#
# TWO NON-OBVIOUS CONSTRAINTS, both from the hooks reference:
#
#   1. SessionStart stdout is INJECTED INTO CLAUDE'S CONTEXT. So this script prints nothing at
#      all on the common path where there is nothing to reap. A chatty version would spend
#      context on every session start forever. tests/reap-orphans.sh asserts the silence.
#
#   2. SessionStart hooks BLOCK and cannot be `async`. So selection is one `ps` call plus
#      string tests — deliberately no `lsof`, no per-process cwd lookup. Registered with
#      `timeout: 15` as a backstop.
#
#      "String tests" means FORK-FREE tests: bash builtins only, no pipelines. The selection
#      loop runs once per ppid==1 process, and macOS launchd leaves hundreds of those, so a
#      single `printf | grep` in the loop body costs ~1.3s — which is how the SessionEnd hook
#      that calls this script ended up exceeding its 1500ms budget and aborting every run.
#      Keep it that way: measure before adding anything to the loop body.
#
# Usage:
#   reap-orphans.sh            dry run — list candidates, kill nothing, exit 0
#   reap-orphans.sh --kill     TERM, brief grace, then KILL
#   reap-orphans.sh --quiet    suppress the dry-run listing (used by the hook wiring)
#
# Exit is always 0. A reaper that fails a session start is worse than a leaked process.

set -u

CONF="${REAP_CONF:-$HOME/.claude/reap-orphans.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${REAP_ROOTS:=$HOME/github}"
: "${REAP_PROTECT:=claude|mcp@latest|[Dd]ocker|colima|postgres|redis|ssh|tmux|screen}"
: "${REAP_MIN_AGE:=120}"

DO_KILL=0
QUIET=0
for a in "$@"; do
  case "$a" in
    --kill)  DO_KILL=1 ;;
    --quiet) QUIET=1 ;;
    --help|-h)
      sed -n '2,30p' "$0"; exit 0 ;;
  esac
done

# etime -> seconds. Formats: SS, MM:SS, HH:MM:SS, DD-HH:MM:SS.
# 10# prefixes are required: "08" is an invalid octal literal in arithmetic context.
etime_secs() {
  local e="$1" d=0 h=0 m=0 s=0 rest
  case "$e" in
    *-*) d="${e%%-*}"; rest="${e#*-}" ;;
    *)   rest="$e" ;;
  esac
  local IFS=:
  # shellcheck disable=SC2086
  set -- $rest
  case $# in
    3) h="$1"; m="$2"; s="$3" ;;
    2) m="$1"; s="$2" ;;
    1) s="$1" ;;
    *) echo 0; return ;;
  esac
  echo $(( 10#${d:-0} * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0} ))
}

# under_root <text> — true when any configured root appears as a path prefix in the text.
under_root() {
  local text="$1" root
  for root in $REAP_ROOTS; do
    [ -n "$root" ] || continue
    case "$text" in *"$root"/*|*"$root") return 0 ;; esac
  done
  return 1
}

# Collect candidates. One ps call; everything after is string work.
#   pid  ppid  uid  etime  command(full argv — argv[0] is the absolute exe path for a
#                                   directly-executed binary, which is what workerd is)
#
# The uid column is filtered explicitly rather than with a ps flag: `ps -Ao … -u $(id -u)`
# silently IGNORES the -u filter when -A is present, and plain `ps -xo` still returns
# root-owned processes attached to the session. Both were measured on this machine; neither
# actually scopes to the current user.
myuid=$(id -u)
candidates=""
count=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # Leading whitespace from ps's right-aligned numeric columns.
  line=${line#"${line%%[![:space:]]*}"}
  pid=${line%% *};  line=${line#* }; line=${line#"${line%%[![:space:]]*}"}
  ppid=${line%% *}; line=${line#* }; line=${line#"${line%%[![:space:]]*}"}
  uid=${line%% *};  line=${line#* }; line=${line#"${line%%[![:space:]]*}"}
  etime=${line%% *}; cmd=${line#* }

  case "$pid$ppid$uid" in ''|*[!0-9]*) continue ;; esac
  [ "$ppid" = 1 ] || continue
  [ "$uid" = "$myuid" ] || continue
  [ "$pid" != "$$" ] || continue

  # Protect list wins over everything else. `[[ =~ ]]` is a builtin and forks nothing; the RHS
  # must stay UNQUOTED or bash matches it as a literal string instead of an ERE. See the fork
  # note in the header — this test runs once per candidate, and on macOS launchd leaves hundreds
  # of ppid==1 processes, so a `grep` pipeline here cost ~1.3s and blew the SessionEnd budget.
  [[ $cmd =~ $REAP_PROTECT ]] && continue

  # Project affinity: exe path or any argv path under a configured root.
  under_root "$cmd" || continue

  age=$(etime_secs "$etime")
  [ "$age" -gt "$REAP_MIN_AGE" ] 2>/dev/null || continue

  candidates="$candidates$pid $age $cmd"$'\n'
  count=$((count + 1))
done <<EOF
$(ps -Ao pid=,ppid=,uid=,etime=,command= 2>/dev/null)
EOF

# Nothing to do: say nothing. This is the SessionStart context-cost guard.
[ "$count" -gt 0 ] || exit 0

if [ "$DO_KILL" -eq 0 ]; then
  [ "$QUIET" -eq 1 ] && exit 0
  printf 'reap-orphans: %d orphaned process(es) under [%s] — dry run, nothing killed\n\n' \
    "$count" "$REAP_ROOTS"
  printf '  %-8s %-12s %-6s %s\n' PID AGE PORTS COMMAND
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    p=${row%% *}; r=${row#* }; a=${r%% *}; c=${r#* }
    # -a is REQUIRED: lsof ORs its selection flags by default, so without it `-p PID` and
    # `-iTCP` are a union and every row reports the system-wide listener count.
    # (This whole listing is dry-run only — the --kill path never calls lsof, which is what
    # keeps the blocking SessionStart hook fast.)
    ports=$(lsof -a -nP -p "$p" -iTCP -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    printf '  %-8s %-12s %-6s %s\n' "$p" "$(printf '%dh%02dm' $((a/3600)) $(((a%3600)/60)))" \
      "${ports:-0}" "$(printf '%s' "$c" | cut -c1-88)"
  done <<EOF
$candidates
EOF
  printf '\nRun with --kill to reap them.\n'
  exit 0
fi

# --- kill ------------------------------------------------------------------------
pids=$(printf '%s' "$candidates" | awk 'NF{print $1}')
[ -n "$pids" ] || exit 0

# Thread count is what shows up in Activity Monitor, so the summary is denominated in it.
# Must be sampled BEFORE the kill. `ps -M` is a few ms per pid and the steady-state case is
# zero or one orphan, so this stays cheap inside the blocking SessionStart hook.
threads=0
for p in $pids; do
  t=$(ps -M -p "$p" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  threads=$((threads + t))
done

# shellcheck disable=SC2086
kill -TERM $pids 2>/dev/null

# Grace, then a hard kill for whatever ignored TERM. Kept short: this runs inside a blocking
# SessionStart hook.
sleep 2
still=""
for p in $pids; do
  kill -0 "$p" 2>/dev/null && still="$still $p"
done
# shellcheck disable=SC2086
[ -n "$still" ] && kill -KILL $still 2>/dev/null

reaped=0
for p in $pids; do
  kill -0 "$p" 2>/dev/null || reaped=$((reaped + 1))
done

# One line, only because we actually did something.
[ "$reaped" -gt 0 ] && echo "reap-orphans: reaped $reaped orphaned process(es), ~$threads threads"
exit 0
