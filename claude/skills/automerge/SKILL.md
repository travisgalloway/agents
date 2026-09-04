---
name: automerge
# No `model:` pin — intentional. /work invokes this mid-turn via the Skill tool, and a model
# override applies for the rest of the calling turn with no way back, so pinning sonnet here would
# silently downshift the opus /work orchestrator. It already runs on sonnet when dispatched, because
# it runs inside /work's sonnet exec subagent.
#
# No `disable-model-invocation`, despite the side effects: /work step 10 hands off to this skill
# through the Skill tool, and that counts as Claude invoking it — the flag would break `/work
# … auto` entirely. The narrowed description below is the compensating control.
#
# `disallowed-tools` is what actually enforces "FULLY AUTONOMOUS" below. The prose said "NEVER
# call EnterPlanMode or ExitPlanMode"; this removes them from the pool so it cannot happen.
# AskUserQuestion goes too — a prompt in an unattended merge run is a stall, not a question.
description: Drive already-open PRs to a squash merge, remediating reviews and CI autonomously. Invoked by /work when you pass `auto`, or directly by you with an explicit PR selector. Never for exploratory use — it merges and deletes branches without asking.
argument-hint: "[this | all | #N | #A,#B | #A-B]"
arguments: scope
disallowed-tools: EnterPlanMode, ExitPlanMode, AskUserQuestion
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Autonomously drive one or more open PRs all the way to merge. For each PR, this command runs a remediation cycle — address review comments, fix CI, wait for the Claude code review — and repeats until the PR is clean, then squash-merges it. Pass `this`, `all`, or a specific PR number / list / range (e.g. `#2`, `#2,#5`, `#2-5`).

## Operating mode: FULLY AUTONOMOUS

This command runs **without pausing for approval**. It remediates, commits, pushes, and merges on its own.

- **Never call `EnterPlanMode`, `ExitPlanMode` or `AskUserQuestion`.** This is enforced, not
  requested: all three are removed from this skill's tool pool by `disallowed-tools` in the
  frontmatter. If you find yourself wanting one, you have hit a **stop condition** — report it.
- **Delegate remediation to the `remediator` subagent**, which runs `/reviews auto` and `/ci auto`
  (§2.2, §2.3). Their `auto` mode runs without plan mode or prompts, and they remain the single
  source of truth for review/CI remediation. Do **not** invoke them in their default (interactive)
  mode, which would pause for approval, and do **not** invoke them inline in this session — see
  §2.2 for why the subagent hop matters.
- The only thing that stops the run is an **unresolvable blocker** (see "Stop conditions"). When one occurs, **abort the entire run immediately** — leave the offending PR untouched, do not move on to other PRs, and surface the blocker clearly with the failing command and PR URL.

## Step 1: Detect repository & resolve scope

1. **`{owner}` and `{repo}` are already resolved** in the repo-context block above. If `owner` is
   empty, error: "No GitHub repository found. This command requires a GitHub repo with an
   authenticated `gh` CLI." and stop.

2. **Resolve `{scope}`.** You were invoked with: `$scope`
   If nothing appears between those backticks, no argument was passed — take the
   **No argument** branch below. Every `{scope}` reference means that value.
   - **`this`** → find the PR for the current branch:
     ```bash
     gh pr list --head "$(git branch --show-current)" --state open --json number,headRefName,title -q '.[0]'
     ```
     If no PR is found, error: "No open PR found for the current branch. Run `/pr` to create one." and stop.
   - **`all`** → enumerate every open non-draft PR:
     ```bash
     gh pr list --state open --draft=false --json number,headRefName,title
     ```
     (`gh pr list` does have a `-d, --draft` flag — verified on gh 2.83.1. Prefer it over
     `--search "draft:false"`, which changes result ordering and applies a different limit.)
   - **A PR number / list / range** (`#2`, `2`, `#2,#5`, `#2-5`) → parse it into an ordered, de-duplicated, ascending set of PR numbers:
     - `#N` / `N` → `[N]`.
     - `#A-B` / `A-B` → inclusive range `A..B`.
     - comma list (`#2,#5`, `2,5`) → those numbers.

     For each number, validate the PR and fetch its fields:
     ```bash
     gh pr view {n} --json number,headRefName,title,state,isDraft
     ```
     If a PR does not exist, error: "PR #{n} not found in {owner}/{repo}." and stop. If it is not open (already merged/closed), error: "PR #{n} is {state}, not open — skipping." and stop. A draft PR is allowed when named explicitly (unlike `all`, which filters drafts).
   - **No argument** → **stop** with usage: "`/automerge` needs a scope: `this`, `all`, or a PR
     number / list / range (e.g. `#2`, `#2,#5`, `#2-5`)." Do not guess and do not prompt.
     `AskUserQuestion` is removed from this skill's tool pool by design (see the frontmatter), and
     defaulting to `all` would squash-merge every open PR in the repo on a bare invocation.

3. Build an ordered **PR queue** of `{number, headRefName, title}`. If the queue is empty, report "No open PRs to process." and stop.

## Step 2: Per-PR remediation cycle

For each PR in the queue, check it out and run the cycle:

```bash
gh pr checkout {number}
```

**Write this PR's automerge-active sentinel** before starting the cycle — this is what
scopes the `asyncRewake` durability hooks (see `~/.claude/settings.json`) to *this*
run, so they never fire in unrelated sessions. The filename carries the PR number,
because nothing here guarantees this is the only `/automerge` alive on the repo: a
scope of `all`, or a second session, puts more than one in flight, and a single shared
file would have them silently overwrite — and on cleanup delete — each other's state
(the same clobber `/work`'s per-issue sentinels exist to prevent). Within one `/work`
or `/backlog` run the merge slot keeps them serialized, but that is the caller's
guarantee, not this file's:

```bash
mkdir -p "$(git rev-parse --show-toplevel)/.claude"
cat > "$(git rev-parse --show-toplevel)/.claude/automerge-active-{number}" <<EOF
{"pr": {number}, "owner": "{owner}", "repo": "{repo}", "session": "$CLAUDE_CODE_SESSION_ID"}
EOF
```

(Ensure `.claude/automerge-active*` is listed in `.git/info/exclude` at the main repo
root — reuse the `/work` §0c excludes step; it is a working artifact, never committed.)
The `session` field scopes both the rewake hook and `SessionEnd` cleanup to this
run — several `claude` sessions may share a repo. `$CLAUDE_CODE_SESSION_ID` is
already exported into every Bash call.

Run the **remediation cycle** below, repeating until the exit condition in 2.5 is met. Bound the cycle to a **maximum of 5 iterations** as an infinite-loop safety; exceeding it is a stop condition.

**Delete the sentinel and its counter only once this PR is genuinely finished** — after
Step 3 has *confirmed* the merge, or when a Stop condition aborts the PR:
`rm -f "$(git rev-parse --show-toplevel)/.claude/automerge-active-{number}"{,.rewakes,.capped,.progress}`.
Aborting on a Stop condition deletes it too, so the durability hooks don't keep rewaking a
session for a PR nobody is working.

There are exactly **two** moments that qualify: a merge confirmed in Step 3, or a Stop condition
that ends work on this PR — wherever that Stop occurs, including the §2.2 / §2.3 / §2.4 stops that
abort before Step 3 is ever reached.

**What does not qualify is exiting the remediation cycle.** §2.5 announces "exit the cycle and
proceed to merge (Step 3)", and an earlier wording here ("on any exit from this PR's cycle") read
as licence to delete the sentinel at that moment. That disarms the only guard covering the handful
of tool calls between the all-clear and `gh pr merge` — precisely where this command has been
observed to stall, green and CLEAN and unmerged. Exiting the *cycle* is not finishing the *PR*.
The `BEHIND` path (Step 3, exit 4) is the same trap: it loops back to 2.3, so the sentinel stays.

Whoever cleans up afterwards must assume this sentinel can outlive a stalled run — `/work`'s stage
teardown removes it explicitly for exactly that reason.

**If `/work` or `/backlog` dispatched this run**, the issue's worktree must already
have been released — their exec stages never invoke `/automerge` themselves; the
orchestrator removes the worktree and dispatches the merge as its own stage, one at a
time (see `/work`'s "Merge queue" and `/backlog` §6f). This matters because Step 3 merges with
`--delete-branch`, which would leave a surviving worktree pinned to a branch that no
longer exists, and `gh pr checkout` above fails while another worktree holds the
branch. If you nonetheless find the branch checked out in a worktree, stop and
surface it rather than merging.

### 2.1 Snapshot review state

Record the set of review-comment IDs and review IDs currently present — this baseline is how new comments are detected later:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate
gh api repos/{owner}/{repo}/pulls/{number}/reviews --paginate
```

Store the IDs you've already addressed across iterations.

### 2.2 Remediate review comments (delegate to `/reviews auto`)

Dispatch the **`remediator`** agent (`Agent`, `subagent_type: "remediator"`,
`run_in_background: false`) with a prompt naming the PR and the skill to run:

> Run `/reviews auto` via the Skill tool for PR #{number} in {owner}/{repo}, on the currently
> checked-out branch. Report one line per the return contract in your definition.

It will fetch comments, categorize them, fix VALID ones, commit, push, reply+resolve every
unresolved thread, and acknowledge review summaries — autonomously, no plan mode, no prompts.

`/reviews` is the single source of truth for review remediation; do not re-implement its
GraphQL/reply/resolve logic here.

**Why a subagent rather than invoking the skill inline:** each dispatch gets a fresh context, so
the repeated `/reviews auto` and `/ci auto` invocations across this command's five cycles do not
re-append their (long) skill bodies into this session. Invoked skill content persists for the
session, and a re-invocation whose rendered content differs appends the whole body again — which
is exactly what happens when the branch state has moved on. The subagent also cannot reach
`EnterPlanMode`/`AskUserQuestion` at all, so an autonomous run cannot stall on a gate.

**Stop** if the remediator reports a contentious/ambiguous comment it could not confidently
categorize, or any reply/resolve API failure (it surfaces the failing comment, error, and
`{pr_url}#discussion_r{comment_id}`).

### 2.3 Wait for and remediate CI (delegate to `/ci auto`)

Dispatch the **`remediator`** agent again (`subagent_type: "remediator"`,
`run_in_background: false`), this time for CI:

> Run `/ci auto` via the Skill tool for PR #{number} in {owner}/{repo}, on the currently
> checked-out branch. Report one line per the return contract in your definition.

It waits for checks with `gh pr checks --watch` (30s interval, 30-minute cap), and on failure
analyzes logs, remediates autonomously, commits, pushes, and re-waits — bounded to 3 attempts.

**Stop** if the remediator reports CI still failing after those attempts, CI not completing within
the 30-minute cap, or that every failing check is an external (non-Actions) check whose logs it
cannot reach — it surfaces the failing check name and the run/check URL in each case.

### 2.4 Wait for the Claude code review (30s poll, 15-minute cap)

Pushing in 2.2 / 2.3 re-triggers the review workflow, so always wait here after any push. The review
runs as the GitHub Actions workflow `.github/workflows/claude-review.yml`, posts its findings as
inline comments authored by `claude[bot]`, and finishes when its workflow run reaches
`status: completed`.

Gating on the run rather than on a reviewer name is deliberate. A workflow run has one terminal
status, and it is keyed to the exact head commit, so no timestamp comparison is needed. The run also
completes cleanly in the cases where no comment is ever posted, such as a triage job that judged
nothing in the PR reviewable.

This wait resolves to **one of three states**, and collapsing the last two into "keep waiting" is an
infinite hang on any repo where the review workflow is not installed:

- **done** — the newest `claude-review` run for the current head commit reads `completed` → proceed to 2.5.
- **not applicable** — the repo has no `claude-review.yml`, or no run exists for this commit after the grace window → log the reason and proceed to 2.5. **Do not wait for a review that will never come.**
- **pending** — a run exists for this commit and has not completed → keep polling until the cap.

Poll every **30 seconds**, capped at **15 minutes total**. A single Bash call cannot span the cap: the tool's ceiling is 600s (`timeout: 600000`), and its *default* is 120s — a bare `sleep 120` loop is killed on its first iteration, which silently ends the turn. So run the loop in bounded chunks of ~9 minutes and re-invoke it until the 15-minute cap is reached, passing `timeout: 600000` explicitly on each call.

**Capture `{head_sha}` before entering the loop** — the commit this wait is about, which is the tip
of the branch you just pushed. Every decision below is keyed to it, and without it the loop reads
another commit's run:

```bash
head_sha=$(git rev-parse HEAD)
```

```bash
# One chunk: 18 iterations x 30s ≈ 9 min. Invoke with timeout: 600000.
# Exits: 0 = done, 3 = not applicable, 4 = chunk elapsed (re-invoke until the 15m cap)
#
# $head_sha comes from the caller (see above). Three guards, none optional:
#
#  - The applicability probe distinguishes a 404 from an API failure. `gh api ... || true`
#    would make an unreachable API indistinguishable from "this repo has no review workflow",
#    which exits 3 and merges while a review is inbound. Only the literal 404 exits 3 here;
#    anything else falls through to the loop, where a still-broken gh rides to exit 4 and the
#    15m cap turns it into a reported stop. That is the correct loud failure.
#
#  - `.workflow_runs` may be absent from the response; `[.workflow_runs[]...]` then aborts jq
#    (rc=5), and the empty result reads as "no run for this commit" — skipping the wait past
#    the grace window. The `// []` must guard the FIELD. (Pinned by tests/jq-run-lookup.sh.)
#
#  - A FAILED gh call must never reach the decision below. An empty $run caused by a
#    network/auth/rate-limit error is indistinguishable from "no run exists for this commit",
#    and past the grace window that reads as exit 3. Retry the tick, conclude nothing.
wf=$(gh api "repos/{owner}/{repo}/actions/workflows/claude-review.yml" --jq '.id' 2>&1)
case "$wf" in
  *"Not Found"*)
    echo "claude-review workflow not installed — skipping wait"; exit 3 ;;
esac

for i in $(seq 1 18); do
  run=$(gh api "repos/{owner}/{repo}/actions/runs?head_sha=$head_sha&per_page=50" \
        --jq '[(.workflow_runs // [])[]
               | select(.path == ".github/workflows/claude-review.yml")]
              | sort_by(.run_number) | last
              | if . == null then "" else "\(.status) \(.conclusion // "")" end' \
        2>/dev/null) \
    || { sleep 30; continue; }
  case "$run" in
    completed*)
      echo "claude-review complete for $head_sha (${run#completed })"; exit 0 ;;
    "")
      # Grace: GitHub delivers the pull_request event asynchronously, so the run can take a
      # minute or two to appear. Past ~3 minutes with no run at all, the event was never
      # delivered for this commit and the remaining cap cannot change that.
      if [ "$i" -gt 6 ]; then
        echo "no claude-review run for $head_sha — skipping wait"; exit 3
      fi ;;
  esac
  sleep 30
done
echo "chunk elapsed, claude-review still pending"; exit 4
```

The `i <= 6` grace window is what stops the event-delivery lag from being read as "not
applicable". Only after ~3 minutes with no run *at all* for this commit does the loop conclude
the workflow never fired for it.

**A run that completed with `conclusion: failure` still exits 0 here, and that is deliberate.** The
review job publishes its own check row on the PR, so a red review is a red check, and 2.3 has
already stopped the run through `/ci auto` before this wait is reached. Holding here as well would
ride every failed review to the 15-minute cap and report the wrong stop condition. The rule the
failure protects against is older than this gate: on a private pull request a reviewer posted an
error stub that satisfied a count-the-reviews gate, and an encryption change merged with no review
coverage at all. A finished run is not the same as a review that happened, so never read the
conclusion as coverage.

**At the 15-minute cap**, if a run for this commit is *still incomplete*, this is a **stop condition**: `claude-review did not complete within 15m`. Never merge a PR while its review is still running. In every other state the loop has already exited and you proceed to 2.5.

The `asyncRewake` hook in `~/.claude/settings.json` (keyed off the sentinel written in Step 2) is the backstop, not the mechanism — if the agent's turn ends mid-wait for any reason, the hook rewakes it to resume polling. The cap above is what guarantees the wait *ends*; the hook only guarantees it isn't abandoned.

### 2.5 Detect new comments & decide

Re-fetch comments/reviews and compare against the baseline from 2.1 (and against IDs already addressed this run):

- **New, unaddressed comments exist** → loop back to 2.2 (next cycle iteration).
- **No new comments AND CI is green** → exit the cycle and proceed to merge (Step 3).

## Step 3: Merge

> **Run this step to completion in a single turn.** The output convention above — timestamp
> *every* turn, intermediate progress turns included — does **not** apply between §2.5's
> all-clear and the merge. Do not summarize, do not report progress, do not hand back: once
> §2.5 says the PR is clean, the next thing you do is merge it.
>
> A PR that is green, `CLEAN`, and fully resolved but still open is the most common failure of
> this command, and every instance of it is a turn that ended inside this gap. It is also where
> the durability hook is weakest: when `/work` dispatches `/automerge` the whole run lives inside
> a subagent, and `Stop` does not fire for subagents — so nothing rewakes you *here*. Keeping the
> sentinel alive through this step (Step 2) does let the orchestrator's own `Stop` catch it
> eventually, and `/work` step 10 re-checks the PR against `gh` afterwards — but both are slow
> backstops for a turn that should never have ended. Do not rely on them; finish the merge.

1. **Confirm mergeability and merge — one Bash call.** The poll and the merge are deliberately
   one script: a tool boundary between them is a place the turn can end.

   `mergeable` is computed asynchronously by GitHub and returns `UNKNOWN` on the first query
   after a push, so it is polled out rather than treated as blocked.

   ```bash
   # Invoke with timeout: 600000. Exits:
   #   0 = merged and verified     2 = conflict      3 = blocked
   #   4 = behind (update + re-wait CI)              5 = not mergeable / unresolved
   #   6 = gh unreachable          1 = merge did not take
   for i in 1 2 3 4 5; do
     j=$(gh pr view {number} --repo {owner}/{repo} \
           --json mergeable,mergeStateStatus 2>/dev/null) || { echo "gh unreachable"; exit 6; }
     m=$(printf '%s' "$j" | jq -r '.mergeable // ""')
     s=$(printf '%s' "$j" | jq -r '.mergeStateStatus // ""')
     [ -n "$m" ] && [ "$m" != "UNKNOWN" ] && break
     sleep 3
   done

   # The two fields mean different things and are judged separately. The allowlist on the
   # last matching line is load-bearing: a DRAFT PR reports mergeable=MERGEABLE, so
   # "anything not explicitly blocked" would merge drafts.
   case "$m:$s" in
     CONFLICTING:*|*:DIRTY)  echo "conflict ($m/$s)"; exit 2 ;;
     *:BLOCKED)              echo "blocked ($m/$s)";  exit 3 ;;
     *:BEHIND)               echo "behind ($m/$s)";   exit 4 ;;
     MERGEABLE:CLEAN|MERGEABLE:UNSTABLE|MERGEABLE:HAS_HOOKS) : ;;
     *) echo "not mergeable ($m/$s)"; exit 5 ;;
   esac

   gh pr merge {number} --squash --delete-branch --repo {owner}/{repo} || exit 1

   # VERIFY. `gh pr merge` can exit 0 without the PR reaching MERGED (merge queue, a race
   # with a concurrent push). The summary must never claim a merge that did not happen.
   state=$(gh pr view {number} --repo {owner}/{repo} --json state -q .state 2>/dev/null)
   [ "$state" = "MERGED" ] || { echo "merge returned 0 but state is ${state:-unreadable}"; exit 1; }
   echo "MERGED"
   ```

2. **Act on the exit code** — and on nothing else. Do not re-derive the verdict from a fresh
   `gh` call; the script already resolved it.
   - `0` → merged **and verified**. Continue to 3.
   - `2` merge conflict → **stop**. Do not auto-resolve; report the blocker and PR URL.
   - `3` blocked → **stop**: required checks or reviews unsatisfied. Report which, via
     `gh pr view {number} --json statusCheckRollup,reviewDecision`.
   - `4` behind → the base moved. Run `gh pr update-branch {number}` and return to 2.3 to
     re-wait for CI. **Not** a stop condition, but it counts against the 5-iteration cycle cap.
   - `5` → **stop**: `GitHub could not compute mergeability` (or the PR is a draft — the
     message carries both values).
   - `6` → **stop**: `could not reach GitHub`. An unreadable state is not a clean one; never
     treat a failed lookup as permission to proceed.
   - `1` → **stop**: the merge did not take. Report the script's message verbatim.
3. **Only now delete this PR's automerge-active sentinel** (see Step 2) — the merge is
   confirmed, so the guard has nothing left to protect:
   `rm -f "$(git rev-parse --show-toplevel)/.claude/automerge-active-{number}"{,.rewakes,.capped,.progress}`.
   Delete it on exit **0**, and on the stop exits **1, 2, 3, 5, 6** before reporting.
   **Not on exit 4.** `BEHIND` is not a stop condition — it updates the branch and loops back
   to 2.3, so the PR is still being worked and deleting the sentinel there would run the whole
   remaining cycle (CI wait, review wait, and this merge step again) with the guard disarmed.
4. Move to the next PR in the queue.

**A `✓ merged` line in Step 4 may only be written for a PR whose script exited 0.** Anything
else is reported as its stop reason, verbatim.

## Step 4: Final summary

Report each PR's outcome:

```
Automerge summary ({owner}/{repo})

✓ #{number} {title} — merged (squash, branch deleted)
✓ #{number} {title} — merged
✗ #{number} {title} — STOPPED: {reason}

Processed {merged_count} merged, stopped at #{number}.
```

Include PR URLs. If the run stopped early, the offending PR and every PR after it in the queue are left untouched.

## Stop conditions (abort the entire run)

- Contentious or ambiguous review comment that can't be confidently categorized.
- Any review reply/resolve API call fails.
- CI still failing after remediation attempts, or CI not completing within its 30-minute cap (`/ci auto` reports both).
- A claude-review run for the head commit still incomplete after its 15-minute cap (see 2.4).
- More than 5 cycle iterations on a single PR.
- PR is in merge conflict (`mergeable = CONFLICTING` or `mergeStateStatus = DIRTY`).
- `mergeStateStatus = BLOCKED` — required checks or reviews unsatisfied.
- `mergeable` still `UNKNOWN` after the 5-poll resolution loop in Step 3. The script does not give
  this its own exit code — it falls to exit 5 (`not mergeable / unresolved`) along with drafts and
  any other unrecognised state, and the message carries both raw values so you can tell them apart.

(`mergeStateStatus = BEHIND` is **not** a stop condition — update the branch and re-run the
cycle from 2.3. It does count against the 5-iteration cap.)

(Every wait in this command is bounded — see the caps in 2.3 and 2.4. The `asyncRewake` durability
hook resumes a wait whose turn ended early; it is not a substitute for a cap, and no wait may be
left uncapped on the assumption the hook will cover it.)

In every case: leave the PR untouched, **delete this PR's automerge-active sentinel**
(see Step 2) so the durability hooks stop rewaking for this PR, do not continue to
other PRs, and surface the failing command + PR URL.

## Important notes

- Requires `gh` CLI installed and authenticated. Repository and branches are pre-resolved by `~/.claude/lib/branches.sh`, injected at the top of this skill.
- Base branch is repo-aware: each merge targets the PR's own base branch. Merge method: squash with branch deletion.
- Delegates review and CI remediation to `/reviews auto` and `/ci auto` (single source of truth), run inside the `remediator` subagent — it does not re-implement that logic.
- Always re-wait for CI and the Claude code review after every push, since pushes re-trigger both.
- Be critical when categorizing review comments — not every comment is worth a code change, but every thread should be resolved with an acknowledgement.
- **Durability**: a `.claude/automerge-active-{number}` sentinel is written per-PR at
  the start of Step 2 and deleted on merge (Step 3) or any Stop condition. It scopes
  the `asyncRewake` hooks in `~/.claude/settings.json` (`Stop`/`TeammateIdle`) to
  active runs owned by this session only — they check live CI and review status and
  rewake the agent if it stopped mid-wait (including the "everything passed but the
  merge never ran" case), so a `/automerge` run can't silently stall for hours.

## Example usage

```
$ /automerge #2

Detecting repo... owner/repo
Resolving scope #2... PR #2: feat: add auth (open)

PR #2: feat: add auth
  Cycle 1: no review comments
  Waiting for CI... ✓  Waiting for review... ✓ (no new comments)
  Merging (squash + delete branch)... ✓ merged

Automerge summary
✓ #2 feat: add auth — merged
```

```
$ /automerge all

Detecting repo... owner/repo
Open non-draft PRs: #42, #43

PR #42: feat: add auth
  Cycle 1: 2 review comments (1 VALID, 1 INVALID) → fixed & resolved, pushed abc123d
  Waiting for CI... ✓ all checks passed
  Waiting for the Claude review... ✓ completed (1 new comment)
  Cycle 2: 1 review comment (VALID) → fixed & resolved, pushed def456a
  Waiting for CI... ✓  Waiting for review... ✓ (no new comments)
  Merging (squash + delete branch)... ✓ merged

PR #43: fix: cache key
  Cycle 1: no review comments
  Waiting for CI... ✗ test failed → STOPPED

Automerge summary
✓ #42 feat: add auth — merged
✗ #43 fix: cache key — STOPPED: CI 'test' failing after remediation
```
