---
name: audit
model: opus
effort: high
description: Run every audit lens against a repository under one confirmation gate. The lenses are closure (half-finished work and backlog grooming, as /closure-audit), design (conformance and architectural soundness), api (API surface and data model), requirements (shipped work against its acceptance criteria), and ux (static and live interface review). Shares stack detection and the capability set across lenses, runs the passes in two waves of parallel subagents, dedupes findings across lenses, then writes the reports, docs and issues after one gate. Never for exploratory use; it creates and edits issues in bulk.
argument-hint: "[lenses=closure,design,api,requirements,ux] [area=<path>] [milestone=\"…\"] [label=…] [-label=…] [#N|#A-B] [since=<N>d] [live=off] [dry-run]"
# `model: opus` + `effort: high` mirror /closure-audit and the four lens commands. Step 0 still
# runs the settings.json drift check, because the gate ends a turn.
# Scanning runs on sonnet at dispatch (`model: "sonnet"` on each `Agent` call), never on opus.
#
# Deliberately NOT `arguments: [...]`: Step 1 strips tokens from anywhere in the string.
#
# User-invoked only. The lens commands also carry `disable-model-invocation`, so this command
# cannot reach them through the Skill tool. It reads their method files and procedures instead,
# and that is the design: one gate for the whole run, never one per lens.
disable-model-invocation: true
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved —
fall back to the per-step instructions below):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-08-15 10:17:13 CDT`. Do this on every turn — intermediate progress turns, gate turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Run the selected audit lenses against the repository, under one gate.

## Operating context & gates

- **Read these before Step 2**, and only those for the selected lenses:
  - `~/.claude/skills/closure-audit/SKILL.md` and
    `~/.claude/skills/feature-closure/references/gap-detection.md` for the closure lens
  - `~/.claude/skills/audit/references/review-method.md` for any review lens
  - `~/.claude/skills/audit/references/{lens}.md` for each selected review lens

  This command runs their procedures. It does not restate them, and where this file is silent
  the lens procedure governs.
- **Everything before Step 6 is read-only.** Nothing is written to the repo or the backlog until
  the gate clears.
- **One user gate, at Step 6**, covering every lens. The lens commands each have their own gate.
  This command replaces those with one.
- **`dry-run` stops after Step 5.**
- **This command never branches, commits, opens a PR, or merges.** Hand the groomed backlog to
  `/backlog` afterwards.

## Step 0: Detect repository and stack

Follow `/closure-audit` Step 0 exactly: the pre-resolved block, the model drift check, the stack
from its manifests, and `CLAUDE.md`. If you cannot identify the stack, **say so and stop.** Do not
scan with guessed patterns.

Set `{run}` to `date '+%Y%m%d-%H%M%S'` and `{run_dir}` to `{repo_root}/.claude/audit/{run}`.
Check `git -C {repo_root} check-ignore -q .claude/audit`. When the path is not ignored, carry a
`⚠` line to the gate. Never edit `.gitignore` yourself.

## Step 1: Parse scope

Strip these tokens from anywhere in `$ARGUMENTS`, in any order. The remainder is an issue selector.

- `lenses=<a,b,…>`: any of `closure`, `design`, `api`, `requirements`, `ux`. The default is all
  five. At most one token.
- `area=<path>`, `milestone="<title>"`, `label=<a,b>`, `-label=<c>`, `include=…`: the
  `/closure-audit` Step 1.1 grammar. Each lens applies the tokens it understands, and the gate
  names any lens that ignored one.
- `since=<N>d` or `since=<YYYY-MM-DD>`: the requirements window.
- `live=off`: skip the UX live pass.
- `dry-run`: stop after Step 5.
- Remainder: `#N`, `#A-B`, or `#1,#3,5`, per `/work` §0a.

**Anything else is a hard usage error**, and so is an unknown lens name. A fuzzy match produces a
scope nobody chose, and this command writes to the backlog.

Print the selected lenses before scanning.

## Step 2: Shared setup

Run once, and hand the results to every lens:

1. **Backlog source**, per `/closure-audit` Step 1.2. A failed lookup is unknown, never empty.
2. **Capability set**, per `/closure-audit` Step 2, when `closure` or `requirements` is selected.
   Requirements reads the capability IDs and `docs/feature-matrix.md`.
3. **Backlog fetch**, once, with `--state all --limit 1000` and the truncation check. Every lens
   reconciles against this one snapshot. **A result exactly equal to `--limit` is truncation.**
4. **Labels**, once, with `gh label list --json name -q '.[].name'`.

## Step 3: Dispatch in two waves

**At most five parallel `Agent` calls per wave, each with `model: "sonnet"`**, the threshold `/work` §0b uses. A deselected lens
drops out of its wave, and an empty wave is skipped.

| Wave | Subagents | Why this order |
|---|---|---|
| **1** | closure passes A, B, C, D, E | requirements and design D1 read closure's results |
| **2** | design (D1 then D2), api (P1 then P2), requirements (R1), ux static (U1), ux live (U2) | one subagent per lens, except UX, whose live pass holds a browser and a server |

Each subagent gets the stack, the scope, its method section, the repo map path
(`$(~/.claude/lib/repo-map.sh path)`), and the absolute path of its output file under `{run_dir}`.
Every `Agent` call in both waves passes `model: "sonnet"`. Each returns **a path, a denominator, a count, and one line.** Never
findings as text. A wave-2 subagent that runs two passes returns one line per pass.

When wave 1 ran, tell the design subagent that D1 skips `docs/contracts/`, because closure pass D
owns that drift.

The UX live subagent follows `/ux-audit` Step 2 in full: `subagent_type: general-purpose` with `model: "sonnet"`, the PID
from `$!`, and **the server ended before it returns, on every path.**

**A pass that cannot see its target reports BLIND, never clean.** Every zero is resolved to `n/a`,
`BLIND` or `clean` per `gap-detection.md`. A BLIND pass halts and reaches the gate as UNAUDITED.
The other passes and waves continue.

## Step 4: Verify, sort, dedupe, reconcile

1. Closure findings follow `/closure-audit` Steps 3 and 4. Review findings follow
   `review-method.md` Rules 2 to 5.
2. **Dedupe across lenses by `file` + `symbol`.** When two lenses report the same place, keep the
   higher-severity row and list the other lens's rule on it. A closure capability gap and a
   requirements `criterion-unmet` on the same capability are one issue, carrying both IDs.
3. Reconcile every finding against the Step 2 snapshot, by capability ID for closure and by
   finding ID for the review lenses.

## Step 5: Build the proposal

Assemble without writing anything:

- the closure docs: `docs/feature-matrix.md`, `docs/test-plan.md`
- one report per review lens: `docs/reviews/{YYYY-MM-DD}-{lens}.md`
- the `docs/parked-findings.md` appends, flat
- issue upgrades, dependency-text fixes, comments, and creates
- the labels to create

If `dry-run`, print the proposal and stop.

## Step 6: The gate

Print the proposal, send a `PushNotification`, and **wait**. This is the only gate.

```
/audit ({owner}/{repo})  lenses: closure,design,api,requirements,ux  scope: {scope}  —  {date}

backlog source: GitHub issues (gh), 212 fetched / limit 1000
stack: SvelteKit / vitest + playwright

wave 1  closure  A 412 producers/7  B 1,204 files/38  C 86 caps/12  D 9 docs/2  E 212 items/9
wave 2  design   D1 23 claims/4 (contracts → closure)   D2 7 checks/3
        api      P1 n/a (adapter-static, no server routes)   P2 n/a (no store declared)
        req      R1 57 criteria/19 issues/6
        ux       U1 64 components/12   U2 17/19 routes/9, server PID 48113 ended

docs to write (6)
  docs/feature-matrix.md               86 rows
  docs/test-plan.md                    86 rows
  docs/reviews/2026-09-22-design.md    9 findings, 2 decisions
  docs/reviews/2026-09-22-requirements.md   6 findings
  docs/reviews/2026-09-22-ux.md        21 findings
  docs/parked-findings.md              +31

new labels (3)   review:design  review:requirements  review:ux

upgrade in place (3)   #14 #22 #31
comment (2)            #31 #38     criterion unmet, issue stays closed
create (9)
  closure  EXP-3        A user can configure which columns appear in an export   CONFIRMED
  design   DSN-3f9a01c2 POST /exports has no authorization check                 high  CONFIRMED
  …
deduped (4)   UX-c8f3d410 + DSN-19ab… on src/routes/settings/+page.svelte

⚠ ux U2: /admin, /billing UNAUDITED (auth redirect, no storageState)
```

Rules the gate honours, from `/closure-audit` Step 6:

- **Never a bare count.** Every number carries its denominator.
- **A blocked pass gets a `⚠` line saying UNAUDITED**, never omission.
- **`n/a` and UNAUDITED are different words and must never be swapped.**
- Print every exclusion and the token that re-includes it.
- If every finding in every lens is parked or covered, say so and stop.

## Step 7: Write

Only after the gate, in this order:

1. `docs/feature-matrix.md`, `docs/test-plan.md`. The matrix goes first because issue bodies
   cite its row IDs.
2. The review reports, then `docs/parked-findings.md`.
3. Labels the user confirmed.
4. `gh issue edit` for upgrades and dependency-text fixes. **Re-fetch each body immediately
   before editing**, because `--body` overwrites the whole body.
5. `gh issue comment` on superseded and unmet-criterion issues.
6. `gh issue create` for new issues, closure first, then the review lenses.

An issue exists only when `gh issue view {n}` returns it. After a partial write, record what
landed and stop. **Do not retry the whole batch.**

## Step 8: Summary

Build every row from `gh` and the filesystem, not from what Step 7 intended:

```bash
# Filter locally: GitHub search tokenizes on the hyphen and would match unrelated titles.
gh issue list --repo {owner}/{repo} --state open --limit 1000 --json number,title \
  --jq '.[] | select(.title | test("^(DSN|API|REQ|UX)-[0-9a-f]{8} ")) | "#\(.number) \(.title)"'
git -C {repo_root} status --porcelain -- docs/
```

Read the exit status: `0` means the output is the answer, and anything else means the state is
**unverified**, never `none`. Do not append `|| true`. Confirm the UX server PID is gone with
`ps -p "$(cat {run_dir}/ux/server.pid)"`, and print it on the summary when `ps` still lists it.

End with `Next: review the created issues, then /backlog to drive them.` Send a final
`PushNotification`.

## Error Handling

- **Stack not identified**: stop before scanning.
- **Unknown token or lens**: a usage error. Print the grammar and stop.
- **A BLIND pass**: UNAUDITED at the gate. The rest of the run continues.
- **Truncated backlog fetch**: raise the limit and re-fetch. Never gate on a truncated backlog.
- **The UX server did not end**: a blocker on the summary, with its PID.
- **Partial write**: record what landed, stop, and name the remaining work.

## Important Notes

- **Read-only until Step 6.**
- **Idempotent.** A second run on an unchanged repo must propose **zero creates**. Closure matches
  by capability ID and the review lenses by finding ID.
- **Never closes or reopens an issue.**
- **Never creates a label outside the gate.**
- **Never branches, commits, or merges.** Hand off to `/backlog`.
