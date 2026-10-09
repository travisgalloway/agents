---
name: feature-closure
description: Keeps coding work converging on a fixed, agreed scope instead of fanning out into endless follow-on issues. Covers four things. First, breaking a design into backlog issues that are vertical, independently shippable slices with explicit completion criteria. Second, executing an issue against a done contract taken from the ticket, parking every out-of-scope discovery instead of acting on it. Third, keeping the repository's CLAUDE.md stocked with the stack's coding norms and the shared definition of done. Fourth, maintaining living documentation in docs/, covering design notes, API and interface contracts, a feature matrix tracking implementation status, and a test plan tracking coverage by test type. Use this on every coding task by default, including bug fixes, refactors, backlog grooming, and design breakdown, and especially any time you are about to say "while I was in there I also noticed", "we should probably also", or "a follow-up issue can handle".
# No `model:` pin — intentional, same reason as /pr, /ci, /reviews and /automerge. /work and
#   /backlog load this mid-turn via the Skill tool, and a model override applies for the rest of
#   the CALLING turn with no way back — pinning it here would silently downshift the opus
#   orchestrator through implementation, PR and merge. The plan/exec model split is enforced at
#   the subagent dispatch boundary (agents/work-plan.md, work-exec.md), never by pinning a
#   nested skill.
# No `disable-model-invocation` — intentional, and the opposite call from /work, /backlog,
#   /commit and /reap. This is the one skill in the suite that MUST fire on Claude's own
#   initiative: a scope rule nobody remembers to invoke is a scope rule that does not exist.
#   Safe to auto-fire because it changes no state, creates no branch, and opens no PR.
# No `references:` key — the key is real (the vendored cloudflare and turnstile-spin skills use
#   it) but it is NOT in the documented set tests/lint-frontmatter.sh enforces, and those two
#   are vendored and therefore unlinted. The reference files below are linked from body prose
#   instead, the way agents-sdk and durable-objects do it.
# No `allowed-tools` — this skill runs no commands of its own. Which is why the note below must
#   NAME lib/branches.sh in plain prose rather than showing the bang-backtick form: that syntax is
#   expanded wherever it appears in a skill body — inside a blockquote, inside a code span, inside
#   a sentence saying "this skill does not use it" — and the bare `branches.sh` it once quoted is
#   not on PATH, so merely loading this skill failed with `command not found`. Never write that
#   form except as a real, absolute path you intend to execute (tests/reference-integrity.sh).
---

> **This skill owns no turn.** Unlike the ten command skills here, it carries no pre-resolved
> `lib/branches.sh` repo-context block and adds no `🕐` footer — it is loaded *into* another
> command's turn, touches no branches, and never reports on its own. The host command's
> timestamp-footer convention is unaffected; keep doing whatever it says.

# Feature Closure

## Why this exists

The default failure mode of an agent working in a real codebase is **divergence**. Every file you
open contains something that could be better. Each of those observations is individually correct,
and acting on all of them means the original task never closes. The user ends up reviewing a
growing pile of adjacent changes instead of receiving the thing they asked for.

The same failure has a second form, one issue upstream. When a design gets broken into a backlog,
the easy decomposition is **by layer** — build the API, then the UI, then wire them together, then
add tests. Each of those tickets is closeable on its own terms, and none of them delivers anything
a person can use. The backlog grows, the burndown looks healthy, and the feature stays unusable
until the last card in the stack lands.

The fix in both cases is the same. **Fix what done means before work starts, make done mean
usable, and separate noticing from acting.**

## The core rule

**Scope is fixed at the moment the done contract is confirmed, and it does not grow without the
user explicitly saying so. Done means a person can use the thing, not that a layer of it exists.**

Anything you discover after scope is fixed goes into the parking file. You mention parked items
once, at the end, in a short flat list. You do not implement them, you do not start them, and you
do not ask mid-task whether you should.

## Which part applies

Read the one that matches. Do not read all five — that is the cost this split exists to avoid.

| If you are… | Read |
|---|---|
| Breaking a design, spec or feature request into backlog issues, or grooming an existing backlog | `references/decomposition.md` |
| Implementing an issue, fixing a bug, or making any code change | `references/execution.md` |
| In a repository whose `CLAUDE.md` has no norms section, or a stale one — **once per repo** | `references/norms.md` |
| Auditing an existing repo for work that is already half-finished, or grooming a backlog that predates any of this | `references/gap-detection.md` |
| Any task at all. Contracts are read before implementing; the feature matrix and test plan are updated in the same change as the code | `references/living-docs.md` |

The paths are relative to this file: `~/.claude/skills/feature-closure/references/`.

## The three moves, in short

You can apply these without loading anything. The references are for when you need the templates.

1. **Fix the contract first.** Before opening implementation files, find the authoritative scope —
   the issue, a spec/ADR in the repo, or an acceptance list committed alongside the feature.
   Restate it as a numbered list. If the issue is thin ("add CSV export"), **upgrade it in place**
   to the full template and confirm before implementing; starting from a one-liner guarantees the
   exact drift this skill prevents. If no issue exists, say so, draft the criteria, get a yes.
2. **Park, do not act.** Hold two questions apart while working. *Does this make a criterion
   pass?* → in scope, do it. *Is this an improvement, a latent bug, a naming inconsistency, a
   missing test elsewhere, a dependency concern, a refactor opportunity?* → a finding, park it.
   One exception: something that **blocks a criterion from being satisfiable at all** is part of
   the work, not a finding — and you say so in the close-out, so the user can see where the diff
   grew and agree with the reason.
3. **Close on the criteria, not on running out of improvements.** Walk the list explicitly against
   the actual diff and an actual run of the tests. Run the **full** suite — "nothing unrelated
   broke" is a criterion, and it is the one most often assumed rather than checked.

**Not scope drift, and not deferrable:** tests, edge cases, error states, and wiring the change
through to something a person can reach. Deferring those is not discipline — it is the
layer-slicing failure showing up inside a single issue.

## Changing something that already exists

**When a change makes an existing statement wrong, fix that statement in place.** Do not append an
annotation next to it, and never leave a reference pointing at something that no longer exists. A
reader should get current truth from reading the document, not from reconstructing it out of a
changelog.

The line that bounds this — and it is not optional, because applying the rule to the right-hand
column destroys the record it exists to keep:

| Edit in place — asserts current truth | Append — a dated log of events |
|---|---|
| issue bodies | `docs/design/adr/` — supersede, never rewrite |
| `docs/contracts/*` | `docs/parked-findings.md` |
| `docs/feature-matrix.md` and `docs/test-plan.md` rows | a run ledger |
| `CLAUDE.md` norms | a dated audit or findings report |

Renaming a thing means updating what points at it, in the same change. A dangling reference is the
same failure as a wrong document: it misleads every future task, and it is cheaper to fix now than
for the next reader to discover the target is gone.

## The Repo map section in CLAUDE.md

The `CLAUDE.md` norms carry a **Repo map** subsection. It lists the layout, the entry points, the
build and test commands, and where each concern lives, in 40 lines or fewer. The scout stage and
every later stage read it before searching. Keep it current: a change that adds or moves a
top-level directory or an entry point updates it in the same commit.

## The parking file

`docs/parked-findings.md`. **Check first** whether the repository already keeps a backlog file or
a findings convention, and match it rather than creating a second one.

Append findings as you hit them. Keep each short enough to write without breaking flow, and
specific enough to act on later without rediscovering it.

```markdown
- [2026-08-14] `src/exports/csv.ts:88`, the column formatter allocates a new
  Intl.NumberFormat per row, which will show up under large exports.
  Found while working on the CSV export endpoint. Severity, perf, non-blocking.
```

File and line, what you saw, what task you were on when you saw it, rough severity. **Do not
include a proposed fix longer than a sentence** — writing the fix is how a parked item turns back
into work.

## The closing summary

```markdown
## Done
1. [criterion], [where it landed, e.g. file or test name]
2. ...

## Verification run
- [command], [result]

## Docs updated
- [contract files changed, and how]
- Feature matrix, [row ID] moved to [status]
- Test plan, [row ID] coverage now [unit / integration / e2e state]

## Blockers handled
- [anything outside the contract you had to fix to make a criterion passable, and why]

## Parked
- [one line per finding, with file reference]
Logged to docs/parked-findings.md. None of these were changed.
```

Keep the parked list **flat and unranked**. Do not editorialize about importance, do not group
items into a suggested phase two, and do not end by asking which one to tackle next. The user
knows where the file is and will decide — offering a next step is how the cycle restarts.

If the parked list is empty, say so and stop. **A short close is a good close.**

If the user reads the parked list and asks for one of the items, that is a **new task**. Give it
its own done contract, however brief, and close it the same way. An approved parked item is not
permission to sweep up its neighbors.

## How this interacts with /work and /backlog

Both commands carry the contract in the **plan file** (`.claude/plans/issue-{N}.md`), which is the
only artifact the plan stage and the exec stage both see:

- The **plan stage** (`work-plan`) writes a `## Definition of done` section into the plan — the
  numbered criteria, the enumerated edge cases, and the commands that prove them. It upgrades a
  thin issue in place first.
- The orchestrator **gates on it**: a plan file with no non-empty `## Definition of done` is the
  blocker `plan stage returned without a done contract`, not something to approve. Without that
  gate the contract is only text in a dispatch prompt, and nothing observes whether it was
  honored — a claim, not an observation.
- The **exec stage** (`work-exec` / `work-exec-opus`) treats that section as the whole of scope,
  runs it before opening the PR, appends out-of-scope discoveries to `docs/parked-findings.md`,
  and updates contracts, the feature-matrix row and the test-plan row **in the same commits as the
  code** — never in a documentation pass, never as a follow-up issue.
- The **closing summary** in `/work` §11 and `/backlog` §9 carries `Docs updated`, `Blockers
  handled` and `Parked`, built from ground truth — `git diff --name-only` over `docs/` in `/work`,
  `git log --name-only` in `/backlog` — rather than from the stage's self-report.
