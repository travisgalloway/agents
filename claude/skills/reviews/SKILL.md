---
name: reviews
# No `model:` pin — intentional. /automerge invokes this mid-turn via the Skill tool, and a model
# override applies for the rest of the calling turn with no way back, so pinning sonnet here would
# silently downshift its caller. It already runs on sonnet when reached through /work's exec subagent.
#
# No `disable-model-invocation` either: /automerge reaches this skill through the Skill tool
# (inside the `remediator` subagent), and that counts as Claude invoking it.
#
# `allowed-tools`: in `auto` mode this command edits files without prompting; without the grant,
# the first edit in a default-permission session blocks on a prompt nobody answers.
description: Fetch, analyze, and remediate PR review comments, then resolve the threads. Invoked by /automerge in `auto` mode, or directly by you for an interactive pass.
argument-hint: "[interactive | auto]"
arguments: mode
allowed-tools: Read, Edit, Grep, Glob, Bash(git:*), Bash(gh:*), Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Fetch and address review comments for the current PR.

**Mode** (default `interactive`):
- **`interactive`** — present analysis, confirm with the user, and enter plan mode before fixing (Steps 4–5).
- **`auto`** — skip all prompts and plan mode; remediate VALID comments and resolve every thread autonomously. Used when invoked by `/automerge`.

**Invoked with:** `$mode`

If nothing appears between those backticks, no argument was passed — use `interactive`.
Every `{mode}` reference below means that resolved value.

## Step 1: Fetch Context

1. **`{owner}` and `{repo}` are already resolved** in the repo-context block above. If `owner` is
   empty, error: "No GitHub repository found. This command requires a GitHub repo with an
   authenticated `gh` CLI."

2. `{branch_name}` is `current_branch` from the repo-context block. If it is empty (detached
   HEAD), error: "Detached HEAD — check out the PR's branch first."
3. Use `gh` to find the open PR for this branch (any branch name is fine — the PR is located by its head, not by a naming convention):
   - Run: `gh pr list --head "{branch_name}" --state open --json number -q '.[0].number'`
   - Get the PR number from the result
   - If no PR found, error: "No open PR found for branch '{branch_name}'. Run `/pr` to create one."

## Step 2: Retrieve Review Comments

Two **different kinds** of feedback live at two endpoints, and they are **not interchangeable**.
Keep them in separate lanes for the whole command — merging them is what breaks Step 7:

| Lane | Endpoint | Repliable? | Resolvable? |
|---|---|---|---|
| **Line comments** | `pulls/{n}/comments` | Yes — `/comments/{id}/replies` | Yes — belongs to a review thread |
| **Review summaries** | `pulls/{n}/reviews` | **No** — there is no replies endpoint | **No** — has no review thread |

A review summary is the top-level body a reviewer submits alongside their line comments.
**An automated reviewer posts one on essentially every PR it reviews.** Treating it like a line comment means
POSTing to `/comments/{summary_id}/replies`, which 404s — and in `auto` mode that failure aborts
the whole `/automerge` run. This is the single most common way this command fails in practice.

1. Fetch both, into separate collections:
   - **Line comments** → `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --paginate`
   - **Review summaries** → `gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews --paginate`
     Keep only entries with a non-empty `.body`; a review with an empty body carries no feedback
     and is skipped entirely.

2. **IMPORTANT**: For each **line comment**, extract and store:
   - **id** - Comment ID (needed for replies)
   - **thread_node_id** - Thread's GraphQL node ID (needed for resolving threads, e.g., `PRRT_...`)
   - File path and line number
   - Comment body
   - Author
   - Created date

3. **Obtain thread node IDs** using GraphQL:

   Since review comments don't directly include their thread's node ID, query the PR's review
   threads — **paginated, and with every comment in each thread**. A `first: 20` un-paginated query
   silently drops threads past the first page, and fetching only a thread's first comment means a
   comment that is a *reply* never maps to its thread — either way the resolve step later fails,
   which in auto mode aborts the whole `/automerge` run:

   ```bash
   gh api graphql -f query='
   query($cursor: String) {
     repository(owner: "{owner}", name: "{repo}") {
       pullRequest(number: {pr_number}) {
         reviewThreads(first: 100, after: $cursor) {
           pageInfo { hasNextPage endCursor }
           nodes {
             id
             isResolved
             comments(first: 50) {
               nodes {
                 id
                 databaseId
               }
             }
           }
         }
       }
     }
   }'
   ```

   Re-invoke with `-f cursor={endCursor}` while `hasNextPage` is true, accumulating all threads.
   Match each **line comment** from Step 2 against **any** comment in a thread (by `databaseId` =
   the REST `id`, or `id` = the REST `node_id`) to find its parent thread's `id` (the
   thread_node_id).

   **Drop threads where `isResolved` is true.** The field is already selected above; act on it.
   `/automerge` runs up to 5 cycles per PR and calls this command each time, so without the
   filter every already-handled thread collects a fresh "✅ Fixed in …" reply on every pass.
   An already-resolved thread is out of scope: no analysis, no reply, no re-resolve.

   If a line comment matches no thread after full pagination, surface that comment explicitly
   rather than resolving blind. (Review summaries never match a thread **by design** — they are
   not thread members. Do not route them through this lookup at all.)

4. Display the unresolved line comments and the review summaries found, each with the details above

## Step 3: Analyze Validity

For each review comment, critically evaluate using these criteria:

**VALID** - Should be fixed:

- Technically correct (actual bugs, security issues, performance problems)
- Improves code quality (removes unused code, fixes inconsistencies)
- Follows project conventions (naming, structure, patterns)
- Low effort, high value fixes

**QUESTIONABLE** - Needs discussion:

- Subjective style preferences without clear benefit
- Refactoring suggestions that change working code significantly
- Comments that might introduce breaking changes
- Unclear or ambiguous feedback

**INVALID** - Can be ignored:

- Incorrect understanding of the code
- Suggestions that would break functionality
- Nitpicks that don't improve anything meaningful
- Already addressed in later commits

## Step 4: Present Analysis

1. Group comments by category (VALID, QUESTIONABLE, INVALID)
2. **IMPORTANT**: Maintain a tracking map for each comment:

   ```
   {
     comment_id: <id>,
     thread_node_id: <thread_node_id>,  // Thread's GraphQL node ID (PRRT_...), not comment's node ID
     file: <path>,
     line: <line>,
     body: <body>,
     category: <VALID|QUESTIONABLE|INVALID>,
     reasoning: <why categorized this way>,
     status: <pending>  // Will update to: fixed, skipped, discussed
   }
   ```

3. For each comment, show:
   - **File**: {path}:{line}
   - **Comment**: {body}
   - **Category**: {VALID/QUESTIONABLE/INVALID}
   - **Reasoning**: Why you categorized it this way
   - **Effort**: {Low/Medium/High}

4. Display summary:

   ```
   Review Comments Analysis:
   ✓ VALID: {count} comments to fix
   ? QUESTIONABLE: {count} comments to discuss
   ✗ INVALID: {count} comments to ignore
   ```

5. Disposition (in `auto` mode this proceeds directly; in `interactive` mode it is what you
   propose to the user at Step 5):
   - VALID comments will be fixed
   - QUESTIONABLE comments will be resolved with a discussion note
   - INVALID comments will be resolved with skip reasoning
   - Review summaries will be acknowledged in a single PR comment (Step 7 · 2.5)

## Step 5: Plan / proceed

Follow the path matching `{mode}`:

- **Auto mode**: Do **not** prompt and do **not** enter plan mode. Proceed directly to Step 6 to remediate all VALID comments and Step 7 to resolve every thread. If a comment is genuinely contentious/ambiguous and cannot be confidently categorized, or if any resolve call later fails, **report the failure clearly** so the caller (e.g. `/automerge`) can stop — do not guess.
- **Interactive mode**: Continue with the plan-mode flow below.

After the user confirms which comments to address, use the `EnterPlanMode` tool to design a detailed fix approach before making any changes.

**In plan mode, you should:**

1. **Review code context** around each flagged comment:
   - Read the full file containing each comment
   - Understand the surrounding code and its purpose
   - Identify related code that might be affected by changes

2. **Re-evaluate comment validity** with deeper code understanding:
   - Confirm VALID comments are actually valid with full context
   - Reconsider QUESTIONABLE comments given better understanding
   - Verify INVALID reasoning still holds

3. **Check if comments were already addressed**:
   - Review commits made after the review comments
   - Check if any fixes were applied but threads not resolved
   - Identify any partial fixes that need completion

4. **Design specific code changes** for valid comments:
   - Outline exact modifications for each file
   - Consider impact on related code
   - Ensure changes follow project conventions
   - Note any refactoring needed to support the fix

5. **Include verification steps**:
   - Which tests need to be run or written
   - Build/typecheck commands to verify changes
   - Manual verification if applicable

**Exit plan mode** with `ExitPlanMode` tool once the plan is complete. User must approve the plan before implementation begins.

## Step 6: Remediate Valid Comments

1. Create a focused plan listing each fix:
   - File and line to change
   - What change to make
   - Why this addresses the comment

2. Implement all approved fixes:
   - Make code changes using Edit tool
   - Verify changes compile/pass tests if appropriate
   - Group related changes logically
   - **Update tracking map**: Mark each addressed comment's status:
     - VALID comments → status: `fixed`
     - INVALID comments (if user approved skipping) → status: `skipped`
     - QUESTIONABLE comments (after discussion) → status: `discussed`

3. Commit the changes — **only if any code actually changed**. When zero comments were VALID
   (everything skipped/discussed), there is nothing to stage: skip steps 3–5 entirely — a bare
   `git commit` would fail, and no `{commit_sha}` exists — and proceed straight to Step 7 (its
   skipped/discussed reply bodies don't reference a SHA).

   ```bash
   git add {files}
   git commit -m "refactor: address review feedback (#{pr_number})

   - {summary of fix 1}
   - {summary of fix 2}
   - {summary of fix 3}"
   ```

4. Push to update the PR. **Rebase first** — inside `/automerge` this command and `/ci auto`
   both push to the same branch in the same cycle, and reviewers can push suggestion commits, so
   a bare push routinely fails non-fast-forward and stops the cycle on a recoverable error:

   ```bash
   git pull --rebase origin "{branch_name}" && git push origin "{branch_name}"
   ```

   If the rebase reports conflicts, **stop** and surface them — do not attempt to resolve them
   here. If the rebase succeeded but rewrote history, use
   `git push --force-with-lease origin "{branch_name}"` (never a bare `--force`).

5. **Capture the commit SHA** for use in Step 7:
   ```bash
   git rev-parse HEAD
   ```

## Step 7: Mark Comments as Resolved

After successfully committing and pushing fixes, acknowledge every piece of feedback on GitHub
(including INVALID and QUESTIONABLE items that weren't directly fixed).

**This section applies to LINE COMMENTS ONLY.** Review summaries are handled in step 2.5 below —
they have no `/replies` endpoint and no thread, so running them through the steps here produces
a 404 that stops the command and, in `auto` mode, aborts the caller's entire `/automerge` run.

For each **line comment** in the tracking map (all statuses, but only threads that were
unresolved per Step 2.3):

### 1. Reply to the Comment

Use `gh` CLI to add a reply acknowledging the action taken:

**For FIXED comments** (status: `fixed`):

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
  -f body="✅ Fixed in {commit_sha}"
```

**For SKIPPED comments** (status: `skipped`):

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
  -f body="⏭️ Skipped - {reasoning}"
```

**For DISCUSSED comments** (status: `discussed`):

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
  -f body="💬 Addressed - {outcome}"
```

**For QUESTIONABLE comments not explicitly discussed** (status: `pending` or any not handled):

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
  -f body="💬 Reviewed - No changes made, marked as resolved"
```

**For INVALID comments** (if not already skipped):

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
  -f body="⏭️ Reviewed - {reasoning from analysis}"
```

### 2. Resolve the Thread

After replying, use GitHub GraphQL API to mark the thread as resolved:

```bash
gh api graphql -f query="
  mutation {
    resolveReviewThread(input: {threadId: \"{thread_node_id}\"}) {
      thread {
        id
        isResolved
      }
    }
  }
"
```

**IMPORTANT**: Use the `thread_node_id` (e.g., starts with `PRRT_...`) from the tracking map, **NOT** the individual comment's node ID (e.g., `PRRC_...`) or the `comment_id`.

- The `resolveReviewThread` mutation requires the thread's node ID, which you can obtain from the `node_id` field of the review thread object in the API response or tracking map.
- If you only have a comment's node ID, you must look up the parent thread to get its node ID.
- Example thread node ID: `PRRT_lABy...`

### 2.5 Acknowledge review summaries (separate lane)

Review summaries cannot be replied to or resolved. Acknowledge them with **one** issue-style
comment on the PR, posted after all line-comment threads are handled:

```bash
gh pr comment {pr_number} --repo {owner}/{repo} --body "$(cat <<'EOF'
Addressed review feedback:

- @{reviewer}: {one-line disposition of their summary — fixed in {sha} / not applicable because …}
EOF
)"
```

Rules:
- **One comment total**, not one per summary — batch every reviewer into a single body.
- Skip entirely when no summary carried actionable content and nothing was fixed; an empty
  acknowledgement is noise on every `/automerge` cycle.
- A summary's *content* still counts: fold anything actionable in it into the VALID set in
  Step 3 so it gets fixed like any other feedback. Only the *acknowledgement mechanism* differs.
- Never attempt `/comments/{id}/replies` or `resolveReviewThread` for a summary id.

### 3. Error Handling

- If **any** reply or resolution fails:
  - **STOP immediately** - do not continue processing other comments
  - Display detailed error information:
    - Which comment failed (file:line)
    - The API error message
    - The command that failed
    - Guidance: "You can manually resolve this comment on GitHub at: {pr_url}#discussion_r{comment_id}"

- Show how many comments were successfully resolved before the error
- Provide the exact command to retry the failed operation

### 4. Success Summary

After all comments are marked as resolved, display:

```
✅ Review Feedback Resolved

Marked {total} line comments as resolved:
  ✓ {fixed_count} fixed and resolved
  ⏭️ {skipped_count} skipped and resolved
  💬 {discussed_count} discussed and resolved
  ({already_resolved_count} thread(s) were already resolved — skipped)

Acknowledged {summary_count} review summary/summaries in one PR comment.

All feedback has been acknowledged on PR #{pr_number}
View PR: https://github.com/{owner}/{repo}/pull/{pr_number}
```

## Important Notes

- **Be critical**: Not all review comments are valid or worth addressing
- **Consider context**: Some comments may not understand the full picture
- **Efficiency matters**: Don't waste time on meaningless changes
- **Test impact**: Consider if changes might break tests
- **Ask questions**: If unsure about a comment's validity, ask the user
- **Repository & branches**: pre-resolved by `~/.claude/lib/branches.sh`, injected at the top of this skill — the shared resolver used by every command in this suite
- **Base branch**: repo-aware — operations target the PR's own base; see `/pr` for how the integration branch is resolved

## Error Handling

- If no open PR found for the current branch: Show error and suggest running `/pr` first
- If no review comments: Show "No review comments found" and exit
- If all comments are INVALID: Explain why and don't make changes
- **If comment resolution fails (Step 7)**:
  - Stop immediately and show detailed error
  - Display which comment failed and why
  - Show how many comments were resolved before the failure
  - Provide manual resolution guidance and retry command

## Example Usage

```
$ /reviews

Fetching review comments for PR #31...

Found 3 review comments:

✓ VALID - packages/core/tests/DiskAdapter.test.ts:28
  "Unused import PermissionError"
  Reasoning: Import is not used anywhere in the file
  Effort: Low

? QUESTIONABLE - packages/core/src/storage/adapters/S3Adapter.ts:45
  "Consider using async/await instead of promises"
  Reasoning: Current code is already using async/await correctly
  Effort: N/A

✗ INVALID - packages/core/src/storage/base/types.ts:12
  "This interface should extend Error"
  Reasoning: This would break the existing error class hierarchy
  Effort: N/A

Summary: 1 VALID, 1 QUESTIONABLE, 1 INVALID

Fix all VALID comments? [y/n] y
Should I mark INVALID comments as resolved with skip reasoning? [y/n] y

[Implements fixes and commits]

Marking comments as resolved...

✅ Replied to comment on DiskAdapter.test.ts:28: "✅ Fixed in abc123d"
✅ Resolved thread for DiskAdapter.test.ts:28

✅ Replied to comment on types.ts:12: "⏭️ Skipped - This would break the existing error class hierarchy"
✅ Resolved thread for types.ts:12

✅ Review Comments Resolved

Marked 2 comments as resolved:
  ✓ 1 fixed and resolved
  ⏭️ 1 skipped and resolved
  💬  0 discussed and resolved

All comments have been acknowledged on PR #31
View PR: https://github.com/{owner}/{repo}/pull/31
```
