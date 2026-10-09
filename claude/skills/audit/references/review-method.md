# Reviewing an implementation for correctness

Load this before running any of the four review lenses: `/design-audit`, `/api-audit`,
`/requirements-audit`, `/ux-audit`, or `/audit`, which runs them together. Each lens also has its
own method file beside this one: `design.md`, `api.md`, `requirements.md`, `ux.md`.

## What this is

`/closure-audit` asks whether finished work is reachable. These lenses ask whether it is correct.
A lens finding is a defect in something that shipped, measured against a design document, an
architectural rule, an acceptance criterion, an API convention, or a usability standard.

## What this file inherits

`feature-closure/references/gap-detection.md` owns five rules, and every lens applies them
unchanged. This file does not restate them.

- A pass that cannot see its target reports BLIND, never clean.
- The denominator is stated before the count.
- A zero denominator has three meanings: `n/a`, `BLIND` and `clean`. A second independent signal
  tells them apart.
- A positive control runs before any zero count is reported.
- Every finding is verified as CONFIRMED, PLAUSIBLE or REFUTED. REFUTED is dropped, and PLAUSIBLE
  is the default when evidence is absent.

## Rule 1: the finding row

Each pass subagent writes one JSON object per line to
`{repo_root}/.claude/audit/{run}/{lens}-{pass}.jsonl`. The `{run}` value is the run's start time,
`date '+%Y%m%d-%H%M%S'`. Every row carries these fields:

```
id · lens · pass · file:line · symbol · rule · severity · verdict · evidence · proposed
```

- `symbol` is the function, component, route, table or document heading the finding sits in.
- `rule` is a short stable slug from the lens method file, such as `layering-violation` or
  `missing-error-state`.
- `evidence` quotes the line or names the file that proves the finding.
- `proposed` is one of `ticket`, `report`, `decision` or `park`, per Rule 4.

The pass returns four things to its orchestrator: a path, a denominator, a count, and one line.
It never returns findings as text. `/closure-audit` Step 3 uses the same contract, for the same
reason: the orchestrator's context pays for a verbose pass.

## Rule 2: the stable finding ID

The ID is the lens prefix plus the first eight hex digits of a SHA-1 hash:

```bash
# Line numbers are deliberately absent: an edit above the finding must not change its ID.
id_input="${rule}|${file}|${symbol}"
id="${prefix}-$(printf '%s' "$id_input" | shasum -a 1 | cut -c1-8)"
```

| Lens | Prefix |
|---|---|
| design | `DSN` |
| api | `API` |
| requirements | `REQ` |
| ux | `UX` |

**The finding ID is what makes a rerun idempotent.** Every created issue carries the ID at the
start of its title, and Rule 5 matches on it. The hash input excludes the line number, so an
unrelated edit elsewhere in the file leaves the ID unchanged. A hash that includes the line number
creates a duplicate issue on every run after any edit.

## Rule 3: severity

| Severity | Meaning |
|---|---|
| **high** | data loss, a broken security boundary, a user blocked from a task, or an unmet acceptance criterion |
| **medium** | an inconsistency a user or a caller can observe, or a WCAG (Web Content Accessibility Guidelines) 2.2 level A or AA failure |
| **low** | anything else, such as naming, style, or a pattern deviation with no observable effect |

Rank the report by severity, then by verdict (CONFIRMED before PLAUSIBLE). The parked list stays
flat, per `execution.md` §B4.

## Rule 4: ticket, report, decision, or park

The `/closure-audit` filter asks for a Capability line. That filter fits missing work, and it
parks most design defects, because a defect is rarely a missing capability. The lenses use a
different test.

**The ticket test asks whether you can write a done contract with an observable acceptance
check.** A test, a reviewer, or a person using the product must be able to see the check pass.
"POST /exports returns 409 on a duplicate key" passes. "Improve error handling" does not.

| The finding is | `proposed` | Goes to |
|---|---|---|
| high or medium, and it passes the ticket test | `ticket` | a new issue, with a done contract |
| a document that contradicts the code | `report` | the report, per `living-docs.md` §D5 |
| a pattern that needs a human decision, such as a layering rule broken in 14 places | `decision` | the report's "Decisions needed" section |
| anything else, including every low finding | `park` | `docs/parked-findings.md`, flat |

A fix issue is naturally one behavior, so the vertical-slice rule in `decomposition.md` §A1 holds
without extra work. Write its body to the `decomposition.md` §A2 template.

A `decision` item never becomes an issue at this gate. The answer may be an ADR (architecture
decision record) that retires the rule rather than code that obeys it, and that choice belongs
to a person.

## Rule 5: reconcile against the backlog

Fetch the backlog once per run, in full:

```bash
# `gh issue list` DEFAULTS TO --limit 30. `--state all`, because a closed issue carrying a finding
# ID is how a rerun knows the finding was already ticketed.
gh issue list --repo "$owner/$repo" --state all --limit 1000 \
  --json number,title,state,stateReason,labels
```

**A result exactly equal to `--limit` is truncation.** Raise the limit, re-fetch, and say that you
did. A failed fetch is unknown, never an empty backlog.

| Match on the finding ID | Gate shows | Action |
|---|---|---|
| an open issue | `[covered by #N]` | none |
| a closed issue | `[previously #N, closed]` | none. The finding is never recreated |
| no issue | the proposed issue | create after the gate |

A closed match that the lens still reproduces is a regression candidate. Show it at the gate with
the evidence. The lenses **never close an issue and never reopen one.** Changing an issue's
disposition is the user's call.

**Labels.** Match existing labels with `gh label list --json name -q '.[].name'`. The lens labels
are `review:design`, `review:api`, `review:requirements` and `review:ux`. A missing label is
proposed at the gate as its own vetoable block. The lenses never create a label outside the gate.

## Rule 6: the report

Each lens writes `docs/reviews/{YYYY-MM-DD}-{lens}.md` after the gate. The report has four
sections, in this order:

1. **Scope.** The date, the repository, the scope tokens, and the coverage line for every pass,
   with its denominator.
2. **Findings.** Ranked per Rule 3. Each entry carries its ID, `file:line`, rule, severity,
   verdict, evidence, and a disposition line: `ticketed as #N`, `covered by #N`, `reported`, or
   `parked`.
3. **Decisions needed.** Every `decision` item, with the count of places it applies.
4. **Not audited.** Every BLIND or UNAUDITED pass, with the probe that failed.

The disposition sits on each finding, at the point of reading. A status table elsewhere in the
file is the failure `gap-detection.md` describes for `COMMAND-AUDIT.md`.

**A dated report is append-only.** A later run writes a new file on its own date. It never edits an
earlier report. When two runs share a date, the second file takes a `-2` suffix.

## The gate and the write

Every lens follows `/closure-audit` Steps 6 to 8 for the gate, the write order, and the summary.
The additions are the report file and the lens labels. The write order is:

1. the report files
2. `docs/parked-findings.md`
3. labels the user confirmed
4. comments on existing issues
5. `gh issue create` for new issues, each titled `{ID} {summary}`

An issue exists only when `gh issue view {n}` returns it. After a partial write, record what
landed and stop. Never retry the whole batch.
