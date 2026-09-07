#!/usr/bin/env bash
# branches.sh (test) — pin the contract of ~/.claude/lib/branches.sh.
#
# The two rules that must never regress:
#   1. Always exits 0 and never writes to stderr. It runs as a skill's dynamic-context command;
#      a failure there breaks skill loading for every consumer.
#   2. Emits only slow-moving facts. Volatile output (SHAs, ahead/behind counts, dirty state)
#      would change the rendered skill body on nearly every invocation, and Claude Code appends
#      a full copy of the body whenever the rendered content differs.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

SCRIPT="$HOME/.claude/lib/branches.sh"
[ -x "$SCRIPT" ] || { bad "not executable: $SCRIPT"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/branches.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name Test
git config --global init.defaultBranch main

# Keep `gh` out of the way so results are deterministic and offline.
mkdir -p "$WORK/bin"; printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
PATH_NO_GH="$WORK/bin:$PATH"

REMOTE="$WORK/remote.git"; git init -q --bare "$REMOTE"
REPO="$WORK/repo"; git clone -q "$REMOTE" "$REPO"
echo x > "$REPO/x"; git -C "$REPO" add -A; git -C "$REPO" commit -qm x
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -qb dev; git -C "$REPO" push -q origin dev
git -C "$REPO" checkout -qb feature/42-thing; git -C "$REPO" push -q origin feature/42-thing

run() { ( cd "$1" && PATH="$PATH_NO_GH" bash "$SCRIPT" 2>"$WORK/err"; echo "rc=$?" ); }
val() { run "$1" | sed -n "s/^$2=//p"; }

section "Contract: exit 0, empty stderr, in every location"
mkdir -p "$REPO/sub/dir"
WT="$WORK/wt"; git -C "$REPO" worktree add -q "$WT" main 2>/dev/null
for loc in "$REPO" "$REPO/sub/dir" "$WT" "$WORK" /tmp; do
  out=$(run "$loc")
  assert_contains "rc=0 in $(basename "$loc")" "$out" "rc=0"
  if [ -s "$WORK/err" ]; then bad "stderr empty in $(basename "$loc")" "$(cat "$WORK/err")"
  else ok "stderr empty in $(basename "$loc")"; fi
done

section "Resolution: owner/repo from the origin remote when gh is unavailable"
assert_eq "repo name"  "remote" "$(val "$REPO" repo)"
assert_eq "owner"      "$(basename "$WORK")" "$(val "$REPO" owner)"

section "Resolution: integration branch"
assert_eq "falls back to main with no config and no gh" "main" "$(val "$REPO" integration_branch)"
mkdir -p "$REPO/.claude"
printf '{"baseBranch":"dev","releaseBranch":"main"}\n' > "$REPO/.claude/branch-config.json"
assert_eq "config baseBranch wins"    "dev"  "$(val "$REPO" integration_branch)"
assert_eq "config releaseBranch wins" "main" "$(val "$REPO" release_branch)"
rm -f "$REPO/.claude/branch-config.json"

section "Resolution: current branch"
assert_eq "current branch"   "feature/42-thing" "$(val "$REPO" current_branch)"
assert_eq "same from subdir" "feature/42-thing" "$(val "$REPO/sub/dir" current_branch)"

section "Detached HEAD degrades to empty, not an error"
D="$WORK/detached"; git clone -q "$REMOTE" "$D"
git -C "$D" checkout -q --detach HEAD
out=$(run "$D")
assert_contains "still rc=0"          "$out" "rc=0"
assert_contains "notes detached HEAD" "$out" "detached HEAD"
assert_eq       "current_branch empty" "" "$(val "$D" current_branch)"

section "The branch grammar: Conventional Commits types are recognized"
# lib/branch-name.sh is the single source of truth for both this script's branch_issue key and
# preflight guard 6 / teardown. Sourced under bash on purpose: the Bash tool's login shell is
# zsh, where [[ =~ ]] captures land in $match and BASH_REMATCH is empty.
GRAMMAR="$(dirname "$SCRIPT")/branch-name.sh"
if [ -r "$GRAMMAR" ]; then ok "branch-name.sh is present"; else bad "branch-name.sh missing — every grammar assertion below is void"; summary; exit 1; fi

# parse <branch> -> "rc|type|scope|bang|issue|slug"
parse() {
  bash -c '. "$1" || exit 9; if branch_parse "$2"; then printf "0|%s|%s|%s|%s|%s" "$bn_type" "$bn_scope" "$bn_breaking" "$bn_issue" "$bn_slug"; else printf "1|%s|%s|%s|%s|%s" "$bn_type" "$bn_scope" "$bn_breaking" "$bn_issue" "$bn_slug"; fi' _ "$GRAMMAR" "$1"
}

for t in feat fix docs style refactor perf test build ci chore revert; do
  assert_eq "type '$t' is recognized" "0|$t|||5|x" "$(parse "$t/5-x")"
done

# `feature` FIRST in the alternation. ERE is leftmost-longest so this passes either way today,
# but a reimplementation as a `case` prefix test would silently call it `feat` — and the type
# is what /work would then generate. Pin the spelling, not just the acceptance.
assert_eq "legacy 'feature' parses as feature, never feat" "0|feature|||42|thing" "$(parse feature/42-thing)"

assert_eq "scope is captured"                "0|feat|api||42|slug" "$(parse 'feat(api)/42-slug')"
assert_eq "breaking marker is captured"      "0|fix||!|17|slug"    "$(parse 'fix!/17-slug')"
assert_eq "scope and breaking together"      "0|feat|api|!|9|s"    "$(parse 'feat(api)!/9-s')"

section "The issue number is optional, and its ambiguity is bounded"
assert_eq "issue-less branch is still recognized" "0|chore||||deps" "$(parse chore/deps)"
assert_eq "2fa is a slug, not issue 2"           "0|fix||||2fa-setup" "$(parse fix/2fa-setup)"
assert_eq "2-fa IS issue 2"                      "0|fix|||2|fa-setup" "$(parse fix/2-fa-setup)"
# GitHub does not link `Closes #007`.
assert_eq "leading zeros are stripped"           "0|fix|||7|x" "$(parse fix/007-x)"
# THE AMBIGUITY WITH NO REGEX FIX: a date-shaped slug reads as an issue number. Pinned here so
# nobody "fixes" it in the grammar — the fix is /pr degrading when `gh issue view` fails.
assert_eq "a date-shaped slug DOES read as an issue (callers must verify)" \
  "0|fix|||2024|01-migration" "$(parse fix/2024-01-migration)"

section "Rejections: what must NOT be recognized"
# for-each-ref wildcards do not cross '/', so a slug containing '/' would be invisible to
# preflight guard 6 and to teardown — the branch exists and every scan reports clean.
assert_eq "a slug containing / is rejected" "1|||||" "$(parse feat/42-a/b)"
assert_eq "a scope containing / is rejected" "1|||||" "$(parse 'feat(a/b)/1-x')"
for b in travis/42-notes wip/12-x main dev release-1.2 feature 'feat(api)' nope/1-x; do
  assert_eq "'$b' is not recognized" "1|||||" "$(parse "$b")"
done

section "New keys: branch_issue and branch_recognized"
git -C "$REPO" checkout -q feature/42-thing
assert_eq "branch_issue on the legacy scheme"  "42"   "$(val "$REPO" branch_issue)"
assert_eq "branch_recognized on the legacy scheme" "true" "$(val "$REPO" branch_recognized)"
git -C "$REPO" checkout -q -b 'feat(api)/8-scoped'
assert_eq "branch_issue on a scoped conventional branch" "8" "$(val "$REPO" branch_issue)"
assert_eq "branch_recognized on a scoped conventional branch" "true" "$(val "$REPO" branch_recognized)"
git -C "$REPO" checkout -q -b wip/nothing
assert_eq "unrecognized branch reports false" "false" "$(val "$REPO" branch_recognized)"
assert_eq "and an EMPTY issue, not a missing key" "" "$(val "$REPO" branch_issue)"
assert_contains "the key is still emitted" "$(run "$REPO")" "branch_issue="
git -C "$REPO" checkout -q feature/42-thing

# Both keys on BOTH exit paths. The not-a-git-repo early exit is a separate emit block and
# already omitted branch_config once; a key that vanishes outside a repo reads to a consumer as
# "unset" rather than "empty".
section "Both keys are emitted on the not-a-git-repo path too"
out=$(run /tmp)
assert_contains "branch_issue present outside a repo"       "$out" "branch_issue="
assert_contains "branch_recognized present outside a repo"  "$out" "branch_recognized=false"
assert_contains "branch_config present outside a repo"      "$out" "branch_config="

section "Detached HEAD degrades both keys to empty/false, still rc 0"
out=$(run "$D")
assert_contains "still rc=0"                  "$out" "rc=0"
assert_eq       "branch_issue empty"       "" "$(val "$D" branch_issue)"
assert_eq       "branch_recognized false" "false" "$(val "$D" branch_recognized)"

section "An unreadable branch-name.sh degrades — it never takes skill loading down"
# The contract is never exit non-zero, never write stderr: this script is injected into eight
# skills, so a failure here breaks skill loading for all of them.
DEG="$WORK/degraded"; mkdir -p "$DEG"; cp "$SCRIPT" "$DEG/"   # branch-name.sh deliberately absent
degout=$( cd "$REPO" && PATH="$PATH_NO_GH" bash "$DEG/branches.sh" 2>"$WORK/derr" ); degrc=$?
assert_eq "rc=0 with the helper missing" "0" "$degrc"
if [ -s "$WORK/derr" ]; then bad "stderr empty with the helper missing" "$(cat "$WORK/derr")"
else ok "stderr empty with the helper missing"; fi
assert_contains "branch_recognized degrades to false" "$degout" "branch_recognized=false"
assert_contains "and says so rather than reporting clean" "$degout" "branch-name.sh unreadable"

section "Stability: output is byte-identical across invocations and after new commits"
a=$(cd "$REPO" && PATH="$PATH_NO_GH" bash "$SCRIPT")
b=$(cd "$REPO" && PATH="$PATH_NO_GH" bash "$SCRIPT")
assert_eq "two consecutive runs identical" "$a" "$b"
echo more > "$REPO/y"; git -C "$REPO" add -A; git -C "$REPO" commit -qm y
echo dirty > "$REPO/z"
c=$(cd "$REPO" && PATH="$PATH_NO_GH" bash "$SCRIPT")
assert_eq "unchanged by a new commit and a dirty tree" "$a" "$c"

section "Stability: no volatile keys are emitted"
for k in sha head commit count ahead behind dirty status timestamp date; do
  assert_not_contains "no '$k' key" "$(printf '%s' "$a" | tr 'A-Z' 'a-z')" "$k="
done

summary
