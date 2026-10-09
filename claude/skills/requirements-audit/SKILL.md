---
name: requirements-audit
model: opus
effort: high
description: Verify that work the backlog calls done satisfies the criteria it was closed against. Pass R1 extracts every acceptance criterion from issues closed as completed in scope, and every Shipped row in docs/feature-matrix.md, then checks each against code and tests. Writes a dated report under docs/reviews/, comments on closed issues with unmet criteria, and creates follow-up issues behind one confirmation gate. Never reopens an issue. Never for exploratory use; it creates issues in bulk.
argument-hint: "[since=<N>d|<YYYY-MM-DD>] [milestone=\"…\"] [label=…] [-label=…] [#N|#A-B] [dry-run]"
# `model: opus` + `effort: high` mirror /closure-audit: classifying a finding and deciding
# ticket-vs-report is judgement work. Step 0 still runs the settings.json drift check, because the
# gate ends a turn and a command's `model:` is not sticky past it.
# Scanning runs on sonnet at dispatch (`model: "sonnet"` on each `Agent` call), never on opus.
#
# Deliberately NOT `arguments: [...]`: Step 1 strips tokens from anywhere in the string.
#
# User-invoked only. This CREATES issues and writes into the repo. /audit runs this lens by reading
# this file and the method files, never through the Skill tool, so denying model invocation costs
# no handoff.
disable-model-invocation: true
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved —
fall back to the per-step instructions below):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-08-15 10:17:13 CDT`. Do this on every turn — intermediate progress turns, gate turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Verify that shipped work satisfies the acceptance criteria it was closed against.

## Operating context & gates

- **Read `~/.claude/skills/audit/references/review-method.md` and
  `~/.claude/skills/audit/references/requirements.md` first.** Also read
  `~/.claude/skills/feature-closure/references/gap-detection.md`, which owns the denominator rule.
  The method files hold the passes, the finding ID, severity, sorting, and the report format. This
  command is their procedure and does not restate them.
- **Everything before Step 6 is read-only.** Nothing is written to the repo or the backlog until
  the gate clears.
- **`dry-run` stops after Step 5.** It prints the proposal and exits.
- **This command never branches, commits, opens a PR, or merges.**

## Step 0: Detect repository and stack

Follow `/closure-audit` Step 0 exactly: take `{owner}`, `{repo}` and `{repo_root}` from the block
above, run the model drift check, detect the stack from its manifests, and read `CLAUDE.md`. If
you cannot identify the stack, **say so and stop.** Do not scan with guessed patterns.

Set `{run}` to `date '+%Y%m%d-%H%M%S'` and `{run_dir}` to `{repo_root}/.claude/audit/{run}`.
Check `git -C {repo_root} check-ignore -q .claude/audit`. When the path is not ignored, carry a
`⚠` line to the gate. Never edit `.gitignore` yourself.

## Step 1: Parse scope

Strip these tokens from anywhere in `$ARGUMENTS`, in any order. The remainder is an issue selector.

- `since=<N>d` or `since=<YYYY-MM-DD>`: the closed-date window. The default is `since=90d`.
- `milestone="<title>"`, `label=<a,b>`, `-label=<c>`: identical grammar to `/backlog` Step 2.
- `dry-run`: stop after Step 5.
- Remainder: `#N`, `#A-B` inclusive, or `#1,#3,5`, per `/work` §0a. An explicit selector
  replaces the `since=` window.

**Anything else is a hard usage error.** A fuzzy match produces a scope nobody chose, and this
command writes to the backlog.

## Step 2: Run the pass

Run R1 in **one subagent** (`Agent` tool). Give it the stack, the scope, the R1 section of
`requirements.md`, the path to `review-method.md`, and the absolute path of its output file,
`{run_dir}/requirements-R1.jsonl`. Pass `model: "sonnet"`.

The fetch and its truncation check live in `requirements.md`. **A result exactly equal to
`--limit` is truncation**, and the pass re-fetches before it counts anything. The filter to
`COMPLETED` and to the date window runs after the fetch.

The pass returns **a path, a denominator, a count, and one line.** Never findings as text.

**A pass that cannot see its target reports BLIND, never clean.** Resolve a zero to `n/a`,
`BLIND` or `clean` per `gap-detection.md` before it reaches the gate. Zero criteria over a nonzero
issue count is BLIND until three bodies checked by hand prove the issues are thin.

## Step 3: Verify and sort

Read the JSONL rows. Drop REFUTED rows. Assign severity per `review-method.md` Rule 3 and
`proposed` per Rule 4. Compute every finding ID per Rule 2.

## Step 4: Reconcile against the backlog

Follow `review-method.md` Rule 5: one full fetch, the truncation check, and a match on finding ID.
Fetch the labels and mark `review:requirements` as proposed when it is absent.

## Step 5: Build the proposal

Assemble without writing anything: the report `docs/reviews/{YYYY-MM-DD}-requirements.md`, the
`docs/parked-findings.md` appends, the issues to create, the comments to post, and the labels to
create. If `dry-run`, print the proposal and stop.

## Step 6: The gate

Print the proposal, send a `PushNotification`, and **wait**. This is the only gate.

```
/requirements-audit ({owner}/{repo})  scope: since=90d  —  {date}

stack: Django / pytest
coverage:  R1 57 criteria / 19 issues / 6      4 issues no-criteria (thin, not findings)
              matrix: 12 Shipped rows / 1

report     docs/reviews/2026-09-22-requirements.md   7 findings
parked     docs/parked-findings.md                   +1

new labels (1)    review:requirements   — decline and these issues land unlabelled

comment (2)   #31 #38     closed as completed, criterion unmet → evidence + new issue number
create (2)
  REQ-2d7c11f0  CSV export omits archived rows (#31 criterion 3)     high    CONFIRMED
  REQ-e40b9a6c  Password reset link expiry untested (#38)            medium  PLAUSIBLE

⚠ #31 and #38 stay closed. Reopen them yourself if you agree
```

Every number carries its denominator. A BLIND pass appears as `⚠ … UNAUDITED`, never by omission.
`n/a` and UNAUDITED are different words and are never swapped.

## Step 7: Write

Only after the gate, in the order `review-method.md` gives under "The gate and the write". An
issue exists only when `gh issue view {n}` returns it. After a partial write, record what landed
and stop. **Do not retry the whole batch.**

## Step 8: Summary

Build every row from `gh` and the filesystem:

```bash
# Filter locally: GitHub search tokenizes on the hyphen and would match unrelated titles.
gh issue list --repo {owner}/{repo} --state open --limit 1000 --json number,title \
  --jq '.[] | select(.title | startswith("REQ-")) | "#\(.number) \(.title)"'
git -C {repo_root} status --porcelain -- docs/
```

Read the exit status: `0` means the output is the answer, and anything else means the state is
**unverified**, never `none`. Do not append `|| true`. Then send a final `PushNotification`.

## Important Notes

- **Read-only until Step 6.** Everything before the gate can be re-run freely.
- **Idempotent by finding ID.** A second run on an unchanged repo must propose **zero creates**.
- **Never closes or reopens an issue.** A closed issue with an unmet criterion gets a comment
  and a new issue.
- **Never creates a label outside the gate.**
- **Never branches, commits, or merges.**
