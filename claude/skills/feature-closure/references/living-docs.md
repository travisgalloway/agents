# Part D. Living documentation in docs/

Load this on any task that crosses a module, service or API boundary, and on any task that changes
what a capability can do.

Contracts and status trackers exist so scope can be checked against something **outside your
context window**. They are only worth having if they are true, so the governing rule is:

**Documentation changes ride along with the code change that makes them true.** Never batch them
into a documentation pass, and never open a follow-up issue to reconcile them.

## D1. Layout

Establish this under `docs/`, **adapting names to any convention the repository already uses**
rather than duplicating an existing structure.

```
docs/
├── design/                 One document per capability area. What the thing is
│   │                       for, the model it assumes, decisions and their
│   │                       rejected alternatives, known constraints.
│   └── adr/                Dated, numbered, immutable once accepted. Supersede
│                           rather than edit — an ADR records why a decision was
│                           made at a time, so rewriting it destroys the record.
│                           The one deliberate exception to fix-in-place (§D5).
├── contracts/
│   ├── api/                External surface. One document per resource or
│   │                       service. Endpoints, request and response shapes,
│   │                       status codes, error envelope, auth requirements,
│   │                       pagination, versioning and deprecation notes.
│   └── interfaces/         Internal boundaries. Module and package public
│                           surfaces, shared types, events and their payloads,
│                           background job signatures, feature flag semantics.
├── feature-matrix.md
├── test-plan.md
└── parked-findings.md
```

**If the API contract is generated** — an OpenAPI document emitted from code or from a schema —
do not hand-maintain a second copy. Point to the generated artifact from `docs/contracts/api/` and
keep only what generation cannot express: intended semantics, error meanings, deprecation
timelines.

## D2. Contracts are read first and written before implementation

**Before implementing anything that crosses a boundary, read the relevant contract.** It is the
authority on what the other side expects.

**Write or amend the contract before the implementation, not after.** Getting the shape agreed
first is cheaper than discovering a mismatch in a Playwright run.

**When implementation reveals the contract is wrong or unworkable, that is not a finding to park.**
Stop, state the mismatch, propose the amended contract, and get confirmation before continuing.
Silently implementing something other than what the contract says is the most expensive drift
there is, because every future task will trust the document.

**Contracts describe behavior, including failure.** A contract that lists only the success
response is incomplete. Error codes, validation failures, and the exact shape a client receives
when something goes wrong belong in the document — those are the paths the edge-case criteria in
`decomposition.md` §A2 require you to test.

## D3. The feature matrix

`docs/feature-matrix.md` is the single view of what exists and how far along it is. Organize it
**by capability area**, matching the design documents, with a table per area rather than one flat
table for the whole product. Logical grouping by domain is what makes it scannable. Ordering
inside an area follows **the user's path through the capability**, not the order things were built.

Give every capability a **stable ID** and use that ID in issue titles, test names and the test
plan, so the three can be cross-referenced without guessing.

```markdown
## Case export

| ID | Capability | UI | API | Data | Status | Issue | Contract |
|----|-----------|----|----|------|--------|-------|----------|
| EXP-1 | Export one case to CSV from case detail | done | done | n/a | Shipped | #412 | contracts/api/exports.md |
| EXP-2 | Export a date filtered set from case list | done | done | done | In progress | #418 | contracts/api/exports.md |
| EXP-3 | Admin configures export columns | none | none | none | Planned | #419 | contracts/api/exports.md |
```

**Per-layer columns are deliberate.** They make a half-sliced capability visible instead of
letting it hide behind a single "in progress" label — exactly the failure `decomposition.md` is
trying to prevent. If a capability sits at API `done` and UI `none` for any length of time, that
is a signal the slicing was wrong.

**Status vocabulary is fixed**: `Planned`, `In progress`, `Shipped`, `Deprecated`. Nothing else,
and in particular nothing that means *partially done* — that state lives in the per-layer columns.

**A capability moves to `Shipped` only when its full definition of done passes.** Not when the
code merges, not when it works locally. If you find yourself wanting to write "Shipped" with an
asterisk, it is not shipped.

## D4. The test plan

`docs/test-plan.md` mirrors the feature matrix **row for row, keyed by the same IDs**, and tracks
coverage by test type so gaps are visible rather than assumed.

```markdown
## Case export

| ID | Unit | Integration | E2E | Edge cases covered | Gaps |
|----|------|-------------|-----|--------------------|------|
| EXP-1 | `csv.test.ts` | `exports.api.test.ts` | `exports.spec.ts` | empty case, permission denied, oversized export | none |
| EXP-2 | `range.test.ts` | `exports.api.test.ts` | none | invalid range, empty result | no e2e for the date picker |
```

**Reference actual file or spec names, not descriptions of intent.** A row saying "covered" with
nothing to open is how coverage claims rot.

**State gaps explicitly and leave them visible.** An empty gaps column is a claim you are making,
so only write it when it is true. A known gap in the plan is useful information; a hidden gap is a
bug waiting to be found by a user.

Keep the test-type columns **aligned with what the repository actually runs**, adding a manual
column only where automation is genuinely impossible — and naming the steps if so.

## D5. Keeping it honest

- When a task changes behavior, update the **contract, the matrix row and the test-plan row in the
  same commit as the code**.
- When a capability is removed, mark it `Deprecated` **with a date** rather than deleting the row,
  and remove the row only once the code and its tests are gone. This is **deferred deletion, not an
  annotation**: the row has a terminating condition and goes away when it is met. That is why it is
  not a violation of the fix-in-place rule below.
- **Fix in place; do not annotate.** When a contract, a matrix row, or a test-plan row becomes
  wrong, rewrite it. Do not append "(changed 2026-08)" beside the stale text, and do not leave a
  reference — a file path, a spec name, an issue number, a section — pointing at something that no
  longer exists. These documents assert *current truth*; a reader must get it by reading, not by
  replaying edits.
- **Two things here are append-only by design, and the rule above does not touch them.**
  `docs/design/adr/` is superseded rather than edited, because an ADR records *why a decision was
  made at a time* — rewriting an accepted one destroys exactly the thing it exists to keep. And
  `docs/parked-findings.md` is a dated log of observations, appended to and never rewritten. The
  distinction that separates them from everything else: **a document asserting current truth is
  edited; a dated log of events is appended to.**
- **Audit as you pass through.** If you open a contract while working and notice it disagrees with
  the code, or find a matrix row claiming `Shipped` for something that is not reachable, **raise
  it in the close-out** rather than burying it in the parked list. A wrong document misleads every
  future task in a way a parked improvement does not.

## Under /work and /backlog specifically

The docs obligation is one criterion in the plan file's `## Definition of done`, not a separate
plan section — so the exec stage sees it in the same list as everything else and it closes with
the rest. Two consequences worth stating:

- The doc edits land in the **exec stage's own commits**, so they arrive in the PR and are
  reviewed with the code that made them true. There is no later pass in which to do this — the
  stage returns, the branch merges, and `/automerge` deletes it.
- The closing summary's `Docs updated` section is built from `git diff --name-only` over `docs/`,
  **not** from the stage's report. A stage that says it updated the matrix and did not is
  indistinguishable, in its return line, from one that did.
