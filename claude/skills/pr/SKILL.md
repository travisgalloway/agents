---
name: pr
# No `model:` pin — intentional. /work invokes this mid-turn via the Skill tool, and a model
# override applies for the rest of the calling turn with no way back, so pinning sonnet here
# would silently downshift the opus /work orchestrator. It already runs on sonnet when
# dispatched, because it runs inside /work's sonnet exec subagent.
#
# No `disable-model-invocation` either, for the same handoff reason: /work step 9 reaches this
# skill through the Skill tool, and that counts as Claude invoking it — the flag would break the
# chain. The description below is narrowed instead, so it does not read as generally applicable.
description: Push the current feature branch and open its pull request. Invoked by /work at its PR gate, or directly by you from a feature branch — not a general-purpose git helper.
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Create a pull request for the current feature branch:

1. **`{owner}` and `{repo}` are already resolved** in the repo-context block above. If `owner` is
   empty, error: "No GitHub repository found. This command requires a GitHub repo with an
   authenticated `gh` CLI."

2. **`{integration_branch}` is already resolved** there too (config `baseBranch` → GitHub default
   → `origin/HEAD` → `main`/`master`). All references to "the integration branch" below mean that
   value (e.g. `dev` in a dev→main release flow).

3. `{branch_name}` is `current_branch` from the repo-context block. If it is empty (detached
   HEAD), error: "Detached HEAD — check out a feature branch first."

4. **Verify this is a recognized work branch.** `branch_recognized` in the repo-context block
   above is `true` when `{branch_name}` matches the suite's branch grammar:

   ```
   {type}[({scope})][!]/[{issue_number}-]{slug}
   ```

   where `{type}` is a Conventional Commits type — `feat` `fix` `docs` `style` `refactor` `perf`
   `test` `build` `ci` `chore` `revert` — or the legacy `feature`. So `feat/42-vector-search`,
   `fix/17-null-deref`, `feat(api)/9-pagination`, `fix!/23-breaking` and `chore/bump-deps` all
   qualify, as does every existing `feature/42-slug` branch.

   If `branch_recognized` is `false`, error: "'{branch_name}' is not a recognized work branch.
   Expected `{type}/[{issue}-]{slug}` with a Conventional Commits type (see
   https://www.conventionalcommits.org/en/v1.0.0/#summary), e.g. `fix/17-null-deref`."

5. **`{issue_number}` is `branch_issue`** from the repo-context block — already parsed from the
   branch, so do not re-derive it. It may be **empty**, which is normal: a branch like
   `chore/bump-deps` carries no issue. Empty means **issue-less mode** — see step 9.

6. **Pre-flight checks:**
   - Check if remote branch exists: `gh api repos/{owner}/{repo}/branches/"{branch_name}" 2>/dev/null` (success = exists; non-zero/404 = deleted or never pushed)
   - Fetch latest integration branch: `git fetch origin {integration_branch}:{integration_branch}`
   - Count local commits ahead of the integration branch: `git rev-list --count {integration_branch}..HEAD`
   - Check if working tree is clean: `git status --porcelain`
   - **Classify whether the branch's work is already upstream** (`{already_merged}`) — see below.

   **Is the work already in the integration branch?** The commit count above **cannot** answer
   this. `/automerge` merges with `gh pr merge --squash`, which writes a *new* commit, so the
   branch's original commits are never ancestors of the integration branch and the count stays
   `> 0` forever. Deciding on the count alone makes Scenario D unreachable and turns every
   post-merge resume into a duplicate PR.

   Run these three tests in order; the first that matches sets `{already_merged} = true`:

   ```bash
   # 1. Ordinary merge commit or fast-forward.
   git merge-base --is-ancestor HEAD {integration_branch} && echo D

   # 2. Squash merge, integration branch not advanced since: trees are identical.
   #    NOTE two dots (tip vs tip). Three dots would diff against the merge base, which after
   #    a squash merge is still the original branch point — it never detects the merge.
   git diff --quiet {integration_branch} HEAD && echo D

   # 3. Squash merge, integration advanced since: compare only the paths this branch touched.
   base=$(git merge-base {integration_branch} HEAD)
   git diff --name-only "$base" HEAD \
     | tr '\n' '\0' | xargs -0 git diff --quiet {integration_branch} HEAD -- && echo D
   ```

   Do **not** use the PR's `mergedAt` with `git rev-list --since`: that filters on committer
   date, which a rebase rewrites, so a rebased-but-merged branch misclassifies. The
   touched-paths test is date-independent. (All four cases pinned by `tests/git-scenarios.sh`.)

7. **Scenario detection and handling.** Evaluate in the order **A → B → D → C**: D and C share
   the same "remote deleted, count > 0" precondition and are separated only by
   `{already_merged}`, so C must be the fallback, never the first match.

   **Scenario A: Normal flow (remote exists OR first push)**
   - Remote branch exists, OR branch never pushed
   - → Continue to step 9 (normal PR creation)

   **Scenario B: Remote deleted, no local changes**
   - Remote branch deleted (the `gh api` branch lookup returns 404 / non-zero)
   - Local branch has 0 commits ahead of the integration branch
   - Working tree is clean
   - → Display: "✓ PR was merged and branch cleaned up remotely. Your local branch is clean."
   - → Suggest: `git checkout {integration_branch} && git pull && git branch -D "{branch_name}"`
   - → Exit without creating PR

   **Scenario C: Remote deleted, has genuinely new local work (NEEDS RECOVERY)**
   - Remote branch deleted
   - Local has commits ahead of the integration branch (count > 0)
   - **AND `{already_merged}` is false** — the work is not yet upstream
   - → Automatically create follow-up branch:
     - Create new branch: `git checkout -b "{branch_name}-followup"`
     - **Suffix the branch you are on** — do not rebuild the name from parts. That preserves
       whatever type and scope it already had (`fix/17-x` → `fix/17-x-followup`), and a name
       rebuilt from `feature/` would silently change the branch's type mid-flight.
     - New branch includes all local commits
     - Continue to step 9 with new branch name
     - Display: "✓ PR was merged. Created follow-up branch: {branch_name}-followup"

   **Scenario D: Remote deleted, commits already in the integration branch**
   - Remote branch deleted
   - Local commits exist (count > 0) but **`{already_merged}` is true**
   - This is the *common* case after `/automerge`, not the rare one — check it **before** C
   - → Display: "✓ PR was merged. Your commits are already in {integration_branch}."
   - → Suggest: `git checkout {integration_branch} && git pull && git branch -D "{branch_name}"`
   - → Exit without creating PR

8. If Scenario B or D: Exit here (no PR creation needed)

9. **Confirm the issue, or fall back to issue-less mode.** If `{issue_number}` is non-empty,
   fetch its title: `gh issue view {issue_number} --json title -q .title`.

   **If that command fails, treat the branch as issue-less** — drop `{issue_number}` and carry on.
   This is load-bearing, not defensive tidying: the issue segment of a branch name is inherently
   ambiguous, and `fix/2024-01-migration` parses as issue **#2024**. Writing `Closes #2024` on
   that branch would link, and on merge close, an unrelated issue. A number the branch merely
   *looks like* it contains is a candidate; `gh` is what confirms it.

   In issue-less mode: use the branch slug (title-cased) as the PR title text in step 12, and
   omit the `Closes` line from the body.

10. Generate a PR summary:
    - Review the commit messages on this branch (use `git log {integration_branch}..HEAD --oneline`)
    - Summarize the changes made in a few bullet points

11. Push the current branch to origin: `git push -u origin "{branch_name}"`

12. Create the PR using `gh pr create`:

    ```bash
    gh pr create \
      --base "{integration_branch}" \
      --head "{branch_name}" \
      --title "{type}: {issue_title}" \
      --body "$(cat <<'EOF'
    Closes #{issue_number}

    ## Summary
    {bullet points of changes}

    ## Testing
    - [ ] Tests added/updated
    - [ ] All tests passing
    - [ ] Manual testing completed
    EOF
    )"
    ```

    - **body first line**: `Closes #{issue_number}` normally — but for a **followup branch
      (Scenario C)** use `Refs #{issue_number}` instead: the original PR's merge already closed the
      issue, and a second `Closes` re-links (and on reopen, re-closes) it for no reason.
      **In issue-less mode (step 9), omit the line entirely** — no `Closes`, no `Refs`.
    - **title**: Issue title prefixed with a conventional commit type. Determine the type based on the primary change:
      - `feat:` - New features or functionality
      - `fix:` - Bug fixes
      - `docs:` - Documentation changes only
      - `test:` - Test additions/changes
      - `refactor:` - Code refactoring without changing behavior
      - `chore:` - Build/config/dependency changes

      **The branch's own type is a hint, not a constraint, and the diff wins.** A branch type is
      guessed from the issue's labels before any code exists; this one is read from the change
      that actually landed, and it becomes the squash commit subject. A `docs:` PR from a
      `feat/` branch is correct and needs no comment. **Never rename the branch to match** — the
      sentinel, the ledger, the Monitor's PR probe, `hooks/automerge-rewake.sh`'s
      `refs/heads/{branch}` check and teardown all key off the recorded name, and every one of
      them fails silent when it changes.
    - **base**: `{integration_branch}`
    - **head**: `{branch_name}` (`gh` auto-detects this from the current branch; pass it explicitly to be safe)
    - Creates a non-draft PR. `gh pr create` prints the PR URL on success.

13. Display:

- PR URL
- PR number
- Issue link
- Reminder to move issue to "In Review" on project board (manual step)

Important notes:

- Only works from a recognized work branch — any Conventional Commits type, plus legacy `feature/` (step 4)
- **Base branch is repo-aware**: opens the PR against `{integration_branch}`, read from `.claude/branch-config.json` (`baseBranch`) when present, otherwise auto-detected from the GitHub default branch / `main` / `master`. In a flow that pushes features to `dev` and cuts releases from `main`, PRs target `dev`.
- **Handles merged PR scenario**: Detects when remote branch was deleted (PR merged) and local has new work
- Ensures all commits are pushed before creating PR
- Uses conventional PR format with issue linking
- Does not automatically move issue status (requires manual confirmation)
- **Smart recovery**: Automatically creates follow-up branch when continuing work after PR merge
