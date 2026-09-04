#!/usr/bin/env bash
# git-scenarios.sh — pin the post-merge branch classification used by /pr steps 6-7 and /work §3,
# and the ahead/behind counts used by /sync §5.
#
# THE BUG: both commands decide "does my local branch still have unmerged work?" with
#   git rev-list --count {integration}..HEAD
# /automerge merges with `gh pr merge --squash`, which writes a NEW commit. The branch's
# original commits are therefore never ancestors of the integration branch and the count stays
# > 0 forever — so Scenario D ("already merged") is unreachable and every post-merge resume
# creates a duplicate follow-up branch.
#
# THE FIX is layered, because no single git test covers every merge style:
#   1. git merge-base --is-ancestor HEAD {integration}   → merge commit / fast-forward
#   2. git diff --quiet {integration} HEAD               → squash, integration not advanced
#   3. git diff --quiet {integration} HEAD -- <files the branch touched>
#                                                        → squash, integration advanced since
# Anything else is genuinely new work (Scenario C).
#
# Test 3 deliberately avoids the PR's `mergedAt` timestamp: `git rev-list --since` filters on
# committer date, which a rebase rewrites, so a rebased-but-merged branch would misclassify.
# Comparing only the paths the branch touched is date-independent and needs no API call.
#
# Note test 2 is TWO-dot (tip vs tip). Three-dot `{integration}...HEAD` diffs against the merge
# base, which after a squash merge is still the original branch point — so it reports the
# feature's whole diff and never detects the merge. See the explicit assertion below.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-scen.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name  Test
git config --global init.defaultBranch main

# new_repo <name> — repo with main + a feature branch carrying two commits
new_repo() {
  local d="$WORK/$1"; mkdir -p "$d"; git -C "$d" init -q
  echo base > "$d/base.txt"; git -C "$d" add -A; git -C "$d" commit -qm "base"
  git -C "$d" checkout -qb feature/42-thing
  echo one > "$d/one.txt"; git -C "$d" add -A; git -C "$d" commit -qm "feat: one"
  echo two > "$d/two.txt"; git -C "$d" add -A; git -C "$d" commit -qm "feat: two"
  git -C "$d" checkout -q main
  echo "$d"
}

squash_merge() { git -C "$1" merge -q --squash feature/42-thing && git -C "$1" commit -qm "feat: thing (#42)"; }

# classify <repo> — the layered test, echoing C (new work) or D (already merged)
classify() {
  local d="$1" base files
  git -C "$d" merge-base --is-ancestor feature/42-thing main 2>/dev/null && { echo D; return; }
  git -C "$d" diff --quiet main feature/42-thing 2>/dev/null && { echo D; return; }
  base=$(git -C "$d" merge-base main feature/42-thing 2>/dev/null) || { echo C; return; }
  files=$(git -C "$d" diff --name-only "$base" feature/42-thing 2>/dev/null)
  [ -n "$files" ] || { echo D; return; }
  if printf '%s\n' "$files" | tr '\n' '\0' \
     | xargs -0 git -C "$d" diff --quiet main feature/42-thing -- 2>/dev/null; then
    echo D; return
  fi
  echo C
}

section "Reproduce the bug: rev-list --count cannot see a squash merge"
d=$(new_repo squashed); squash_merge "$d"
cnt=$(git -C "$d" rev-list --count main..feature/42-thing)
assert_eq "count is still >0 after squash merge (this is why D was unreachable)" "2" "$cnt"

section "Three-dot diff is the WRONG test (diffs against the merge base, not the tip)"
git -C "$d" diff --quiet main...feature/42-thing
assert_eq "three-dot reports differences even though the work is merged" "1" "$?"

section "Two-dot diff correctly detects the squash merge"
git -C "$d" diff --quiet main feature/42-thing
assert_eq "two-dot reports no differences" "0" "$?"
assert_eq "classify → D" "D" "$(classify "$d")"

section "Scenario D1: ordinary merge commit"
d=$(new_repo merged); git -C "$d" merge -q --no-ff -m "merge" feature/42-thing
assert_eq "is-ancestor catches it → D" "D" "$(classify "$d")"

section "Scenario D2: squash merge, integration not advanced"
d=$(new_repo d2); squash_merge "$d"
assert_eq "classify → D" "D" "$(classify "$d")"

section "Scenario C: new local work after a squash merge"
d=$(new_repo newwork); squash_merge "$d"
git -C "$d" checkout -q feature/42-thing
echo three > "$d/three.txt"; git -C "$d" add -A; git -C "$d" commit -qm "feat: three"
assert_eq "classify → C" "C" "$(classify "$d")"

section "Scenario D3: squash merge, integration advanced with unrelated work"
d=$(new_repo d3); squash_merge "$d"
echo other > "$d/other.txt"; git -C "$d" add -A; git -C "$d" commit -qm "chore: unrelated"
# Full-tree diff now differs, so test 2 fails; only the touched-paths test can resolve it.
git -C "$d" diff --quiet main feature/42-thing
assert_eq "full-tree diff now says 'differs' (would be a false C)" "1" "$?"
assert_eq "touched-paths test rescues it → D" "D" "$(classify "$d")"

section "Scenario D3 + genuinely new work still classifies as C"
git -C "$d" checkout -q feature/42-thing
echo four > "$d/four.txt"; git -C "$d" add -A; git -C "$d" commit -qm "feat: four"
assert_eq "classify → C" "C" "$(classify "$d")"

section "Rebased-but-merged branch is not misclassified (why not to use mergedAt/--since)"
d=$(new_repo rebased); squash_merge "$d"
git -C "$d" checkout -q feature/42-thing
git -C "$d" rebase -q --force-rebase --onto "$(git -C "$d" rev-parse feature/42-thing~2)" \
  "$(git -C "$d" rev-parse feature/42-thing~2)" >/dev/null 2>&1 || true
assert_eq "still → D despite rewritten committer dates" "D" "$(classify "$d")"

section "/sync §5: new-commit count direction"
d="$WORK/sync"; mkdir -p "$d"
git -C "$d" init -q --bare "$WORK/sync-remote" 2>/dev/null || git init -q --bare "$WORK/sync-remote"
git clone -q "$WORK/sync-remote" "$d" 2>/dev/null
echo a > "$d/a"; git -C "$d" add -A; git -C "$d" commit -qm a; git -C "$d" push -q origin main
before=$(git -C "$d" rev-parse main)
# Advance the remote by two commits, then fetch so origin/main is ahead of the local tip.
c=$(mktemp -d "$WORK/clone.XXXXXX"); git clone -q "$WORK/sync-remote" "$c"
echo b > "$c/b"; git -C "$c" add -A; git -C "$c" commit -qm b
echo c > "$c/c"; git -C "$c" add -A; git -C "$c" commit -qm c
git -C "$c" push -q origin main
git -C "$d" fetch -q origin
wrong=$(git -C "$d" rev-list --count "origin/main..$before")
right=$(git -C "$d" rev-list --count "$before..origin/main")
assert_eq "documented direction returns 0 (the bug)"       "0" "$wrong"
assert_eq "corrected direction returns the real count"     "2" "$right"

section "Live call sites use the corrected classification"
ROOT="$HOME/.claude"
# `found` guards against the files being absent, which would skip every assertion below and
# read as a pass.
found=0
for f in "$ROOT/skills/pr/SKILL.md" "$ROOT/skills/work/SKILL.md"; do
  [ -f "$f" ] || continue
  found=$((found+1)); body=$(cat "$f")
  assert_contains "$(basename "$(dirname "$f")")/$(basename "$f"): uses two-dot diff test" \
    "$body" 'git diff --quiet'
done
[ "$found" -ge 2 ] || bad "expected pr and work files, found $found"
found=0
for f in "$ROOT/skills/sync/SKILL.md"; do
  [ -f "$f" ] || continue
  found=$((found+1))
  body=$(cat "$f")
  # Match the full command, not a bare range: the corrected file mentions the inverted range
  # in prose explaining why it is wrong, and that mention must not fail the test.
  assert_not_contains "$(basename "$f"): no rev-list with the inverted range" \
    "$body" 'rev-list --count origin/<branch>..<branch_before>'
  assert_contains "$(basename "$f"): rev-list uses the corrected range" \
    "$body" 'rev-list --count <branch_before>..origin/<branch>'
done
[ "$found" -ge 1 ] || bad "expected the sync skill file, found none"

summary
