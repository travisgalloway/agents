---
name: status
model: sonnet
effort: low
description: Show current development status for the active feature branch — issue, checklist progress, and git stats
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Show current work status for the active feature branch:

1. **`{owner}`, `{repo}`, `{integration_branch}` and `{current_branch}` are already resolved** in
   the repo-context block above. If `owner` is empty, error: "No GitHub repository found. This
   command requires a GitHub repo with an authenticated `gh` CLI."

2. Display `{current_branch}`. If it is empty (detached HEAD), show "Detached HEAD — not on a
   branch" and exit.

3. Determine whether this is a recognized work branch, using `branch_recognized` and
   `branch_issue` from the repo-context block above — both are already parsed, so do not
   re-derive them:
   - `branch_recognized=false` → show "Not a recognized work branch (expected a Conventional
     Commits type, e.g. `fix/17-null-deref`)" and exit.
   - Recognized with a non-empty `branch_issue` → that is `{issue_number}`; continue to step 4.
   - Recognized with an **empty** `branch_issue` (e.g. `chore/bump-deps`) → this is normal, not
     an error. Skip steps 4-6 entirely and go straight to the git statistics in step 7.
4. Fetch issue details: `gh issue view {issue_number} --json number,title,state,labels,milestone,body`
   - If this fails, the number may name a PR rather than an issue: retry with
     `gh pr view {issue_number} --json number,title,state,body` and label the output accordingly.
     If both fail, show "No issue or PR #{issue_number} found" and continue to the git stats.
5. Display issue information:
   - Issue #: {number} - {title}
   - Status: {state} ({status on project board if available})
   - Labels: {label list}
   - Milestone: {milestone name or "None"}
6. Parse and display checklist progress:
   - Extract all checklist items from issue body (markdown patterns: `- [ ]` and `- [x]`)
   - Show: "Tasks: {completed}/{total}"
   - List completed tasks (✓)
   - List remaining tasks (○)
7. Show git statistics.

   **Refresh the base ref first** — otherwise every count below is measured against whatever
   `{integration_branch}` happened to be at the last local pull, and silently drifts stale:

   ```bash
   git fetch origin {integration_branch}
   ```

   Then compare against `origin/{integration_branch}`:
   - Commits on this branch: `git rev-list --count origin/{integration_branch}..HEAD`
   - Files changed: `git diff --shortstat origin/{integration_branch}...HEAD`
     (`--shortstat` alone — passing `--stat` as well is a conflicting output format, and the
     later flag simply wins.)
   - Last commit: `git log -1 --format="%h - %s (%cr)"`

   If the fetch fails (offline, no auth), fall back to the local `{integration_branch}` ref and
   note `(base ref may be stale — fetch failed)` in the output rather than erroring.

8. Show quick actions available:
   - `/commit` - Make a new commit
   - `/ci` - Check CI status and remediate failures
   - `/reviews` - Address PR review comments
   - `/pr` - Create pull request
   - `/automerge` - Autonomously remediate and merge open PRs
   - `/work {issue}` - Switch to different issue

Important notes:

- Works on any recognized work branch — any Conventional Commits type, plus legacy `feature/`. A branch with no issue number shows git stats only
- Repository, integration branch and current branch come pre-resolved from
  `~/.claude/lib/branches.sh` (injected at the top of this skill) — the same resolver every
  command in this suite uses, so they can never disagree about the base branch
- Git stats are measured against `origin/{integration_branch}` after a fetch, not the local ref
- Provides a quick overview of current progress
- Helps track checklist completion
