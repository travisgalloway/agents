#!/usr/bin/env bash
# run-all.sh — run every check in ~/.claude/tests. Exit non-zero if any fails.
#
# Prints the assertion total at the end. tests/README.md deliberately does not restate that
# number: a hardcoded count is wrong on the next commit and nothing notices.
set -u
cd "$(dirname "$0")" || exit 1

ESC=$(printf '\033')
rc=0; total=0; unknown=""

for t in lint-frontmatter jq-run-lookup ledger-sweep git-scenarios hook-sentinels branches \
         reap-orphans session-cleanup bg-snapshot rewake-observability automerge-merge-gate merge-gate work-probes \
         backlog-guards closure-audit-guards stage-processes precommit-hook prepush-hook repo-map reference-integrity skill-blocks-portability; do
  printf '\033[1m━━ %s\033[0m\n' "$t"
  # Run ONCE and keep the output. The previous version ran each suite twice — once through a
  # pipe for display, once more for its status, because `sed` swallows the exit code. That
  # doubled the runtime and, worse, meant the reported status came from a different execution
  # than the output shown.
  out=$(bash "$t.sh" 2>&1); src=$?
  printf '%s\n' "$out" | sed 's/^/  /'
  [ "$src" -eq 0 ] || rc=1

  # An unparseable tally is UNKNOWN, not zero — silently adding 0 would under-report the total
  # while still looking like a clean sum.
  n=$(printf '%s\n' "$out" | sed "s/${ESC}\[[0-9;]*m//g" \
        | sed -nE 's/^(PASS|FAIL) ([0-9]+) passed.*/\2/p' | tail -1)
  if [ -n "$n" ]; then total=$((total + n)); else unknown="$unknown $t"; fi
  printf '\n'
done

if [ -n "$unknown" ]; then
  printf '\033[33m━━ assertion total ≥ %d (no tally parsed from:%s)\033[0m\n' "$total" "$unknown"
else
  printf '━━ %d assertions\n' "$total"
fi

if [ "$rc" -eq 0 ]; then
  printf '\033[32m━━ ALL SUITES PASS\033[0m\n'
else
  printf '\033[31m━━ SOME SUITES FAILED\033[0m\n'
fi
exit "$rc"
