---
name: backlog
model: opus
effort: high
description: Drive an entire open backlog to merged PRs, dependency-ordered, one issue at a time. Enumerates every open issue, topologically sorts it, confirms once, then dispatches each issue's opus plan stage, exec stage and merge stage as autonomous subagents — the main session only orchestrates and verifies. Ledger-backed, so a run survives compaction, /clear and session restarts. A scope selector — one milestone, a label expression, or an explicit issue range — narrows a run to part of the backlog; a bare /backlog still means the whole of it, and `epic`- and `blocked`-labelled issues are excluded by default, disclosed at the gate and re-includable there. Never for exploratory use — with `auto` it merges and deletes branches across the whole backlog without asking.
argument-hint: "[#N|#A-B|milestone=\"…\"|label=…] [-label=…] [include=epic|blocked|all] [auto] [parallel=N] [opus]"
# `model: opus` + `effort: high` mirror /work, and for the same reason: this session decomposes,
# gates and triages blockers rather than doing mechanical work. Both halves of that invariant are
# required — a command's `model:` is not sticky past a turn boundary and the confirmation gate
# ends a turn, so the settings.json drift check in Step 1 stays too.
#
# Deliberately NOT `arguments: [...]`. Step 2 strips `auto`, `parallel=N`, `opus` and every scope
# token from anywhere in the string, so nothing has a fixed position; $ARGUMENTS gives Step 2 the
# raw string. A structured `arguments:` list would also have to declare the scope tokens optional
# with a defaulted meaning, which is exactly the ambiguity Step 2's "remainder must be empty" rule
# exists to remove.
#
# User-invoked only, same reasoning as /work, /commit and /reap. This creates branches, commits,
# opens PRs and (with `auto`) merges them across the WHOLE backlog — never something Claude should
# start on its own initiative. Nothing else in the suite invokes /backlog, so denying model
# invocation costs no handoff.
disable-model-invocation: true
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh), Bash(bash __CLAUDE_HOME__/lib/backlog-preflight.sh:*), Bash(bash __CLAUDE_HOME__/lib/backlog-teardown.sh:*), Bash(bash __CLAUDE_HOME__/lib/stage-processes.sh:*)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved —
fall back to the per-step instructions below):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp once per issue, not once per turn.** This is the one place
> `/backlog` departs from the suite's per-turn `🕐` convention, and it is deliberate: a 40-issue run
> spends roughly 240 orchestrator turns, where per-turn timestamping costs ~28k tokens and fires
> ~240 extra `Stop` events into the rewake hook. Instead, run `date '+%Y-%m-%d %H:%M:%S %Z'` and
> print a `🕐 …` footer on **each issue's terminal summary line** and on the final run summary.
> Never hand-write the time; always read it from `date`.

Drive every open issue in this repository to a merged PR, in dependency order, one at a time. The
main session is an **orchestrator**: it dispatches, verifies against `gh`, and records — it never
reads code, never writes an implementation, and never holds a plan file in context.

## Operating context

- **One user gate for the whole run**: queue confirmation (Step 5). After it, every stage runs
  unattended.
- **Three stages per issue**, each its own subagent dispatch: **plan** (`work-plan`, opus) →
  **exec** (`work-exec`, or `work-exec-opus` with the `opus` token) → **merge** (`{exec_agent}`
  running `/automerge`). A single agent cannot switch models mid-run, and splitting merge out keeps
  the exec stage from carrying `/automerge`'s 447 lines on top of an implementation.
- **One merge at a time, run-wide.** The merge stage runs only with `auto`, and holds a single slot
  that PRs take in queue order (§6f). A PR that fails to merge halts the run (Step 7 R6). Merges are
  what advance the base every later branch is measured against, so they are the one thing this
  command never overlaps.
- **The orchestrator will compact.** A 40-issue queue costs ~10.5k tokens per issue to orchestrate;
  the first compaction lands around position 15. This command does not try to avoid that. It
  survives it, via the ledger (see "The ledger" below) and by keeping the guards in scripts rather
  than in prose.
- **Completion is an observation, never a claim.** A stage's report, a task's status field and an
  exit code are all claims. `merged` means `gh pr view --json state` read `MERGED`.

## Step 1: Detect the repository

1. **`{owner}`, `{repo}`, `{repo_root}` and `{integration_branch}` are already resolved** in the
   context block above. Use them; do not re-run `gh repo view`. If `owner` came back empty, error
   with "No GitHub repository found. This command requires a GitHub repo with an authenticated `gh`
   CLI." and stop.
2. **Model-drift check** — `jq -r '.model // "unset"' ~/.claude/settings.json`.
   - `opus` → proceed silently.
   - `unset` → note `session default model is unset; inheriting the account default` and continue.
   - anything else → print `⚠ session default model is '{model}', not 'opus': after the queue gate
     this orchestrator falls back to it` and continue.

   Warn, never block. And never set **`opusplan`** as the session default for this suite: it
   switches to sonnet the moment `ExitPlanMode` is called.

## Step 2: Parse the flags (strict)

**You were invoked with:** $ARGUMENTS

Token stripping is order-independent:

1. **`auto`** anywhere in the string → `{automerge} = true`; otherwise `false`.
2. **`parallel=N`** → `{parallel} = N` (positive integer); otherwise `1`.
3. **`opus`** as a standalone whitespace-delimited token → `{exec_model} = opus` and
   `{exec_agent} = "work-exec-opus"`; otherwise `sonnet` / `"work-exec"`.
4. **Scope tokens**, each stripped from anywhere in the string:
   - **`milestone=<title>`** — exact milestone title, at most one. Quote a title containing spaces
     (`milestone="Phase B"`); unquoted, the second word survives into the remainder and rule 6
     correctly rejects the whole invocation. `milestone=none` selects unmilestoned issues. Resolve
     against `gh api repos/{owner}/{repo}/milestones --jq '.[].title'`: no exact match ⇒ retry
     case-insensitively; still nothing, or more than one, ⇒ error listing the repo's titles. Never
     guess. A mistyped milestone matches nothing and yields an empty queue, and an empty queue is
     indistinguishable from a finished backlog.
   - **`label=<name>[,<name>…]`** — repeatable. Commas inside one token are **OR**, separate tokens
     are **AND** — `label=area:facts,area:signals label=type:feature` is a feature issue in either
     area. Same semantics as repeating `gh issue list --label`.
   - **`-label=<name>[,<name>…]`** — repeatable; excludes. Spelled with a leading `-` rather than
     `!=` so it needs no quoting and cannot trip history expansion in any shell.
   - **`include=epic|blocked|all`** — repeatable; cancels a default exclusion (rule 7). It only ever
     cancels a **default** — it never re-adds something `-label=` or `milestone=` removed.
5. **The remainder is the issue selector**, using `/work` §0a's grammar unchanged so the two
   commands read alike: `#N`, `#A-B` (inclusive), `#1,#3,5`.
6. **Anything else is an error** — print the usage from `argument-hint` and stop. `/backlog
   paralel=3` and `/backlog milestone=PhaseB` must both fail loudly. **This is a deliberate
   divergence from `/work` §0a rule 5**, which treats an unrecognised remainder as a description and
   resolves it with `gh issue list --search`. That is safe for a gated handful of issues and unsafe
   here: a fuzzy match returns *some* issues, the gate shows a plausible-looking queue, and an
   unattended run proceeds on a scope nobody chose — the same shape as the `--limit 30` trap in
   Step 3.
7. **Default exclusions — `epic` and `blocked`** — dropped unless re-included, and **never dropped
   silently**: Step 5.5 prints them with their numbers.
   - `epic` is a tracker, not a unit of work. Its body decomposes into the issues already in the
     queue, so dispatching it yields either a PR that implements nothing or one that attempts a
     whole phase.
   - `blocked` is excluded because **this command writes it** — §6g applies it on every block and
     skip. Excluding it by default is what makes a re-run resume forward instead of re-attempting
     everything the last run proved stuck, and `include=blocked` is the deliberate "retry the
     blocked ones" invocation. It is also the label most likely to be stale, which is answered by
     disclosure at the gate, not by a different default: a stale label costs one line at a gate that
     already blocks, while the opposite default costs an unattended run over issues someone marked
     stuck.
   - **Explicitly named issues override the defaults for themselves** — `/backlog #50` runs `#50`
     even though it is an epic. An explicit `-label=` still applies; `#50 -label=epic` is a usage
     error, not a silent empty queue.
8. **Every token that is present must hold**: `milestone=` ∩ `label=` ∩ not `-label=` ∩ the issue
   selector.

A bare `/backlog` is valid and remains the primary invocation — `{automerge}=false` (so §6f is
skipped and the run ends with one open PR per issue), `{parallel}=1`,
`{exec_agent}="work-exec"`, scope `= the whole open backlog minus the default exclusions`. The scope
selector narrows **which issues are dispatched**. It never narrows **what is read**: Step 3 always
enumerates every open issue, for the reason given there.

## Step 3: Enumerate the backlog (always in full)

```bash
# `gh issue list` DEFAULTS TO --limit 30. Without the flag this silently returns the 30
# most-recently-created issues and the gate below shows a plausible-looking short backlog —
# the single most likely way this command appears to work while doing a fraction of the job.
gh issue list --repo {owner}/{repo} --state open --limit 1000 \
  --json number,title,body,milestone,labels
```

**Assert the count is below the limit.** A result exactly equal to `--limit` is truncation, not a
backlog: raise the limit, paginate, and say that you did. `gh issue list` already excludes PRs.

**Enumerate the whole backlog even when the scope is narrow — never push `milestone=` or `label=`
into this query as `--milestone` / `--label`.** Step 4.1 resolves a dependency by asking whether the
referenced `#N` is in the fetched open set, and treats an absence as "closed, therefore already
satisfied". Narrow the fetch and every open issue outside the scope starts reading as closed: live
dependencies silently become satisfied ones, in the optimistic direction this command refuses
everywhere else. So one unfiltered fetch defines `{universe}`, the truncation assertion above applies
to it, and the scope filter is jq over that JSON, producing `{scope} ⊆ {universe}`:

```bash
# {excluded_labels} = the default exclusions, minus any include=, plus every -label= name.
# {label_groups}    = one array per label= token; AND across groups, OR within a group.
# {only}            = the explicit issue numbers, or [] — when non-empty, the DEFAULT exclusions do
#                     not apply to those numbers (rule 2.7), but -label= names still do.
jq --arg ms "{milestone}" --argjson want '{label_groups}' --argjson drop '{excluded_labels}' '
  map( (.labels | map(.name)) as $l
     | select( ($ms == "" or (.milestone.title // "@none") == $ms)
           and ( $want | all( any(. as $n | $l | index($n)) ) )
           and ( ($l | any(. as $n | $drop | index($n))) | not ) ) )'
```

One `gh` call either way, and the gate can now report what was dropped — which it must.

## Step 4: Build the dependency graph and order the queue

`gh` exposes **no** dependency fields — `gh issue list --json` and `gh issue view --json` offer
neither `subIssues` nor `blockedBy` nor `parent` (verified against gh 2.83.1). So:

1. **Parse the `body` already fetched** in Step 3 for `Blocked by #N`, `Depends on #N`,
   `Requires #N`, `Needs #N` (case-insensitive). Only an `#N` that is itself in the open queue
   becomes an edge — a reference to a closed issue is already satisfied.

   **Specify the parse exactly, because an unspecified one is not one parse but two.** A
   declaration is: **anchored at the start of its line** (optionally after a `-` or `*` list
   marker), the keyword, then **exactly one `#N`**, backticks around the number tolerated. Nothing
   later on the line is read.

   That precision is load-bearing rather than fussy. Left loose, the same repo yields two different
   graphs: a *strict* reading drops a real edge whenever one line carries two references
   (`Blocked by #150 and #151` silently becomes one edge), while a *permissive* reading invents one
   from any prose sentence that happens to contain a keyword and an issue number — and two such
   sentences pointing at each other **fabricate a cycle**, which rule 4 below turns into a hard stop
   on a backlog that is perfectly well-formed. Both failures were observed on a real repo.

   So the authoring convention this parse implies is: one edge per line, inside `## Dependencies`,
   and **no other line in the body carrying both a keyword and an `#N`**. A line that does is an
   authoring error, not an edge. Detect it by parsing twice — strictly and permissively — and
   reporting any reference the two readings disagree about; that diff is the whole check, and it is
   cheap. Report those lines at the gate and let a human fix the issue text. Never silently pick one
   reading: the two disagree precisely where the backlog is ambiguous.
2. **Best-effort enrichment**, once, tolerating failure:
   `gh api repos/{owner}/{repo}/issues/{n}/sub_issues` and `.../dependencies/blocked_by`. These are
   preview endpoints. **A 404 or 410 means "this API is not available here", which is not the same
   as "this issue has no dependencies"** — say once that enrichment was unavailable, then rely on
   body parsing. Never let an unreadable source resolve to the optimistic answer.
3. **Topologically sort**, breaking ties by milestone due date then issue number:

   ```bash
   # The four-part key is required. `sort_by(.milestone.dueOn)` alone puts jq's null FIRST, so
   # unmilestoned issues lead the queue. Without .milestone.title the key COLLAPSES TO ISSUE NUMBER
   # in any repo whose milestones carry no due date — which GitHub does not require, and which is
   # the common case — so the milestone half of this key silently does nothing while the comment
   # claims it orders the run. And without .number, sort_by's stability preserves gh's DESCENDING
   # creation order within a milestone, which is backwards.
   sort_by([ (if .milestone.dueOn then 0 else 1 end),
             (.milestone.dueOn // ""),
             (.milestone.title // "~"),   # "~" (0x7E) sorts after any letter: unmilestoned last
             .number ])
   ```

   (`dueOn` is camelCase; the milestone object is `{number,title,description,dueOn}`.)

   Title order is **lexicographic**: right for `Phase A`…`Phase G`, wrong for `Sprint 9` before
   `Sprint 10`. It is a fallback, not a repair — so **if no issue in the queue has a `dueOn`, say so
   at the gate**: `⚠ no milestone in this queue has a due date — order fell back to milestone title,
   then issue number`. Setting due dates is one fix; another, where the repo labels issues by phase
   or sprint, is to rank on that label instead — `sort_by([(first(.labels[].name|select(startswith("phase:"))) // "phase:~"), .number])`
   — which encodes ordering without publishing a calendar commitment. Prefer whichever the repo
   already maintains, and **assert it is present on every issue**, so the fallback can never fire
   silently. Scoping to a single milestone makes the question moot, since within one milestone the
   key is issue number by construction.
4. **A cycle is a hard error.** Name the members and stop. Do not break it by issue number — a
   declared cycle is a statement that the issues are mis-specified, and silently picking an order
   would produce a run whose failures look like implementation problems.

Store `{queue}` and `{parents}` (issue → its parent issue numbers). A repo with no declared
dependencies degrades to plain milestone-then-number ordering, the parent gate passes trivially,
and descendant marking is a no-op.

**Excluded and out-of-scope issues are two different things, and the difference decides an edge.**

- An `#N` that is **closed** is satisfied. Unchanged.
- An `#N` that is **open but not in `{scope}`** — a different milestone, filtered out by `-label=`,
  or excluded as `blocked` — is **still a parent**. Record it in `{parents}` exactly as an in-scope
  one, so §6a's preflight checks it against `gh` (rc 8) and the issue is `skipped` with its true
  cause rather than planned against a codebase missing what `#N` was to add. Out of scope is not
  closed.
- An `#N` excluded as an **`epic` drops the edge entirely.** An epic is a container that is closed
  by hand and merges never, so keeping it as a parent would gate its children in every run forever —
  a permanent skip that reads exactly like a dependency. `Blocked by #<epic>` states membership, not
  sequencing. Say once that epic edges were dropped, and how many.

Out-of-scope parents are not nodes in the graph: they cannot form a cycle and cannot be dispatched.
They can only gate — which is why they are annotated at the gate rather than silently dropped.

## Step 5: Run start and the confirmation gate

1. **Whole-run preflight:**

   ```bash
   # rc 0 = proceed. Any other rc: read the printed reason, fix it, and re-run. Act on the exit
   # code and on nothing else — do not re-derive the verdict from a fresh git call.
   bash __CLAUDE_HOME__/lib/backlog-preflight.sh 0 --run-start \
     --integration {integration_branch} --worktrees 1
   ```

   At run start exactly one worktree should exist, whatever `{parallel}` is — none have been
   provisioned yet. (Per-issue calls pass `{expected_worktrees}`; see Step 6a.) This also installs
   the `info/exclude`
   entries the run depends on, so the ledger and plan files can never be committed into a PR.
2. **Propose raised caps** for issues with in-degree ≥ 3 or DAG depth ≥ 8 — the integration issues
   at the end of a long chain, where a 90-minute cap breach discards everything built before it.
   Suggest `exec: 10800` (3 h) for those. Editable at the gate.
3. **Offer branch protection** on `{integration_branch}` for the duration of the run, requiring only
   the fast CI contexts. One `gh api` call, reversible, and it converts a procedural guarantee into
   a platform one: a bad state then surfaces as a clean `/automerge` `BLOCKED` stop rather than a
   silent merge with CI red, since `mergeStateStatus: UNSTABLE` sits in `/automerge`'s merge
   allowlist. **Offer it; never apply it unasked** — it mutates repository settings. Do not require
   `claude-review`: requiring a slow context risks a transient `BLOCKED` with no retry, and §6e
   already gates the merge on it.
4. **Detect whether the Claude code review is active**, once:
   `gh api "repos/{owner}/{repo}/contents/.github/workflows/claude-review.yml?ref={integration_branch}" --jq .sha`.
   A 404 means the workflow is not installed, so skip §6e for the whole run. Any other failure is
   unknown, not absent: keep §6e armed rather than skipping a gate because one call did not
   answer. Probe the file, not the workflows endpoint: GitHub keeps a deleted workflow listed as
   active there.
5. **The gate.** Open with the **scope line**, then the **exclusion line**, then the queue.

   ```
   scope: milestone="Phase B" -label=type:spike  →  19 of 74 open issues
   excluded: 11 epic (#50, #51, #52, #53, #54, #122, #198–#202)
             41 blocked (#12, #13, #49, …)   — include=epic / include=blocked / include=all re-adds
   ⚠ #164 (blocked, excluded) is a parent of 7 in-scope issues (#165 #166 #167 #168 #169 #172 #174):
     they will be skipped. `include=blocked` runs it instead.
   ```

   The `⚠` line is the one that earns the default. An exclusion that is not printed is
   indistinguishable from an issue that does not exist, and an exclusion that gates other issues
   turns one stale label into a third of the run skipped — visibly here, silently otherwise. Compute
   it from `{parents}`: for every excluded issue, the in-scope issues that name it. **If every issue
   in the scope is gated by an excluded or out-of-scope parent, that is a scoping mistake, not a
   run** — say so and stop rather than opening a gate on a queue that can only skip.

   Then print every issue as `#N — title`, with its milestone, its labels, its parents, and an
   annotation where one applies — `[open PR #123]`, `[branch exists]`, `[parent #11 out of scope]`.
   Issues already in flight are **shown, not dropped**: the plan stage's resume logic handles them
   correctly, and seeing them lets the user drop some before confirming. The labels are printed for
   the same reason — a `type:spike` or a decision issue that no selector distinguishes is dropped
   here, by a human, which is what this gate is for. State `{parallel}`, `{exec_model}`,
   `{automerge}`, the caps and any overrides.

   **State the merge policy in the same breath, because it is what the user is actually
   confirming.** With `{automerge}` true: merges are serialized one PR at a time in queue order, and
   a PR that fails to merge **halts the run** (§6f). With `{automerge}` false: nothing is merged at
   all, and the run ends with **one open PR per issue**, every one of them cut from the same base —
   say that as a count, e.g. `no auto: this run will end with 19 open PRs`. Send a
   `PushNotification`. **Wait.** This is the only user gate in the run.
6. **Rotate a finished ledger, then write the header** (next section). If `_run-ledger.jsonl` exists
   and its last `t:"run"` line carries `"event":"complete"`, the previous run finished: `mv` it to
   `_run-ledger-$(date -u +%Y%m%dT%H%M%SZ).jsonl` and say that you did. Appending a second run to a
   completed one is not additive — Step 8's `group_by(.issue)|map(last)` reads terminal records
   across **both** runs, so any issue the old run merged resumes as already done in the new one.
   Rotation is what keeps that query true. The old file stays in `.claude/plans/`, which
   `info/exclude` already covers.

**Deliberate override of `/work`'s "Workflow `pipeline()` above 5 issues" rule:** use the **Agent
tool, sequentially, at any queue size**. That rule exists so one issue's exec can overlap the next
issue's plan — which `{parallel}=1` forbids outright. The Workflow path also has no `Monitor` or
`TaskStop`, and makes N×3 stages a single non-resumable unit. Given that compaction is certain,
resumability wins. Say which mechanism you are using before dispatching.

## The ledger — the run's durable state

`{repo_root}/.claude/plans/_run-ledger.jsonl`, append-only, one JSON object per line, **written by
the orchestrator only, never by a subagent.** At the moment the ledger matters most — a stalled or
killed stage — the subagent is precisely the thing that cannot write, and the orchestrator is the
only party that ran `gh` for ground truth.

That location is chosen, not incidental. `.claude/plans/` is already in `info/exclude` (the
preflight script guarantees it), `hooks/session-cleanup.sh` never touches it, and the rewake hook
reads plan files by exact path — so a sibling file there is inert, needs no new exclude entry, and
can never be swept into a PR by an exec stage's `git add .`, which any new path under `.claude/`
otherwise would be.

Header, once, after the gate:

```json
{"t":"run","ts":"…","session":"$CLAUDE_CODE_SESSION_ID","repo_root":"…","owner":"…","repo":"…",
 "integration_branch":"main","automerge":true,"parallel":1,"exec_agent":"work-exec-opus",
 "scope":{"raw":"milestone=\"Phase B\" -label=type:spike","milestone":"Phase B","labels":[],
          "exclude":["epic","blocked","type:spike"],"issues":null},
 "queue":[9,11,15],"parents":{"10":[9],"12":[11]},
 "caps":{"plan":1800,"exec":5400,"merge":7200},"cap_overrides":{"27":{"exec":10800}}}
```

**The header is the only `t:"run"` line that carries `queue`** — pauses, resumes and completions are
also `t:"run"` — so that field, not the type, is what Step 8 selects on. `scope.raw` is recorded so a
resume can restate the run it is resuming rather than re-deriving a scope from a queue.

One line per transition:

```json
{"t":"stage","issue":9,"stage":"plan","event":"dispatch","branch":"feat/9-…","plan_file":"…","epoch":1754}
{"t":"stage","issue":9,"stage":"plan","event":"armed","name":"plan-9","monitor":"<task-id>","teammate":"<agentId>"}
{"t":"stage","issue":9,"stage":"plan","event":"done","plan_mtime":1754}
{"t":"stage","issue":9,"stage":"plan","event":"teardown","monitor":"stopped","teammate":"already-gone","rc":0}
{"t":"stage","issue":9,"stage":"exec","event":"dispatch","head_before":"abc123"}
{"t":"stage","issue":9,"stage":"exec","event":"armed","name":"exec-9","monitor":"<task-id>","teammate":"<agentId>"}
{"t":"stage","issue":9,"stage":"exec","event":"done","pr":81,"head_after":"def456"}
{"t":"stage","issue":9,"stage":"exec","event":"teardown","monitor":"stopped","teammate":"stopped","rc":0}
{"t":"merge","issue":9,"pr":81,"event":"queued"}
{"t":"merge","issue":9,"pr":81,"event":"gate","rc":1,"reason":"BEHIND"}
{"t":"stage","issue":9,"stage":"merge","event":"dispatch","pr":81}
{"t":"stage","issue":9,"stage":"merge","event":"armed","name":"merge-9","teammate":"<agentId>"}
{"t":"verify","issue":9,"pr":81,"gh_state":"MERGED"}
{"t":"stage","issue":9,"stage":"merge","event":"teardown","teammate":"stopped","rc":0}
{"t":"merge","issue":9,"pr":81,"event":"released"}
{"t":"issue","issue":9,"event":"complete","result":"merged","pr":81,"url":"…"}
```

**`event` is the only transition key on a `t:"stage"` line.** Step 8 and Step 9 select on `.event`,
so a stage recorded under any other key is invisible to the resume and to the sweep. The
resume of a long /backlog run wrote `"status":"dispatched"` for its last 30 dispatches, and
none of them were swept. The `armed` line is written **after** the `Agent` call returns, because
that is when the `agentId` exists; `dispatch` is written before, and never carries an ID. Every
`armed` line must be closed by a `teardown` line, and Step 9 treats an unclosed one as a leak.

**The `t:"merge"` lines are the merge slot**, and they exist because the slot is run state that must
survive a compaction. `queued` when the PR enters the queue, `gate` with the `merge-gate.sh` exit
code, `dispatch` when it takes the slot, `released` when `gh` confirmed the merge and the slot is
free again. At most one PR sits between `dispatch` and `released` in a healthy ledger; two means the
slot was double-taken and the run should stop. Step 8 reconstructs the slot from exactly these lines.
A halted run also appends `{"t":"run","ts":"…","event":"halted","issue":9,"pr":81,"reason":"merge gate rc 5 — CONFLICTING"}`.

Terminal `t:"issue"` results are `merged`, `blocked` or `skipped`. Also append a
`{"t":"stash","issue":N,"ref":"stash@{0}"}` line whenever preflight stashed orphaned work.

`epoch`, `monitor` and `teammate` exist **purely for compaction survival**: `epoch` is the freshness
floor for the plan-file gate, and the task IDs are what `TaskStop` needs once the context that armed
them is gone. Without them a post-compaction orchestrator leaves a 60-second poller running per
issue for the rest of the session, each emitting into the context that just compacted. That is a
spiral, not a leak.

`ts` comes from `date -u +%FT%TZ` — never hand-written.

**A second durable channel, free.** On every block or skip, apply the repo's existing `blocked`
label (never create one) and comment the cause on the issue. That survives the ledger being lost and
is readable by a human.

## Step 6: The per-issue loop

**The orchestrator computes these three values before dispatching anything for issue `#{n}`, and
passes them to every stage. No stage may derive any of them itself.**

- **`{branch}` = `{type}/{n}-{slug}`**, where `{slug}` is 2–4 meaningful words from the issue
  title, kebab-cased, and `{type}` is the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/#summary)
  type implied by the issue's labels — **ordered, first match wins**: `bug`/`defect`/`regression`
  → `fix`; `documentation`/`docs` → `docs`; `performance`/`perf` → `perf`;
  `refactor`/`refactoring` → `refactor`; `test`/`tests`/`testing` → `test`; `ci`/`build` → `ci`;
  `chore`/`dependencies`/`deps` → `chore`; everything else, including no labels at all → `feat`.
  This is the same ordered map `/work` step 4 applies, and the order is load-bearing precisely
  because it is applied in two places: an issue labelled both `bug` and `documentation` must not
  get a different branch depending on which command ran.

  **Never generate a scope or a breaking marker** — `feat(api)/…` is accepted on a hand-made branch,
  but parentheses are zsh glob characters and generated names stay clear of them.

  **The orchestrator picks this name**, writes it into the sentinel, uses it in
  the Monitor probes, and gives it verbatim to the plan stage — which must check out *that exact
  string* rather than inventing its own. If the two ever disagree, every branch-keyed lookup
  afterwards — the Monitor's PR probe, preflight guard 6, the rewake hook's `refs/heads/{branch}`
  check, teardown's branch deletion — silently targets a ref that does not exist and reports
  "nothing to see" instead of failing. That is the blind-monitor shape: it reads exactly like a
  healthy run.
- **`{plan_file}` = `{repo_root}/.claude/plans/issue-{n}.md`**, absolute. Inside a worktree
  `git rev-parse --show-toplevel` returns the *worktree* root, and `hooks/automerge-rewake.sh`
  reads this exact path for its freshness check.
- **`{tree}`** = `{repo_root}` at `{parallel}=1`, else
  `{repo_root}/.claude-work/$CLAUDE_CODE_SESSION_ID/issue-{n}`.

Two more per-issue values come from the ledger, not from memory:
`{plan_cap}` and `{exec_cap}` are `caps.plan` / `caps.exec` from the header, **overridden by
`cap_overrides["{n}"]` when present** (Step 5.2 builds those). The ledger stores seconds; state them
to the subagent in minutes or hours, e.g. `Budget: 90 minutes`.
`{comma_separated_parents}` is `{parents}["{n}"]` from Step 4, joined with commas — omit the
`--parents` flag entirely when an issue has none.

### 6a. Preflight, sweep, snapshot, sentinel

```bash
bash __CLAUDE_HOME__/lib/backlog-preflight.sh {n} \
  --parents {comma_separated_parents} --integration "{integration_branch}" \
  --repo {owner}/{repo} --stash --tree "{tree}" --worktrees {expected_worktrees}
```

`{expected_worktrees}` is `1 + (number of issues currently in flight in their own worktrees)` — so
`1` at `{parallel}=1`, and `1 + k` when `k` issues are live at `{parallel}>1`. Guard 9 runs on every
invocation, not just at run start, so omitting this flag makes every per-issue preflight after the
first fail with rc 9 once a second worktree legitimately exists.

| rc | Meaning | Action |
|---|---|---|
| 0 | pass | proceed |
| 2 | HEAD not on the base branch | resolve by hand — **do not** checkout while dirty |
| 3 | dirty tree, stash failed | resolve by hand. Never `checkout -f` / `reset --hard` |
| 4 | a stage committed straight to the base branch | **stop the whole run**; do not bury it |
| 5 | fast-forward failed | resolve the diverged base branch |
| 6 | stale branch for issue `{n}` under **any** prefix | check `gh pr list --head`; delete only what reads `MERGED` |
| 7 | another session's sentinel | another run is live on this repo — stop |
| 8 | a parent is not merged | record `skipped`, apply §7 R1, continue to the next issue |
| 9 | worktree count wrong | release the leaked worktree (or pass the right `--worktrees`) |
| 11 | parent state unreadable | **unknown, not satisfied** — stop and fix `gh` access |
| 12 | `info/exclude` could not be installed | **stop the whole run** — the ledger and plan files are committable into a PR |
| 64 | usage error in the invocation above | fix the flags; never proceed as though it passed |

If it stashed anything, record the stash ref in the ledger — that is orphaned work and must be
resolved by hand later, never dropped.

Then the **ledger sweep**: `TaskStop` any monitor or teammate whose task ID appears in the ledger
for an issue already terminal. Run this at *every* preflight, not only at the end — after
a compaction the only record of those IDs is the ledger, and an orphaned 60-second poller emits into
the very context that just compacted.

Then take the **process snapshot** the teardown sweep compares against:

```bash
bash __CLAUDE_HOME__/lib/stage-processes.sh snapshot {n}
```

`backlog-teardown.sh` step 3 sweeps the processes a stage orphaned, and it identifies them by two
conditions together: absent from this snapshot, and reparented to PID 1. Without the snapshot the
sweep exits 5 and reports **blind**, because it cannot tell the stage's processes from the ones you
were already running. Blind is not clean, and teardown returns 3 rather than reporting success.

Then write the sentinel — **once per stage, never hand-edited in place**:

```bash
mkdir -p "{repo_root}/.claude"
cat > "{repo_root}/.claude/work-active-{n}" <<EOF
{"issue": {n}, "stage": "plan", "branch": "{branch}", "owner": "{owner}", "repo": "{repo}",
 "session": "$CLAUDE_CODE_SESSION_ID"}
EOF
```

Use the bound `{repo_root}`, **not** `$(git rev-parse --show-toplevel)`. The `session` field is what
makes cleanup safe and is **immutable**; only the orchestrator may refresh `"stage"`, and only when
handing an issue from exec to merge. `$CLAUDE_CODE_SESSION_ID` is already exported into every Bash
call.

### 6b. Arm the Monitor before yielding

**Dispatch-then-idle is forbidden.** The completion notification only fires when a subagent exits
*cleanly*, which is exactly the case that is not stalling. Ending a turn is not idling — yielding
*unwatched* is.

Check the ledger's recorded task IDs and `~/.claude/run/bg-tasks-$CLAUDE_CODE_SESSION_ID.json`
(written by `hooks/bg-snapshot.sh` from the `Stop` payload's `background_tasks`) first, and read
either as **evidence, not proof**. A monitor shown for this issue is reused. Nothing shown means
*either* none was armed *or* the view could not answer — `seen: absent` and a missing file are both
unknown — and the correct action is the same either way: arm one, and `TaskStop` any duplicate that
later surfaces. A second poller wastes ticks; an unwatched stage is a multi-hour stall. Teammates
invert this: **never** spawn a second for one stage, even when nothing is listed.

**Not `TaskList`.** It is the `TaskCreate` to-do board — it does not track monitors, teammates or
background shells, so it reports "nothing" unconditionally and has never once caught a duplicate.

Validate the probes at arm time. A monitor that cannot see its subject must report **blind**, never
**healthy** — a monitor pointed at a valid-but-wrong tree emits nothing for the entire stage and
reads as a perfectly healthy run.

```bash
# {tree} is the hard gate — a wrong tree is what makes a monitor silently blind.
git -C "{tree}" rev-parse --git-dir >/dev/null || exit 1

# Then the stage-appropriate signal. An exec or merge stage commits to {branch}, so the ref must
# resolve. A PLAN stage does not: it CREATES the branch, so at arm time that ref legitimately does
# not exist yet, and asserting it would block every fresh issue. What makes a plan stage
# observable is the plan file, so check its directory.
case "{stage}" in
  exec|merge) git -C "{tree}" rev-parse --verify "{branch}" >/dev/null || exit 1 ;;
  plan)       plan_dir=$(dirname "{plan_file}"); [ -d "$plan_dir" ] || exit 1 ;;
esac
```

A failure here is a blocker — never arm a watcher that cannot see anything. But a missing branch
during a plan stage is not a failure; it is the expected starting state.

Then arm a `Monitor` with **`persistent: true`** — this is required, not stylistic. `Monitor`'s own
`timeout_ms` caps at 60 minutes, which is shorter than the exec budget (90 minutes, up to 3 h with an
override) and shorter than the merge budget (2 h); a non-persistent monitor would therefore expire
partway through a normal stage and leave the rest of it unwatched, which is the dispatch-then-idle
failure wearing a monitor's clothes. Give it the description `issue #{n} {stage}: progress + stalls`,
carrying
`claude-work-monitor:${CLAUDE_CODE_SESSION_ID}:#{n}` in argv so `SessionEnd` cleanup can find it.
Keep its task ID for the `armed` line (§6c / §6d), which is written once the teammate's `agentId` is
also known — that pair is what `TaskStop` needs at teardown and after a compaction.

```bash
# Poll every 60s; emit ONLY on change. Every emitted line is a message in the orchestrator's
# context, and "still working" is not news. It is also self-defeating: Monitor auto-stops a source
# that emits too much, so a chatty heartbeat silently disarms the stall guard it was meant to be.
# Silence here means healthy — which is exactly why the probes above must be validated.
# Three signals: a plan stage produces no commit and no PR for its entire legitimate 30-minute
# life, so commits+PR alone would false-STALL every healthy plan stage at the 10-minute mark.
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
    # Emit and KEEP POLLING — never exit. The orchestrator owns teardown decisions, and this
    # monitor must survive the whole stage. Resetting re-emits STALL every 10 stalled minutes.
    echo "STALL — #{n} {stage}: no commit, PR state change, or plan-file write in 10m"
    stalls=0
  fi
  sleep 60
done
```

When an event lands, print it as a one-line heartbeat. Events are rare by design, so each is worth
showing.

**Confirm the watcher is still alive whenever you touch the issue** — at each cap check and on every
rewake. Silence means healthy *only while something is watching*; a monitor that died is
indistinguishable from a stage that is quietly working, and the two have opposite correct responses.
If the monitor is gone from the snapshot (`~/.claude/run/bg-tasks-$CLAUDE_CODE_SESSION_ID.json`,
`seen: listed` and its ID absent) before its stage ended, re-arm it (re-validating the probes) and
say that you did. An `absent` snapshot answers nothing — re-arm rather than assume.

### 6c. Plan stage

Record `epoch` (`date +%s`) in the ledger **before** dispatching. Then `Agent` with
`subagent_type: "work-plan"`, `name: "plan-{n}"` and `run_in_background: true`. The call returns
at once with an `agentId`; that string is the teammate's task ID. Append the `armed` line now,
carrying the Monitor's task ID from §6b and this `agentId`. A dispatch with no `armed` line is one
§6g cannot tear down by ID and Step 9 cannot find.

Do **not** pass the Agent tool's `mode:` — deprecated and silently ignored, and a subagent otherwise
inherits the session's permission mode, which is how an "autonomous" stage ends up blocked forever
on a prompt nobody will answer. Do **not** pass `model:` or `effort:` either: the agent file carries
model, effort and `permissionMode: bypassPermissions`, and setting them per-dispatch splits the
configuration across two sources that can silently disagree. Caveat: a parent session in `auto`
permission mode *suppresses* the agent-defined `permissionMode` — run `/backlog` from `default`,
`acceptEdits` or `bypassPermissions`.

The dispatch prompt must be self-contained. `work-plan` never reads any skill body, so a reference
to "steps 1–7 of the inline loop" points at something it cannot see:

> You are a fully autonomous planning agent. Your only job is to plan issue #{n}.
>
> Working tree: `{tree}`. Integration branch: `{integration_branch}`.
>
> 1. `gh issue view {n}` — read the body and its `- [ ]` checklist.
> 2. Check out `{integration_branch}`, `git fetch origin && git merge --ff-only`, then
>    `git checkout -b "{branch}"`. **Use that branch name exactly as given — do not derive your own.**
>    The orchestrator has already written it into this issue's sentinel and into the watcher that is
>    monitoring you; a different name makes both of them silently blind.
> 3. Mark the issue in progress using an **existing** label only — never create one. If the repo
>    has no such label this step correctly does nothing.
> 4. Explore the codebase. Validate every checklist item against the current code — items are often
>    already done or no longer apply. Identify the files to create / modify / delete. Design the
>    ordered approach with its edge cases and risks. Specify how it will be verified.
> 5. Write the plan to `{plan_file}` with exactly these sections: **Context** (issue number, title,
>    problem/goal) · **Task checklist** (the issue's items with validated state) · **Files to
>    create / modify / delete** · **Implementation approach** · **Verification** (tests to add or
>    run, build/typecheck commands, manual checks) · **Definition of done** (the numbered criteria
>    that fix scope, the enumerated edge cases, and the command that proves each one — including
>    that `docs/` contracts, the feature-matrix row and the test-plan row are updated in the same
>    commits as the code).
>
> Establish that last section **first**, before exploring — load the `feature-closure` skill and
> follow its Part B §B1. The contract comes from the issue body; if the issue is thin, upgrade it
> in place via `gh issue edit` to the Part A template and say so in your one-line return.
>
> **Do not enter plan mode, and do not call `ExitPlanMode`.** No dispatcher is waiting on a plan
> approval, and you would block on it forever. Plan and write; approval is not yours to seek.
>
> Budget: {plan_cap}. Report a blocker rather than wait past it.
>
> Return the plan file's absolute path and a one-line summary. Nothing else.

**Then verify the file was written**, before dispatching exec:

```bash
stat -f %m "{plan_file}" 2>/dev/null || stat -c %Y "{plan_file}" 2>/dev/null
```

It must exist **and** be newer than the recorded `epoch`. Existence alone is not enough — plan files
are never deleted, so a stale one from an aborted run would read as success and the exec stage would
implement the wrong plan. Absent or older ⇒ blocker `plan stage returned without writing the plan`.

**Then check it carries a done contract.** Freshness proves the stage wrote *a* file; this proves
it wrote the one thing the exec stage's scope depends on:

```bash
awk '/^## Definition of done/{f=1;next} f&&/^## /{exit} f&&NF{print;exit}' "{plan_file}"
```

Empty output ⇒ blocker `plan stage returned without a done contract`. Without this check the
contract is only text in a dispatch prompt and nothing observes whether the stage honored it — and
an unattended run across the whole backlog is exactly where an unobserved contract goes unnoticed
for the longest.

### 6d. Exec stage

Record `head_before` (`git -C "{tree}" rev-parse "{branch}"`) in the ledger, then dispatch `Agent`
with `subagent_type: {exec_agent}`, `name: "exec-{n}"` and `run_in_background: true` — only if the
plan stage passed its gate — and append the `armed` line with the returned `agentId`, exactly as
in §6c.

> You are a fully autonomous execution agent. Your only job is to execute the approved plan for
> issue #{n}.
>
> Working tree: `{tree}`. Branch: `{branch}`.
>
> - **Before your first commit, assert `git symbolic-ref --short HEAD` reads `"{branch}"`.** If it
>   reads `{integration_branch}`, stop and report a blocker — do not commit.
> - **Every process you start must end before you return.** Do not use `&`, `nohup`, or `disown`.
>   Your standing rules permit detaching long commands; two things here override that. At
>   `{parallel}=1` this tree is shared with every other issue in the queue, and a detached process
>   outlives teardown and keeps writing into the tree the next issue is editing. Separately, any
>   process left behind keeps burning CPU for the rest of the session. Use foreground calls with
>   `timeout: 600000`, or report a blocker. If a background process is genuinely unavoidable,
>   capture its PID from `$!` on the same line that starts it, and end it by that PID.
> - **Never build that cleanup on `jobs -p`.** Under a non-interactive `zsh -c` it returns nothing,
>   so `kill $(jobs -p)` ends nothing and the shell still prints whatever success message follows
>   it. One stage shipped exactly that and left twenty busy loops running for 3h26m at 601.8% CPU,
>   with the load average at 195.63. Teardown now sweeps for orphans and will report yours.
>
> Read the plan at `{plan_file}` and implement it. Commit at natural stopping points per `/commit`
> conventions, referencing `#{n}`. Keep the issue in sync — checkbox toggles (match on task text,
> not line number, and re-fetch the body first), existing labels only, one concise comment per
> stopping point.
>
> Run the plan's Verification section **and its Definition of done**, and make both pass, **before**
> opening the PR. Run the full suite, not only the tests you wrote — "nothing unrelated broke" is a
> criterion and it is the one most often assumed rather than checked.
>
> **The plan's `## Definition of done` is the whole of scope.** Load the `feature-closure` skill
> and follow its Part B. Anything else you notice — an unrelated bug in a file you had to touch, a
> tempting refactor, a missing test nearby — is a **finding**: append it to
> `docs/parked-findings.md` with file and line, and do not act on it. The one exception is
> something that blocks a criterion from being satisfiable at all; take that on and name it in your
> return line. Update `docs/` contracts, the feature-matrix row and the test-plan row **in the same
> commits as the code** — the branch merges and its worktree is released, so there is no later.
> Report the parked count in your return line as a count, not a list.
>
> Do NOT pause at any gate. Invoke `/pr` via the Skill tool to push and open the PR, then **stop and
> return the PR number**. Do **not** invoke `/automerge` — the orchestrator runs the merge as its
> own stage.
>
> Budget: {exec_cap}. Report a blocker rather than wait past it.
>
> Report back concisely: PR number, status, blocker reason, and `procs=N` — how many background
> processes you started and ended. `procs=0` is the expected answer. One line, no narrative.

**Then compare `head_after` against `head_before`.** The synchronous result tells you the stage
*returned*; it does not tell you it *did anything*. An unchanged SHA with a clean
`git -C "{tree}" status --porcelain` means the stage produced nothing, whatever it reported — record
the blocker `exec stage returned without committing` rather than carrying an empty branch to a PR.

### 6e. Claude code review gate

Skip entirely if Step 5.4 found no `claude-review.yml`. Otherwise, before dispatching the merge,
read the newest review run for the PR's head commit:

```bash
head_sha=$(gh pr view {pr_number} --repo {owner}/{repo} --json headRefOid -q .headRefOid)
gh api "repos/{owner}/{repo}/actions/runs?head_sha=$head_sha&per_page=50" \
  --jq '[(.workflow_runs // [])[]
         | select(.path == ".github/workflows/claude-review.yml")]
        | sort_by(.run_number) | last | .status // "none"'
```

Proceed when this reads `completed`, or when 15 minutes have passed since the PR opened. **The
review posts inline comments as `claude[bot]`, and its check rows reach `statusCheckRollup` only
once the run exists.** With fast CI, `mergeStateStatus` reads `CLEAN` in the window between the
push and the run appearing, and on its first cycle `/automerge`'s review poll has no prior comment
to compare against, so without this gate the run races the review once per PR.

### 6f. Merge stage — the run's single merge slot

**Skipped entirely when `{automerge}` is false.** Record the PR as open, append the terminal ledger
line with `result: "pr-open"`, tear down (§6g step 2), and continue. Nothing merges in a run without
`auto`, which the Step 5 gate disclosed as a count of the open PRs the run will leave behind.

When `{automerge}` is true, **one merge is in flight run-wide, and PRs take the slot in `{queue}`
order.** An issue whose exec stage finished while the slot is busy is `merge-queued`: release its
worktree, `TaskStop` its Monitor, keep its sentinel, and append `{"t":"merge","event":"queued"}`.
Nothing is working on a queued issue, so no cap and no stall rule applies to it (§6h) — a queued PR
torn down for "no progress" is a healthy PR killed for waiting its turn. At `{parallel}=1` the slot
is free by construction; at `{parallel}>1` it is the only thing keeping two `/automerge` runs off
the same base.

**Gate before taking the slot.** The previous merge moved the base, so this asks whether the PR
still applies to it:

```bash
bash __CLAUDE_HOME__/lib/merge-gate.sh {pr_number} --repo {owner}/{repo}
```

Act on the exit code and on nothing else. Append it as `{"t":"merge","event":"gate","rc":N}`.

| rc | Meaning | Action |
|---|---|---|
| `0` | ready (`CLEAN`, `HAS_HOOKS`, `UNSTABLE`, `BLOCKED`) | Take the slot and dispatch |
| `1` | `BEHIND` | Take the slot and dispatch. `/automerge` Step 3 exit 4 runs `gh pr update-branch` and re-waits CI. This is the normal reading for every PR after the first |
| `2` | unknown | **Halt** (R6). An unreadable state is not a merge |
| `3` | already `MERGED`/`CLOSED` | Free the slot, record it, move on. This is what makes a resumed run idempotent |
| `5` | `DIRTY`/`CONFLICTING` | **Halt** (R6). Record the conflict as this issue's blocker |
| `6` | `DRAFT` | **Halt** (R6) |

The gate asks whether the PR still applies to the base, **not** whether it is green. `BLOCKED` and
`UNSTABLE` are rc 0 because remediating CI and reviews is `/automerge`'s own cycle.

On rc `0` or `1`: refresh the sentinel's `"stage"` to `exec` (keeping `session` untouched) so the 2 h
cap and the rewake guard keep covering the merge, then dispatch `Agent` with
`subagent_type: {exec_agent}`, `name: "merge-{n}"`, `run_in_background: true` and the prompt
`/automerge #{pr_number}`, and append the `armed` line with the returned `agentId`.

**The slot is freed only by §6g.** `MERGED` frees it for the next PR in queue order; anything else
halts the run (R6). Append `{"t":"merge","event":"released"}` at that moment, never when the merge
stage merely returns.

**Merge is its own stage even at `{parallel}=1`.** The exec subagent would otherwise be holding the
plan file, the implementation, `/pr`, `/automerge`, `/ci` and `/reviews` at once — and can compact
mid-merge, which is the provenance of the "returned without merging" failure. A separate dispatch
halves the exec context, gives the merge a fresh window, and makes it independently retryable from
the ledger. At `{parallel}>1` there is an additional reason: `/automerge` merges with
`--delete-branch`, so a worktree still holding the branch ends up pinned to a deleted one — release
the worktree (teardown) *before* dispatching merge.

### 6g. Verify against `gh`, then tear down

```bash
# Guard BOTH fields. Without `// ""` a null one aborts jq, the output is empty, and the table
# below records "unverified" for a PR that actually merged — turning this check into the very
# failure it exists to prevent.
gh pr view {pr_number} --repo {owner}/{repo} --json state,mergedAt \
  -q '(.state // "") + " " + (.mergedAt // "")'
```

| Observed | Action |
|---|---|
| `MERGED` | Record merged. The **only** state that may print `✓ merged` |
| `OPEN`, stage reported a genuine stop condition (conflict, `BLOCKED`, CI failing) | Record that blocker |
| `OPEN`, stage reported success or nothing actionable | Re-dispatch the merge stage **once**, then re-check. Still `OPEN` ⇒ blocker `merge stage returned without merging` |
| `CLOSED` | Record closed-without-merge. Do not retry |
| empty / command failed | `merge unverified — could not reach GitHub`. A failed lookup is not a merge |

Before a retry, `rm -f` any `automerge-active-{pr_number}` sentinel the stalled attempt left behind. Retry
once — a second failure is a blocker, not a third attempt.

**A blocker here halts the run (R6).** `MERGED` frees the merge slot and the loop continues to the
next issue; every other terminal reading stops further dispatch, because each later branch was cut
from a base that this PR was supposed to advance. Exec stages already in flight finish and open
their PRs, then tear down. Append the `t:"run"` `"event":"halted"` line, and leave every
undispatched issue in the ledger with its reason (R5) so the summary and any resume see the queue
the header declared.

Then, **on every exit path — success, blocker, cap breach, error, abandonment**:

1. `TaskStop` the Monitor, then the teammate, by the IDs on the stage's `armed` line. **Do this on
   a clean return too.** A subagent that has returned its result is still registered with the
   harness: `ListAgents` keeps showing it as `completed`, and the harness counts it among the
   background agents it stops at `/clear`. The 20-issue /backlog run left 41 of them that way, one
   plan and one exec per issue, because the clean-return path skipped this step. Record each reply:

   | `TaskStop` reply | Record as | Then |
   |---|---|---|
   | success | `stopped` | continue |
   | `No task found with ID: …` | `already-gone` | continue; the harness had released it |
   | anything else | `failed` | the stage is **not** torn down; name it as a blocker |

   A stage with no `armed` line has nothing to stop by ID. `TaskStop` by name instead (`plan-{n}`,
   `exec-{n}`, `merge-{n}`), record the same outcome, and say in the summary that the ID was missing.
2. ```bash
   bash __CLAUDE_HOME__/lib/backlog-teardown.sh {n} --pr {pr_number} \
     --root {repo_root} --integration {integration_branch} --branch "{branch}" \
     [--merged]        # ONLY after gh read MERGED above
     [--worktree "{tree}"]   # only at {parallel}>1
   ```

   **Always pass `--branch`.** That block runs `git branch -D`, which is irreversible, and you
   already own the exact name. Without the flag teardown falls back to scanning for branches
   whose name merely *looks like* it belongs to issue `{n}` — a guess, on a delete path.
   rc 3 means something was deliberately left in place: a branch or worktree holding unmerged
   work, an orphaned process outside the stage's tree, or a process sweep that could not observe.
   Name it in the final summary and resolve it by hand. A sweep that reports **BLIND** means no
   snapshot was taken in §6a, so orphaned processes cannot be ruled out — record that as the
   blocker rather than reporting the stage torn down.
3. Append the `teardown` line — `{"t":"stage","issue":{n},"stage":"…","event":"teardown","monitor":"…","teammate":"…","rc":N}`,
   with the two outcomes from step 1 and the script's exit code from step 2 — then the terminal
   ledger line.
4. If blocked or skipped, apply the `blocked` label (only if one already exists) and comment the
   cause on the issue.

**Recording a blocker is not a substitute for teardown.** It is the opposite: a blocked issue's
monitor and teammate are precisely the ones still running. Never move to the next issue while the
previous one's monitor is still polling.

### 6h. Caps

| Signal | Threshold | Action |
|---|---|---|
| No commit **and** no PR state change **and** no plan-file write | 10 min (`stalls=10`) | `SendMessage` the **existing** teammate to re-poke it. Do not spawn a second; its `agentId` is unchanged, so the `armed` line still names it |
| Still no progress after a re-poke | 2 re-pokes (~30 min) | Teardown, record `blocked` |
| Plan-stage wall clock | 30 min | Teardown, `plan stage exceeded 30m` |
| Exec-stage wall clock (through `/pr`) | 90 min, or this issue's override | Teardown, `exec stage exceeded {cap}` |
| Merge stage | 2 h | Teardown, `merge exceeded 2h` |
| An issue sitting in `merge-queued` | none — no cap, no stall rule | Its Monitor is stopped and nothing is working on it, so it cannot stall. The caps resume when it takes the merge slot |
| Rewake hook's no-progress notice | 30 min plan / 45 min exec | **Verify first** — `git -C "{tree}" status --porcelain`. Uncommitted edits are invisible to the hook. Tear down only if genuinely stuck |
| Rewake hook's "looks unwatched" nudge | never while a Monitor or teammate for that issue is live | Re-arm what is missing, re-check ground truth, answer briefly. A nudge is a prompt to check, not a verdict |

The 2 h merge allowance exists because `/automerge`'s own bounded waits — up to 5 cycles, each with
a 30-minute CI cap and a 15-minute review cap — can legitimately sum past 90 minutes. Note that
`hooks/automerge-rewake.sh` uses a 45-minute plan cap against this orchestrator's 30, so the hook's
self-heal never fires first: **hook silence is not a second opinion.**

Exceeding a cap is a **blocker**, never a reason to keep waiting.

## Step 7: Blocker policy — dependency-aware

`/work` asserts that issues are independent units. For a dependency-ordered queue that is false, and
it is deliberately not carried forward: if a root blocks, its children build against a codebase
missing what the root was to add, and dispatching them burns full plan+exec cycles to produce
blockers whose stated causes are misleading.

- **R1 — pre-dispatch parent gate.** Preflight rc 8. Every parent must read merged in `gh`. Not "PR
  open and green": at `{parallel}=1` every branch is cut from `{integration_branch}`, so an unmerged
  parent is invisible to its children. Any parent unmerged ⇒ do not dispatch; record `skipped`,
  label, continue.
- **R2 — block-time descendant marking.** On recording `#N` blocked, mark its **full transitive
  descendant set** `skipped` in one pass, with the reason. Fan-out is usually skewed — a few roots
  gate most of the queue.
- **R3 — retry once, roots only.** A high-fan-out root's first blocker earns one clean retry:
  preflight the tree, delete the stale branch, re-dispatch the plan stage from scratch, re-verify.
  Never retry a leaf.
- **R4 — never stop the run for a plan or exec blocker.** An issue that never reached a PR leaves
  nothing open against the base, so the queue continues past it. A cancellation at the Step 5 gate
  and a merge failure (R6) are the two things that stop everything, and both mean running teardown
  for every in-flight issue first, not merely ceasing to dispatch.
- **R5 — do not silently compact the queue.** Skipped entries stay in the ledger with their reason,
  so the summary and any resume see the queue the header declared.
- **R6 — halt on a merge failure** (`{automerge}` only). A `merge-gate.sh` rc `2`, `5` or `6`, or any
  §6g reading other than `MERGED`, stops further dispatch. This is the one place R4 does not apply,
  and the asymmetry is the point: issues are independent units right up until one of them merges,
  and after that every unmerged branch in the queue is measured against a base that moved. Let
  in-flight exec stages finish and open their PRs, tear down every in-flight issue, append the
  `"event":"halted"` ledger line, and go to Step 9. Without `auto` nothing merges, so R6 never
  fires.

## Step 8: Resume (after `/clear`, a crash, or a new session)

If `{repo_root}/.claude/plans/_run-ledger.jsonl` exists, offer to resume instead of re-enumerating:

```bash
L={repo_root}/.claude/plans/_run-ledger.jsonl
# The HEADER is the only t:"run" line carrying `queue`. Selecting on .t alone and taking the last
# line returns whichever run-level note was written most recently — a pause, a resume, or a
# completion — none of which has a queue, and the resume then silently has nothing to resume.
jq -c 'select(.t=="run" and has("queue"))' "$L" | tail -1
# And a completed run is not a resumable one:
jq -c 'select(.t=="run")' "$L" | tail -1 | jq -r '.event // "header"'
jq -c 'select(.t=="issue")' "$L" | jq -s 'group_by(.issue)|map(last)'
# Watchers still armed — an `armed` line with no `teardown` — are stopped before anything resumes:
jq -c 'select(.t=="stage" and (.event=="armed" or .event=="teardown"))' "$L" | jq -sc 'group_by([.issue,.stage])|map(select(last.event=="armed")|last)'
# A stage line keyed "status" is malformed: nothing above can see it.
jq -c 'select(.t=="stage" and has("status"))' "$L" | head -3
# The merge slot: any PR whose last t:"merge" line is `dispatch` or `queued` still owns or awaits it.
jq -c 'select(.t=="merge")' "$L" | jq -s 'group_by(.pr)|map(last)|map(select(.event!="released"))'
ls {repo_root}/.claude/work-active-* {repo_root}/.claude/automerge-active-* 2>/dev/null
git symbolic-ref --short HEAD; git status --porcelain; git stash list
```

**Every `t:"stage"` line is keyed `event`.** If the last probe prints anything, the ledger was
written by a run that did not follow the schema. Say so, and treat those stages as unswept: their
IDs were never recorded, so `TaskStop` them by name (`plan-{n}`, `exec-{n}`, `merge-{n}`) and
report the outcome. IDs from the `armed` probe are only meaningful inside the session that armed
them; after `/clear` or a new session the harness has already stopped them, and a `No task found`
reply is the expected one.

**If the last `t:"run"` line reads `halted`, the run stopped on a merge failure (R6).** Resuming is
legitimate, and it starts at that issue rather than past it — say which issue and PR halted it, and
what the recorded reason was, so the user can fix the PR first. Do not skip forward to the next
issue: the whole point of the halt was that the base did not advance.

**If that second probe reads `complete`, do not offer to resume.** The ledger describes a finished
run; say so, rotate it (Step 5.6), and enumerate afresh. The file existing means *a* run happened
here, never that one is unfinished — and a completed run whose last line is minutes old would
otherwise both offer a phantom resume and, under the rule below, refuse the new run as a concurrent
one.

Take the first queue entry with no terminal record — then **reconcile against ground truth before
assuming anything.** A crash between the exec `done` line and the `verify` line hides a completed
merge:

```bash
gh pr list --search "#{n} in:body" --state all --json number,state,headRefName
```

A `MERGED` PR the ledger left open means the ledger lost its last write: append it and move on. The
reverse — the ledger says merged but no `MERGED` PR exists — is the dangerous direction: treat it as
unverified and re-check, never as done.

**Rebuild the merge slot from the probe above, never from memory.** A PR left at `dispatch` owned the
slot when the session died, and the merge may well have completed after the last write; a PR left at
`queued` never took it. Re-run `merge-gate.sh` on each in `{queue}` order — rc `3` is exactly the PR
that merged while the session was gone, and it is why the gate reports `MERGED` as a skip rather than
an error. Then drain the queue normally. The slot is free only once every `t:"merge"` line reads
`released`.

**One run per repo at a time.** If the ledger header carries a foreign `session` and its last line
is under 2 hours old, refuse and print the owning session. A last line of
`{"t":"run","event":"complete",…}` releases that lock regardless of its age. Two concurrent runs enumerate the same
issues and collide on nearly every one: they overwrite each other's `work-active-{n}` `session`
field — which disarms *both* rewake guards and makes `session-cleanup.sh` refuse to delete either —
overwrite each other's plan files in a way that passes the freshness gate, and collide hard on
`git worktree add`.

## Step 9: Final sweep and summary

Sweep first, then report:

- **The ledger first.** Every `armed` line with no `teardown` line for the same issue and stage
  names a Monitor or teammate a stage left running:

  ```bash
  L={repo_root}/.claude/plans/_run-ledger.jsonl
  jq -c 'select(.t=="stage" and (.event=="armed" or .event=="teardown"))' "$L" \
    | jq -sc 'group_by([.issue,.stage]) | map(select(last.event=="armed") | last)
              | .[] | {issue,stage,name,monitor,teammate}'
  ```

  `TaskStop` each `monitor` and `teammate` it lists, append the missing `teardown` line with the
  outcomes, and report the count as **leaked by a stage** — a teardown path was skipped, and that
  goes in the summary rather than being quietly repaired. A stage line keyed `status` instead of
  `event` is invisible to this query; Step 8 names such a ledger as malformed.
- **`ListAgents`** (own subagents only — peer sessions belong to other runs; a row marked
  `completed` is still a candidate, because a returned subagent stays listed until stopped) and
  **`~/.claude/run/bg-tasks-$CLAUDE_CODE_SESSION_ID.json`** (monitors, teammates, background
  shells) — `TaskStop` any survivor and **say so**. An empty reading is "nothing reported live",
  never proof that nothing is live, and a missing or `absent` snapshot is not even that. A sentinel
  found after both views said nothing is a disagreement — name it.
- `ls {repo_root}/.claude/*-active-*` → empty.
- `ls ~/.claude/run/stage-pids-*.txt` → empty. `stage-processes.sh sweep` deletes the snapshot it
  consumed, so a leftover is a stage whose `backlog-teardown.sh` never ran. Name the stage and run
  the sweep by hand.
- `git worktree list` → one entry. No per-issue branches survive:
  `git for-each-ref --format='%(refname:short)' refs/heads | grep -Ev '^(main|master|dev)$'` →
  empty. **Not** `git branch --list 'feature/*'`: that pattern misses every conventional prefix
  and every slug containing `/`, so it reports clean while a `fix/…` branch is still on disk.
- `git status --porcelain` → clean. `git stash list` → empty. A stash left by preflight guard 3 is
  orphaned work: resolve it by hand, never drop it.
- Revert branch protection if it was enabled for the run.

Build every row from `gh`, not from what the stages reported:

```
/backlog summary ({owner}/{repo}) — {count} issues dispatched

✓ #9  dual-weighting result type   — merged            PR #75  <url>
✗ #11 purged-CV splitters          — STOPPED: mypy strict failure in src/splitters.py
○ #12 combinatorial purged CV      — skipped (parent #11 not merged)
⚠ #45 corporate action engine      — merged, verification partial — <what was not proven>
○ #52 factor exposure report       — not dispatched (run halted at #11)

Issues: {count} dispatched, {merged} merged, {open} PR(s) open, {blocked} blocked, {skipped} skipped,
        {undispatched} not dispatched.
Left for hand resolution: <stashes, worktrees, branches — or "none">
Docs updated: <docs/ paths touched across the run, and which matrix/test-plan rows moved — or "none">
Blockers handled: <out-of-contract fixes a stage had to make, with the issue and the reason — or "none">
Parked: <one flat line per finding, with file reference — or "none">
Follow-ups filed: <list, or "none">

🕐 {date}
```

**If the run halted (R6), say so on its own line above the table** — `halted at #{n} (PR #{pr}):
<reason>` — and list every queue entry that was never dispatched with that reason. A summary that
drops the tail reads as a finished backlog, which is the one thing a halted run is not. Name what
the user has to do to resume: fix the PR, then re-run, and Step 8 picks up at that same issue.

The last three lines come from the branches, not from the stages' reports — a stage that says it
updated the matrix and did not returns the same line as one that did:

```bash
git log --name-only --pretty=format: {integration_branch} -- docs/ | sort -u | grep .
git log -p {integration_branch} -- docs/parked-findings.md | grep '^+- \['
```

Read each command's **exit status**, not just its output: `0` means the printed lines are the
answer, `1` means genuinely none, and anything else means the lookup failed and the state is
**unknown** — write `unverified`, never `none`. Do not append `|| true`; it collapses all three
into "nothing there".

Keep `Parked` **flat and unranked** — no suggested phase two, no "which would you like next".
Offering a next step is how the cycle restarts, and after an unattended run across a whole backlog
that list is long enough to become a second backlog if it is presented as one.

`Docs updated: none` on a run that merged behavior changes is worth naming rather than omitting:
every plan's Definition of done carries the docs criterion, so an empty docs diff means a criterion
was reported passing and nothing observed it. That is the same class as the `⚠` row below.

The `⚠` row is the one that matters most: **merged is not validated.** Where a plan's Verification
section flagged a criterion as satisfied only against fixtures, stubs, or an unavailable dependency,
the issue merged legitimately but was not proven — collapsing that into `✓` misreports the state of
the codebase. File a follow-up issue quoting the plan's own wording, and list it.

## Error Handling

- **No GitHub repo / `gh` unauthenticated** — stop at Step 1 with the message above.
- **Empty backlog** — say so and stop; do not open the gate on an empty queue.
- **Enumeration hit the limit** — treat as truncation, not a backlog (Step 3).
- **Dependency cycle** — hard error naming the members (Step 4.4). Before reporting one, check the
  strict-vs-permissive diff from Step 4.1: a cycle that exists under only one reading is an
  authoring defect in the issue text, and naming the offending lines is far more useful than naming
  the cycle.
- **Unrecognised or unresolvable scope token** — usage error at Step 2. Never a search, never a
  guess: an unattended run must not start on a scope nobody chose.
- **Scope matched nothing** — print the parsed scope back and stop with `scope matched 0 open
  issues`. That is a different failure from an empty backlog and must not be reported as one.
- **Preflight rc 4 or rc 7** — stop the whole run. Everything else is per-issue.
- **`gh` unreachable mid-run** — an unreadable state is `unverified`, never resolved to the
  optimistic answer. Record it and surface it.

## Example Usage

```
/backlog
    Enumerate, order, confirm. Each issue is planned by opus and implemented by sonnet;
    PRs are left open for review. Nothing merges.

/backlog auto
    The same, but each PR is driven to a squash merge before the next issue starts.

/backlog auto opus
    The exec stage runs on opus at medium effort instead of sonnet. The intended
    invocation for a substantial backlog.

/backlog auto opus parallel=2
    Two issues in flight at once, each in its own worktree under
    .claude-work/$CLAUDE_CODE_SESSION_ID/. The merge stage releases a worktree before
    /automerge runs, since --delete-branch cannot remove a branch a worktree holds.

/backlog milestone="Phase B" auto opus
    One milestone, minus its epic and blocked issues. The usual shape: a queue small
    enough to actually read at the gate, and a stale `blocked` label costs one issue
    rather than forty.

/backlog label=area:facts -label=type:spike
    Every open facts-area issue that is not a spike, across milestones. PRs left open.

/backlog #141-176 auto
    An explicit range. Naming issues explicitly overrides the default epic/blocked
    exclusions for those numbers; an explicit -label= still applies.

/backlog include=blocked milestone="Phase D"
    Re-attempt what a previous run — or a human — marked blocked. Read the gate list
    before confirming: this is the invocation that runs issues something declared stuck.
```

## Important Notes

- **The orchestrator never reads code.** A stage returns at most a path, a status, and one line of
  prose. Work products go in files; the orchestrator gets the pointer. That is the entire purpose of
  the plan file — a handoff by reference, so a plan reaches the exec stage without passing through
  this session.
- **The timestamp convention is per-issue here, not per-turn** — see the note at the top. This is
  the only place `/backlog` departs from the suite's house style.
- **Agent types, sentinel names and the plan-file path are fixed.** `settings.json`'s `SubagentStop`
  matcher is literally `work-exec|work-exec-opus`; `hooks/automerge-rewake.sh` globs
  `.claude/work-active-*` and hardcodes `.claude/plans/issue-{N}.md`. Renaming any of them silently
  removes the stall backstop rather than producing an error.
- **The rewake hook is a backstop, never the mechanism.** It resumes a wait whose turn ended early;
  it is not a substitute for a cap, and no wait may be left uncapped on the assumption it will be
  covered.
- `/ci` and `/reviews` are never invoked interactively from here. `/automerge` reaches them in their
  `auto` modes inside its own subagent.
