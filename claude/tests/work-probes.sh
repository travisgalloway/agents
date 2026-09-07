#!/usr/bin/env bash
# work-probes.sh — run the arm-time monitor probe from skills/work/SKILL.md, extracted from
# the markdown so the block the model reads is the block under test.
#
# THE BUG: the probe asserted `git rev-parse --verify {branch}` for *every* stage, and the
# surrounding prose says to record a blocker when it fails. But the PLAN stage is what CREATES
# the branch (step 4), and the monitor is armed before yielding to that stage — so on a fresh
# issue the ref does not exist yet, and every orchestrated run would record a blocker before
# doing any work at all.
#
# The rule being pinned is narrower than "assert everything": a monitor that cannot see its
# target must fail loud, but a plan stage whose branch does not exist yet is not that case —
# it is the expected starting state. What makes a plan stage observable is the plan file.
#
# The probe runs under $BLOCK_SHELL (zsh — the Bash tool's login shell), not bash. See lib.sh:
# the two shells disagree about enough that running an extracted block under bash can pass
# while every production run of the same text fails.
#
# No network, no gh. Real throwaway repos under $TMPDIR.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

SKILL="${CLAUDE_ROOT:-$HOME/.claude}/skills/work/SKILL.md"
[ -f "$SKILL" ] || { bad "skill not found at $SKILL"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/work-probes.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com; git config --global user.name Test

REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
echo x > "$REPO/x"; git -C "$REPO" add -A; git -C "$REPO" commit -qm x
PLANS="$REPO/.claude/plans"; mkdir -p "$PLANS"

assert_block_shell "$BLOCK_SHELL"

SRC=$(extract_block "$SKILL" 'rev-parse --git-dir')
[ -n "$SRC" ] || { bad "could not extract the arm-time probe block"; summary; exit 1; }
# Guard the extraction itself: if the block ever loses its stage split, every assertion below
# would still "pass" for the exec cases and silently stop testing the plan-stage regression.
case "$SRC" in
  *'case "{stage}"'*) ok "extracted block is stage-aware" ;;
  *) bad "extracted block has no {stage} split — the regression guard is void"; summary; exit 1 ;;
esac

# run_probe <stage> <tree> <branch> <plan_file> -> exit code
run_probe() {
  printf '%s' "$SRC" \
    | sed -e "s#{stage}#$1#g" -e "s#{tree}#$2#g" -e "s#{branch}#$3#g" -e "s#{plan_file}#$4#g" \
    > "$WORK/probe.sh"
  # $BLOCK_SHELL, not bash: this block is markdown the Bash tool runs under the login shell.
  "$BLOCK_SHELL" "$WORK/probe.sh" >/dev/null 2>&1; echo $?
}

section "Plan stage: a branch that does not exist yet is the EXPECTED starting state"
# THE REGRESSION. The plan stage creates the branch, so requiring it here blocked every
# fresh issue in orchestrated mode before any work began.
assert_eq "arms with the branch not yet created" "0" \
  "$(run_probe plan "$REPO" feature/1-new "$PLANS/issue-1.md")"

section "Exec stage: the branch must resolve"
git -C "$REPO" branch feature/2-done
assert_eq "arms when the branch exists" "0" \
  "$(run_probe exec "$REPO" feature/2-done "$PLANS/issue-2.md")"
assert_eq "refuses a branch that is missing at exec time" "1" \
  "$(run_probe exec "$REPO" feature/9-missing "$PLANS/issue-9.md")"

section "Conventional branch names, including a scope, survive the substitution"
# THE TRAP: zsh glob-expands parentheses, so an UNQUOTED {branch} placeholder makes
# `feat(api)/3-scoped` rc=1 ("no matches found") no matter what git says. `zsh -n` cannot see
# it — it is a runtime failure — so this fixture is the only thing that catches a regression
# to an unquoted placeholder. rc=1 here means the monitor refuses to arm and every stage on a
# scoped branch is a blocker that reads exactly like a healthy refusal.
git -C "$REPO" branch 'feat(api)/3-scoped'
git -C "$REPO" branch 'fix!/4-bang'
assert_eq "exec arms on a scoped branch feat(api)/3-scoped" "0" \
  "$(run_probe exec "$REPO" 'feat(api)/3-scoped' "$PLANS/issue-3.md")"
assert_eq "exec arms on a breaking-marker branch fix!/4-bang" "0" \
  "$(run_probe exec "$REPO" 'fix!/4-bang' "$PLANS/issue-4.md")"
assert_eq "exec still refuses a scoped branch that does not exist" "1" \
  "$(run_probe exec "$REPO" 'feat(api)/8-absent' "$PLANS/issue-8.md")"

section "A wrong tree is refused for BOTH stages — the real blind-monitor risk"
assert_eq "plan stage refuses a tree that is not a repo" "1" \
  "$(run_probe plan "$WORK/not-a-repo" feature/1-new "$PLANS/issue-1.md")"
assert_eq "exec stage refuses a tree that is not a repo" "1" \
  "$(run_probe exec "$WORK/not-a-repo" feature/2-done "$PLANS/issue-2.md")"

section "Plan stage still needs somewhere to write the plan"
assert_eq "refuses a missing plans directory" "1" \
  "$(run_probe plan "$REPO" feature/1-new "$WORK/nowhere/issue-1.md")"

summary
