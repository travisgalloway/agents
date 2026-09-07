#!/usr/bin/env bash
# stage-processes.sh — record the process table before a /work or /backlog stage, then find and
# end the OS processes that stage orphaned.
#
# WHY THIS EXISTS. On 2026-09-04 a stage left twenty `zsh` busy loops running for 3h26m at 601.8%
# CPU on a 10-core laptop, and the load average reached 195.63. The stage had written its own
# cleanup:
#
#     for i in $(seq 1 20); do (while :; do :; done) & done
#     spinners=$(jobs -p)
#     ...
#     kill $spinners 2>/dev/null; echo "spinners stopped"
#
# `jobs -p` returns nothing under a non-interactive `zsh -c`, so `spinners` was empty, `kill` ended
# nothing, and the shell printed "spinners stopped" regardless. The parent then exited and the
# subshells reparented to PID 1. Neither /work's Stage teardown nor backlog-teardown.sh looked at
# the process table, so nothing noticed for three and a half hours. Both commands verify completion
# against git and gh already; this is the same observation applied to processes.
#
# HOW A STAGE ORPHAN IS IDENTIFIED. Two conditions together, never one alone. The PID is absent
# from the snapshot taken before dispatch, and its parent is PID 1. A stage runs for up to 90
# minutes and the operator keeps working during it, so "new since the snapshot" on its own would
# sweep up unrelated work.
#
# WHY CWD DECIDES WHAT GETS KILLED. Among those orphans, only the ones whose working directory sits
# inside the stage's tree are attributable to the stage. Those are ended. Everything else is
# printed and left alone, because a wrong guess here kills the operator's own long-running job.
#
# BLIND IS NOT CLEAN. A missing snapshot, or an lsof that cannot read a process, exits 5 and says
# so. The standing rule is that a check which cannot observe its target reports BLIND, never
# healthy, and an empty result is unknown rather than good news.
#
# CONTRACT: act on the exit code.
#   0   sweep complete (finding nothing is also success)
#   3   orphans found outside the tree and left alone — report them, decide by hand
#   5   could not observe: no snapshot, or lsof unavailable. BLIND, not clean.
#   64  usage error
#
# Output is one line per action taken, for the ledger and the transcript.

set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
RUN_DIR="$CLAUDE_HOME/run"

usage() {
  cat <<'EOF'
usage: stage-processes.sh snapshot <label>
       stage-processes.sh sweep <label> [options]

  snapshot   record the current PID set before dispatching a stage
  sweep      end the processes that stage orphaned, and report the rest

sweep options:
  --tree PATH   the stage's working tree. Orphans whose cwd is inside it are ended;
                orphans elsewhere are reported and left alone. Without it, nothing is
                ended and every orphan is reported.
  --dry-run     report what would be ended, end nothing
  --keep        do not delete the snapshot afterwards (default is to delete it)

<label> is the issue number for /work and /backlog. It names the snapshot file at
$CLAUDE_HOME/run/stage-pids-<label>.txt
EOF
}

say() { printf '%s\n' "$1"; }

[ $# -ge 1 ] || { usage >&2; exit 64; }
cmd="$1"; shift
case "$cmd" in -h|--help) usage; exit 0 ;; esac

[ $# -ge 1 ] || { printf 'a <label> is required\n'; usage >&2; exit 64; }
label="$1"; shift
case "$label" in
  ''|*[!A-Za-z0-9._-]*) printf 'label must be alphanumeric with . _ - only: %s\n' "$label"; exit 64 ;;
esac

snapshot_file="$RUN_DIR/stage-pids-$label.txt"

# Every PID currently on the machine, one per line. Used by both subcommands, so a difference
# between them can never come from asking two different questions.
current_pids() { ps -Ao pid= 2>/dev/null | tr -d ' ' | grep -E '^[0-9]+$' || true; }

case "$cmd" in
  snapshot)
    [ $# -eq 0 ] || { printf 'snapshot takes no options\n'; usage >&2; exit 64; }
    mkdir -p "$RUN_DIR" || { printf 'cannot create %s\n' "$RUN_DIR"; exit 5; }
    pids=$(current_pids)
    # An empty ps is not an empty machine. Refuse to write a snapshot that would make every
    # process on the box look new to the sweep.
    [ -n "$pids" ] || { say "BLIND: ps returned nothing — snapshot not written for $label"; exit 5; }
    printf '%s\n' "$pids" > "$snapshot_file"
    say "snapshot $label: $(printf '%s\n' "$pids" | wc -l | tr -d ' ') pids recorded"
    exit 0
    ;;
  sweep) ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'unknown subcommand: %s\n' "$cmd"; usage >&2; exit 64 ;;
esac

tree=""; dry=0; keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tree)    tree="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --keep)    keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1"; usage >&2; exit 64 ;;
  esac
done

# --- the two ways this sweep can be blind ------------------------------------------
if [ ! -r "$snapshot_file" ]; then
  say "BLIND: no snapshot at $snapshot_file — cannot tell this stage's processes from yours. Nothing swept."
  exit 5
fi
if ! command -v lsof >/dev/null 2>&1; then
  say "BLIND: lsof not available — cannot attribute orphans by working directory. Nothing swept."
  exit 5
fi

before_count=$(grep -cE '^[0-9]+$' "$snapshot_file" 2>/dev/null || true)
[ "${before_count:-0}" -gt 0 ] 2>/dev/null || { say "BLIND: snapshot $snapshot_file is empty. Nothing swept."; exit 5; }

now=$(ps -Ao pid=,ppid= 2>/dev/null || true)
[ -n "$now" ] || { say "BLIND: ps returned nothing. Nothing swept."; exit 5; }

# Resolve the tree once. A relative or symlinked path compared against lsof's absolute, resolved
# cwd would match nothing and silently sweep nothing.
tree_real=""
if [ -n "$tree" ]; then
  tree_real=$(cd "$tree" 2>/dev/null && pwd -P) || tree_real=""
  if [ -z "$tree_real" ]; then
    say "BLIND: --tree $tree does not resolve to a directory. Nothing swept."
    exit 5
  fi
fi

# --- candidates: new since the snapshot AND reparented to init ---------------------
# Both conditions, never one alone. Self and ancestors are excluded so the sweep cannot end the
# shell running it.
# The snapshot is READ AS A FILE, never passed through `awk -v`. A -v assignment cannot carry
# embedded newlines: awk aborts with "newline in string", the candidate list comes back empty, and
# the sweep reports "no orphaned processes" while having looked at nothing. That is the same
# blind-reported-as-clean failure this script exists to catch, and it was caught here in testing.
self=$$
parent=$PPID
candidates=$(
  printf '%s\n' "$now" | awk -v self="$self" -v parent="$parent" '
    NR == FNR { if ($1 ~ /^[0-9]+$/) seen[$1 + 0] = 1; next }
    { pid = $1 + 0; ppid = $2 + 0 }
    ppid != 1 { next }
    pid == self || pid == parent { next }
    !(pid in seen) { print pid }
  ' "$snapshot_file" -
) || { say "BLIND: could not compare the snapshot against the process table. Nothing swept."; exit 5; }

if [ -z "$candidates" ]; then
  say "sweep $label: no orphaned processes"
  [ "$keep" -eq 1 ] || rm -f "$snapshot_file"
  exit 0
fi

# --- attribute each candidate by its working directory -----------------------------
rc=0
ended=0
foreign=0
unreadable=0

for pid in $candidates; do
  cmdline=$(ps -o command= -p "$pid" 2>/dev/null || true)
  [ -n "$cmdline" ] || continue   # exited between the two ps calls; nothing to do

  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)

  if [ -z "$cwd" ]; then
    # Unreadable is unknown. Report it and leave it; do not treat "no cwd" as "not ours".
    say "UNREADABLE cwd, left alone: pid $pid — ${cmdline}"
    unreadable=$((unreadable + 1))
    rc=3
    continue
  fi

  in_tree=0
  if [ -n "$tree_real" ]; then
    case "$cwd" in
      "$tree_real"|"$tree_real"/*) in_tree=1 ;;
    esac
  fi

  if [ "$in_tree" -eq 0 ]; then
    say "NOT THIS STAGE, left alone: pid $pid cwd=$cwd — ${cmdline}"
    foreign=$((foreign + 1))
    rc=3
    continue
  fi

  if [ "$dry" -eq 1 ]; then
    say "would end: pid $pid cwd=$cwd — ${cmdline}"
    ended=$((ended + 1))
    continue
  fi

  kill -TERM "$pid" 2>/dev/null || true
  # A busy loop ignores nothing, but a process mid-write deserves the chance to finish. One
  # second, then SIGKILL: the whole point of this sweep is that the process does not survive it.
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    say "COULD NOT END: pid $pid cwd=$cwd — ${cmdline}"
    rc=3
  else
    say "ended orphan: pid $pid cwd=$cwd — ${cmdline}"
    ended=$((ended + 1))
  fi
done

say "sweep $label: ended $ended, left alone $((foreign + unreadable))"
[ "$keep" -eq 1 ] || rm -f "$snapshot_file"
exit "$rc"
