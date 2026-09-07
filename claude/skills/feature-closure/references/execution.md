# Part B. Executing an issue

Load this when implementing an issue, fixing a bug, or making any code change. For breaking a
design into issues, read `decomposition.md` instead.

## B1. Establish the done contract before writing code

Do this **first**, before opening implementation files.

Find the authoritative source of scope, in this order:

1. The issue or ticket referenced in the user's message, in the branch name, or in the current
   commit context
2. A spec, design doc, RFC or ADR in the repository that covers this work
3. An acceptance list already committed alongside the feature

**If the issue was written under Part A**, its definition of done is the contract. Restate it back
as a numbered list and start.

**If the issue predates this skill or is thin, upgrade it in place.** Rewrite its body to the Part
A template, fill in the edge cases and verification steps, and confirm with the user before
implementing. An issue that says only "add CSV export" is not a contract, and starting from it
guarantees the exact drift this skill prevents.

**If no issue exists at all**, say so plainly, draft the acceptance list from the user's request
using the Part A template, and get a yes before proceeding.

**Write the confirmed contract somewhere durable** so it survives context compaction and session
restarts. Under `/work` and `/backlog` that place is the plan file's `## Definition of done`
section — already the handoff artifact, already excluded from commits. Outside those commands, use
the parking file or a scratch file in the working tree that you delete before finishing.

If the spec is genuinely ambiguous on a point that **changes the implementation**, ask about that
one point before starting. Ask **once, batched**, not repeatedly through the task.

## B2. Implement only what the contract covers

While working, hold two questions apart:

- **Does this change make a criterion pass?** → in scope. Do it.
- **Is this an improvement, a latent bug, a naming inconsistency, a missing test elsewhere, a
  dependency concern, or a refactor opportunity?** → a finding. Park it.

**One exception.** If something genuinely blocks a criterion from being satisfiable *at all*, it
is not a finding, it is part of the work. A missing migration that prevents the endpoint from
running is a blocker. A poorly named variable two functions away is not. When you take on a
blocker, note it in the closing summary and why — so the user can see where the diff grew and
agree with the reason.

Resist scope drift in these specific shapes, which are the common ones:

- Fixing an unrelated bug you noticed in a file you had to touch anyway
- Refactoring surrounding code to make your change fit more elegantly
- Adding tests for existing untested code near your change
- Upgrading, replacing or reconfiguring a dependency
- Generalizing a concrete implementation because a future case might need it
- Applying a pattern consistently across files the contract did not name

Each of those is a reasonable thing to want. **None of them is this task.**

**Note what is *not* scope drift.** Tests, edge cases, error states, and wiring the change through
to something a person can reach are all **inside** the contract. Deferring them is not discipline,
it is the layer-slicing failure showing up inside a single issue.

## B2a. A statement your change falsified is in scope

Parking is for things you *noticed*. It is not for things you *broke*.

If your change makes an existing statement wrong — a contract that describes the old response
shape, a comment naming a function you renamed, a matrix row, a README step, a reference to a file
you moved — **correcting it is part of the change**, not a finding. It was true before you started
and it is false because of you.

Fix it **in place**. Do not append "(now returns 400)" beside the old line, do not leave a
`NOTE: superseded` marker, and do not leave a reference pointing at a thing that no longer exists.
The next reader should not have to reconstruct current truth from a changelog.

The test is causal, and it is quick: **would this still be wrong if I reverted my change?** If yes,
it is a finding — park it. If no, you falsified it, so you fix it.

This does not extend the contract. It is the same criterion Part A already states — *"contracts
reflect what actually shipped; the feature matrix row and the test plan row are updated in the same
change as the code"* — applied to every other statement your change touched.

## B3. Park findings as you go

Maintain the parking file at `docs/parked-findings.md`, or wherever the repository already keeps a
backlog if one exists — **check for an existing convention before creating a new file.**

Append findings as you hit them. Keep each one short enough to write without breaking your flow,
and specific enough to act on later without rediscovery.

```markdown
- [2026-08-14] `src/exports/csv.ts:88`, the column formatter allocates a new
  Intl.NumberFormat per row, which will show up under large exports.
  Found while working on the CSV export endpoint. Severity, perf, non-blocking.
```

Include the file and line, what you saw, what task you were on when you saw it, and a rough
severity. **Do not include a proposed fix longer than a sentence.** Writing the fix is how a
parked item turns back into work.

## B4. Close out

**You are done when every criterion passes, not when you run out of things to improve.** Walk the
list explicitly and confirm each one against the actual diff and an actual run of the tests. Run
the **full suite**, not only the tests you wrote — "nothing unrelated broke" is a criterion, and
it is the one most often assumed rather than checked.

A criterion is closed by an **observation**, never by a claim. `git log -1` for committed, `gh pr
view --json state` reading `MERGED` for merged, a `stat` newer than the run that wrote it for a
file written, a green run you actually saw for tests passing. A subagent's report and a command's
exit code are both claims.

Then produce the closing summary:

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

Keep the parked list **flat and unranked**. Do not editorialize about how important the items are,
do not group them into a suggested phase two, and do not end by asking which one to tackle next.
The user knows where the file is and will decide. **Offering a next step is how the cycle
restarts.**

If the parked list is empty, say so and stop. A short close is a good close.

## B5. When the user does want to expand scope

If the user reads the parked list and asks for one of the items, **that is a new task**. Start
over at B1 for it. Give it its own definition of done, however brief, and close it the same way.
Do not treat an approved parked item as permission to sweep up its neighbors.

## Under /work and /backlog specifically

The exec stage does not do B1 — the plan stage already did, and the contract is sitting in the
plan file's `## Definition of done`. So:

- **Read the plan file first and treat that section as the whole of scope.** Do not re-derive it.
  If the contract no longer matches reality, that is a **blocker to surface**, not a licence to
  substitute your own judgement — the same rule the exec agent already follows for the design.
- **Run the Definition of done and make it pass before opening the PR.** A PR opened against an
  unrun contract is the `⚠ merged, verification partial` row in `/backlog`'s summary — merged
  legitimately, never proven.
- **Park to `docs/parked-findings.md`**, which is committed and rides the PR. That is deliberate:
  a findings list nobody can see in the repo is a list nobody reads. It is not a working artifact
  and does **not** belong in `.git/info/exclude` alongside the plan files.
- **Docs ride along in the same commits as the code**, never a documentation pass and never a
  follow-up issue. See `living-docs.md`.
- Report the parked count in the stage's one-line return. The return contract stays as it is — a
  path, a status, one line — so it is a count, not a list; the orchestrator reads the file.
