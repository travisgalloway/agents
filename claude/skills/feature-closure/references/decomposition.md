# Part A. Breaking a design into backlog issues

Load this when breaking a design, spec or feature request into issues, or grooming an existing
backlog. For executing one of the resulting issues, read `execution.md` instead.

## A1. Slice vertically, never by layer

An issue is a **thin, complete path through every layer the capability touches**. Narrow the
capability as much as you need to keep an issue small. Never narrow it by removing depth.

**Wrong, sliced by layer**

1. Add case export API endpoint
2. Add export button and modal to case list UI
3. Wire the modal to the endpoint
4. Add tests for export

Nothing is usable until issue 3 lands, and issue 4 is a placeholder that will be dropped when the
sprint gets tight.

**Right, sliced by capability**

1. A user can export a single case to CSV with the default column set, from the case detail page
2. A user can select a date range on the case list and export the matching cases
3. An admin can configure which columns appear in exports

Each of those ships end to end. Each is demonstrable. If only the first one lands, the feature is
smaller than planned but **real**.

If a capability genuinely cannot be sliced thin enough to fit one issue, one preparatory issue is
acceptable — a schema migration, a shared client wrapper. Mark it explicitly as an **enabler** in
the issue title, keep it to **one**, and make it a hard prerequisite of the very next issue so it
cannot sit in the backlog as orphaned infrastructure.

## A2. Every issue carries a definition of done

Write the criteria **into the issue body**. Do not link to a general standard and assume it will
be read. Tailor each item to the actual capability, and **delete** any layer the issue truly does
not touch rather than leaving a hollow checkbox.

```markdown
## Capability
One sentence, phrased as something a person can do when this is finished.

## Scope
In scope, as bullets. Then, explicitly, out of scope, as bullets.

## Definition of done
- [ ] End to end, every layer this touches. UI renders and is reachable through
      real navigation, API endpoint is registered and documented, persistence
      layer migrated and applied.
- [ ] Happy path proven to work against a running system, not just in unit tests.
- [ ] Edge cases enumerated below are handled and covered by tests.
- [ ] Unit tests for the logic. Integration tests for the API contract, including
      status codes and error shapes. Playwright test for the user-visible flow.
- [ ] No form validation errors, no unhandled API errors, no console errors or
      warnings in the exercised paths.
- [ ] Typecheck, lint, and build all clean.
- [ ] Full existing test suite still green. No unrelated or tangential behavior
      changed.
- [ ] No dead code paths left behind. No unreferenced components, routes, flags,
      exports, fixtures, or feature toggles introduced and abandoned.
- [ ] Usable on its own. No follow-up issue is required for a person to get value
      from this.
- [ ] Contracts in `docs/contracts/` reflect what actually shipped. The feature
      matrix row and the test plan row are updated in the same change as the code.

## Edge cases
Enumerate them here rather than gesturing at them. Empty result set,
permission denied, expired session, concurrent edit, oversized payload,
network failure mid-request, and whatever else the capability actually
exposes.

## Verification
The exact commands or steps that prove the above. Test file paths, the
Playwright spec name, the manual check if one is unavoidable.
```

**The verification section is what turns the checklist from a wish into a contract.** An item
nobody can check is not a criterion.

## A3. Sizing and ordering

Order issues so value lands early and each one leaves the product **shippable**. After any issue
in the sequence merges, the branch should be releasable — not feature complete, but not broken and
not half wired.

If an issue's definition of done cannot fit in a reviewable change, split it by **narrowing the
capability further**: by user-facing scenario, by entity, by permission tier, by input type. Never
split by layer, and never split by leaving the tests for later.

Do not create issues for work that has no acceptance criteria — "improve error handling", "clean
up the export module". If that work matters, tie it to a capability that requires it, or leave it
in the parking file where findings live.

## A4. Epics and milestones

When issues roll up into an epic or milestone, the same rule applies one level higher.

- **The epic's end state must be fully functional on its own.** If the last issue in an epic is
  called "wire everything together", "integration and polish", or "add missing tests", the
  decomposition was wrong. Go back to A1.
- Write the epic's own definition of done in the tracker, phrased as the complete capability a
  person gains, plus the same end-to-end / tests-clean / nothing-broken / no-dead-paths criteria
  applied across the whole set.
- **Each constituent issue must still stand alone.** An epic is a grouping for planning, not a
  permission slip for issues that only make sense together.
- If the epic were cancelled after any given issue, what shipped so far should be coherent and
  worth keeping. If cancelling would leave the codebase with an unreachable UI or an unused
  endpoint, reorder or re-slice.

## A5. Before writing anything to the backlog

**Check the repository's existing issue conventions first.** Look for issue templates in
`.github/`, an existing backlog file, or the format of recent issues. Match what is there rather
than imposing this template wholesale — keeping the definition-of-done and verification sections.

Then **show the user the proposed decomposition** as a list of capabilities with a one-line
rationale for the ordering, before creating the issues. Getting the slicing wrong is much more
expensive than getting an implementation detail wrong, and it is the thing worth a round trip.

## Under /backlog specifically

`/backlog` enumerates and topologically sorts an existing backlog; it does not re-slice one. So
the decomposition above has to be right **before** a `/backlog` run, not during it — an unattended
run across a layer-sliced backlog merges every layer issue and produces nothing usable, and every
row reads `✓`. If you are grooming in preparation for `/backlog`, that is the moment this part
applies. Note also that `/backlog` excludes `epic`-labelled issues by default, which only works if
the epic's constituent issues each stand alone per A4.
