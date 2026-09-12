#!/usr/bin/env bash
# automerge-merge-gate.sh — run the two decision scripts in skills/automerge/SKILL.md against
# a gh stub. They are extracted from the markdown, so the file the model reads is the file
# under test; a divergence between doc and behavior fails here.
#
# Both scripts are run under EVERY shell in $SHELLS — bash and zsh. See BLOCK_SHELL in lib.sh:
# the Bash tool runs the user's login shell, so a suite that only runs the block under bash
# can pass while every production run fails.
#
# THE BUGS being pinned:
#
#  1. Step 3 claimed a merge it never confirmed. `gh pr merge` can exit 0 without the PR
#     reaching MERGED (merge queue, a race with a concurrent push), and the summary then
#     printed "✓ merged" for an open PR. The script must verify state and fail otherwise.
#
#  2. Step 3's poll and merge used to be separate tool calls. They are now one script — a
#     tool boundary between the all-clear and `gh pr merge` is where the run was observed to
#     stall. This suite also pins that a blocked state never reaches `gh pr merge` at all.
#
#  3. §2.4's review wait swallowed gh failures: `2>/dev/null || true` made a network error
#     indistinguishable from "this repo has no review workflow", which exits 3 and skips the
#     wait entirely — merging while a review is inbound. A failed lookup must conclude
#     nothing. This is inherited from the Copilot wait §2.4 used to run, and it is the same
#     bug in the same place: only a literal 404 from the workflow probe may exit 3.
#
#  4. §2.4 keys every decision on the head commit, so the run it reads is the run for the
#     commit it is about. The predecessor compared ISO-8601 timestamps with
#     `[ "$latest" \> "$pushed_at" ]`; bash accepts that, and zsh — the shell the block
#     actually runs in — has no `>` operator in `[` and errors with rc=2, so the branch never
#     fired and every /automerge run rode to the 15-minute cap. Matching on $head_sha retires
#     that comparison. The capture is asserted at its call site below.
#
# No network calls: gh and sleep are both stubs on PATH.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

# CLAUDE_ROOT is overridable so the suite can be run against a scratch copy of the skill —
# how you check a pin still bites without editing the live file.
SKILL="${CLAUDE_ROOT:-$HOME/.claude}/skills/automerge/SKILL.md"
[ -f "$SKILL" ] || { bad "skill not found at $SKILL"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/am-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
GH_LOG="$WORK/gh.log"; export GH_LOG

# sleep is stubbed to a no-op: the review wait is 18 iterations of `sleep 30`.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"; chmod +x "$WORK/bin/sleep"
export PATH="$WORK/bin:$PATH"

# The shells each extracted block is run under. zsh is the production one (BLOCK_SHELL);
# bash stays in the list because the blocks are also read and reasoned about as bash.
SHELLS="bash $BLOCK_SHELL"
SH=bash   # current interpreter; set by the loops below

section "The interpreters these blocks are checked under"
for s in $SHELLS; do assert_block_shell "$s"; done

# extract_block lives in lib.sh — Step 3's fence is nested inside a numbered list, so the
# de-indent there matters here.
#
# The skill addresses a concrete PR; substitute its placeholders.
render() { sed -e 's/{number}/1/g' -e 's/{owner}/o/g' -e 's/{repo}/r/g'; }

# ============================================================ Step 3: the merge gate
extract_block "$SKILL" 'gh pr merge' | render > "$WORK/merge.sh"
[ -s "$WORK/merge.sh" ] || { bad "could not extract the Step 3 merge script"; summary; exit 1; }
grep -q 'gh pr merge 1 --squash' "$WORK/merge.sh" \
  || { bad "extracted the wrong block — no rendered merge command"; summary; exit 1; }

cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *mergeable*)
    [ "${GH_FAIL:-0}" = "1" ] && { echo "gh: could not connect" >&2; exit 1; }
    printf '{"mergeable":"%s","mergeStateStatus":"%s"}\n' "${GH_M:-MERGEABLE}" "${GH_S:-CLEAN}" ;;
  "pr merge"*) exit "${GH_MERGE_RC:-0}" ;;
  *"--json state"*) printf '%s\n' "${GH_STATE_AFTER:-MERGED}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# merge_rc [VAR=VAL ...] -> sets $RC, $OUT; resets the gh call log. Runs under $SH.
RC=0; OUT=""
merge_rc() {
  : > "$GH_LOG"
  OUT=$(env "$@" "$SH" "$WORK/merge.sh" 2>&1); RC=$?
}

merge_suite() {
  section "Step 3 merges only a genuinely mergeable PR [$SH]"
  merge_rc GH_M=MERGEABLE GH_S=CLEAN GH_STATE_AFTER=MERGED
  assert_eq "CLEAN + verified MERGED → exit 0 [$SH]" "0" "$RC"
  assert_contains "reports MERGED [$SH]" "$OUT" "MERGED"
  merge_rc GH_M=MERGEABLE GH_S=UNSTABLE GH_STATE_AFTER=MERGED
  assert_eq "UNSTABLE is still mergeable → exit 0 [$SH]" "0" "$RC"
  merge_rc GH_M=MERGEABLE GH_S=HAS_HOOKS GH_STATE_AFTER=MERGED
  assert_eq "HAS_HOOKS is still mergeable → exit 0 [$SH]" "0" "$RC"

  section "A merge that did not take is NOT a merge [$SH]"
  # gh pr merge exits 0, but the PR is still open. The old flow printed "✓ merged" here.
  merge_rc GH_M=MERGEABLE GH_S=CLEAN GH_STATE_AFTER=OPEN
  assert_eq "merge returned 0 but state is OPEN → exit 1 [$SH]" "1" "$RC"
  assert_contains "says so explicitly [$SH]" "$OUT" "state is OPEN"
  merge_rc GH_M=MERGEABLE GH_S=CLEAN GH_MERGE_RC=1
  assert_eq "gh pr merge itself failing → exit 1 [$SH]" "1" "$RC"

  section "Blocking states never reach gh pr merge [$SH]"
  for spec in "CONFLICTING:CLEAN:2" "MERGEABLE:DIRTY:2" "MERGEABLE:BLOCKED:3" "MERGEABLE:BEHIND:4"; do
    m=${spec%%:*}; rest=${spec#*:}; s=${rest%%:*}; want=${rest##*:}
    merge_rc GH_M="$m" GH_S="$s"
    assert_eq "$m/$s → exit $want [$SH]" "$want" "$RC"
    assert_not_contains "$m/$s did not invoke the merge [$SH]" "$(cat "$GH_LOG")" "pr merge"
  done

  section "A draft PR reports MERGEABLE — the allowlist must still block it [$SH]"
  merge_rc GH_M=MERGEABLE GH_S=DRAFT
  assert_eq "MERGEABLE/DRAFT → exit 5, not merged [$SH]" "5" "$RC"
  assert_not_contains "draft did not invoke the merge [$SH]" "$(cat "$GH_LOG")" "pr merge"

  section "Unreadable state is not permission to proceed [$SH]"
  merge_rc GH_FAIL=1
  assert_eq "gh unreachable → exit 6 [$SH]" "6" "$RC"
  assert_not_contains "unreachable did not invoke the merge [$SH]" "$(cat "$GH_LOG")" "pr merge"
  merge_rc GH_M=UNKNOWN GH_S=CLEAN
  assert_eq "mergeability never resolves → exit 5 [$SH]" "5" "$RC"
  assert_not_contains "unknown did not invoke the merge [$SH]" "$(cat "$GH_LOG")" "pr merge"
}

for SH in $SHELLS; do merge_suite; done

# ============================================================ §2.4: the review wait
extract_block "$SKILL" 'claude-review complete' | render > "$WORK/review.sh"
[ -s "$WORK/review.sh" ] || { bad "could not extract the review wait loop"; summary; exit 1; }
# The loop reads $head_sha from its caller (§2.4 captures it before entering).
sed -i.bak '1i\
head_sha="${HEAD_SHA:-deadbeef}"
' "$WORK/review.sh"

# Two endpoints, two stubs in one script:
#   GH_WF    — what the workflow probe returns. "notfound" renders gh's own 404 text.
#   GH_RUN   — what the runs lookup returns ("" = no run for this commit).
#   GH_FAIL  — every call fails, the way an unreachable API does.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = "1" ] && { echo "gh: could not connect" >&2; exit 1; }
case "$*" in
  *contents/.github/workflows/claude-review.yml*)
    case "${GH_WF:-0123456789abcdef0123456789abcdef01234567}" in
      notfound) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      fail)     echo "gh: could not connect" >&2; exit 1 ;;
      *)        printf '%s\n' "${GH_WF:-0123456789abcdef0123456789abcdef01234567}" ;;
    esac ;;
  *actions/runs*)
    [ "${GH_RUN_FAIL:-0}" = "1" ] && { echo "gh: could not connect" >&2; exit 1; }
    printf '%s\n' "${GH_RUN:-}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

review_rc() { OUT=$(env "$@" "$SH" "$WORK/review.sh" 2>&1); RC=$?; }

review_suite() {
  section "Review wait: a failed lookup must never read as 'not applicable' [$SH]"
  # THE REGRESSION. Exit 3 means "skip the wait", i.e. merge without the review.
  review_rc GH_FAIL=1
  assert_eq "gh down → exit 4 (chunk elapsed), NOT 3 [$SH]" "4" "$RC"
  assert_not_contains "never claims the workflow is missing [$SH]" "$OUT" "not installed"
  assert_not_contains "never claims there is no run [$SH]" "$OUT" "no claude-review run"

  # The workflow probe failing is the same trap one call earlier: a 500 is not a 404. It must
  # fall through to the loop rather than concluding the workflow is absent.
  review_rc GH_WF=fail GH_RUN_FAIL=1
  assert_eq "workflow probe unreachable → exit 4, NOT 3 [$SH]" "4" "$RC"
  assert_not_contains "an unreachable probe is not an absent workflow [$SH]" "$OUT" "not installed"
  # With the probe down but the runs endpoint answering, the loop still decides on the run.
  review_rc GH_WF=fail GH_RUN=""
  assert_not_contains "an unreachable probe never says 'not installed' [$SH]" "$OUT" "not installed"

  # And the runs lookup failing, with the workflow known to exist.
  review_rc GH_RUN_FAIL=1
  assert_eq "runs lookup unreachable → exit 4, NOT 3 [$SH]" "4" "$RC"
  assert_not_contains "an unreachable lookup is not an absent run [$SH]" "$OUT" "no claude-review run"

  section "Review wait: the real states resolve correctly [$SH]"
  review_rc GH_WF=notfound
  assert_eq "repo has no review workflow → exit 3 (not applicable) [$SH]" "3" "$RC"
  assert_contains "says why [$SH]" "$OUT" "not installed"

  review_rc GH_RUN="completed success"
  assert_eq "run for this commit completed → exit 0 (done) [$SH]" "0" "$RC"
  assert_contains "names the commit [$SH]" "$OUT" "deadbeef"
  assert_contains "reports the conclusion [$SH]" "$OUT" "success"

  # A red review job is a finished review. CI's own gate reports the failure; waiting past it
  # here would ride every failed review to the 15-minute cap and stop the run.
  review_rc GH_RUN="completed failure"
  assert_eq "run completed with failure → still exit 0 [$SH]" "0" "$RC"

  review_rc GH_RUN="in_progress "
  assert_eq "run still going → keeps polling, exit 4 [$SH]" "4" "$RC"
  review_rc GH_RUN="queued "
  assert_eq "run queued → keeps polling, exit 4 [$SH]" "4" "$RC"

  section "Review wait: the grace window for event-delivery lag [$SH]"
  # The workflow exists but no run has appeared. Past ~3 minutes that means the event was
  # never delivered for this commit, and the remaining cap cannot change it.
  review_rc GH_RUN=""
  assert_eq "workflow installed, no run for this commit → exit 3 [$SH]" "3" "$RC"
  assert_contains "names the commit it could not find a run for [$SH]" "$OUT" "no claude-review run for deadbeef"
}

for SH in $SHELLS; do review_suite; done

# ============================================================ §2.4: the capture call site
# Every decision keys on the head commit, and the capture lives OUTSIDE the extracted block
# (the loop takes $head_sha from its caller), so it is asserted against the file.
section "§2.4 captures the head commit, not a timestamp"
CAP=$(grep -n 'head_sha=\$(' "$SKILL" | head -1)
assert_contains "captures via git rev-parse HEAD" "$CAP" "git rev-parse HEAD"
SKILL_BODY=$(cat "$SKILL")
assert_not_contains "no timestamp comparison left in the skill" "$SKILL_BODY" 'pushed_at'
assert_not_contains "no bare %cI — it carried a local offset" "$SKILL_BODY" "--format=%cI"

summary
