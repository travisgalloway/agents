---
name: work
model: opus
effort: high
description: Start or resume work on one or more GitHub issues/PRs, drive each to a PR, and optionally automerge. Each issue is planned by an opus subagent and executed by a sonnet subagent (or opus at medium effort with the `opus` token), handed off via a written plan file. A single issue (#N) runs inline with full gating; multiple issues or a description trigger orchestrated mode — the main session dispatches each issue's plan/exec stages to their own autonomous subagents.
argument-hint: "<#N | #A-B | #1,#3 | \"description\"> [auto] [parallel=N] [opus]"
# Deliberately NOT `arguments: [selector, flags]`. Positional binding is the wrong model here:
# §0a strips `auto`, `parallel=N`, and `opus` from anywhere in the string and treats the remainder as
# the selector, so the tokens have no fixed positions. $ARGUMENTS gives §0a the raw string it parses.
# User-invoked only. This command creates branches, commits, opens PRs and (with `auto`) merges
# them — never something Claude should start on its own initiative. Nothing else in the suite
# invokes /work, so denying model invocation costs no handoff. See also `disable-model-invocation`
# on /commit; the other five must stay model-invocable because /work and /automerge chain to them
# via the Skill tool, which counts as Claude invoking a skill.
disable-model-invocation: true
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh), Bash(bash __CLAUDE_HOME__/lib/stage-processes.sh:*)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved —
fall back to the per-step instructions below):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Do this on every turn — intermediate progress turns, plan-mode turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Start or resume work on the issue(s)/PR(s) named by `{selector}`, drive each one through the full lifecycle — plan → implement → commit → PR — and, when `auto` is given, hand the new PR off to `/automerge`.

## Operating context & gates

- **Two modes, different gate sets:**
  - **Inline mode** (single explicit `#N`): Two user gates — (1) **plan approval** (`ExitPlanMode`), (2) **PR review** (before opening the PR). Queue confirmation is skipped since there is only one issue. Everything else runs autonomously.
  - **Orchestrated mode** (multiple issues or a description selector): **One user gate only** — (1) **queue confirmation**, after which each issue's plan/exec subagents auto-accept plan + PR and run fully unattended. The main session acts as orchestrator, dispatching each issue's opus plan stage and `{exec_model}` exec stage in turn.
- **Autonomous phases never prompt.** Implementing the approved plan, committing (per `/commit` conventions), and the `auto` merge phase all run without prompting. The merge phase delegates to **`/automerge`**, which itself uses **`/ci auto`** and **`/reviews auto`** — never invoke `/ci` or `/reviews` in their interactive modes from here, and never enter plan mode during the merge phase.
- **Local or Remote Control.** This command runs identically whether driven from the local CLI or a Remote Control (web/mobile) session — it executes on the container either way. At each gate (and on completion/blocker) it calls the `PushNotification` tool so you can step away and respond from your phone. The notification shows locally as a desktop notification and pushes to your phone when Remote Control is connected; it no-ops gracefully if no push is sent (a "not sent" result is expected and needs no action).
- **Model split.** Every issue is decomposed into a **plan stage** (`model: opus` — explore, design, produce the plan) and an **exec stage** (`model: sonnet` by default, or `opus` at effort `medium` when the `opus` token is passed — implement, commit, and, in orchestrated mode, PR + automerge). A single agent/worker cannot switch models mid-run, so these are always two separate subagent dispatches, never one. The exec model is decided once, at parse time (§ 0a), and applies to **every** exec dispatch in the run — inline, orchestrated, and the standalone merge stage alike. The two stages hand off via a written **plan file** at `.claude/plans/issue-{N}.md` (see "Plan-file handoff" below). This split applies identically in inline and orchestrated modes.
- **The orchestrator itself runs in opus** — it is the session doing the decomposition, gating, and blocker triage, not mechanical work. Two things enforce this together, and both are required:
  - `model: opus` in this command's frontmatter, and
  - `"model": "opus"` as the **session default** in `~/.claude/settings.json`.

  A command's `model:` override only "applies for the rest of the current turn" — it is not sticky. Every user gate here (queue confirmation, plan approval, PR review) *ends a turn*, so on the next turn the session falls back to its default. If that default is anything but opus, the orchestrator silently downgrades mid-run, right after the plan gate.

  For the same reason, **never set `opusplan` as the session default for this suite.** `opusplan` switches to sonnet the moment `ExitPlanMode` is called — which is exactly step 7 — so the orchestrator would drop to sonnet for implementation, PR, and merge. Use a plain `opus` default; the sonnet half of the split is delivered by the exec *subagent* dispatch, not by the session model.

## Step-by-Step Instructions

> **Step order.** These run `0 → 0a → 0b → 0c`. Repo detection (0) comes first because resolving a
> description selector into issue numbers (0a) needs `gh` and the repo, and the queue-confirmation
> gate (0b) needs the resolved queue. The previous ordering listed 0a and 0b ahead of 0 while 0a
> depended on 0 — circular, and unfollowable as written.

### 0. Detect Repository (once, before everything)

Steps 0 and the integration-branch resolution run **once** for the whole run, not per issue. Use the `gh` CLI to detect the current repository:

1. **`{owner}` and `{repo}` are already resolved** in the repo-context block at the top of this
   skill. Use those values; do not re-run `gh repo view`.
2. If `owner` came back empty there, error: "No GitHub repository found. This command requires a
   GitHub repo with an authenticated `gh` CLI." and stop.
3. Most `gh` subcommands auto-detect the repo from the working directory, so `--repo
   {owner}/{repo}` is optional; pass it when you want to be explicit.
4. **Model-drift check** — read the session default model: `jq -r '.model // "unset"' ~/.claude/settings.json`.
   - `opus` → proceed silently.
   - `unset` → the session inherits the account default. Note it in one line — `session default
     model is unset; inheriting the account default` — and continue.
   - anything else → print `⚠ session default model is '{model}', not 'opus': after each user gate
     this orchestrator falls back to it (see "Model split")` and continue.

   Warn only, never block: the user may have switched defaults deliberately, but the invariant in
   "Model split" fails silently without this check.

**The integration branch** (`{integration_branch}` — the branch features merge into / branch off
from) is already resolved in the repo-context block above, via the shared ladder in
`~/.claude/lib/branches.sh`: config `baseBranch` → GitHub default branch → `origin/HEAD`
symbolic-ref → `main`/`master`. All references to the base branch below use that value.

If it came back empty, re-derive it with that same ladder before continuing.

### 0a. Parse the Selector & Build the Issue Queue

**You were invoked with:** $ARGUMENTS

If nothing follows that colon, no argument was passed — stop and show the usage from
`argument-hint` rather than guessing a selector.

Turn that raw argument string into flags plus an ordered queue (token stripping is order-independent):

1. **Strip `auto`** — if present anywhere in the argument string, set `{automerge} = true`; otherwise `{automerge} = false`.
2. **Strip `parallel=N`** — if present anywhere in the argument string, set `{parallel} = N` (must be a positive integer); otherwise `{parallel} = 1`.
3. **Strip `opus`** — if the bare token `opus` appears anywhere in the argument string, set
   `{exec_model} = opus` and `{exec_agent} = "work-exec-opus"`; otherwise `{exec_model} = sonnet`
   and `{exec_agent} = "work-exec"`. Strip only a **standalone whitespace-delimited token** — never a
   substring of a quoted description (`/work 'opus migration issues'` selects issues; it does not set
   the flag), the same rule that governs `auto`.
4. The remainder is the `{selector}`.
5. **Parse `{selector}` into an ordered, de-duplicated, ascending issue queue** `{queue}`:
   - `#N` / `N` → `[N]`.
   - `#A-B` / `A-B` → inclusive range `A..B`.
   - comma list (`#1,#3,5`) → those numbers.
   - **Anything else → treat it as a description.** Resolve it to open issues (repo detection in
     step 0 has already run). Use **defensive label matching**: for "all P0 issues", try
     `gh issue list --state open --label P0 --json number,title` and then the other plausible
     spellings (`p0`, `priority: P0`, `priority/P0`, …), taking the first that returns matches. If
     no label matches, fall back to `gh issue list --state open --search "<text>" --json number,title`.
     Note that `--label`/`--search` are query flags on `gh issue list` itself — you cannot filter
     an already-fetched JSON blob with them, so each attempt is its own invocation. Collect the
     matching numbers. Remember that this queue came from a description (it always gets the
     confirmation gate in 0b, and triggers orchestrated mode).
6. Store `{queue}`, `{automerge}`, `{parallel}`, `{exec_model}`, and `{exec_agent}`.
7. Set `{orchestrated} = true` if `{queue}` has more than one issue **or** it came from a description; otherwise `{orchestrated} = false`.

### 0b. Confirm the Queue (user gate #1 — orchestrated mode only)

If `{orchestrated}` is true (`{queue}` has more than one issue **or** it came from a description):

1. Print each resolved item as `#N — title`.
2. State the execution plan: **mechanism** (`Agent` tool for ≤5 issues, `Workflow` pipeline for >5), **concurrency** (`parallel={parallel}` workers), **exec model** (`exec=sonnet` by default, or `exec=opus (medium effort)` when the `opus` token was passed), and the **merge policy** — with `auto`, merges are serialized one at a time in queue order and a PR that fails to merge halts the run (see "Merge queue"); without `auto`, every issue ends at an open PR.
3. Send a `PushNotification`, e.g. `"/work: resolved {count} issues ({#a,#b,#c}) — confirm to start (parallel={parallel})"`.
4. **Wait for the user's go-ahead.** This is the **only** user gate in orchestrated mode — after this, workers run fully unattended.

A single explicit `#N` selector sets `{orchestrated} = false`, skips this gate, and proceeds directly to the inline per-issue loop.

### 0c. Plan-file handoff (shared by both modes)

Every issue's plan stage (opus) and exec stage (`{exec_model}`) are separate subagent dispatches —
one agent cannot switch models mid-run. They hand off through a single artifact:

- **Path**: `{repo_root}/.claude/plans/issue-{number}.md`, where `{repo_root}` is
  `git rev-parse --show-toplevel` **resolved once by the orchestrator in the main working tree**.
  Inside a worktree, `--show-toplevel` returns the *worktree* root — so a stage must never
  re-derive this path itself; pass the orchestrator-computed **absolute path** to both stages.
  (This also keeps the rewake hook's plan-file freshness check accurate — it reads the main root.)
- **Excludes**: ensure `.claude/plans/`, `.claude/work-active*`, `.claude/automerge-active*`, and
  `.claude-work/` (the worktree root, see "Concurrency and isolation") are listed in
  `$(git rev-parse --git-common-dir)/info/exclude`; append any that are missing (skip silently if
  already present). Use `info/exclude`, **not** `.gitignore`: it is shared by every worktree and
  never committed, while a `.gitignore` edit exists only in the main working tree — in a fresh
  worktree these files would be untracked and the exec stage's `git add .` would commit the plan
  file into the PR. All are working artifacts, never committed.
- **Format**: the plan file contains exactly what the plan stage designs — persisted so the exec
  stage can act on it without re-deriving it. **Six sections**, and the sixth is not optional:
  - **Context** — issue number, title, problem/goal.
  - **Task checklist** — the issue's `- [ ]` items with current validated state.
  - **Files to create / modify / delete** — specific paths.
  - **Implementation approach** — ordered steps, edge cases, risks.
  - **Verification** — tests to add/run, build/typecheck commands, manual checks.
  - **Definition of done** — the numbered criteria that fix scope, the enumerated edge cases, and
    the commands that prove each one. This is the **done contract**: the exec stage treats it as
    the whole of scope and parks anything else (see `feature-closure`, Part B). One of its
    criteria is always that `docs/` contracts, the feature-matrix row and the test-plan row are
    updated **in the same commits as the code** — a docs pass deferred to a follow-up issue is
    the drift this section exists to stop. §7 gates on this section being present and non-empty.

  **This schema is stated in three places and they must move together** — here, in
  `backlog/SKILL.md` §6c's dispatch prompt, and in `agents/work-plan.md`. A change made in one is
  a change silently absent from two thirds of the runs.
- **Who writes it**: the plan stage does, directly, before reporting back — identically in both
  modes. It is never returned as text through the orchestrator (see "Return contract" below).

## Orchestrated mode (multi-issue / description selectors)

When `{orchestrated}` is true, **do not run the inline per-issue loop below**. Instead, the main session acts as an orchestrator and dispatches each issue in `{queue}` through two staged subagents — a **plan stage** (`model: opus`) and an **exec stage** (`model: {exec_model}`) — handed off via the plan file described in § 0c.

### Mechanism

- **`{queue}` ≤ 5 issues** → use the **Agent tool** (teammate agents), named e.g. `plan-{n}` / `exec-{n}`. Easier to monitor and resume.
- **`{queue}` > 5 issues** → use a **Workflow** `pipeline()` with two stages per issue — `agent(planPrompt, {agentType: 'work-plan', ...})` then `agent(execPrompt, {agentType: {exec_agent}, ...})` — so one issue's exec stage can run while the next issue's plan stage is still going (no barrier between stages).

State the chosen mechanism in output before dispatching.

### Stage instructions

For each issue `#{n}`, dispatch the plan stage, and once it completes, dispatch the exec stage.

**Plan stage** (`work-plan` agent — opus):

> You are a fully autonomous planning agent. Your only job is to plan issue #{n}.
>
> Run steps 1–7 of the inline `/work` loop for `#{n}`: detect the issue/PR, resolve or create its
> branch off `{integration_branch}`, mark it in-progress, explore the codebase, validate tasks
> against current code, and design the implementation approach.
>
> **Do not enter plan mode, and do not call `ExitPlanMode`.** There is no gate for you to cross:
> `ExitPlanMode` raises a plan-approval request to a dispatcher that is not waiting on one, and you
> would block on it forever. Plan and write; approval is not yours to seek.
>
> Write the plan to `{plan_file_path}` (the orchestrator-computed absolute path per § 0c). Return
> that path and a one-line summary — nothing else.

**Exec stage** (`{exec_agent}` agent — `{exec_model}`), dispatched only if the plan stage succeeds:

> You are a fully autonomous execution agent. Your only job is to execute the approved plan for
> issue #{n}.
>
> Read the plan at `{plan_file_path}` (from the plan stage) and implement it: make the changes,
> commit at natural stopping points per `/commit` conventions (referencing `#{n}`), and keep the
> issue in sync (checkbox toggles, labels, PR/commit links). Do NOT pause at any gate — auto-approve
> the PR (proceed to open it without prompting). Invoke `/pr` via the Skill tool to push and open
> the PR, then **stop and return the PR number**. Do **not** invoke `/automerge` — the orchestrator
> owns the merge at every `{parallel}`, because merges are serialized across the whole queue and a
> subagent holding one issue cannot see that queue (see "Merge queue").
>
> **Every process you start must end before you return.** Do not use `&`, `nohup`, or `disown`.
> Use foreground calls with `timeout: 600000`, or report a blocker. If a background process is
> genuinely unavoidable, capture its PID from `$!` on the same line that starts it, and end it by
> that PID.
>
> **Never build that cleanup on `jobs -p`.** Under a non-interactive `zsh -c` it returns nothing,
> so `kill $(jobs -p)` ends nothing and the shell still prints whatever success message follows it.
> One stage shipped exactly that and left twenty busy loops running for 3h26m at 601.8% CPU, with
> the load average at 195.63. Teardown now sweeps for orphans and will report yours.
>
> When done, report back concisely: PR number, status (PR open / blocked), any blocker reason,
> and `procs=N` — how many background processes you started and ended. `procs=0` is the
> expected answer.

Because each stage is given a single `#{n}` and never re-invokes `/work` itself, there is no
recursion — the orchestrator dispatches stages directly rather than delegating to another `/work`
run.

Dispatch both stages **by agent type** — `subagent_type: "work-plan"` (opus) and `subagent_type: {exec_agent}`, which is `"work-exec"` (sonnet) by default and `"work-exec-opus"` (opus at effort `medium`) when the `opus` token was passed — all defined in `~/.claude/agents/`. Their frontmatter carries the model and effort, `permissionMode: bypassPermissions` (so edits, commits, pushes, and `gh` calls never prompt), and the standing conventions (timestamp footer, no plan mode, return contract) — so none of that needs restating per dispatch. Do **not** pass the Agent tool's `mode` parameter: it is deprecated and silently ignored, and a subagent otherwise inherits the session's permission mode — which is exactly how an "autonomous" background stage ends up blocked forever on a permission prompt nobody will answer. Caveat: a parent session in `auto` mode suppresses the agent-defined `permissionMode`; run `/work` from default, `acceptEdits`, or `bypassPermissions` mode. Likewise, do **not** pass the Agent tool's `model:` (or a Workflow `effort:`) to compensate for the exec upgrade: the Agent tool has **no** `effort` parameter, so the agent file is the only thing that can express "opus at medium", and setting the model per-dispatch would split model and effort across two sources that silently disagree.

### Return contract (both stages, both modes)

**The orchestrator's context is the scarce resource.** It exists to learn that a stage finished and
move the plan along — nothing more. So a stage returns **at most a path, a status, and one line of
prose**. Never plan text, never a file dump, never a narrative of what it explored. Work products go
in files; the orchestrator gets the pointer. This is why the plan file exists: it is a handoff **by
reference**, so the plan reaches the exec stage without ever passing through the session between
them.

The same rule governs everything else the orchestrator arms — see the heartbeat below, which stays
silent while a stage is healthy precisely because "still working" is not news.

### Durability sentinel

Before dispatching a stage, take the process snapshot the teardown sweep compares against:

```bash
bash __CLAUDE_HOME__/lib/stage-processes.sh snapshot {n}
```

Without it the sweep in teardown step 5 exits 5 and reports **blind**, because it cannot tell the
stage's processes from yours. Then write a `work-active-{n}` sentinel; delete it when the stage ends (success
or blocker). This is what scopes the `asyncRewake` hooks in `~/.claude/settings.json` to *this* run, so
a stalled orchestrator gets rewaked instead of idling — and so the hooks stay inert in unrelated
sessions. It is the `/work` counterpart of `/automerge`'s per-PR `automerge-active-{pr}` sentinel, and the hook
honors either.

**One sentinel per issue** — the filename carries `{n}`. With `{parallel}` > 1 several stages are in
flight at once, and a single shared file would have them silently overwrite each other's state.

```bash
mkdir -p "$(git rev-parse --show-toplevel)/.claude"
cat > "$(git rev-parse --show-toplevel)/.claude/work-active-{n}" <<EOF
{"issue": {n}, "stage": "plan|exec", "branch": "{branch}", "owner": "{owner}", "repo": "{repo}",
 "session": "$CLAUDE_CODE_SESSION_ID"}
EOF
```

**Write it once and do not rewrite it in place.** Both hooks and `session-cleanup.sh` key off the
`session` field, so a hand-edit that drops it orphans the sentinel: `mine()` treats an unstamped
file as this session's while `session-cleanup.sh` refuses to touch it.

The `session` field is what makes cleanup safe: several `claude` sessions run at once, often on the
same repo, and both the rewake hook and `SessionEnd` cleanup use it to act only on **their own**
run's state. `$CLAUDE_CODE_SESSION_ID` is already exported into every Bash call — nothing to derive.

Delete it on **every** exit from a stage — completion, cap breach, or blocker — so the hooks stop
rewaking for work that is no longer running. That deletion is step 3 of **Stage teardown** below; do
not treat it as a standalone rule. Ensure `.claude/work-active*` is excluded alongside
`.claude/plans/` (same §0c `info/exclude` step).

The hook self-heals a sentinel you fail to delete rather than rewaking forever: it drops one whose
stage has passed its wall-clock cap, whose plan file is newer than it, or whose PR has merged/closed.
That is a safety net for a crashed stage, not a licence to skip the `rm -f` — a lingering sentinel
still costs the session rewake turns before it expires.

Separately, the hook stops nudging a stage that shows **no observable progress** for 30 min (plan) /
45 min (exec and automerge) — no new commit on the branch, no PR state change, no plan-file write —
and asks once for teardown. Two things to know about that notice:

- **It is not a firing count.** It used to be (`MAX_REWAKES=20`), which measured how often the
  session went idle rather than whether the stage was moving; a chatty session exhausted it in about
  four minutes and demanded teardown of four healthy stages at once. Rounds where the hook could not
  read `gh` at all are excluded entirely — unobservable is unknown, never "nothing happened."
- **It cannot see uncommitted edits.** A stage writing files in a worktree without committing looks
  exactly like one doing nothing. Check `git -C "{tree}" status --porcelain` and the Monitor's output
  before acting on it; if files are moving, ignore the notice and let the wall-clock caps below own
  the deadline.

### Stage teardown

**Every exit from a stage runs teardown — success, blocker, cap breach, error, or abandonment. There
is no path that skips it.** Everything this command starts is long-lived, so anything not explicitly
released keeps running for the rest of the session. In order:

1. **`TaskStop` the stage's `Monitor`.** It is `persistent: true` — unstopped, it polls `git log` and
   `gh pr list` every 60s against a branch nobody is working on, until the session ends.
2. **`TaskStop` the teammate**, unless it already exited cleanly on its own.
3. **`rm -f` the sentinel and its side files**: `rm -f .claude/work-active-{n}{,.rewakes,.capped,.progress}`.
   All three, every time — `.progress` carries the last observed progress fingerprint, and one left
   behind is inherited by the next run on that issue as if it were a fresh sample.
4. **`rm -f` any `automerge-active-{pr}` sentinel this issue's merge stage left behind**, plus its
   `.rewakes`, `.capped` and `.progress`. `/automerge` now keeps that sentinel alive until the merge is *confirmed* (its Step 2),
   which is deliberate — it is what lets a stalled merge be rewaken. The cost is that a merge stage
   which stops without merging leaves one on disk, and nothing else here would remove it:
   `session-cleanup.sh` only catches it at `SessionEnd`, hours later. Until then it costs a rewake
   turn every time the session goes idle.
5. **Sweep the processes the stage orphaned:**

   ```bash
   bash __CLAUDE_HOME__/lib/stage-processes.sh sweep {n} --tree "{tree}"
   ```

   **Before the worktree release, not after.** A process still holding a cwd inside the worktree
   makes `git worktree remove` fail, and step 6 would then report uncommitted-work contention that
   is really a leaked process. At `{parallel}`=1 pass the repo root as `--tree`.

   Read the exit code. `0` is clean. `3` means something was left for you: an orphan outside the
   tree, or one that would not end. `5` means the sweep was **blind** — no snapshot was taken
   before dispatch, so orphans cannot be ruled out. Blind is not clean; record it as a blocker
   rather than reporting the stage torn down.
6. **Release the issue's worktree**, if one was provisioned (see "Concurrency and isolation").

**Recording a blocker is not a substitute for teardown.** It is the opposite: a blocked issue's
monitor and teammate are precisely the ones still running. Every row of the caps table below, and
every "record and continue to the next issue" in the blocker policy, means *tear down first, then
record*.

Before arming anything, check whether one is already live — a rewake or a resumed run can re-enter
this code with a monitor already watching the issue. Ask the two views that actually track live
work, and read either as **evidence, not proof**:

- **The ledger's `monitor`/`teammate` task IDs** for this issue — recorded at arm time, and the only
  record that survives a compaction.
- **`~/.claude/run/bg-tasks-$CLAUDE_CODE_SESSION_ID.json`** (written by `hooks/bg-snapshot.sh` from
  the `Stop` payload's `background_tasks`) — `seen: listed` carries the in-flight monitors and
  shells; `seen: absent` or a missing file is **unknown**, never empty. `ListAgents` covers
  subagents, not monitors.

**Do not use `TaskList` for this.** It is the `TaskCreate` to-do board and does not track monitors,
teammates or shells at all, so it answers "nothing" every single time — a check that has never once
done its job. Resolve a disagreement toward the cheaper failure:

- **A monitor for this issue is listed** → reuse it; never stack a second on the same branch.
- **Nothing is listed, or the view is unreadable** → **arm one**, and `TaskStop` any duplicate that
  later surfaces. Do not reason about whether one "should" already exist: the correct action is the
  same either way. A second 60s poller wastes ticks; an unmonitored stage is the dispatch-then-idle
  stall this entire section exists to prevent.

Teammates invert that rule: never spawn a second for the same stage, even when nothing is listed.
A duplicate poller is recoverable; two teammates committing to one branch is not.

### Concurrency and isolation

- Keep at most `{parallel}` issues in flight at once (each occupying both its stages in sequence). With the default `{parallel}=1`, wait for the current issue's exec stage to finish (and merge, when `{automerge}`) before launching the next issue's plan stage — this is the safest default for avoiding dependency/merge conflicts.
- **Merge stages are serialized whatever `{parallel}` is.** Exec stages may overlap; merges never do. See "Merge queue" below.
- When `{parallel} > 1`: a given issue's plan stage and exec stage **must** share one branch and working tree (the exec stage builds on the branch the plan stage created and reads the plan file it wrote) — do **not** give each stage its own `isolation: "worktree"`, since that would put them in different trees and break the handoff. Instead, the orchestrator provisions **one worktree per in-flight issue** up front (`git worktree add`) and passes that worktree's absolute path to both of that issue's stages. At `{parallel}=1` no worktree isolation is needed.
- **Worktree path is session-scoped**, so cleanup can tell whose it is:
  `{repo_root}/.claude-work/$CLAUDE_CODE_SESSION_ID/issue-{n}`. Exclude `.claude-work/` alongside
  `.claude/plans/` (same §0c `info/exclude` step).
- **Release it when the issue is done** — this is step 6 of Stage teardown, and it applies on every
  exit, including blockers:

  ```bash
  git worktree remove "{worktree}"   # NO --force
  git worktree prune
  ```

  **Never `--force`.** A non-zero exit means uncommitted work in that tree: leave it alone, print the
  path, and record it in the final summary. An abandoned worktree is recoverable; destroyed work is
  not.
- **Order matters against `/automerge`, and the exec stage cannot fix it itself.** `/automerge`
  merges with `gh pr merge --squash --delete-branch`, so a worktree that still has the branch checked
  out ends up pinned to a deleted branch — and `gh pr checkout` inside `/automerge` also fails while
  another worktree holds the branch. The exec stage is *standing in* the worktree that has to go, so
  it **never invokes `/automerge`**: it stops after `/pr` and returns the PR number (its dispatch
  prompt says so). The **orchestrator** then (1) releases the issue's worktree (teardown step 6), and
  (2) enters the PR into the merge queue below, which dispatches the merge as its own stage — a
  `{exec_agent}` subagent whose prompt is `/automerge #{pr_number}` — keeping the issue's sentinel in
  place (rewrite it with `"stage": "exec"` refreshed) so the 2 h cap and rewake guard keep covering
  the merge. This holds at `{parallel}=1` too, where there is no worktree to release but the
  serialization still is the orchestrator's to enforce. **When that subagent returns, verify the
  merge against `gh` exactly as step 10 requires.** The subagent is where the stall happens and its report is not evidence.
  `Stop` does not fire inside a subagent, so the guard that covers this wait everywhere else
  cannot reach it while it runs; a `SubagentStop` hook now catches the common case (see
  `hooks/automerge-rewake.sh`), and the surviving `automerge-active-{pr}` sentinel lets the
  orchestrator's own `Stop` catch the rest — but both are backstops, and this check is the one
  that does not depend on harness behavior. Clear that sentinel in teardown either way.

### Merge queue

**Only when `{automerge}` is true.** Without `auto` nothing here runs, every issue ends at an open
PR, and that is the documented behavior of a run without the token.

Every branch in `{queue}` was cut from `{integration_branch}` at its own plan time, so no branch
contains any other's work. Merging them concurrently is what leaves a pile of PRs open against a
base that has moved out from under all of them. So the orchestrator holds **one merge slot** for
the whole run:

- **One merge stage in flight, run-wide.** Never dispatch a second while one is unverified —
  including at `{parallel}>1`, where several exec stages legitimately overlap.
- **FIFO in `{queue}` order.** Issue k's PR merges before issue k+1's. An issue whose exec stage
  finished early waits its turn.
- **A waiting issue is `merge-queued`.** Release its worktree (teardown step 6, already required
  before any merge), `TaskStop` its Monitor, and **keep** its `work-active-{n}` sentinel. Nothing is
  working on it, so leaving the Monitor armed would tear down a healthy PR at the 10-minute stall
  rule for the crime of waiting. Queue depth is bounded by `{parallel}`, so it needs no cap of its
  own.

**Drain the slot like this.** When the slot is free and `{queue}` order says PR `#{pr}` is next:

```bash
bash __CLAUDE_HOME__/lib/merge-gate.sh {pr} --repo {owner}/{repo}
```

The previous merge moved the base, so this asks whether `#{pr}` still applies to it. Act on the
exit code and nothing else:

| rc | Meaning | Action |
|---|---|---|
| `0` | ready (`CLEAN`, `HAS_HOOKS`, `UNSTABLE`, `BLOCKED`) | Take the slot: dispatch the merge stage |
| `1` | `BEHIND` | Take the slot and dispatch anyway. `/automerge` Step 3 exit 4 runs `gh pr update-branch` and re-waits CI. This is the normal reading for the second and every later PR in a queue |
| `2` | unknown | **Halt.** An unreadable state is not a merge. Record `merge gate unreadable for #{pr}` |
| `3` | already `MERGED`/`CLOSED` | Free the slot and move on. Nothing to do, and this is what makes a re-entered drain idempotent |
| `5` | `DIRTY`/`CONFLICTING` | **Halt.** Record the conflict as this issue's blocker |
| `6` | `DRAFT` | **Halt.** Record `PR #{pr} is a draft` |

The gate answers whether the PR still applies to the base, **not** whether it is green — `BLOCKED`
and `UNSTABLE` are rc 0 because remediating CI and reviews is `/automerge`'s own cycle.

**Then verify the merge stage's result against `gh` (step 10) and free the slot.** `MERGED` frees it
for the next PR. Anything else halts.

**Halting means:** stop dispatching new plan stages and new merges; let exec stages already in
flight finish and open their PRs, since their work is done and abandoning it buys nothing; then run
**Stage teardown for every remaining in-flight issue** and go to step 11. Issues never dispatched
stay in the summary with `not dispatched — run halted at #{n}`.

The halt is what keeps the sequence honest. Continuing past a PR that did not merge means every
later branch is built on a base missing that work, which is the stacking this section exists to
prevent.

### Subagent activity heartbeat (durability)

**Dispatch-then-idle is forbidden.** It is exactly how multi-hour stalls happen: the orchestrator
dispatches a teammate, yields **with nothing watching**, and blocks forever on a completion
notification that never arrives because the teammate stalled mid-turn rather than finishing. The
completion notification is a *convenience*, never the primary signal — it only fires when a teammate
exits cleanly, which is precisely the case that isn't stalling.

**Ending a turn is not idling.** The forbidden thing is yielding *unwatched*; a turn that ends with a
live `Monitor` is the healthy case, and so is every ordinary reply to the user while a stage runs.
This distinction is load-bearing, not pedantic: conflating the two is what let the rewake hook read
"a sentinel exists and a turn ended" as "the session stalled" and fire after every reply — a
heartbeat at roughly one nudge per five seconds. The hook now reads the `Stop` payload's
`background_tasks` to tell the two apart, and stays silent while anything is watching the issue.

So while any plan/exec teammate is in flight, arm a **`Monitor`** on that issue's observable
progress before yielding. Every stdout line the script prints becomes an event delivered to the
orchestrator, so it keeps watching without holding a turn open.

**Poll every 60s; emit only when something changed.** Every emitted line is a message in the
orchestrator's context, and "still working" is not news — a per-tick heartbeat would spend ~90
messages across an exec stage saying nothing. It would also be self-defeating: `Monitor` **auto-stops
a source that emits too much**, so a chatty heartbeat can silently disarm the very stall guard it was
meant to be. Silence here means healthy.

**Which is exactly why the probes must be validated before arming.** "Silence means healthy" holds
only while the probes can actually *see* the target. A monitor pointed at a valid-but-wrong tree —
the main repo root while the work happens in a worktree, say — emits nothing for the entire stage
and reads as a perfectly healthy run. A health check that cannot observe its subject must report
**blind**, never **healthy**; that failure is the expensive one precisely because it looks like the
good outcome. So assert the tree, then assert whichever signal *this* stage is expected to produce:

```bash
# {tree} is the hard gate — a wrong tree is what makes a monitor silently blind.
git -C "{tree}" rev-parse --git-dir >/dev/null || exit 1

# Then the stage-appropriate signal. An exec stage commits to {branch}, so the ref must
# resolve. A PLAN stage does not: it CREATES the branch (step 4), so at arm time that ref
# legitimately does not exist yet — asserting it for a plan stage would block every fresh
# issue. What makes a plan stage observable is the plan file, so check its directory.
case "{stage}" in
  exec) git -C "{tree}" rev-parse --verify "{branch}" >/dev/null || exit 1 ;;
  plan) plan_dir=$(dirname "{plan_file}"); [ -d "$plan_dir" ] || exit 1 ;;
esac
```

A failure here is a blocker — never arm a watcher that cannot see anything. But **a missing branch
during a plan stage is not a failure**; it is the expected starting state.

```bash
# Monitor: description "issue #{n} {stage}: progress + stalls", persistent: true
# Emits on state change and on stall only — a healthy stage produces no events.
# claude-work-monitor:${CLAUDE_CODE_SESSION_ID}:#{n}
#   ^ keep this marker: it lands in the process's argv, so SessionEnd cleanup can
#     identify this session's monitors without touching another session's.
# Watches THREE signals: last commit, PR state, and the plan file's mtime. The
# plan-file signal is what makes plan stages observable — a plan stage produces no
# commits and no PR for its entire (legitimately up to 30-min) life, so commits+PR
# alone would false-STALL every healthy plan stage at the 10-minute mark.
# {plan_file} is the orchestrator-computed absolute path from §0c.
# {tree} is the issue's worktree when {parallel} > 1, and the MAIN REPO ROOT at {parallel}=1,
# where no worktree is provisioned ("Concurrency and isolation"). The orchestrator substitutes
# the concrete path — never leave it unset, or `git -C` silently watches the wrong tree.
stalls=0; last=""
while :; do
  commit=$(git -C "{tree}" log -1 --oneline 2>/dev/null || true)
  # `.[0]` is null when no PR exists yet, and jq interpolates null fields as the string "null" —
  # so a naive "\(.number):\(.state)" yields "null:null", never empty, and the ${pr:-none}
  # default below could never fire. Guard it.
  pr=$(gh pr list --head "{branch}" --state open --json number,state \
       -q '.[0] | if . then "\(.number):\(.state)" else "" end' 2>/dev/null || true)
  plan=$(stat -f %m "{plan_file}" 2>/dev/null || stat -c %Y "{plan_file}" 2>/dev/null || true)
  now="$commit|$pr|$plan"
  if [ "$now" != "$last" ]; then
    # Skip the first sample: it's the starting state, not a change.
    [ -n "$last" ] && echo "$(date '+%H:%M:%S %Z') — #{n} {stage}: ${commit:-no commits} | PR ${pr:-none} | plan ${plan:-absent}"
    stalls=0
  else
    stalls=$((stalls+1))
  fi
  last="$now"
  if [ "$stalls" -ge 10 ]; then
    # Emit and KEEP POLLING — never exit. The orchestrator owns teardown decisions,
    # and this same monitor must survive the whole stage (the rewake hook says
    # "reuse the existing monitor", which only works if a stall doesn't kill it).
    # Resetting the counter re-emits STALL every 10 stalled minutes.
    echo "STALL — #{n} {stage}: no commit, PR state change, or plan-file write in 10m"
    stalls=0
  fi
  sleep 60
done
```

Use `persistent: true` — `Monitor`'s own `timeout_ms` caps at 60 minutes, which is shorter than the
exec stage's 90-minute budget. `TaskStop` the monitor when the stage ends.

The happy path needs no monitor event at all: a background teammate already delivers a **completion
notification** when it exits cleanly. The monitor exists for the case that notification cannot cover
— the teammate that stalls and therefore never exits.

**Caps and escalation** (a wait that cannot end is a bug, not patience):

| Signal | Threshold | Action |
|---|---|---|
| No new commit **and** no PR state change **and** no plan-file write | 10 min (`idle_ticks=10`) | `SendMessage` the **existing** teammate to re-poke it — it may have stalled mid-turn. Do not spawn a second one |
| Still no progress after a re-poke | 2 re-pokes (~30 min) | **Stage teardown**, then record the issue as blocked |
| Plan-stage wall clock | 30 min | **Stage teardown**, then record blocker `plan stage exceeded 30m` |
| Exec-stage wall clock (implementation through `/pr`) | 90 min | **Stage teardown**, then record blocker `exec stage exceeded 90m` |
| Exec stage once `/automerge` is in flight | 2 h total for the stage | **Stage teardown**, then record blocker `exec+automerge exceeded 2h` |
| An issue sitting in `merge-queued` | none — no cap, no stall rule | Its Monitor is stopped and nothing is working on it, so it cannot stall. The caps resume when its merge stage is dispatched. A queued issue torn down for "no progress" is a healthy PR killed for waiting its turn |
| Rewake hook's no-progress notice (backstop, fires once) | 30 min plan / 45 min exec+automerge | **Verify first** — `git -C "{tree}" status --porcelain`. Uncommitted edits are invisible to it. Tear down only if genuinely stuck |
| Rewake hook's "looks unwatched" nudge | at most 1 per stage per 10 min, and **never while a Monitor or teammate for that issue is in flight** | Re-arm whatever is missing, re-check ground truth, then answer briefly. A nudge is a prompt to check, not a verdict that you stalled |

The 2-hour extension exists because `/automerge`'s own bounded waits can legitimately sum past
90 minutes (up to 5 cycles, each with a 30-min CI cap and a 15-min review cap) — a slow-but-healthy
merge must not be torn down as a blocker by a cap tighter than its parts. 2 h matches the rewake
hook's `EXEC_CAP`/`AUTOMERGE_CAP`; `/automerge`'s internal caps govern inside it.

Every action above means the **full** teardown — monitor *and* teammate *and* sentinel *and* worktree
— not just `TaskStop`-ing the teammate. The stall path is the one where the monitor is most likely to
be orphaned, because it is the path where you are busy thinking about the teammate.

Exceeding a cap is a **blocker**, never a reason to keep waiting. Blocked issues follow the existing
blocker policy below: tear down, record, and continue to the next issue.

When a monitor event does land, print it as a one-line `🕐` heartbeat (e.g.
`🕐 14:32:10 CDT — #7 exec: first commit, PR not yet opened`). Events are rare by design, so each one
is worth showing.

This 60s cadence is the orchestrator's own poll — only the main session can background-poll; a
dispatched teammate cannot. It is independent of the GitHub API poll cadences inside `/ci` and
`/automerge` (30s, capped), which those commands run for themselves.

**The Workflow path (`{queue} > 5`) needs the same discipline** — including teardown. It has no
teammate to `TaskStop`, but it still creates sentinels and worktrees, and those leak identically: have
each stage release its own, and sweep any survivors after the `pipeline()` returns. The caps go *in
the stage prompts* instead: tell each `agent()` stage its wall-clock budget (30 min
plan / 90 min exec, 2 h once `/automerge` is in flight) and to report a blocker rather than wait past it. A stage that errors or is
skipped comes back as `null` — `log()` every null stage explicitly, so a silently-dropped stage is
never mistaken for a success in the final summary.

### Blocker policy (same as inline)

A plan-stage or exec-stage failure (a `/pr` failure, or any other blocker before a PR exists) is **torn down** (see Stage teardown), **recorded**, and the run **continues** to the next issue — an issue that never reached a PR leaves nothing open against the base. If the plan stage fails, the exec stage for that issue is skipped and the plan-stage failure is recorded as the blocker.

**A merge failure halts the run instead** (`{automerge}` only): a merge-gate blocker or any verified non-`MERGED` outcome stops further dispatch — see "Merge queue". Issues are independent units right up until one of them merges; after that the base has moved and the rest of the queue is no longer independent of it.

**A stage that fails by *reporting* a blocker still needs teardown.** Only cap breaches arrive with the
teammate already stopped; a self-reported failure may leave it alive, and its monitor certainly is.
Never move to the next issue while the previous one's monitor is still polling.

The user cancelling at the gate in step 0b and a merge failure are the two things that stop the whole
run — and "stop the whole run" means **run Stage teardown for every in-flight issue** before
stopping, not just ceasing to dispatch new ones. At `{parallel} > 1` there may be several live.

Collect each issue's result (PR number, merge status, blocker) for the final summary in step 11.

---

## Inline per-issue loop

> **When this runs:** the inline loop is used for a single explicit `#N` selector, driven by the main session. For multi-issue / description selectors the orchestrator (section above) dispatches the equivalent work across staged plan/exec subagents instead of running it here in the main session — steps 1–7 map to the plan stage and steps 8–10 map to the exec stage.

Now iterate over `{queue}` **one issue at a time**, driving each one all the way through (and, if `{automerge}`, to merge) **before starting the next**. Within steps 1–10 below, `{number}` refers to the **current** issue in the queue.

> Note on `auto` ordering: with multiple issues and `auto`, each issue is fully driven plan → implement → PR → merge before the next begins (not batched).

### 1. Detect Issue vs PR

Use the `gh` CLI to check what exists:

**A. Fetch Issue**:

- Run: `gh issue view {number} --json number,title,state,body,labels,milestone,author,createdAt`
- If the command succeeds, store the issue details. If it errors (not found), there is no issue
  with this number.

**B. Fetch PR**:

- Run: `gh pr view {number} --json number,title,state,headRefName,body,isDraft 2>/dev/null`
- If the command succeeds, store the PR details. If it errors, there is no PR with this number.

**C. Determine what to work on**:

- If BOTH issue and PR exist with this number: Ask user "Found both issue #{number} and PR #{number}. Which would you like to work on?"
- If ONLY issue exists: Work on the issue
- If ONLY PR exists: Work on the PR (and find associated issue if linked)
- If NEITHER exists: Error and exit

### 2. Extract Branch Information

**If working on PR**:

- Branch name is in PR details: `headRefName` field
- Linked issue: Parse PR body for "Closes #" or "Fixes #" pattern

**If working on issue**:

- Search for an existing PR linked to this issue:
  `gh pr list --state all --search "{issue_number} in:body" --json number,headRefName,state,body`
- If a PR is found: extract the branch name from its `headRefName`
- If no PR: Will need to create branch (step 4)

### 3. Check Branch Status (Resume Logic)

Once branch name is determined, check if it exists:

**A. Check local branch**:

```bash
# Every conventional prefix, not just feature/ — and NOT a `git branch --list` pattern: its
# wildcards do not cross `/`, so `*/{number}-*` cannot see a branch like `feat/{number}-a/b`
# at all and the scan would report clean while the branch sits right there.
git for-each-ref --format='%(refname:short)' refs/heads \
  | grep -E "^[^/]+/{number}-" 2>/dev/null
```

or if branch name is known:

```bash
git branch --list "{branch_name}" 2>/dev/null
```

**B. Check remote branch** (if not found locally):

```bash
git ls-remote --exit-code --heads origin "{branch_name}" 2>/dev/null
```

**C. Handle scenarios**:

- **Local branch exists**:
  - Checkout: `git checkout "{branch_name}"`
  - Pull latest: `git pull origin "{branch_name}" 2>/dev/null` (ignore errors if no upstream)
  - Message: "✓ Resumed work on existing local branch: {branch_name}"

- **Remote branch exists (but not local)**:
  - Fetch and checkout: `git fetch origin "{branch_name}":"{branch_name}" && git checkout "{branch_name}"`
  - Message: "✓ Fetched and checked out branch from remote: {branch_name}"

- **Remote deleted (PR likely merged)**:
  - Check if the PR is merged: `gh pr view {pr_number} --json state,mergedAt` — `{pr_number}` is the
    number of the PR found in step 2 (from `gh pr list --search` when working on an issue), **not**
    the issue number; the two only coincide when the selector named a PR directly. If step 2 found
    no PR, there is nothing to check — treat as "no branch exists" (step 4).
  - If merged:
    - Fetch latest integration branch: `git fetch origin {integration_branch}:{integration_branch}`
    - Check if any local commits exist: `git rev-list --count {integration_branch}..HEAD`
    - **Then classify whether that work is already upstream** (`{already_merged}`). The commit
      count alone cannot tell you: `/automerge` squash-merges, which writes a *new* commit, so
      the branch's originals are never ancestors of the integration branch and the count stays
      `> 0` forever. Deciding on the count would offer a followup branch after every single
      merge. Run these in order; first match wins:

      ```bash
      # 1. Ordinary merge commit or fast-forward.
      git merge-base --is-ancestor HEAD {integration_branch} && echo already_merged

      # 2. Squash merge, integration not advanced since — two dots, tip vs tip.
      #    (Three dots diff against the merge base and never detect a squash merge.)
      git diff --quiet {integration_branch} HEAD && echo already_merged

      # 3. Squash merge, integration advanced since — compare only the paths this branch touched.
      base=$(git merge-base {integration_branch} HEAD)
      git diff --name-only "$base" HEAD \
        | tr '\n' '\0' | xargs -0 git diff --quiet {integration_branch} HEAD -- && echo already_merged
      ```

      Do **not** use `mergedAt` with `git rev-list --since`: it filters on committer date, which
      a rebase rewrites. (Pinned by `tests/git-scenarios.sh`, same logic as `/pr` step 6.)
    - If local commits > 0 **and `{already_merged}` is false**:
      - Ask: "PR #{number} was merged. You have {count} local commit(s) not yet upstream. Create a followup branch?"
      - If yes: Create `"{branch_name}-followup"` and cherry-pick commits. **Suffix the branch
        you are on** rather than rebuilding the name — that preserves its type and scope
        (`fix/17-x` → `fix/17-x-followup`); rebuilding from `feature/` would silently change
        the branch's type mid-flight.
    - If no local commits, **or `{already_merged}` is true**:
      - Message: "PR #{number} was already merged. Switching to {integration_branch}."
      - Checkout integration branch: `git checkout {integration_branch}`
      - Exit (work is complete)

- **No branch exists anywhere**:
  - Proceed to step 4 to create new branch

### 4. Create New Branch (if needed)

If no existing branch found:

1. Extract kebab-case slug from issue/PR title (2-4 meaningful words, lowercase, hyphen-separated)
2. **Derive `{type}` from the issue's labels** — already fetched in step 2A's
   `gh issue view … --json …,labels,…`, so this costs no extra call. **Ordered, first match
   wins** (the order is part of the contract: `/backlog` derives the same value in its
   orchestrator, and an unspecified order would branch an issue labelled both `bug` and
   `documentation` differently depending on which command ran):

   | Label (case-insensitive) | `{type}` |
   |---|---|
   | `bug`, `defect`, `regression` | `fix` |
   | `documentation`, `docs` | `docs` |
   | `performance`, `perf` | `perf` |
   | `refactor`, `refactoring` | `refactor` |
   | `test`, `tests`, `testing` | `test` |
   | `ci`, `build` | `ci` |
   | `chore`, `dependencies`, `deps` | `chore` |
   | `enhancement`, `feature`, anything else, or no labels | `feat` |

   Only `bug`, `documentation` and `enhancement` are GitHub *default* labels, so in most repos
   this settles on `feat`. That is the correct outcome, not a failure to match.

   **Never generate a scope or a breaking marker.** `feat(api)/…` and `fix!/…` are accepted on a
   hand-made branch but never minted here: parentheses are glob characters in zsh, and keeping
   them out of generated names caps that exposure to branches a human typed deliberately.
3. Create branch name: `{type}/{number}-{slug}`
4. Ensure on integration branch: `git checkout {integration_branch}`
5. Pull latest: `git pull origin {integration_branch}`
6. Create and checkout: `git checkout -b "{type}/{number}-{slug}"`
7. Message: "✓ Created new branch: {type}/{number}-{slug}"

### 4b. Mark Issue In Progress (status label)

Once a branch is checked out or created (whether resumed in step 3 or created in step 4), mark
the issue as in progress so its status reflects that work has started:

1. Fetch the repo's existing labels: `gh label list --json name -q '.[].name'`.
2. **Defensive matching** — only apply a label that already exists in the repo. Never create a
   new label silently.
3. If a status label like `in progress`, `in-progress`, or `wip` exists and is not already on
   the issue, add it: `gh issue edit {number} --add-label "<label>"`.
4. If no matching status label exists, skip silently (no error, no new label).
5. Message (only if a label was added): "✓ Marked issue #{number} as '<label>'"

### 5. Display Work Context

Show comprehensive information:

**Issue/PR Details**:

- Number and title
- Current state (open/closed/merged)
- Labels
- Milestone (if assigned)
- Full description
- Author and creation date

**Task Checklist**:

- Extract tasks from issue body (look for `- [ ]` or `- [x]` markdown patterns)
- Count and display: "Tasks: {completed}/{total}"
- List all tasks with status indicators:
  - ✓ Completed tasks (- [x])
  - ○ Remaining tasks (- [ ])

**Git Status**:

- Current branch name
- Commits ahead of the integration branch. **Refresh the base ref first** — the local
  `{integration_branch}` is whatever it was at the last pull, so counting against it silently
  drifts stale as soon as the base moves. This is the same fix `/status` step 7 already applies;
  the two `git fetch` calls in §3 above are inside the "remote deleted" branch and never run
  on the ordinary path that reaches here.

  ```bash
  git fetch origin {integration_branch}
  git rev-list --count origin/{integration_branch}..HEAD
  ```
- Working tree status: `git status --short`

### 6. Update Issue as Work Progresses

As the implementation session proceeds, keep the GitHub issue in sync with the work. These
updates are **batched and applied at natural stopping points** — typically right after a
`/commit`, or when the user pauses or finishes a chunk of work — **not** per task item and
**without prompting for confirmation on each individual update**. (Project board column moves
are the exception and remain confirmation-gated; see Important Notes.)

At each natural stopping point, perform the following:

**A. Toggle completed checkboxes**

1. **Re-fetch the current issue body first** (`gh issue view {number} --json body -q .body`)
   to avoid clobbering edits made since `/work` started.
2. For each task item whose work is now complete, change its `- [ ]` to `- [x]`. Match on the
   **task text**, not line number — the body may have shifted since `/work` started.
3. Write the updated body back: `gh issue edit {number} --body-file <tmpfile>` (write the new
   body to a temp file to preserve formatting and newlines).
4. Recompute and report the new count: "✓ Updated issue #{number}: {completed}/{total} tasks checked"

**B. Update labels / status**

- When **all** task items are checked, swap the in-progress status label for a done/ready label
  if one exists — e.g. remove `in progress` and add `ready for review`.
- **Defensive matching** — only ever use labels that already exist in the repo (see step 4b);
  never create a new label silently. If no matching label exists, skip.

**C. Link PR / commits**

- After commits are made or a PR is opened, post a **single concise comment** on the issue
  referencing them — e.g. the PR number (`#{pr}`) and/or the short commit SHAs from
  `git log {integration_branch}..HEAD --oneline`. Use `gh issue comment {number} --body "..."`.
- Keep it terse — a reference line, not a verbose narrative. Batch **one comment per stopping
  point**, not one per commit.
- Skip if the PR body already auto-links the issue via `Closes #{number}` and no new
  information is worth surfacing.

### 7. Plan (opus plan subagent, then user gate #2)

After displaying the work context, delegate the design to the **`work-plan`** agent type (`Agent`,
`subagent_type: "work-plan"` — opus with `permissionMode: bypassPermissions` in its definition;
never pass the deprecated `mode:` param) — planning benefits from the stronger model, while the
mechanical implementation later does not. **Dispatch it synchronously (`run_in_background: false`).**
Inline mode arms no sentinel and no Monitor — that machinery belongs to orchestrated mode — so a
background dispatch here would be unguarded dispatch-then-idle, whereas a synchronous call cannot
stall the session — the tool result always comes back. That is *all* it guarantees: the result
proves the stage **returned**, never that it did anything. Check the work itself before moving on
(the plan-file gate below, and the SHA comparison in step 8).

**Dispatch it *before* entering plan mode, never inside it.** Two failures follow from getting this
backwards, and both have bitten this command:

- A subagent **inherits the parent's permission mode**. Dispatched from inside `EnterPlanMode`, the
  plan subagent lands in a mode that blocks the writes it exists to make — so it cannot write the
  plan file, and the plan has to be smuggled back as text through the orchestrator's context.
- Told to clear the gate itself, it calls `ExitPlanMode`, which raises a **plan-approval request to a
  parent that has already ended its turn**. Nobody answers, and it blocks on that tool result
  forever. That is the dispatch-then-idle stall in its purest form — a deadlock, not a slow run.

So: the **orchestrator** owns the gate, and the **subagent** owns the plan file. Neither does the
other's job.

**Dispatch the opus plan subagent** with the current issue context (number, title, body, task
checklist, branch name) and have it:

0. **Establish the done contract first**, before opening implementation files — load the
   `feature-closure` skill and follow its Part B §B1. The contract comes from the issue body. If
   the issue is thin (a title and a sentence), **upgrade it in place** to the Part A template —
   capability, in/out of scope, criteria, edge cases, verification — via `gh issue edit`, and say
   so in the one-line return so the user knows the ticket changed. An issue that says only "add
   CSV export" is not a contract, and planning from it guarantees the drift the gate below
   exists to catch.

1. **Explore the codebase** to understand current implementation state:
   - Read relevant files mentioned in tasks or the issue description
   - Understand existing patterns, architecture, and conventions
   - Identify dependencies and related code

2. **Validate each task** against current code state:
   - Check if any tasks are already complete (code exists)
   - Identify tasks that may be outdated or need updating
   - Flag tasks that have changed scope based on current implementation
   - Note any blocking dependencies between tasks

3. **Identify files to create/modify**:
   - List specific files that need to be created
   - List existing files that need modification
   - Note any files that should be deleted or moved

4. **Design implementation approach** for remaining tasks:
   - Propose order of implementation (respecting dependencies)
   - Outline specific changes for each file
   - Consider edge cases and error handling
   - Identify potential risks or challenges

5. **Include verification steps**:
   - Which tests need to be written or updated
   - Build/typecheck commands to run
   - Manual verification steps if applicable

Have the subagent **write** the plan to the orchestrator-computed absolute path from § 0c, and
**return only that file's absolute path plus a one-line summary** — per the return contract above.
(The no-plan-mode rule, the return contract, and the `🕐` footer are baked into the `work-plan`
agent definition — no need to restate them in the dispatch prompt.)

**Before the gate, confirm the file was actually written.** Capture `date +%s` immediately *before*
dispatching, then `stat` the absolute path from §0c and compare — the file must exist and be newer
than that timestamp. Existence alone is not enough: plan files are never deleted, so a stale one
from an earlier aborted run would read as success and send the user to approve the wrong plan. If
it is absent or older, that is a blocker (`plan stage returned without writing the plan`), not a
gate. **The orchestrated plan-stage dispatch takes the same gate** before it hands off to exec —
otherwise the exec stage is launched purely on the plan stage's self-report.

**Then check the plan carries a done contract.** Freshness proves the stage wrote *a* file; this
proves it wrote the one thing the exec stage's scope depends on:

```bash
awk '/^## Definition of done/{f=1;next} f&&/^## /{exit} f&&NF{print;exit}' "{plan_file_path}"
```

Empty output means the section is absent or has no content under it, and that is the blocker
`plan stage returned without a done contract` — not a gate, and not something to approve and fix
later. Without this check the contract is only text in a dispatch prompt and **nothing observes
whether the stage honored it**: a claim, not an observation. Read only this one line into the
session, never the plan body — the return contract still applies.

**User gate #2 — approve by reference.** Once the subagent reports back, `EnterPlanMode`, then:

1. Show the one-line summary and the plan file's path — **not its contents**. Reading the file back
   into the session would undo the whole point of the handoff; the user opens it directly.
2. Send a `PushNotification`, e.g. `"/work #{number}: plan ready for approval — .claude/plans/issue-{number}.md"`,
   so the user can review from the local desktop or their phone.
3. Call `ExitPlanMode`. The user must approve before implementation begins.

The plan file is already on disk, so approval gates *implementation*, not the writing of the plan. If
the user rejects or asks for changes, re-dispatch the plan subagent with their feedback and let it
rewrite the file in place.

### 8. Implement & Commit (`{exec_model}` exec subagent, autonomous)

Once the plan is approved, dispatch the **`{exec_agent}`** agent type (`Agent`,
`subagent_type: {exec_agent}` — `work-exec` (sonnet) by default, `work-exec-opus` (opus at effort
`medium`) when the `opus` token was passed, each with `permissionMode: bypassPermissions` in its
definition; never pass the deprecated `mode:` param, and never pass `model:`),
**synchronously** (`run_in_background: false` — same reasoning as step 7: it cannot stall the
session, and it still proves nothing about what landed),
to implement it **without further prompting**:

1. Read the plan at its absolute path (from step 7) and make the changes it describes.
2. **Treat the plan's `## Definition of done` as the whole of scope.** Load the `feature-closure`
   skill and follow its Part B. Anything else you notice — an unrelated bug in a file you had to
   touch, a refactor that would make the change fit more elegantly, a missing test nearby, a
   dependency worth upgrading — is a **finding**: append it to `docs/parked-findings.md` with file
   and line, and do not act on it. The one exception is something that blocks a criterion from
   being satisfiable at all; take that on and say so in the return line. Tests, edge cases, error
   states and wiring the change through to something a person can reach are **inside** the
   contract, not deferrable.
3. **Update `docs/` in the same commits as the code** — the relevant contract under
   `docs/contracts/`, the `docs/feature-matrix.md` row, the `docs/test-plan.md` row. Never a
   separate documentation pass and never a follow-up issue: the branch merges and `/automerge`
   deletes it, so there is no later in which to do this.
4. **Run the plan's Verification and Definition of done, and make them pass, before returning.**
   `/backlog` §6d already requires this of its exec stage and `/work` did not — so a contract
   enforced there was silently skipped here. Run the **full** suite, not only the tests you wrote;
   "nothing unrelated broke" is a criterion and it is the one most often assumed rather than
   checked.
5. Commit at natural stopping points using `/commit` conventions (conventional message + `(#{number})` issue reference). Do not prompt per change.
6. Keep the issue in sync as you go using **Step 6** (toggle checkboxes, update labels, link commits).
7. Stop after committing — in inline mode the orchestrator owns the PR gate (step 9), so tell it explicitly **not** to invoke `/pr` or `/automerge`.
8. Return the parked count in the one-line report (`… 3 parked`). A **count**, not a list — the
   return contract is unchanged, and the orchestrator reads the file rather than the report.

The synchronous tool result tells you the stage **returned**; it does not tell you it **did
anything**. Capture the head SHA *before* dispatching and compare after:

```bash
git -C "{tree}" log -1 --format=%H
```

(Inline mode never binds `{tree}` — that is orchestrated-only, per "Concurrency and isolation" — so
inline runs use the main repo root here.)

An unchanged SHA with a clean `git status --porcelain` means the stage produced nothing,
whatever it reported — record the blocker `exec stage returned without committing` rather than
carrying an empty branch into the PR gate. Otherwise proceed to step 9.

### 9. Create the PR (user gate #3)

When the work for this issue is complete and committed:

1. Generate the PR title (conventional, referencing the issue) and a short summary from the commits.
2. Display the proposed PR title + summary, and send a `PushNotification`, e.g. `"/work #{number}: PR ready to review"`.
3. **Wait for the user's go-ahead.** Then delegate to **`/pr`** (via the Skill tool) to push the branch and open the PR. Capture the new `{pr_number}` and PR URL.

### 10. Automerge (if `auto`)

If `{automerge}` is **false**, the PR is left open for review — record the outcome and continue to the next issue.

If `{automerge}` is **true**, the PR takes the run's single merge slot (see "Merge queue"). **Run the
gate first** — in orchestrated mode the base has moved since this branch was cut, and inline it costs
one read:

```bash
bash __CLAUDE_HOME__/lib/merge-gate.sh {pr_number} --repo {owner}/{repo}
```

rc `0` or `1` proceeds. rc `3` means it is already merged, so free the slot and skip. rc `2`, `5` or
`6` is a blocker and **halts the run** — the exit-code table in "Merge queue" is the contract.

On rc `0`/`1`, hand the PR off to **`/automerge #{pr_number}`** (via the Skill tool in inline mode; as
a `{exec_agent}` subagent in orchestrated mode). This phase is **fully autonomous**:

- It remediates reviews/CI (`/reviews auto`, `/ci auto`), waits for the Claude code review, and squash-merges — with **no user prompts** and **no plan mode**.

**Then verify the merge against `gh`, and record what `gh` says — not what the stage reported.**

```bash
# Guard BOTH fields. Without `// ""` a null one aborts jq, the output is empty, and the
# table below records "merge unverified" for a PR that actually merged — turning this
# check into the very failure it exists to prevent.
gh pr view {pr_number} --repo {owner}/{repo} --json state,mergeStateStatus \
  -q '(.state // "") + " " + (.mergeStateStatus // "")'
```

| Observed | Action |
|---|---|
| `MERGED` | Record merged. This is the **only** state that may print `✓ merged`. |
| `OPEN`, stage reported a genuine Stop condition (conflict, `BLOCKED`, CI failing) | Record that blocker — the normal path below. |
| `OPEN`, stage reported success or nothing actionable | **Re-dispatch the merge once** (see below), then re-check. Still `OPEN` → record blocker `merge stage returned without merging`. |
| `CLOSED` | Record closed-without-merge. Do not retry. |
| empty / command failed | A failed lookup is not a merge. Record `merge unverified — could not reach GitHub` and surface it. |

**Re-dispatch means re-running whatever this mode used the first time** — the Skill tool here in
the inline loop, and a fresh `{exec_agent}` merge-stage subagent in orchestrated mode, at every
`{parallel}` (see "Merge queue"). The retry holds the same merge slot; it does not release it to the
next PR and come back. Before retrying, `rm -f` any `automerge-active-{pr}`
sentinel the stalled attempt left behind, so the retry starts from a clean guard; keep the issue's
`work-active-{n}` sentinel and refresh its mtime. Retry **once** — a second failure is a blocker,
not a third attempt.

This check is not belt-and-braces; it is the backstop. A merge stage that ends one step short of
`gh pr merge` and returns as though it were finished is the observed failure mode, and it is
invisible from the report alone. In the **orchestrated** paths `/automerge` runs inside a subagent,
where `Stop` does not fire at all; inline it runs in this session, where `Stop` does fire and the
rewake hook applies. So the hook covers some paths and not others — this check covers all of them.

**Per-issue blockers** (a plan-stage failure, a `/pr` failure): run **Stage teardown**, record the outcome, send a `PushNotification` describing the blocker, and **continue to the next issue** — an issue that never reached a PR leaves nothing open against the base, so it does not compromise the sequence. Teardown comes first: "continue to the next issue" must never mean leaving this one's monitor and teammate running.

**A merge failure is different, and does not continue.** When `{automerge}` is true, a gate blocker
(rc `2`/`5`/`6`) or any verified non-`MERGED` outcome **halts the run** as described in "Merge
queue". Continuing would cut every later branch from a base missing this PR's work, which is the
stacking the merge queue exists to prevent. Without `auto` there is no merge and no halt.

(Exception, unchanged: if the user *cancels at a gate* in steps 0b/7/9, tear down every in-flight issue, then stop the whole run.)

### 11. Final Sweep & Summary (after the loop or all issues complete)

**Sweep before summarizing.** Stage teardown should have released everything already; this is the
check that it did, because the run ends here and anything still alive stays alive for the rest of the
session:

1. **`ListAgents` and `~/.claude/run/bg-tasks-$CLAUDE_CODE_SESSION_ID.json`** — `TaskStop` any
   `/work` subagent, monitor or teammate still live for an issue in `{queue}`, and say so; a
   survivor means a teardown path was missed and is worth reporting rather than quietly fixing.
   Peer-session rows in `ListAgents` belong to other sessions — never stop those. **An empty
   reading is not an assertion that nothing is live**: monitors and teammates are in-process, so
   nothing in `ps` corroborates it, and a missing or `absent` snapshot means the question went
   unanswered. Say "nothing reported live", and if steps 2–3 then turn up sentinels or worktrees
   neither view mentioned, name that disagreement in the summary. (`TaskList` is the to-do board
   and tracks none of this — it is not the sweep.)
2. `ls {repo_root}/.claude/work-active-* {repo_root}/.claude/automerge-active-*` — both should be
   empty. `rm -f` any stragglers and their `.rewakes` / `.capped` / `.progress` side files. **Check the automerge ones too**: a
   merge stage that stopped short leaves its sentinel behind by design (teardown step 4), and one
   that survives this sweep keeps rewaking the session about a PR nobody is working.
3. `git worktree list` — no `.claude-work/$CLAUDE_CODE_SESSION_ID/` entries should remain. Remove the
   clean ones; list any dirty ones in the summary rather than force-removing them.

**Then build the summary from ground truth, not from what the stages reported.** For every issue
in `{queue}`:

```bash
gh pr list --head "{branch}" --repo {owner}/{repo} --state all --json number,state,url \
  -q '.[0] | if . then "\(.number) \(.state) \(.url)" else "no-pr" end'
git log --oneline -1 "origin/{branch}" 2>/dev/null || echo "no remote branch"
```

Every row is written from that output:

- `✓ … merged` requires `gh` to say **`MERGED`**. A stage's claim that it merged is not sufficient
  — a merge stage that stops one step short of `gh pr merge` returns exactly the same way a
  successful one does.
- `MERGED` when the stage reported a blocker is also worth naming — the run recovered, and a
  summary that hides it teaches the wrong lesson about the blocker.
- A `gh` call that *fails* yields neither a merge nor an open PR: record `unverified` and say the
  lookup failed. Never resolve an unreadable state to the optimistic one.

**Closure lines, also from ground truth.** For each issue, read what the branch actually contains
rather than what the exec stage reported — a stage that says it updated the matrix and did not
returns the same line as one that did:

```bash
git diff --name-only "{integration_branch}...{branch}" -- docs/
git diff -U0 "{integration_branch}...{branch}" -- docs/parked-findings.md | grep '^+- \['
```

Read the second command's **exit status**, not just its output: `0` means findings were parked and
they are the lines printed, `1` means none were, and anything else means the lookup failed and the
parked state is **unknown** — say so rather than reporting `none`. Do not append `|| true`; it
collapses all three into "nothing there", which is the failure shape `CLAUDE.md` names.

Add three lines per issue, and keep them terse:

- **Docs updated** — the `docs/` paths the branch touched, and which matrix/test-plan rows moved.
  Empty output on a behavior-changing issue is worth naming, not omitting: it means a criterion
  claims docs rode along and nothing did.
- **Blockers handled** — anything outside the contract the exec stage had to fix to make a
  criterion passable, and why. This is where the diff legitimately grew; showing it lets the user
  agree with the reason.
- **Parked** — one flat line per finding with its file reference, closing with
  `Logged to docs/parked-findings.md. None of these were changed.` Keep it **unranked**: no
  suggested phase two, no "which would you like next". Offering a next step is how the cycle
  restarts. If nothing was parked, say `Parked: none` and stop — a short close is a good close.

Then send a final `PushNotification`.

**Inline mode** (single `#N`) — summary for that one issue with outcome and PR URL.

**Orchestrated mode** (multi-issue / description) — table across all issues:

```
/work summary ({owner}/{repo}) — orchestrated {n} issues

✓ #2 <title>  — merged (auto)         PR #37 <url>
✓ #7 <title>  — PR #41 opened          PR #41 <url>
✗ #9 <title>  — STOPPED: CI 'test' failing
○ #11 <title> — skipped (blocker above)

○ #13 <title> — not dispatched (run halted at #9)

Issues: {n} dispatched, {merged} merged, {open} PR(s) open, {blocked} blocked, {undispatched} not dispatched.
```

**If the run halted**, say so on its own line above the table — `halted after #{n}: <reason>` — and
list every queue entry that was never dispatched with that reason rather than omitting it. A summary
that silently drops the tail reads as a completed backlog.

Include PR URLs. Final notification example: `"/work done (orchestrated): 2 merged, 1 PR open, 1 blocked"`.

## Error Handling

### Issue/PR Not Found

If neither issue nor PR exists:

- Error: "Could not find issue #{number} or PR #{number} in {owner}/{repo}"
- Suggest: "Check the issue/PR number and try again"

### Branch Checkout Failure

If branch checkout fails:

- Display git error message
- Suggest: "There may be uncommitted changes. Run `git status` to check."

### Merge Conflicts on Pull

If pulling remote branch results in conflicts:

- Display conflicted files
- Message: "Merge conflicts detected. Please resolve manually, then commit."

### No Associated Issue for PR

If working on PR but no issue is linked:

- Warning: "This PR is not linked to an issue. Tasks may not be available."
- Continue with PR description only

## Usage Examples

### Example 1: Resume work on existing issue

```bash
/work 31

# Output:
# Checking for issue #31 and PR #31...
# Found issue #31: "Phase 1: Storage Layer"
# Found existing PR #31 linked to this issue
# Local branch found: feat/31-storage-layer
# ✓ Resumed work on existing local branch
# ✓ Marked issue #31 as 'in progress'
#
# Issue #31: Phase 1: Storage Layer
# Status: Open | Labels: enhancement, phase-1, in progress
# Tasks: 2/5 completed
#   ✓ Create StorageAdapter interface
#   ✓ Implement DiskAdapter
#   ○ Implement S3Adapter
#   ○ Implement R2Adapter
#   ○ Add adapter tests
#
# → Entering plan mode to design the remaining tasks (you approve the plan)...
#
# ...later, after implementing S3Adapter and committing:
# ✓ Updated issue #31: 3/5 tasks checked
# ✓ Linked commit abc1234 on issue #31
```

### Example 2: Start new work on issue

```bash
/work 42

# Output:
# Checking for issue #42 and PR #42...
# Found issue #42: "Add Vector Search with HNSW"
# No existing branch found
# ✓ Created new branch: feat/42-vector-search
#
# Issue #42: Add Vector Search with HNSW
# Status: Open | Labels: enhancement, phase-5
# Tasks: 0/8 completed
#   ○ Design HNSW index structure
#   ○ Implement insert algorithm
#   ...
#
# → Entering plan mode to design the implementation (you approve the plan)...
```

### Example 3: Resume after PR merged

```bash
/work 35

# Output:
# Checking for issue #35 and PR #35...
# Found PR #35: "feat: implement S3 adapter"
# PR #35 is merged (closed)
# Remote branch deleted
# No local commits remaining
# ✓ Work completed. Switched to main branch.
#
# PR #35 was successfully merged.
# Use /work with a new issue number to start new work.
```

### Example 4: Single issue with automerge

```bash
/work #42 auto

# opus plan subagent designs the approach → .claude/plans/issue-42.md written on approval
# → sonnet exec subagent implements → commits → PR review (you approve) → /pr opens PR #58
# → hands off to /automerge #58 → remediates reviews/CI autonomously → squash-merged.
# 🔔 notifications fire at plan approval, PR review, and on completion.
```

### Example 5: A range of issues (orchestrated, PRs open for review)

```bash
/work #2-5

# 🔔 "/work: resolved 4 issues (#2,#3,#4,#5) — confirm to start (parallel=1)"
# Mechanism: Agent tool (≤5 issues, sequential)
# After you confirm, dispatches plan(opus) → exec(sonnet) per issue, one issue at a time.
# Each issue's plan stage auto-accepts the plan; its exec stage auto-accepts the PR.
# No `auto`, so PRs are left open for review.
#
# /work summary (owner/repo) — orchestrated 4 issues
# ✓ #2 <title> — PR #37 opened  <url>
# ✓ #3 <title> — PR #38 opened  <url>
# ✓ #4 <title> — PR #39 opened  <url>
# ✓ #5 <title> — PR #40 opened  <url>
# Issues: 4 dispatched, 0 merged, 4 PR(s) open, 0 blocked.
```

### Example 6: A natural-language description, with automerge (orchestrated)

```bash
/work 'all P0 issues' auto

# Resolves the description to open issues, e.g.:
# 🔔 "/work: resolved 3 issues (#7,#11,#14) — confirm to start (parallel=1)"
# Mechanism: Agent tool (≤5 issues, sequential)
# After you confirm, fully drives each one — plan(opus) → exec(sonnet) → merge — before the next.
#
# /work summary (owner/repo) — orchestrated 3 issues
# ✓ #7  fix: token refresh — merged (auto)  PR #41 <url>
# ✓ #11 fix: retry backoff — merged (auto)  PR #42 <url>
# ✗ #14 fix: cache key — STOPPED: CI 'test' failing
# Issues: 3 dispatched, 2 merged, 0 PR(s) open, 1 blocked.
```

### Example 7: Large fan-out via Workflow, with parallelism

```bash
/work 'all P1 issues' auto parallel=2

# Resolves to e.g. 8 issues → Workflow pipeline (>5)
# 🔔 "/work: resolved 8 issues (#1,#2,...) — confirm to start (parallel=2)"
# Two issues run concurrently, each in its own worktree shared by its plan(opus) and exec(sonnet)
# stages; the next pair starts after both finish.
```

### Example 8: Upgrade the exec stage to opus

```bash
/work #1 auto parallel=1 opus

# Same flow as Example 4, but the exec stage runs on opus at effort medium
# (subagent_type: work-exec-opus) instead of sonnet. The plan stage is opus either way.
# Applies to every exec dispatch in this run, including the standalone merge stage.
# Per-invocation only — the next /work is back to sonnet.
```

## Important Notes

- **Selector forms**: `{selector}` accepts a single number (`#1`/`1`), a range (`#2-5`), a comma list (`#1,#3`), or a natural-language description (`'all P0 issues'`). Multi-issue and description selectors trigger **orchestrated mode**; a single explicit `#N` runs **inline**.
- **Model split**: every issue is planned by an **opus** subagent and executed by a **sonnet** subagent — a single agent can't switch models mid-run, so these are always two dispatches, connected by a written plan file at `.claude/plans/issue-{N}.md` (§ 0c). Applies identically in inline and orchestrated modes.
- **`opus` token**: upgrades **every** exec dispatch in that run — implementation *and* the standalone merge stage — from sonnet to **opus at effort `medium`**, by dispatching the `work-exec-opus` agent instead of `work-exec`. The plan stage and orchestrator are already opus and unaffected. It is per-invocation: nothing is written to settings, so the next `/work` is back to sonnet. Reach for it when the implementation itself is the hard part, not just the design.
- **Two modes, different gates**:
  - **Inline** (`#N` only): plan approval (`ExitPlanMode`) and PR review (before `/pr`) — two gates, unchanged from before.
  - **Orchestrated** (multi-issue / description): queue confirmation only (gate #1) — each issue's plan/exec subagents then run fully unattended, auto-accepting plan + PR.
- **`auto` is independent of orchestration**: `/work #2-5` dispatches subagents that open PRs and leave them for review; `/work #2-5 auto` also drives each to merge via `/automerge`. Works the same in both modes.
- **Automerge handoff**: with the trailing `auto` keyword, each PR is handed to `/automerge #{pr_number}` — fully autonomous (delegates to `/ci auto` + `/reviews auto`); never runs `/ci`/`/reviews` interactively or enters plan mode during merge.
- **Parallelism** (`parallel=N`, default 1): orchestrated mode runs issues strictly sequentially by default. `parallel>1` runs multiple issues concurrently, each in its own worktree shared by that issue's plan and exec stages (worktree isolation prevents working-tree clashes between issues). Sequential is strongly preferred when issues may share files or have dependencies.
- **Queue ordering**: issues run in ascending order, each driven fully (to merge when `auto`) before the next at default `parallel=1`. A per-issue blocker is recorded and the run continues to the next issue; cancelling at a gate stops the whole run.
- **No recursion**: the orchestrator dispatches each issue's plan/exec stages directly rather than delegating to another `/work` invocation, so orchestration cannot nest.
- **Remote Control**: runs identically locally or in a web/mobile Remote Control session. `PushNotification` fires at each gate and on completion/blocker so you can respond from your phone; it no-ops gracefully when no push is sent.
- **Repository & branches**: pre-resolved by `~/.claude/lib/branches.sh`, injected at the top of this skill — the shared resolver used by every command in this suite (resolved once, before the loop)
- **Base branch**: repo-aware `{integration_branch}` — from `.claude/branch-config.json` (`baseBranch`) when present, otherwise auto-detected from the GitHub default branch / `main` / `master`
- **Branch naming**: `{type}/{number}-{slug}` (e.g. `feat/42-storage-adapter`,
  `fix/17-null-deref`), where `{type}` is a [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/#summary)
  type derived from the issue's labels (step 4). A scope and a breaking marker
  (`feat(api)/9-x`, `fix!/23-x`) are **accepted** on hand-made branches but never generated.
  The legacy `feature/{number}-{slug}` is accepted forever — nothing is renamed.
- **Smart resume**: Automatically detects and checks out existing work
- **Merged PR handling**: Gracefully handles completed work with followup option
- **Issue sync**: Checkbox toggles, status-label changes, and PR/commit-link comments are applied **automatically in batches** at natural stopping points (e.g. after a commit) — no per-update confirmation prompt
- **Project board**: Do not automatically move issues across board columns - wait for user confirmation. The automatic issue sync above does **not** extend to project board column moves
- **Defensive labels**: Label changes only ever use labels that **already exist** in the repo - never create a new label silently
- **Avoid clobbering**: Always re-fetch the issue body immediately before editing it, so concurrent changes are not overwritten
- **PR priority**: When resuming PR, shows PR details but also linked issue tasks
