# Audit — the custom slash-command suite (decision record)

> ## THIS IS A HISTORICAL RECORD, NOT A WORK QUEUE
>
> Everything below was written **before** the fixes landed, and Part 1's findings are phrased in
> the present tense about behavior that **no longer exists** ("the command will stall", "so
> `/automerge` aborts", "merges while a Copilot review is inbound"). Read those bodies as *what was
> wrong*, never as *what to do*. The dispositions table is the authority on current state; where
> the two disagree, the table wins.
>
> Kept because the forensic detail behind twenty real bug fixes is worth having. **Do not delete
> it without rehoming §3.5** — see the note there.

**Original scope**, at the time of writing: `automerge`, `ci`, `commit`, `pr`, `reviews`, `status`,
`sync`, `work`, plus `agents/work-{plan,exec}.md`, `hooks/*.sh`, `settings.json`. Verified against
the Claude Code docs and `gh` 2.83.1.

Commands lived in `~/.claude/commands/*.md` then; **that directory no longer exists** and every
command is now `~/.claude/skills/<name>/SKILL.md`. Path references throughout this file are stale in
that way, and its line-number citations into `hooks/automerge-rewake.sh` predate roughly a doubling
of that file — locate things by symbol, not by line.

The suite has also grown past this audit's scope: `agents/work-exec-opus.md`, `agents/remediator.md`,
and `skills/reap/` all postdate it, and the `remediator` agent in particular changes §3.1's answer.

Regression tests: `bash ~/.claude/tests/run-all.sh` (223 assertions across 10 suites).

## Dispositions

`closed` = fixed, with the file that proves it. `superseded` = the objective was met a different
way. `deferred` / `open` = still outstanding, and repeated under "Still open" at the end.

| Item | Disposition | Evidence |
|---|---|---|
| #1 `/pr` squash-merge misclassification | closed | `skills/pr/SKILL.md` §6 three-test ladder; `tests/git-scenarios.sh` |
| #2 `/work` §3 same bug | closed | `skills/work/SKILL.md` §3 |
| #3 `/ci` `{run_id}` never obtained | closed | `skills/ci/SKILL.md` — `--json name,state,bucket,link,workflow`, run-id derived by `sed` |
| #4 `/reviews` 404 on review summaries | closed | `skills/reviews/SKILL.md` — two lanes; summaries never resolved |
| #5 `/reviews` ignores `isResolved` | closed | `skills/reviews/SKILL.md` §2.3 |
| #6 `/automerge` exits on a stale Copilot review | closed | `skills/automerge/SKILL.md` §2.4 `$pushed_at` comparison; `tests/automerge-merge-gate.sh` |
| #7 jq aborts on null `.reviewRequests` (2 files) | closed | `skills/automerge/SKILL.md` + `hooks/automerge-rewake.sh`; `tests/jq-reviewrequests.sh` |
| #8 `mergeable: UNKNOWN` treated as blocked | closed | `skills/automerge/SKILL.md` Step 3 poll loop; `tests/automerge-merge-gate.sh` |
| #9 hook deletes other sessions' sentinels | closed | `hooks/automerge-rewake.sh` — `mine()` before `expired()`; `tests/hook-sentinels.sh` |
| #10 `/sync` no remote-counterpart guard | closed | `skills/sync/SKILL.md` §2 |
| #11 `/sync` inverted commit count | closed | `skills/sync/SKILL.md` §5 |
| #12 `/status` §8 flags + stale base ref | closed | `skills/status/SKILL.md` §3 fetches, counts against `origin/`. **The `/work` §5 half was missed for months and is now also fixed** — `skills/work/SKILL.md` §5 |
| #13 `/commit` cwd-relative `add`, no empty guard | closed | `skills/commit/SKILL.md` §7 |
| #14 `/work` §0a/§0b out of order | closed | `skills/work/SKILL.md` — now `0 → 0a → 0b → 0c` |
| #15 Monitor `{worktree}` undefined at `parallel=1` | closed | `skills/work/SKILL.md` — `{tree}`, explicitly bound for both cases |
| #16 Monitor `${pr:-none}` dead | closed | `skills/work/SKILL.md` — `if . then … else "" end` |
| #17 caps table drifted from the monitor | closed | `skills/work/SKILL.md` caps table names all three signals |
| #18 false `gh pr list --draft` claim | closed | `skills/automerge/SKILL.md` §1.2 |
| #19 `/ci` commit references PR as issue | closed | `skills/ci/SKILL.md` §5-auto |
| #20 `/ci` + `/reviews` push without rebase/lease | closed | both §5-auto / §6.4 |
| Part 2 — `settings.json` missing `model` | closed | `settings.json` — `"model": "opus"` |
| §3.1 `disallowed-tools` over prose | **superseded** | Adopted for `/automerge`. The proposed `/ci-auto` + `/reviews-auto` split was **not** done and is not planned — `agents/remediator.md` gets the same enforcement by running them in a subagent that cannot reach those tools |
| §3.2 `disable-model-invocation` | closed (narrowed) | `/work`, `/commit`, `/reap`. Rejected for `/automerge` and `/pr` with in-file rationale — the flag breaks Skill-tool handoffs |
| §3.3 explicit argument binding | closed | `ci`, `reviews`, `automerge`, `commit`. `/work` declines it with in-file rationale (its tokens have no fixed positions) |
| §3.4 kill branch-resolution duplication | closed | `lib/branches.sh`, referenced by every suite skill; `tests/branches.sh`. Note: the real path is `lib/`, not the `${CLAUDE_SKILL_DIR}/../_git/` this document proposes |
| §3.5 scope the rewake hook to skills | **rejected** | See the note in that section — it is the only record of why |
| §3.6 `WorktreeCreate` / `WorktreeRemove` hooks | **deferred** | `tests/README.md` "Deferred" cites this section by number |
| §3.7 `effort` per command | closed | `work: high`; `commit`/`status`/`sync`/`reap: low` |
| §3.8 `allowed-tools` on `/ci`, `/reviews` | closed | both, as a superset of the proposal |
| §3.9 model-pin consistency | closed | `/commit` pin dropped; `/status`, `/sync` retained as recommended |

**Three items were corrected while implementing**, because building the tests disproved the stated
mechanism — each is marked inline: **#1/#2** (three-dot diff was the wrong fix), **#7** (`join` does
not error on null; the real defect is an unguarded null *field*), and **§3.5**. **§3.2** was
narrowed for the reason in its row above.

---

## Part 1 — Logic errors

Ordered by blast radius. Each is a defect in the spec as written, not a style preference.

### 1. `/pr` Scenario C and Scenario D are indistinguishable → spurious follow-up branch  🔴

`pr.md` §7 branches on `git rev-list --count {integration_branch}..HEAD`:

- **C** (remote deleted, `count > 0`) → auto-create `feature/{n}-{slug}-followup` and open a second PR.
- **D** (remote deleted, "commits already in the integration branch") → report and exit.

But `/automerge` merges with `gh pr merge --squash`. A squash merge writes a **new** commit, so the
branch's original commits are never ancestors of the integration branch — `count` stays `> 0`
forever. **Scenario D can never be reached**; the common post-merge case always falls into C and
opens a duplicate PR whose diff is empty or a re-application of merged work.

**Fix** — decide on *content*, not commit count.

> **Corrected during remediation.** The original text proposed `git diff --quiet {base}...HEAD`
> (three dots). That is **wrong**: three-dot diffs against the merge base, which after a squash
> merge is still the original branch point — so it reports the branch's entire diff and never
> detects the merge. Two dots (tip vs tip) is required. Proven in `tests/git-scenarios.sh`.

No single git test covers every merge style, so the classification is layered — first match wins:

```bash
git fetch origin {integration_branch}:{integration_branch}

# 1. Ordinary merge commit or fast-forward.
git merge-base --is-ancestor HEAD {integration_branch} && echo D

# 2. Squash merge, integration branch not advanced since — TWO dots, tip vs tip.
git diff --quiet {integration_branch} HEAD && echo D

# 3. Squash merge, integration advanced since — compare only the paths this branch touched.
base=$(git merge-base {integration_branch} HEAD)
git diff --name-only "$base" HEAD \
  | tr '\n' '\0' | xargs -0 git diff --quiet {integration_branch} HEAD -- && echo D
```

Do **not** use the PR's `mergedAt` with `git rev-list --since`: that filters on committer date,
which a rebase rewrites, so a rebased-but-merged branch misclassifies. The touched-paths test is
date-independent. Keep the `count` check only to separate B from C/D.

### 2. `/work` §3 has the same squash-merge bug  🔴

"Remote deleted (PR likely merged)" → `git rev-list --count {integration_branch}..HEAD` → "If local
commits > 0 … Create a followup branch". Identical failure. Apply the same `git diff --quiet
{integration_branch}...HEAD` test.

### 3. `/ci` §4 uses `{run_id}`, which is never obtained  🔴

Step 4 says `gh run view {run_id} --log-failed`. Nothing in Steps 1–3 produces a `run_id`.
`gh pr checks` emits check names, states and *URLs* — not run IDs. The command will either guess or
stall on the first failing check.

Compounding it: Step 2 runs bare `gh pr checks {pr}` (tab-separated text) but Step 2's parser reads
`conclusion` and `state` — fields that only exist under `--json`.

**Fix** — make Step 2 structured and derive the run id from the check link:

```bash
gh pr checks {pr} --repo {owner}/{repo} --json name,state,bucket,link,workflow
```

`bucket` is exactly the categorisation Step 2 hand-rolls: `pass` / `fail` / `pending` / `skipping` /
`cancel`. Then for Actions checks, the run id is the `.../actions/runs/<ID>/job/<JOB>` segment of
`link`; extract it. Add an explicit fallback for non-Actions checks (Vercel, external CI) which have
no run id at all — today they silently break Step 4.

### 4. `/reviews` §7 will hard-fail on review *summary* comments → aborts every `/automerge`  🔴

Step 2 collects from two endpoints:

- `pulls/{n}/comments` — line comments. These have a reply endpoint and a review thread. ✅
- `pulls/{n}/reviews` — review **summaries**. These have **no** `/comments/{id}/replies` endpoint and
  **no** `reviewThread` node. ❌

Step 7 then iterates "for each comment in the tracking map (ALL comments, regardless of status)" and
POSTs to `.../comments/{comment_id}/replies` for every one. For a review-summary id that 404s.
Step 3's escape hatch ("surface that comment explicitly rather than resolving blind") routes straight
into `/automerge` §2.2's stop condition.

Copilot posts a review summary on essentially every PR it reviews. So `/automerge` aborts on the
first cycle of most PRs.

**Fix** — keep the two sources in separate lanes:
- Line comments → reply + `resolveReviewThread` (current logic, unchanged).
- Review summaries → they are not resolvable. Read them for *content* (they often carry the real
  feedback), fold any actionable point into the VALID set, and acknowledge with a single
  `gh pr comment {n} --body "..."` at the end. Never attempt `/replies` or `resolveReviewThread`.

### 5. `/reviews` ignores `isResolved`, so `/automerge` re-replies every cycle  🟠

The GraphQL query in §2.3 selects `isResolved` and then never uses it. `/automerge` runs up to 5
cycles per PR and calls `/reviews auto` each time, so an already-resolved thread gets a fresh
"✅ Fixed in …" reply on every pass. Filter to `isResolved == false` before building the tracking
map, and treat already-resolved threads as out of scope.

### 6. `/automerge` §2.4 exits "done" on a *stale* Copilot review  🔴

The prose states the done condition as "Copilot is no longer a requested reviewer **and** a Copilot
review **newer than the last push** exists". The script only tests existence:

```bash
elif [ -n "$latest" ]; then
  echo "Copilot review complete ($latest)"; exit 0
```

On cycle ≥ 2 there is *always* a `$latest` from the previous cycle. GitHub re-requests Copilot
asynchronously after a push, so there is a window where `reqs` does not yet contain copilot and
`latest` is the old review → the loop exits immediately → §2.5 sees no new comments → **merges while
a Copilot review is inbound**. That is precisely what §2.4 says must never happen.

**Fix** — capture the push moment and compare, plus a grace floor:

```bash
pushed_at=$(git log -1 --format=%cI)          # or the ISO time of the push
# ...
elif [ -n "$latest" ] && [[ "$latest" > "$pushed_at" ]]; then   # lexicographic works on ISO-8601
  echo "Copilot review complete ($latest)"; exit 0
```

and do not accept the "not applicable" branch during the first ~90 s after a push.

### 7. `jq` bug drops the Copilot wait entirely (two places)  🟠

> **Corrected during remediation.** The original text claimed `join(",")` *errors* on a null
> `.login`. It does not — jq renders null as an empty element and exits 0, so team reviewers are
> harmless. Verified in `tests/jq-reviewrequests.sh`. The real defect is below.

`automerge.md` §2.4:
```
-q '[.reviewRequests[].login] | join(",")'
```
`hooks/automerge-rewake.sh:143`:
```
-q '[.reviewRequests[].login] // [] | join(",")'
```

Both abort with rc=5 — `Cannot iterate over null` — when `.reviewRequests` is **absent** from the
response (a failed or partial `gh` call, an API shape change). Both call sites wrap the command in
`2>/dev/null || true`, so the error is swallowed, `$reqs` is empty, and the code concludes
**"Copilot not requested"** → skips the wait → merges while Copilot may still be reviewing.

The hook's `// []` was clearly *intended* as that null-guard, but it is dead code: `|` binds looser
than `//`, so it parses as `([...] // []) | join(",")`, and an array literal is never null. The
guard has to sit on the **field**, not outside the array construction.

**Fix (both files)** — guard the field; `.login // .slug` additionally names team reviewers, who
carry `.slug`:
```
-q '[(.reviewRequests // [])[] | .login // .slug // empty] | join(",")'
```

### 8. `/automerge` §3 stops on GitHub's async `mergeable: UNKNOWN`  🟠

`gh pr view --json mergeable` returns `UNKNOWN` while GitHub computes the merge commit — routinely on
the first query after a push. §3.1 says "If `mergeable` is `CONFLICTING` **or otherwise blocked** →
stop", which reads `UNKNOWN` as a blocker and aborts a healthy run.

**Fix** — poll: re-query up to ~5 times at 3 s while `mergeable == "UNKNOWN"`; treat only `CONFLICTING`
as a conflict stop, and evaluate `mergeStateStatus` separately (`BLOCKED` = required checks/reviews,
`BEHIND` = needs update, `DIRTY` = conflict).

### 9. `automerge-rewake.sh` deletes *other sessions'* sentinels  🟠

The script's own contract (line 93-97) says a sentinel owned by another session "is not ours to act on
OR delete". But `expired()` runs **before** `mine()` in both loops:

```bash
if expired "$sentinel" "$AUTOMERGE_CAP"; then rm -f "$sentinel" "$counter"; continue; fi
mine "$sentinel" || continue        # ← too late
```
(same at lines 186-190 for `work-active-*`)

A second session whose plan stage is legitimately past `PLAN_CAP` — or any session whose sentinel is
older than the cap but still live — gets its guard silently disarmed by this session's hook.

**Fix** — swap the order: `mine "$sentinel" || continue` first, then `expired`.

### 10. `/sync` has no guard for a protected branch with no remote counterpart  🟠

§2 makes `{release_branch}` "always a candidate" and `{integration_branch}` a candidate "only if it
exists". Only the **current** branch gets the `git rev-parse --verify --quiet origin/{branch}` check.
If `origin/{release_branch}` does not exist (fresh repo, `main` configured but only `master` pushed,
release branch never pushed), §3's classification `git rev-parse origin/<branch>` fails with no
handling.

**Fix** — apply the same `origin/<branch>` existence probe to every member of the sync set, and mark a
missing one `⊘ skipped (no remote counterpart)` exactly as the current branch already is.

### 11. `/sync` §5 new-commit count is inverted  🟡

> `git rev-list --count origin/<branch>..<branch_before>`

`A..B` counts commits reachable from `B` but not `A`. For a branch that was *behind*, `branch_before`
is an ancestor of `origin/<branch>`, so this always returns **0**. Correct form:

```bash
git rev-list --count <branch_before>..origin/<branch>
```

### 12. `/status` §8: conflicting `git diff` flags + stale base ref  🟡

```
git diff --stat {integration_branch}...HEAD --shortstat
```
`--stat` and `--shortstat` are mutually exclusive output formats; the last one wins, so `--stat` is
dead weight. Use `--shortstat` alone.

Separately, `/status` §8 and `/work` §5 both count against the **local** `{integration_branch}` ref
without fetching first, so "commits ahead" is stale whenever the base has moved. `/pr` §6 gets this
right (`git fetch origin {b}:{b}` before counting) — port that, or count against
`origin/{integration_branch}` after a plain `git fetch origin {integration_branch}`.

### 13. `/commit` §7: `git add .` is cwd-relative, and there is no empty-commit guard  🟡

- `git add .` stages only from the current working directory. Run from a subdirectory (common in a
  monorepo, and in `/work`'s per-issue worktrees), it silently omits changes elsewhere in the repo
  while Step 7's `git status --porcelain` display shows them. Use `git add -A` (or `git add -A :/`).
- If `git status --porcelain` is empty, Step 7–8 run `git add` + `git commit` and the commit **fails**.
  `/reviews` §6.3 handles exactly this case explicitly; `/commit` does not. Add: if the porcelain
  output is empty, report "nothing to commit" and exit 0.

### 14. `/work` §0a / §0b are specified out of order  🟡

§0a step 4 says description→issue resolution "is done once, **after repo detection in step 0**". But
§0b — which prints the resolved queue and asks for confirmation — is documented *before* §0, and §0b
is where `{queue}` must already exist. The literal reading is circular. Reorder to
`0 (repo detect) → 0a (parse + resolve) → 0b (confirm) → 0c (handoff setup)`, and renumber; the
current `0a, 0b, 0, 0c` sequence is itself a readability trap.

### 15. `/work` Monitor script: `{worktree}` is undefined at `parallel=1`  🟡

```bash
commit=$(git -C {worktree} log -1 --oneline ...)
```
"Concurrency and isolation" states plainly: "At `{parallel}=1` no worktree isolation is needed." So on
the default path the substitution has no value. Specify the fallback explicitly — `git -C {worktree
or repo_root}` — or always set `{worktree}` to the repo root at `parallel=1`.

### 16. `/work` Monitor: `${pr:-none}` never fires  🟢

```bash
gh pr list ... -q '.[0] | "\(.number):\(.state)"'
```
With no PR, `.[0]` is `null`, and jq interpolates `null` fields as the string `null` — so `$pr` is
`"null:null"`, never empty. The `${pr:-none}` default is dead and the heartbeat prints
`PR null:null`. Use `-q '.[0] | if . then "\(.number):\(.state)" else "" end'`.

### 17. `/work` caps table has drifted from the monitor script  🟢

The table's first row reads "No new commit **and** no PR state change | 10 min". The script watches
**three** signals (commit, PR, plan-file mtime) — and the surrounding prose explains at length why the
third is essential. Update the table row to name all three, or the next reader will "simplify" the
script back into false-STALLing every plan stage.

### 18. `/automerge` §1.2: the `--draft` claim is false on current `gh`  🟢

> note: `gh pr list` has no `--draft` flag — filter drafts via search

`gh` 2.83.1 (installed here) has `-d, --draft   Filter by draft state`. Prefer
`gh pr list --state open --draft=false --json number,headRefName,title` — `--search "draft:false"`
silently changes result ordering and caps differently.

### 19. `/ci` §5-auto: commit references the PR number as if it were an issue  🟢

```
git commit -m "fix: resolve CI failures (#{pr_number})"
```
Every other command in the suite uses `(#{issue_number})` (`/commit` §6, `/work` step 8). `#{pr}` in a
commit body creates a self-referential cross-link on the PR. Use the issue number derived from the
branch, falling back to omitting the reference.

### 20. `/ci` §5-auto and `/reviews` §6.4 push without rebase or lease  🟢

`git push origin {branch_name}` with no `--force-with-lease` and no preceding fetch/rebase. Inside
`/automerge`, `/reviews auto` and `/ci auto` both push to the same branch in the same cycle, and
Copilot/bots can push suggestions. A non-fast-forward push fails with no handling and the cycle stops
on an error that a `git pull --rebase` would have resolved.

---

## Part 2 — Configuration invariant currently violated

> **Closed.** `settings.json:2` is now `"model": "opus"`, so both halves of the invariant hold and
> the drift check no longer fires. Everything below describes the state before that — the "❌
> **absent**" and "no `model` key at all" claims are no longer true of the tree.

`work.md` §"Model split" states the orchestrator requires **both**:

1. `model: opus` in `work.md` frontmatter ✅ present, and
2. `"model": "opus"` as the session default in `~/.claude/settings.json` ❌ **absent**

`settings.json` has no `model` key at all. So:

- `/work` §0 step 5's drift check (`jq -r .model ~/.claude/settings.json`) returns `null` and prints
  its warning on **every single run**.
- After each user gate the orchestrator falls back to the *account* default rather than a pinned
  `opus`. Today that resolves to Opus, so it works — but the invariant `work.md` spends two paragraphs
  defending is not actually enforced anywhere.

**Fix** — either add `"model": "opus"` to `settings.json` (and keep the never-`opusplan` note, which is
correct), or make the drift check tolerate an unset key (`null` → "inheriting account default, assumed
opus") so it stops crying wolf. The first is what the command asks for.

---

## Part 3 — Feature integrations worth adopting

### 3.1 Enforce autonomy with `disallowed-tools` instead of prose  ⭐ highest value

`/automerge` opens with **"NEVER call `EnterPlanMode` or `ExitPlanMode`"** in bold. That is a request.
Frontmatter makes it a guarantee — the tools are removed from the pool while the skill is active:

```yaml
disallowed-tools: EnterPlanMode, ExitPlanMode, AskUserQuestion
```

The docs call out this exact use case ("autonomous skills that should never call certain tools, such
as `AskUserQuestion` for a background loop"). Apply to `/automerge`; apply the same to
`/ci` and `/reviews` **only** in their `auto` path — which is an argument for splitting those into
`/ci` + `/ci-auto`, since frontmatter cannot be conditional on an argument.

Caveat: the restriction clears on your next *user* message, which is the right lifetime for an
autonomous multi-turn run.

> **SUPERSEDED — the split above is not pending work; it will not be done.** `/automerge` adopted
> `disallowed-tools`, but `/ci` and `/reviews` did not get split. Instead `/automerge` stopped
> invoking them inline and now dispatches `agents/remediator.md`, whose frontmatter carries
> `disallowedTools: EnterPlanMode, ExitPlanMode, AskUserQuestion` — and subagents cannot reach
> those tools regardless. Same guarantee, no split, plus a fresh context per cycle. That agent
> postdates this document, which is why nothing below mentions it.
>
> Note the spelling trap the two forms hide: skills use kebab-case `disallowed-tools`, agents use
> camelCase `disallowedTools`. The wrong one is silently ignored, which is what
> `tests/lint-frontmatter.sh` exists to catch.

### 3.2 `disable-model-invocation: true` on the destructive commands  ⭐ security-relevant

Custom commands have been **merged into skills**. Consequence: everything in `~/.claude/commands/` is
now **model-invocable** by default — Claude can decide on its own to run `/automerge` (which
squash-merges PRs and deletes branches), `/commit`, `/pr`, or `/work`. These are all listed in the
active skill roster right now.

> **No longer true of `/work` and `/commit`** (nor of `/reap`, which postdates this): all three set
> `disable-model-invocation: true`. `/automerge` and `/pr` remain model-invocable **deliberately** —
> the flag also blocks Skill-tool handoffs, and `/work` reaches both of them that way, so setting it
> would break `/work … auto` outright. Their compensating control is a narrowed `description`.

```yaml
disable-model-invocation: true    # → /automerge, /work, /commit, /pr
```

Leave it off for read-only `/status`, `/sync`, `/ci` (interactive) — auto-invocation there is a
feature. Note this also blocks preloading into subagents, which is fine since `/work`'s stages invoke
them explicitly via the Skill tool.

### 3.3 Bind arguments explicitly with `$ARGUMENTS` / `arguments:`  ⭐

Not a bug today — the docs confirm that when `$ARGUMENTS` is absent, "arguments are appended as
`ARGUMENTS: <value>`" — but every command in the suite relies on that implicit tail and then refers to
a `{mode}` / `{scope}` / `{selector}` placeholder that appears nowhere in the substituted text. The
model has to infer the binding each time.

```yaml
# ci.md / reviews.md
arguments: mode
argument-hint: "[interactive | auto]"
```
then in the body: **Mode** (`$mode`, default `interactive` when empty).

```yaml
# work.md
arguments: [selector, flags]
```
An unfilled named argument expands to the empty string (indexed `$1` would stay literal), so
`$mode` degrades cleanly to the documented default. `/commit` should use `$ARGUMENTS` for the message.

> **Adopted for `/ci`, `/reviews`, `/automerge` and `/commit`; declined for `/work`.** The
> `arguments: [selector, flags]` snippet above is the wrong model there and was not used: §0a
> strips `auto`, `parallel=N` and `opus` from *anywhere* in the string and treats the remainder as
> the selector, so the tokens have no fixed positions. `/work` takes the raw `$ARGUMENTS` instead,
> with the reasoning recorded in its own frontmatter comment.

### 3.4 Kill the six-fold duplication of branch resolution  ⭐

The identical 4-step "resolve `{integration_branch}`" block is copy-pasted verbatim into `commit.md`,
`pr.md`, `status.md`, `sync.md`, `work.md`, and referenced from `reviews.md`. It costs 4–6 tool calls
of latency at the start of every command and it will drift.

Migrate to `~/.claude/skills/<name>/SKILL.md` (a directory gets you supporting files) and put the
logic in one script, then inject its output with bash substitution so the facts are *already in
context* when the model starts:

```markdown
---
name: pr
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/../_git/branches.sh)
---

Repo context (pre-resolved):
!`${CLAUDE_SKILL_DIR}/../_git/branches.sh`
```

`` !`cmd` `` runs at invocation and inlines the output. One shared `branches.sh` emitting
`owner/repo`, `integration_branch`, `release_branch`, `current_branch`, `issue_number` replaces ~40
lines × 6 files and removes a whole round of tool calls per command.

`${CLAUDE_SKILL_DIR}` in both the body and the `allowed-tools` rule is the documented pattern for
running a bundled script without a permission prompt.

> **Adopted, at a different path.** The real artifact is `~/.claude/lib/branches.sh`, referenced by
> **absolute path** in every suite skill's `allowed-tools` and `` !`…` `` line — not
> `${CLAUDE_SKILL_DIR}/../_git/`, which appears nowhere in the tree.
>
> It also carries a contract this section did not anticipate: **never exit non-zero, never write to
> stderr, and emit only slow-moving facts.** Invoked skill content persists for a session, and a
> re-invocation whose *rendered* content differs re-appends the whole skill body — so a SHA or a
> dirty-tree flag in this output would make `/automerge` re-append all of `reviews.md` and `ci.md`
> on every one of its five cycles. Pinned by `tests/branches.sh`; explained in `tests/README.md`.

### 3.5 Scope the rewake hook to the skills that need it

Today `automerge-rewake.sh` is registered globally on `Stop` and `TeammateIdle`, so it forks a bash
process, shells out to `git`, and (when a sentinel exists) makes 3 `gh` API calls on **every turn of
every session in every repo**. The sentinel check makes it *inert*, not *free*.

Skills and agents now support a `hooks:` frontmatter block scoped to their own lifecycle:

```yaml
# automerge.md / work.md
hooks:
  Stop:
    - hooks:
        - type: command
          command: bash ~/.claude/hooks/automerge-rewake.sh
          asyncRewake: true
          statusMessage: Checking for an active bounded wait
```

Same script, same behaviour, but armed only while the command is active. Verify the lifetime matches
your multi-turn runs before removing the global registration — if a skill-scoped hook unloads at the
same point `disallowed-tools` clears, keep the global one for `/automerge`.

> **REJECTED — and this paragraph is the only record of why, anywhere in the tree. Do not delete
> it without moving the reasoning somewhere in `hooks/` first.**
>
> The caveat above turned out to be the deciding fact: **a skill-scoped hook unloads when the skill
> finishes**, and the whole purpose of this hook is to fire *after* a turn has ended — including
> turns that ended because the skill stopped early. Scoping it to the skill would disarm it in
> precisely the case it exists for. The global registration on `Stop` / `TeammateIdle` stays, and
> the per-item sentinel check remains the thing that makes it inert elsewhere.
>
> Since this was written, a third registration was added: `SubagentStop`, scoped by a
> `matcher` on `agent_type` rather than by skill lifecycle — see `hooks/automerge-rewake.sh`'s
> header. That is the shape scoping should take here.

### 3.6 Use `WorktreeCreate` / `WorktreeRemove` hooks

Both are now documented hook events. `/work`'s worktree bookkeeping (`§Concurrency and isolation`
provisioning, teardown step 4, and `session-cleanup.sh`'s `git worktree list` sweep) is currently all
prose-enforced, which is exactly the kind of thing that gets skipped on a blocker path. A
`WorktreeRemove` hook can assert the sentinel is gone; a `WorktreeCreate` hook can register the path
for the SessionEnd sweep without relying on the `.claude-work/$SESSION/` naming convention.

Related: `SubagentStart`, `TaskCreated`, `TaskCompleted` and `StopFailure` are all real events now.
`TaskCompleted` in particular could replace part of the Monitor heartbeat with a push signal — though
`/work`'s core argument stands: the completion notification can't cover the teammate that *stalls*, so
keep the Monitor for stall detection and use `TaskCompleted` only to tighten the happy path.

> **DEFERRED.** `tests/README.md`'s "Deferred" section cites this section by number — keep the
> `§3.6` anchor. The reason is that the payload schemas were undocumented; the CLI bundle has
> since turned out to carry readable Zod schemas for every hook event, so the probe that section
> asks for can largely be done by reading the bundle instead of by experiment.
>
> One correction: the event list above omits **`SubagentStop`**, which is the one that was
> actually adopted (`settings.json`, matcher `work-exec|work-exec-opus`). It does not descend from
> this section's reasoning — and it refutes an assumption this section shares, that a subagent
> which *finishes* needs no guard. A subagent that ends its turn one step short of its goal
> finishes too. See `hooks/automerge-rewake.sh`'s header.

### 3.7 Set `effort` per command

```yaml
effort: low      # status, sync, commit  — mechanical, high-volume
effort: high     # work  — decomposition, gating, blocker triage
```

Session default is `high` (`settings.json: effortLevel`). `/status` and `/sync` are deterministic git
plumbing and don't need it; `/work`'s orchestrator does.

### 3.8 Add `allowed-tools` so autonomous runs can't stall on a prompt

`settings.json` pre-approves `Bash(git:*)` and `Bash(gh:*)`, but **not** `Edit` / `Write`. `/ci auto`
and `/reviews auto` both edit files. Invoked from a default-permission main session (not via the
`bypassPermissions` subagents), the first Edit raises a prompt that nobody answers — the exact
dispatch-then-idle stall the whole rewake apparatus exists to prevent.

```yaml
# ci.md, reviews.md
allowed-tools: Read, Edit, Grep, Glob, Bash(git:*), Bash(gh:*)
```

### 3.9 Model-pin consistency

`pr.md`, `ci.md`, `reviews.md`, `automerge.md` deliberately omit `model:` — and the reasoning in
their header comments is **correct** per the docs ("the override applies for the rest of the current
turn"). But `commit.md`, `status.md`, `sync.md` still pin `model: sonnet`. `/commit` is the risk:
`work.md` step 8 and `work-exec.md` invoke "`/commit` conventions", and if that ever becomes a real
Skill-tool invocation from the opus orchestrator, it silently downshifts the rest of that turn. Drop
the pin from `commit.md` and note why, matching the other four. `/status` and `/sync` are terminal —
leave them.

> **Done exactly as recommended.** `/commit` no longer pins a model — a comment stating this
> reasoning sits where the pin was. `/status` and `/sync` keep `model: sonnet`.

---

## Still open

Everything else in this document is closed or superseded — see the dispositions table at the top.
This replaces the original "Suggested order of work", every entry of which is now done; left as a
queue it would have directed a reader to redo eleven completed fixes.

- **§3.6 — `WorktreeCreate` / `WorktreeRemove` hooks.** Deferred, tracked in `tests/README.md`'s
  "Deferred" section, which cites this document's `§3.6` by number. `/work`'s worktree bookkeeping
  is still prose-enforced.
- **Nothing else.** #12's long-missed `/work` §5 half was fixed while reconciling this document;
  §3.1's split is superseded rather than pending.

### Two lessons this document earned, worth keeping

- **A findings report written in the present tense becomes a lie the moment it is acted on.** Every
  Part 1 body still says the bug *is* happening. A one-line "Status: remediated" 470 lines away did
  not counteract that, and the file kept reading as live work for months. If a future audit is
  written this way, give each finding its own disposition line at the point of reading.
- **A retired document can still be load-bearing.** §3.5's rejection rationale exists nowhere else
  in the tree, and `tests/README.md` points at `§3.6` by number — so "just delete the stale audit"
  would have silently destroyed the only record of a real design decision. Check what cites a file
  before retiring it.
