---
name: commit
effort: low
description: Make a properly formatted commit with issue reference
argument-hint: "<message>"
# No `model:` pin — intentional, matching /pr, /ci, /reviews and /automerge. A model override
# applies for the rest of the calling turn with no way back, so pinning sonnet here would
# silently downshift any opus caller that reaches this skill. /work's exec stage already runs
# on sonnet.
#
# User-invoked only: committing is a side effect whose timing belongs to you. Nothing in the
# suite invokes /commit through the Skill tool — /work and work-exec reference "/commit
# conventions" and inline them — so denying model invocation breaks no handoff.
disable-model-invocation: true
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved):

!`__CLAUDE_HOME__/lib/branches.sh`

**Invoked with:** $ARGUMENTS

That text is the commit message. If it is blank, derive a concise conventional-commit
subject from the staged diff instead of prompting.

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Make a commit with conventional commit format:

1. The current branch is `current_branch` from the repo-context block above. If it is empty
   (detached HEAD), stop: "Detached HEAD — check out a branch before committing."

2. **The repo's protected branches** (`{integration_branch}` and `{release_branch}`) are already
   resolved in the repo-context block above, via the shared ladder in `~/.claude/lib/branches.sh`.

   If `{release_branch}` equals `{integration_branch}`, the repo has a single protected branch and
   the guard below simply applies to that one branch. If either came back empty, the guard cannot
   be enforced — say so and stop rather than committing blind.

3. **Verify NOT on a protected branch**:
   - If the current branch equals `{integration_branch}` or `{release_branch}`, display error and exit: "❌ Cannot commit directly to {branch}. It's a protected branch — please create a feature branch first."
   - This enforces the branch protection rule - all changes must go through PRs
4. **`{issue_number}` is `branch_issue`** from the repo-context block above — already parsed
   from the branch by the shared grammar, so do not re-derive it. It is empty when the branch
   carries no issue number (`chore/bump-deps`) or is not a recognized work branch; that is
   normal and handled in step 6.
5. Determine the commit type based on the changes and message context:
   - `feat:` - New features or capabilities
   - `fix:` - Bug fixes
   - `docs:` - Documentation changes
   - `test:` - Test additions or modifications
   - `refactor:` - Code restructuring without behavior change
   - `chore:` - Build, config, or tooling changes
6. Format the commit message as: `{type}: {message} (#{issue_number})`
   - Example: `feat: add storage adapter interface (#12)`
   - **If `{issue_number}` is empty, omit the suffix entirely**: `chore: bump deps`. Never
     substitute a PR number.
   - The commit type comes from **this commit's changes**, not from the branch's prefix. A
     `docs:` commit on a `feat/` branch is correct and common.
7. Stage changes:
   - First inspect what will be staged: `git status --porcelain`
   - **If the output is empty, there is nothing to commit.** Report "Nothing to commit — working
     tree clean" and exit successfully. Do not proceed: `git commit` with an empty index fails,
     and inside `/work`'s exec stage that failure reads as a blocker when the real situation is
     that a previous step already committed everything.
   - Display the exact list of files (modified, new/untracked, deleted) that are about to be committed, so nothing unintended is included silently.
   - Then stage all changes with `git add -A`

     Use `-A`, not `git add .`: the bare form is **relative to the current working directory**, so
     run from a subdirectory (a monorepo package, or one of `/work`'s per-issue worktrees) it
     silently omits changes elsewhere in the repo — including files this command just listed.
8. Create the commit with the formatted message
9. Display:
   - Commit type used
   - Full commit message
   - Commit hash (short form)
   - Files changed summary (the staged file list shown in step 7)

Important notes:

- Protected branches are read from `.claude/branch-config.json` (`baseBranch` / `releaseBranch`) when present, otherwise auto-detected from the GitHub default branch and `main`/`master`
- If the branch carries no issue number, create the commit without an issue reference
- Choose the most appropriate commit type based on the nature of changes
- Keep the message concise and descriptive
- Use imperative mood (e.g., "add" not "added", "fix" not "fixed")
