---
name: closure-audit
model: opus
effort: high
description: Audit a repository and its issue backlog for work that is already half-finished, then groom the backlog so it can actually be closed. Finds half-wired vertical slices (an endpoint nobody calls, a component nobody routes, a migration nobody queries), in-code markers on reachable paths, test-coverage gaps, contract and documentation drift, and backlog hygiene problems (thin issues, layer-sliced issues, issues superseded by shipped code, ambiguous dependency lines). Writes docs/feature-matrix.md and docs/test-plan.md, upgrades thin issues in place, and creates vertical closure issues — all behind a single confirmation gate. Run it before /backlog so that run is driving real, sliced, closeable work. Never for exploratory use; it creates and edits issues in bulk.
argument-hint: "[area=<path>] [milestone=\"…\"] [label=…] [-label=…] [#N|#A-B] [dry-run]"
# `model: opus` + `effort: high` mirror /work and /backlog, and for the same reason: this session
# classifies findings, decides ticket-vs-park, and slices capabilities — judgement work, not
# mechanical work. The per-pass scanning is delegated to subagents where the model can be cheaper.
# Both halves are required: a command's `model:` is not sticky past a turn boundary and the
# confirmation gate ends a turn, so the settings.json drift check in Step 0 stays too.
#
# Deliberately NOT `arguments: [...]`. Step 1 strips `area=`, `dry-run` and every scope token from
# anywhere in the string, so nothing has a fixed position; $ARGUMENTS gives Step 1 the raw string.
#
# User-invoked only, same reasoning as /work, /backlog, /commit and /reap. This CREATES and EDITS
# issues in bulk and writes files into the repo — never something Claude should start on its own
# initiative. Nothing else in the suite invokes /closure-audit, so denying model invocation costs
# no handoff.
disable-model-invocation: true
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved —
fall back to the per-step instructions below):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-08-15 10:17:13 CDT`. Do this on every turn — intermediate progress turns, gate turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Audit the repository and its backlog for work that is already half-finished, then groom the backlog
so it can be closed.

## Operating context & gates

- **Everything before Step 6 is read-only.** Steps 0–5 scan, classify and propose. Nothing is
  written to the repo, the backlog, or any issue until the gate clears.
- **One user gate, at Step 6.** Same model as `/backlog` Step 5: a scope line with a denominator,
  the exclusions and how to re-include them, a `⚠` line for every downstream consequence, and
  per-item rows a human can veto individually. After it, Step 7 writes without further prompting.
- **`dry-run` stops after Step 5.** It prints the proposal and exits. No gate, no writes.
- **Load `feature-closure` first**, and read `references/gap-detection.md`. That file is the
  method — the five signals, the denominator rule, the three-state verify, and the sorting rule
  that decides ticket vs report vs park. This command is its procedure; it does not restate it.
- **This command never branches, commits, opens a PR, or merges.** It grooms. Hand the groomed
  backlog to `/backlog` afterwards — deliberately a separate run, so bulk issue-writing never
  shares a gate with branch deletion.

## Step 0: Detect repository and stack

1. Take `{owner}`, `{repo}`, `{repo_root}`, `{integration_branch}` from the pre-resolved block
   above. If empty, resolve per `/work` §0 — `.claude/branch-config.json` →
   `gh repo view --json defaultBranchRef` → `git symbolic-ref refs/remotes/origin/HEAD` →
   `main`/`master`.
2. **Model drift check.** `jq -r '.model // "unset"' ~/.claude/settings.json` must read `opus`.
   The gate below ends a turn, and a session defaulting to anything else silently downgrades the
   classification work that follows it. Warn and continue if it disagrees.
3. **Detect the stack** from manifests — `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`,
   `Gemfile`, `pom.xml` — and read `CLAUDE.md` if the repo has one. The probes in Steps 2–3 are
   stack-specific; a probe written for the wrong stack is the blind-monitor failure, and it reports
   as a clean repo.
4. State the detected stack and test runner in output before scanning. If you cannot identify
   them, **say so and stop** — do not scan with guessed patterns.

## Step 1: Parse scope, and detect where the backlog lives

### 1.1 Scope tokens

Strip these from anywhere in `$ARGUMENTS`, order-independent; the remainder is an issue selector.

- `area=<path>` — restrict the codebase scan to a subtree. At most one. Repo-relative.
- `milestone="<title>"`, `label=<a,b>`, `-label=<c>`, `include=epic|blocked|all` — identical
  grammar and semantics to `/backlog` Step 2. Commas within a `label=` token are OR, separate
  tokens are AND. `-label=` excludes. `include=` cancels a *default* exclusion only.
- `dry-run` — stop after Step 5.
- Remainder — `#N`, `#A-B` inclusive, `#1,#3,5`, per `/work` §0a.

**Anything else is a hard usage error.** Same call as `/backlog` rule 6, for the same reason: a
fuzzy match produces a plausible-looking scope nobody chose, and this command writes to the backlog.

### 1.2 Backlog source detection

The backlog is wherever this repo actually keeps it. `feature-closure` §A5 requires matching the
existing convention rather than imposing one. Detect, first hit wins, and **state which won**:

1. **GitHub issues** — `gh repo view {owner}/{repo} --json hasIssuesEnabled -q .hasIssuesEnabled`
   returns `true`.
2. **A backlog file** — `BACKLOG.md`, `docs/backlog.md`, `TODO.md`, or whatever convention the repo
   shows. Check `.github/ISSUE_TEMPLATE/` too: a repo with templates and no issues still tells you
   the intended format.
3. **Neither** — propose creating `docs/backlog.md` at the gate. Do not silently pick.

A failed `gh` lookup is **unknown**, not "no issues" — the distinction matters here more than
anywhere, because reading it as "no issues" turns a grooming run into a bulk-create run against a
backlog that already exists.

## Step 2: Build the capability set

Passes A and C key off this, so it comes before the fan-out.

A **capability** is something a person can do, at the granularity `docs/feature-matrix.md` tracks.
Derive them from what the repo exposes — routes, commands, jobs, public API surface — grouped by
area, and give each a **stable ID** (`EXP-1`, `AUTH-2`). Reuse existing IDs when
`docs/feature-matrix.md` is already present; that file is the authority on IDs already assigned.

**The ID is what makes this command idempotent.** Step 4 matches findings to existing backlog items
and matrix rows by ID, so an ID that is regenerated differently on each run turns a groom into a
duplicate-create. If `docs/feature-matrix.md` exists, IDs come from it and are never renumbered.

Print the count. **Zero capabilities is a blocker**, not an empty repo.

## Step 3: The five passes

Dispatch A–E as **parallel subagents** (`Agent` tool, ≤5 items — the same threshold `/work` §0b
uses to choose the Agent tool over a Workflow). Give each the stack, the scope, the capability set,
and an absolute path to write to under `{repo_root}/.claude/audit/`.

**Return contract, identical to `/work`'s:** each pass returns **a path, a denominator, a count,
and one line**. Never findings as text. The orchestrator's context is what pays for a verbose pass,
and a whole-repo audit is the easiest way to exhaust it.

| Pass | Looks for | Denominator it must report |
|---|---|---|
| **A** Half-wired slices | producer with no consumer — see `gap-detection.md` §A | producers enumerated |
| **B** In-code markers | `TODO`/`FIXME`/`HACK`/`XXX`, not-implemented throws, stub returns, skipped tests | files scanned |
| **C** Test-coverage gaps | per capability: unit / integration / e2e referencing it | capabilities × test files enumerated |
| **D** Contract and doc drift | `docs/contracts/` vs code, matrix rows claiming `Shipped` for the unreachable, `CLAUDE.md` vs repo, and **dangling references** — a doc, contract, matrix row or issue citing a file, symbol, spec or issue number that no longer exists | documents read |
| **E** Backlog hygiene | thin, layer-sliced, superseded, ambiguous-dependency issues | backlog items fetched |

Each pass **verifies before reporting** — CONFIRMED / PLAUSIBLE / REFUTED per `gap-detection.md`,
dropping REFUTED, and defaulting to PLAUSIBLE rather than refuting on absence of evidence.

Every finding row carries the same five fields so Step 4 can reconcile uniformly:

```
id · pass · file:line · capability phrasing (or "—") · CONFIRMED|PLAUSIBLE
```

### 3.1 Pass E fetches the backlog in full

```bash
# `gh issue list` DEFAULTS TO --limit 30 — without the flag this silently returns the 30
# most-recent issues and the gate shows a plausible-looking short backlog. `--state all`,
# not open-only: a CLOSED issue is how a superseded ticket is recognised.
gh issue list --repo {owner}/{repo} --state all --limit 1000 \
  --json number,title,body,state,stateReason,labels,milestone,closedAt
```

**Assert the count is below the limit.** A result exactly equal to `--limit` is truncation, not a
backlog: raise it, paginate, and say that you did.

Parse dependency declarations **twice — strictly and permissively** — per `/backlog` §4.1, and
report every reference the two readings disagree about. That diff is the whole check: a strict
reading silently drops an edge when one line carries two references, a permissive one fabricates
edges from prose. Each disagreement is a Pass E finding whose fix is a `gh issue edit` to the
one-edge-per-line convention.

### 3.2 The denominator rule, and the three meanings of zero

**A pass that cannot see its target reports BLIND, never clean.** Every pass states its denominator
before its count.

**A zero denominator has three meanings, and collapsing them is the failure this rule exists to
stop** — the same "done / not-applicable / pending" mistake that once hung `/automerge` forever:

| Zero means | Test for it | Disposition |
|---|---|---|
| **n/a** | nothing corroborates that the class should exist — no config declares it, no script runs it, no dependency provides it | `n/a` in the coverage line. Not a gap, not a blocker |
| **BLIND** | something *does* corroborate it | **blocker.** `UNAUDITED` at the gate, never a finding |
| **clean** | a positive control proves the probe works over that file set | `0`, naming the control |

**Corroborate before calling a zero `n/a`.** A SvelteKit repo with `adapter-static` and no
`+server.ts` anywhere genuinely has no server routes — `n/a`. The same repo returning zero e2e
specs while `playwright.config.ts` declares `testMatch` globs and `package.json` has `test:e2e` is
a **broken probe**: the specs are named `*.e2e.ts` and the glob looked for `*.spec.ts`. Reporting
that as a coverage gap invents a finding per capability against a fully covered repo.

**Run a positive control before reporting any zero count.** Probe the same file set for something
certain to exist — `import`, `function` — and state the result. A control returning zero means the
file set is wrong and every count from that pass is void.

Halt a BLIND pass, name the probe, and carry it to the gate. The other passes continue.

## Step 4: Reconcile against the backlog

Match every finding to the existing backlog **by capability ID first**, then by file path, then by
title similarity. Then sort it:

| Finding state | Proposed action |
|---|---|
| Already covered by an open issue | leave alone — show as `[covered by #N]` |
| Covered by a **thin** issue (no acceptance criteria) | **upgrade in place** to the `decomposition.md` §A2 template |
| Superseded by shipped code | **comment with the evidence, apply an existing stale label. Never close.** |
| Ambiguous dependency line | `gh issue edit` to one edge per line |
| An uncovered capability gap | **create** a vertical slice with a done contract |
| Anything else | append to `docs/parked-findings.md` |

Two constraints do the real work here:

- **The Capability line is the filter.** `decomposition.md` §A3 forbids issues for work with no
  acceptance criteria — "improve error handling", "clean up the export module". If a finding
  cannot be phrased as "a person can *X*", it is **parked, not ticketed**, however real it is.
  This is what stops a whole-repo audit from emitting two hundred tickets.
- **Slice new issues vertically.** Per §A1, an issue is a thin complete path through every layer,
  never "add the endpoint". An audit that emits layer-sliced tickets has reproduced the exact
  failure it was run to find.

The thin-issue upgrade is **not new machinery** — `/work` §7, `/backlog` §6c and
`agents/work-plan.md` already do it, writing the template at `decomposition.md`. Use the same
template so an upgraded issue is indistinguishable from one `/work` would have produced.

**Why superseded issues get a comment while thin ones get rewritten.** `feature-closure` says to
fix things in place rather than annotate, and this looks like an exception. It is not. Upgrading a
thin issue **preserves its intent** and only sharpens it, so rewriting the body is safe. Declaring
an issue obsolete **changes its disposition**, which is the user's decision and not yours to make
from inferred evidence — so the comment is a handoff to a human, not a substitute for a fix. A
dangling reference *inside* an issue body is different again: that is a falsified statement, and
you fix it in place with the dependency-text edit above.

**Labels.** Fetch existing labels with `gh label list --json name -q '.[].name'` and match
defensively. The suite's rule is *never create a label silently* — the operative word is
**silently**. Any label you want that does not exist is proposed at the gate as its own vetoable
block; declining means the issues are created unlabelled, and the `⚠` line says so.

## Step 5: Build the proposal

Assemble, without writing anything:

- the `docs/feature-matrix.md` rows — columns `ID | Capability | UI | API | Data | Status | Issue |
  Contract`, per-layer cells `done` / `none` / `n/a`, status strictly one of
  `Planned` / `In progress` / `Shipped` / `Deprecated`
- the `docs/test-plan.md` rows — `ID | Unit | Integration | E2E | Edge cases covered | Gaps`,
  keyed by the same IDs, **naming real spec files**, with gaps stated rather than left blank
- the `docs/parked-findings.md` appends, flat and unranked
- the issue edits and creates
- the labels to create

**Rank the report by blast radius** — a capability nobody can reach outranks a missing e2e test,
which outranks a `TODO`. **The parked list stays flat**, per `execution.md` §B4; that is not an
inconsistency, it is the difference between something you act on now and a second backlog wearing
a disguise.

If `dry-run`, print this and stop.

## Step 6: The gate

Print the proposal, send a `PushNotification`, and **wait**. This is the only gate.

```
/closure-audit ({owner}/{repo})  scope: {scope}  —  2026-08-15

backlog source: GitHub issues (gh)      stack: SvelteKit / vitest + playwright
coverage:  A 412 producers/7        server routes n/a (adapter-static)
           B 1,204 files/38         control: 158 import hits
           C 86 caps, 61 specs/12   e2e UNAUDITED — probe found 0 but playwright.config
                                    declares 5 testMatch globs
           D 9 docs/2
           E 74 items (12 closed)/9

docs to write (3)
  docs/feature-matrix.md    86 rows (new)
  docs/test-plan.md         86 rows (new)
  docs/parked-findings.md   +14 findings

new labels to create (2)          — decline and these issues land unlabelled
  closure:half-wired
  closure:no-tests

upgrade in place (3)   #14 #22 #31        thin — no acceptance criteria
fix dependency text (2) #40 #57           strict/permissive parses disagree
propose obsolete (1)   #9                 superseded by src/exports/csv.ts:12
                                          → comment + `stale` label, NOT closed
create (6)
  EXP-3  A user can configure which columns appear in an export       CONFIRMED
  AUTH-4 A user can reset a password from the login screen            PLAUSIBLE
  …

⚠ 14 findings are not capability gaps — parked, not ticketed
⚠ pass B could not enumerate Go files; that subtree is UNAUDITED, not clean
```

Rules the gate must honour:

- **Never a bare count.** Every number carries its denominator.
- **An exclusion that is not printed is indistinguishable from an issue that does not exist.**
  Print what was excluded and the token that re-includes it.
- **A blocked pass gets a `⚠` line saying UNAUDITED, never omission.** A pass that halted on a zero
  denominator must appear here; silently dropping it is how a partial audit reads as a clean one.
- **`n/a` and `UNAUDITED` are different words and must never be swapped.** `n/a` says the class does
  not exist here; `UNAUDITED` says it does and we could not see it. A reader acts on those
  differently, and the second one means the run is incomplete.
- Show items already in flight rather than dropping them — a human vetoes individually.
- If **every** finding is parked and nothing is proposed, say so and stop. A short close is a good
  close, and there is nothing to gate.

## Step 7: Write

Only after the gate. Order matters — the matrix is written first because issue bodies cite row IDs.

1. `docs/feature-matrix.md`, `docs/test-plan.md`, `docs/parked-findings.md`
2. Labels the user confirmed
3. `gh issue edit` for upgrades and dependency-text fixes — **re-fetch each body immediately
   before editing**, never from the Step 3 snapshot; the audit may have taken a while and
   `gh issue edit --body` is a whole-body overwrite
4. `gh issue comment` + stale label for superseded issues
5. `gh issue create` for new slices, each carrying its capability ID in the title

**An issue is created only when `gh issue view {n}` returns it** — never because `gh issue create`
exited 0. Per `CLAUDE.md`, completion is an observation, not a claim.

If a write fails partway, **record what landed and stop**. Do not retry the whole batch: the
successful creates are already there, and a blind retry is how the duplicate backlog gets made.

## Step 8: Summary

Build every row from `gh` and the filesystem, not from what Step 7 intended:

```bash
gh issue list --repo {owner}/{repo} --state open --limit 1000 --search "EXP-" --json number,title
git -C {repo_root} status --porcelain -- docs/
```

Read exit status, not just output: `0` means the printed lines are the answer, `1` means genuinely
none, anything else means the lookup failed and the state is **unverified**, never `none`. Do not
append `|| true`.

```
/closure-audit summary ({owner}/{repo}) — scope {scope}

✓ docs/feature-matrix.md   86 rows written
✓ docs/test-plan.md        86 rows written
✓ docs/parked-findings.md  +14
✓ upgraded  #14 #22 #31
✓ created   #81 #82 #83 #84 #85 #86
⚠ #9 commented + labelled stale — NOT closed, close it yourself if you agree
⚠ pass B: Go subtree UNAUDITED (probe could not enumerate); re-run with area=

Next: review the created issues, then `/backlog` to drive them.
```

Every created issue carries its own disposition inline. **Do not write a findings report in the
present tense with a status table elsewhere** — `COMMAND-AUDIT.md` earned that lesson: a report
whose dispositions live 400 lines from the findings keeps reading as live work for months.

Then send a final `PushNotification`.

## Error Handling

- **Stack not identified** — stop before scanning. Guessed probes report a clean repo.
- **Zero denominator on any pass** — resolve it to `n/a`, `BLIND` or `clean` per §3.2 before
  reporting. Only `BLIND` is a blocker; the others continue and the gate shows `UNAUDITED` for it.
  Never report a zero without saying which of the three it is.
- **`gh` unavailable or repo unresolved** — fall back to backlog-file mode and say so; never treat
  a failed lookup as an empty backlog.
- **Truncated issue fetch** — raise the limit and re-fetch. Never gate on a truncated backlog.
- **Scope matched zero capabilities** — a scoping mistake, not a clean repo. Say which, and stop.
- **Partial write** — record what landed, stop, and name the remaining work. Never blind-retry.

## Important Notes

- **Read-only until Step 6.** Everything before the gate can be re-run freely.
- **Idempotent by capability ID.** A second run on an unchanged repo must propose **zero creates**.
  That is the acceptance test and the likeliest thing to be quietly wrong.
- **Never closes an issue.** Superseded issues get evidence and a label; the close is yours.
- **Never creates a label outside the gate.**
- **Never branches, commits, or merges.** Hand off to `/backlog`.
- **Denominators everywhere.** A pass that cannot observe its target reports BLIND, never healthy.
