# Part E. Finding what is already incomplete

Load this when auditing an existing repository for half-finished work — by hand, or as the method
behind `/closure-audit`. For slicing *new* work read `decomposition.md`; for executing a ticket
read `execution.md`.

## What this is

Parts A–D enforce closure **prospectively**: they stop the next issue from being layer-sliced and
the next change from shipping without its docs. They do nothing about what already merged.

This part is their **retroactive** counterpart. Two lines of the Part A definition-of-done are
exactly what an audit re-checks after the fact:

- *"No dead code paths left behind. No unreferenced components, routes, flags, exports, fixtures,
  or feature toggles introduced and abandoned."*
- *"Usable on its own. No follow-up issue is required for a person to get value from this."*

An audit is those two criteria, applied to code that was merged before anyone was checking.

## The rule that makes an audit trustworthy

**A pass that cannot see its target reports BLIND, never clean.**

This is the most expensive failure shape there is, and an audit is where it does the most damage:
*"0 findings"* and *"my grep was wrong"* render identically. A clean report is the outcome everyone
wants, so nobody interrogates it.

So **state the denominator before the count, every time**:

- ✅ `412 route definitions enumerated, 7 with no caller`
- ❌ `7 unwired routes`
- ❌ `no unwired routes found`

The same applies to every truncatable fetch. A result exactly equal to your limit is truncation,
not an answer.

### A zero denominator has three meanings, not two

This is the rule that is easiest to get wrong, and getting it wrong in either direction is
expensive. **Never collapse these three into one**:

| Zero means | When | Disposition |
|---|---|---|
| **n/a** — the producer class does not exist in this stack | nothing corroborates that it should: no config declares it, no script runs it, no dependency provides it | report `n/a`, audit nothing, this is not a gap |
| **BLIND** — your probe is wrong | something *does* corroborate it: a config declares it, a script runs it, a dependency provides it | **blocker.** Report UNAUDITED, never a finding |
| **clean** — the class exists and is genuinely empty | the probe is proven working by a positive control | report `0`, and say what the control was |

**The discriminator is a second, independent signal.** Before calling a zero "n/a", check whether
anything else in the repo says that class should exist — `playwright.config.ts` declaring
`testMatch` globs, a `test:e2e` script, `@playwright/test` in devDependencies. If a second signal
says it exists and your probe found none, **your probe is wrong**, and reporting "no coverage" is
how an audit fabricates a dozen findings against a repo that is fully covered.

Worked example, from the run that produced this rule. A SvelteKit repo returned three zeros:

- `+server.ts` routes: **0** — `svelte.config.js` uses `adapter-static` and no `+server.ts` exists
  anywhere. Nothing corroborates server routes. → **n/a**, correctly nothing to audit.
- e2e specs: **0** — but `playwright.config.ts` declares five `testMatch` globs and `package.json`
  has `test:e2e`. Two corroborating signals. The probe had globbed `*.spec.ts` / `*.test.ts` while
  the repo names them `*.e2e.ts`. → **BLIND.** Reporting it as a coverage gap would have invented
  twelve findings against a repo with a complete Playwright suite.
- `TODO`/`FIXME` markers: **0** — a positive control (`git grep import` → 158 hits) proves the
  grep reaches these files at all. → **clean**, and the control is what makes that claim safe.

### Positive controls

**Prove the probe can find something before you report that it found nothing.** Run the same probe
shape against a pattern you are certain exists — `import`, `function`, the language's most common
keyword — over the same file set. A control that returns zero means the file set or the tool
invocation is wrong, and every count derived from it is void.

Cheap, and it is the difference between "there are no markers" and "I cannot see this code".

## The five signals

### A. Half-wired vertical slices

The core signal, and the one no linter reports. Each is a **producer with no consumer**, or the
reverse:

| Producer | Consumer to look for |
|---|---|
| Route/handler registered | a call site in client code — fetch, RPC, form action, link |
| Component/screen defined | a route that renders it, or a parent that mounts it |
| Migration applied, table/column created | a query, model, or ORM mapping that reads it |
| Module export declared | a single importer anywhere outside its own tests |
| Feature flag introduced | a read site — and a retirement plan if it is permanently on |
| Config key / env var read | a place it is actually set, and documented |

Establish the producer set first — that is your denominator. Then check each for a consumer.

```bash
# Shape of the probe, not a recipe. Adapt the patterns to the stack you detected.
# Denominator first, and print it, so a broken pattern is visible as 0 rather than silent.
rg -n --no-heading "$PRODUCER_PATTERN" -- "$SCOPE" | tee /dev/stderr | wc -l
```

**Tests do not count as consumers.** An endpoint exercised only by its own unit test is exactly
the half-wired case: the layer closed, the capability never reached a person. Exclude test paths
from the consumer search and say that you did.

### B. Explicit in-code markers

The cheap pass. `TODO`, `FIXME`, `HACK`, `XXX`; not-implemented throws; stub returns; skipped
tests (`it.skip`, `xit`, `describe.skip`, `@pytest.mark.skip`, `t.Skip()`, `#[ignore]`);
large commented-out blocks.

Most of these are **not** capability gaps — see the sorting rule below. A `TODO` about a variable
name is a parked finding at best. What earns a ticket is a marker sitting on a path a user reaches:
a skipped test for a shipped capability, a stub return in a handler that is registered and called.

### C. Test-coverage gaps

Per capability, is there a unit, integration, and end-to-end test that actually references it.
Feeds `docs/test-plan.md`'s Gaps column directly, so record it in that shape from the start.

Reference **real file and spec names**, never "covered" — the same rule §D4 states, for the same
reason: a coverage claim you cannot open is one that rots.

Your denominators here are two: how many capabilities you enumerated, and how many test files.
Zero test files found in a repo that has tests means your probe missed the convention.

### D. Contract and documentation drift

`docs/contracts/` disagreeing with the code. A feature-matrix row claiming `Shipped` for something
unreachable. `CLAUDE.md` describing a stack the repo no longer uses.

§D5 already sorts these for you: **a document that disagrees with the code goes in the report, not
the parking file.** A wrong document misleads every future task in a way a parked improvement does
not.

### E. Backlog hygiene

The backlog is part of the audit surface, not just its output:

- **Thin issues** — a title and a sentence, no acceptance criteria. Upgradeable in place.
- **Layer-sliced issues** — "add the endpoint", "build the UI", "wire it up". The A1 failure,
  still in the backlog.
- **Epics whose last card is integration** — "wire everything together", "polish", "add missing
  tests". Per A4, that means the decomposition was wrong.
- **Superseded issues** — the code already shipped. Evidence is a file and line, and the finding
  is a comment on the issue, never a silent close.
- **Ambiguous dependency lines** — a line carrying a dependency keyword and more than one `#N`, or
  prose that a permissive parse reads as an edge and a strict one does not. Parse twice and report
  what the two readings disagree about; that diff *is* the check.

## Sorting a finding: ticket, report, or park

This is the decision that keeps an audit from generating two hundred tickets nobody will read.

| The finding is… | Goes to |
|---|---|
| A capability a person cannot yet get, phrasable as "a person can *X*" | **a new issue**, sliced per A1, with a done contract |
| A document that contradicts the code | **the report**, raised explicitly — §D5 |
| An existing issue that is thin or mis-sliced | **an edit to that issue**, rewritten in place |
| An existing issue superseded by shipped code | **a comment on that issue** carrying the evidence — changing its disposition is the user's call |
| Anything else — a nit, a perf smell, a naming inconsistency, a refactor | **`docs/parked-findings.md`**, flat |

**The test is whether you can write the Capability line.** `decomposition.md` §A3 already forbids
issues for work with no acceptance criteria — "improve error handling", "clean up the export
module". If a finding cannot be phrased as something a person gains, it is not a ticket, however
real it is. That single filter is what makes the output actionable rather than exhausting.

## Verifying a finding before you report it

Audit findings are cheap to generate and expensive to act on, so verify before reporting. Three
states, one pass:

- **CONFIRMED** — you can name the producer, the missing consumer, and what a person cannot do as
  a result.
- **PLAUSIBLE** — the mechanism is real, but reachability is uncertain: dynamic dispatch, a
  registry populated at runtime, a framework convention your probe cannot see.
- **REFUTED** — constructible from the code. The consumer exists and you found it; the export is
  a public API entry point; the flag is read through a generated accessor. **Quote the line that
  proves it.**

Report CONFIRMED and PLAUSIBLE; drop REFUTED.

**PLAUSIBLE by default.** Do not refute a finding merely because a consumer *might* exist
somewhere you did not look — that is the blind-monitor failure wearing a different hat. Refute only
when you can point at the thing that disproves it. Dynamic wiring is the common honest PLAUSIBLE:
say the probe cannot see it, rather than guessing either way.

## Ranking, and the one place ranking is wrong

Rank the **report** by blast radius: a capability nobody can reach outranks a missing e2e test,
which outranks a `TODO`. A reader who acts top-down should be spending their time well.

But the **parking file stays flat and unranked** — `execution.md` §B4 is explicit about that, and
it is not an inconsistency. A ranked report is something you act on now; a ranked parking file is
a second backlog wearing a disguise, and the ranking invites exactly the "which one next?" cycle
the parking file exists to stop.

## Writing the report so it does not rot

`COMMAND-AUDIT.md` earned this one the hard way, and it is worth quoting:

> **A findings report written in the present tense becomes a lie the moment it is acted on.** Every
> Part 1 body still says the bug *is* happening. A one-line "Status: remediated" 470 lines away did
> not counteract that, and the file kept reading as live work for months.

So: **give every finding its own disposition line, at the point of reading** — not a status table
elsewhere in the file. `ticketed as #N`, `parked`, `fixed in <sha>`, `open`. A finding whose
disposition is only recorded somewhere else will be re-litigated by the next person to open the
file, and the audit becomes work rather than saving it.

Date the report, and say what it was scoped to. An undated audit of an unnamed subtree cannot be
re-run and compared, which is the only thing that tells you whether the debt is shrinking.
