---
name: sync
model: haiku
effort: low
description: Sync the release, integration, and current branches with the remote (fetch --all -p)
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Synchronize the release branch, the integration branch, and the current branch with the remote in one shot — without switching branches — running the `git fetch --all -p` prune. Validation happens up front: if anything is unsafe, the whole sync aborts **before** any branch is touched.

## Step 1: Resolve branches (repo-aware)

`{integration_branch}`, `{release_branch}` and `{current_branch}` are already resolved in the
repo-context block above, via the shared ladder in `~/.claude/lib/branches.sh` (config
`baseBranch`/`releaseBranch` → GitHub default → `origin/HEAD` → `main`/`master`). `gh` is
best-effort there; the git fallbacks cover the case where it is unavailable.

If `{integration_branch}` equals `{release_branch}`, the repo has a single protected branch and
the set below simply collapses to one.

## Step 2: Build the sync set (deduplicated)

The sync set is, with duplicates removed:

1. `{release_branch}` — a candidate.
2. `{integration_branch}` — only if it differs from `{release_branch}`.
3. **Current branch** — only if it is not detached HEAD (`git branch --show-current` is
   non-empty) and not already `{release_branch}` or `{integration_branch}` (already covered).

**Then filter the whole set by remote counterpart** — every member, not just the current branch:

```bash
git rev-parse --verify --quiet "origin/<branch>" >/dev/null
```

A branch with **no** `origin/` counterpart is **skipped**, reported as
`⊘ <branch>: skipped (no remote counterpart)`. This is not an error. It happens routinely: a
feature branch that was never pushed, a `{release_branch}` that resolved to `main` in a repo
that only ever pushed `master`, or a configured `releaseBranch` that does not exist remotely.

Applying this filter to the protected branches too is the point — without it, Step 3's
classification runs `git rev-parse origin/<branch>` on a ref that does not exist and the whole
sync dies partway through validation.

If the filtered set is empty, report `Nothing to sync (no branches with remote counterparts)`
and exit 0.

## Step 3: Preflight + validate (abort BEFORE mutating anything)

1. **Working tree must be clean:**
   ```bash
   git status --porcelain
   ```
   - If output is non-empty, **abort**: "❌ Working tree has uncommitted changes. Commit or stash before running /sync." (No auto-stash.)

2. **Prune-fetch** — updates remote-tracking refs and prunes deleted remotes; does **not** touch local branch tips:
   ```bash
   git fetch --all -p
   ```

3. **Classify each branch** in the sync set against `origin/<branch>` (no mutation yet):
   - **up-to-date** — local tip equals `origin/<branch>` (`git rev-parse <branch>` == `git rev-parse origin/<branch>`).
   - **behind (fast-forwardable)** — local tip is an ancestor of the remote tip:
     ```bash
     git merge-base --is-ancestor <branch> origin/<branch>
     ```
     (exit 0, and tips differ).
   - **no local branch yet** — only `origin/<branch>` exists locally; treated as fast-forwardable (will be created from remote).
   - **diverged/ahead** — local branch exists but is **not** an ancestor of `origin/<branch>` (it has commits not on the remote).

4. **Abort on any divergence:** if **any** branch is classified **diverged/ahead**, abort the entire sync before applying updates:
   - "❌ {branch} has local commits not on origin (diverged) — cannot fast-forward. Resolve manually."
   - List **every** offending branch. Leave all branches untouched.

## Step 4: Apply updates (only if all validation passed)

For each branch classified **behind** or **no local branch yet**:

- **Current branch** (the checked-out one): `git pull --ff-only`
- **Non-current branch:** fast-forward (or create) the local ref without checkout:
  ```bash
  git fetch origin <branch>:<branch>
  ```

Branches classified **up-to-date** are skipped (no-op). Never switch branches; never force; never merge.

## Step 5: Summary

Show a per-branch result:

```
Sync complete

✓ {release_branch}: updated ({n} new commits)
✓ {integration_branch}: updated ({n} new commits)
• {current_branch}: already up to date
⊘ {current_branch}: skipped (no remote counterpart)

Pruned {count} deleted remote branch(es)
💡 Consider rebasing your feature branch onto the updated {integration_branch}.
```

Compute new-commit counts with `git rev-list --count <branch_before>..origin/<branch>`, capturing
each branch's tip **before** the update.

Mind the direction: `A..B` counts commits reachable from `B` but not `A`. For a branch that was
*behind*, `<branch_before>` is an ancestor of `origin/<branch>`, so the reversed form
`origin/<branch>..<branch_before>` always returns **0** and every branch reports "updated (0 new
commits)". (Pinned by `tests/git-scenarios.sh`.)

Show the rebase reminder only when a separate current feature branch was part of the set.

## Error Handling

- **No upstream for current branch** (`git pull --ff-only` reports no tracking information):
  - Suggest: `git branch --set-upstream-to=origin/{current_branch} {current_branch}`
- **Network / auth failure** on `git fetch`:
  - Display the error and suggest checking connectivity and `gh auth status`.
- **Non-fast-forward surfaces at apply time** (race after validation): report the branch and stop; do not force.

## Usage Example

```bash
/sync

# On feat/42-vector-search in a dev→main repo:
# Resolving branches... release=main, integration=dev
# Sync set: main, dev, feat/42-vector-search
# Working tree clean ✓
# Fetching --all -p...
# Validating fast-forward for main, dev, feat/42-vector-search... all OK
#
# Sync complete
# ✓ main: updated (3 new commits)
# ✓ dev: updated (5 new commits)
# • feat/42-vector-search: already up to date
# Pruned 2 deleted remote branch(es)
# 💡 Consider rebasing your feature branch onto the updated dev.
```

## Important Notes

- **No branch switching**: the current branch never changes; protected branches are fast-forwarded via refspec fetch.
- **Repo-aware**: release/integration branches come from `.claude/branch-config.json` (`releaseBranch` / `baseBranch`) when present, otherwise auto-detected from the GitHub default branch and `main`/`master`.
- **Safe by construction**: all validation runs before any update; a dirty tree or any diverged branch aborts the whole operation with nothing changed.
- **Fast-forward only**: never merges or forces — divergence is surfaced for manual resolution.
