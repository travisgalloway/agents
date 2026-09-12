---
name: ci
# No `model:` pin — intentional. /automerge invokes this mid-turn via the Skill tool, and a model
# override applies for the rest of the calling turn with no way back, so pinning sonnet here would
# silently downshift its caller. It already runs on sonnet when reached through /work's exec subagent.
#
# No `disable-model-invocation` either: /automerge reaches this skill through the Skill tool
# (inside the `remediator` subagent), and that counts as Claude invoking it.
#
# `allowed-tools` matters here specifically. In `auto` mode this command edits files without
# prompting, and an unprompted edit in a default-permission session raises a permission request
# nobody answers — the exact dispatch-then-idle stall the rewake hook exists to catch.
description: Check CI status for the current PR and remediate failures. Invoked by /automerge in `auto` mode, or directly by you for an interactive plan-mode fix.
argument-hint: "[interactive | auto | local]"
arguments: mode
allowed-tools: Read, Edit, Grep, Glob, Bash(git:*), Bash(gh:*), Bash(act:*), Bash(docker:*), Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Check CI status for the current PR and remediate any failures.

**Mode** (default `interactive`):
- **`interactive`** — fetch status, analyze failures, and enter plan mode for approval before fixing (Steps 4–5).
- **`auto`** — wait for checks to complete, then remediate failures autonomously without plan mode or prompts (Step 5-auto). Used when invoked by `/automerge`.
- **`local`** — run the repository's `local-commit-check` job on this machine under `act`, with no
  pull request and no GitHub call (Step 0). The same job the pre-commit gate runs.

**Invoked with:** `$mode`

If nothing appears between those backticks, no argument was passed — use `interactive`.
Every `{mode}` reference below means that resolved value.

## Step 0: Local act run (`local` mode)

Only when `{mode}` is `local`. Steps 1 to 5 do not apply; stop after this step.

1. Verify the Docker daemon answers:
   ```bash
   docker info >/dev/null 2>&1 && echo DOCKER_UP || echo DOCKER_DOWN
   ```
   On `DOCKER_DOWN`, error: "Docker is not running. Start Docker Desktop, then rerun `/ci local`."
2. Verify the repository defines the job. Anchor on the job key, not a prose mention:
   ```bash
   grep -lE '^[[:space:]]+local-commit-check:' .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null
   ```
   If nothing matches, report: "No `local-commit-check` job in `.github/workflows`. Add one from
   `templates/ci-hybrid-workflow.yml` in the agents repository, then rerun." and stop.
3. Run the job. The trigger is `workflow_dispatch`, which GitHub never fires on its own, so the
   same file serves both sides:
   ```bash
   act workflow_dispatch -j local-commit-check
   ```
   Hold the call under the Bash ceiling (`timeout: 600000`). The first run on a machine pulls the
   runner image and can take several minutes.
4. Exit 0: report "Local CI passed under act." and stop.
5. Exit non-zero: show the failing step's output, name the likely fix, and stop. Do not touch
   GitHub, do not commit, and do not enter plan mode; the fix is the user's next move.

## Step 1: Detect Context

1. **`{owner}` and `{repo}` are already resolved** in the repo-context block above. If `owner` is
   empty, error: "No GitHub repository found. This command requires a GitHub repo with an
   authenticated `gh` CLI."

2. `{branch_name}` is `current_branch` from the repo-context block. If it is empty (detached
   HEAD), error: "Detached HEAD — check out the PR's branch first."
3. Use `gh` to find the open PR for this branch (any branch name is fine — the PR is located by its head, not by a naming convention):
   - Run: `gh pr list --head "{branch_name}" --state open --json number -q '.[0].number'`
   - Get the PR number from the result
   - If no PR found, error: "No open PR found for branch '{branch_name}'. Run `/pr` to create one."

## Step 2: Fetch CI Status

**In `auto` mode**, first **wait** for all checks to finish before reading status. `--watch` blocks until completion, so no `sleep` is needed — but it is **not** unbounded, and must not be treated as such:

```bash
gh pr checks {pr_number} --repo {owner}/{repo} --watch --fail-fast --interval 30
```

Two rules make this wait actually terminate:

- **Pass `timeout: 600000` on the Bash call.** The tool's default timeout is 120s, so any CI run longer than two minutes would otherwise be killed as a tool timeout — the wait dies silently and the turn just ends. 600000ms (10 min) is the tool's ceiling.
- **Cap the wait at 30 minutes** — at most **3** such 10-minute calls, re-invoked only while checks are genuinely still pending. If checks have not reached a terminal state after 30 minutes, stop waiting and report `CI did not complete within 30m` as a **failure**, so a caller like `/automerge` hits a clean stop condition instead of hanging.

Then (both modes) fetch the final status of all check runs for the PR **as JSON**:

```bash
gh pr checks {pr_number} --repo {owner}/{repo} --json name,state,bucket,link,workflow
```

Use `--json`. The bare command prints tab-separated text with no `conclusion` or `state` field to
parse, so any instruction to read those fields silently fails against it.

`bucket` is `gh`'s own normalization and maps directly onto the categories below — prefer it over
re-deriving anything from `state`:

| `bucket` | Category | Note |
|---|---|---|
| `pass` | **Passing** | |
| `skipping` | **Passing** | report as `passed (skipped)`, not uncategorized |
| `fail` | **Failing** | |
| `cancel` | **Failing** | |
| `pending` | **Pending** | covers queued / in_progress |

Store each failing check's `link` — Step 4 needs it to locate logs.

## Step 3: Display CI Status

Show a summary of all CI checks:

```
CI Status for PR #{pr_number}

✓ {check_name} - passed
✓ {check_name} - passed
✗ {check_name} - failed
○ {check_name} - pending

Summary: {passing_count} passing, {failing_count} failing, {pending_count} pending
```

**If all checks pass**:
- Display: "✓ All CI checks passing!"
- Exit successfully

**If checks are pending** (and none failing):
- **Interactive mode**: Display "○ CI checks still running. Check back later or wait for completion." and exit (no action needed yet).
- **Auto mode**: this should not happen (you already waited with `--watch` in Step 2); if it does, re-run the `--watch` wait and re-read status — but **within the same 30-minute cap from Step 2**, not as a fresh unbounded wait. Once the cap is spent, report `CI did not complete within 30m` as a failure and stop.

**If any checks are failing**:
- Continue to Step 4

## Step 4: Analyze Failures

For each failing check:

1. **Fetch detailed logs.** `{run_id}` is not something you already have — `gh pr checks` reports
   names, states and links, never run IDs. Derive it from the check's `link` (captured in Step 2):

   ```bash
   # link looks like https://github.com/{owner}/{repo}/actions/runs/<RUN_ID>/job/<JOB_ID>
   run_id=$(printf '%s' "{link}" | sed -n 's#.*/actions/runs/\([0-9]*\).*#\1#p')
   ```

   Then:
   ```bash
   gh run view "$run_id" --log-failed --repo {owner}/{repo}
   ```

   **Fallback — checks with no run id.** Only GitHub Actions checks have one. Third-party checks
   (Vercel, CircleCI, Codecov, any external status) produce a `link` that does not match the
   pattern above and `run_id` comes back empty. Do **not** call `gh run view` with an empty id.
   Instead:
   - Record the check as `{name}: external check, logs at {link}`.
   - If **every** failing check is external, there is nothing to remediate autonomously: report
     the failures with their links as a **stop condition** rather than attempting blind fixes.
   - If some checks are Actions-based, remediate those and report the external ones alongside.

2. **Identify failure type** by parsing logs:
   - **Test failures**: Look for test framework output (jest, vitest, pytest, etc.)
   - **Lint errors**: Look for eslint, prettier, or other linter output
   - **Build errors**: Look for TypeScript, compilation, or bundling errors
   - **Other**: Deployment, security scanning, etc.

3. **Extract key error information**:
   - Error messages
   - File paths and line numbers
   - Stack traces (if applicable)

4. **Display failure analysis**:
   ```
   Failing Checks Analysis:

   ✗ {check_name}
     Type: {test|lint|build|other}
     Errors:
       - {file}:{line} - {error_message}
       - {file}:{line} - {error_message}
   ```

## Step 5: Remediate

Follow the path matching `{mode}`:

### Step 5-auto: Autonomous remediation (`auto` mode)

Do **not** enter plan mode. Remediate without prompting:

1. For each failing check, fetch failure logs (Step 4's `run_id` derivation + `gh run view
   "$run_id" --log-failed --repo {owner}/{repo}`) and identify the root cause from Step 4's
   analysis. External checks with no run id are not remediable here — see Step 4's fallback.
2. Apply fixes directly with the Edit tool.
3. Commit and push to the current branch. The issue reference is the **issue** number —
   `branch_issue` from the repo-context block above — matching `/commit` conventions and the rest
   of this suite. Do not use the PR number: `#{pr_number}` in a commit on that same PR is a
   self-referential link. If the branch carries no issue number, omit the reference entirely.

   **Re-derive `branch_issue` if the branch changed since this skill was loaded.** The
   repo-context block is rendered once, at load time, and `/automerge` Step 2 runs
   `gh pr checkout {number}` — so when this skill is reached through that path the injected
   `current_branch` describes whatever was checked out *before* the switch. Confirm with
   `git branch --show-current` before trusting it.
   ```bash
   git add {files}
   git commit -m "fix: resolve CI failures (#{issue_number})

   - {summary of each fix}"
   git pull --rebase origin "{branch_name}" && git push origin "{branch_name}"
   ```
   Rebase before pushing: inside `/automerge`, `/reviews auto` pushes to this same branch in the
   same cycle, so a bare push routinely fails non-fast-forward. If the rebase conflicts, stop and
   surface it. If it rewrote history, push with `--force-with-lease` (never a bare `--force`).
4. **Re-wait** for checks under the same bounded rules as Step 2 (`--interval 30`, `timeout: 600000`, 30-minute cap), then re-read status.
5. Repeat steps 1–4 up to **3 remediation attempts**. If checks pass → report success and exit. If checks still fail after 3 attempts, or a wait hits its 30-minute cap → report failure clearly (failing check name + `gh run view` URL, or `CI did not complete within 30m`) so the caller (e.g. `/automerge`) can stop. Do not loop indefinitely.

### Step 5-interactive: Plan mode (`interactive` mode)

After analyzing failures, use the `EnterPlanMode` tool to design a remediation approach.

**In plan mode, you should:**

1. **Review failure logs in detail**:
   - Re-read the full error output for each failing check
   - Understand the exact nature of each failure
   - Note any patterns across multiple failures

2. **Explore relevant code files**:
   - Read files mentioned in error messages
   - Understand the context around failing code
   - Identify related files that might be affected

3. **Identify root causes**:
   - Determine if failures are due to code changes in this PR
   - Check if failures are flaky tests or infrastructure issues
   - Identify if failures are related to each other

4. **Design specific fixes**:
   - Outline exact changes needed for each failure
   - Consider impact on other parts of the codebase
   - Note any test updates needed

5. **Include verification steps**:
   - Commands to run locally to verify fixes
   - How to re-trigger CI after pushing fixes

**Exit plan mode** with `ExitPlanMode` tool once the plan is complete. User must approve the plan before implementation begins.

## Error Handling

- **No PR found**: "No open PR found for branch '{branch_name}'. Run `/pr` to create one first."
- **No CI checks**: "No CI checks found for this PR. CI may not be configured."
- **GitHub API error**: Display the error message and suggest checking GitHub status

## Example Usage

```
$ /ci

Fetching CI status for PR #42...

CI Status for PR #42: feat: add user authentication

✓ lint - passed (12s)
✓ typecheck - passed (8s)
✗ test - failed (45s)
○ deploy-preview - pending

Summary: 2 passing, 1 failing, 1 pending

Analyzing failures...

✗ test
  Type: Test failure
  Errors:
    - src/auth/login.test.ts:45 - Expected 200, received 401
    - src/auth/login.test.ts:67 - Timeout waiting for response

1 failing check needs attention. Entering plan mode to design fixes...

[EnterPlanMode]
```

## Important Notes

- Works from any branch that has an open PR (the PR is located by its head branch)
- Requires `gh` CLI to be installed and authenticated
- Fetches latest CI status from GitHub (not cached)
- Interactive mode uses plan mode for thoughtful fixes; auto mode remediates autonomously (used by `/automerge`)
- **Repository & branches**: pre-resolved by `~/.claude/lib/branches.sh`, injected at the top of this skill — the shared resolver used by every command in this suite
