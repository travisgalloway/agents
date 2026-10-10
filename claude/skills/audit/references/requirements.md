# Requirements lens

Method for `/requirements-audit` and the requirements lens of `/audit`. Read `review-method.md`
first. This file adds the pass, its denominator, and its `n/a` condition. Finding prefix: `REQ`.

## Pass R1: shipped work against its acceptance criteria

**Question.** Does each thing the backlog calls done satisfy the criteria it was closed against?

**Sources.**

1. Issues closed as completed within the scope. The default scope is the last 90 days, and a
   `since=` token overrides it. An explicit `#N` selector overrides both.
2. Rows in `docs/feature-matrix.md` whose status is `Shipped`, when the file exists.

Fetch the closed issues once, in full:

```bash
# --limit 1000 because the default of 30 silently drops older closures. `stateReason` separates
# COMPLETED from NOT_PLANNED: an issue closed as not planned has no criteria to verify.
gh issue list --repo "$owner/$repo" --state closed --limit 1000 \
  --json number,title,body,stateReason,closedAt,labels,milestone
```

**A result exactly equal to `--limit` is truncation.** Raise the limit and re-fetch. Filter to
`stateReason == "COMPLETED"` and to the `closedAt` window after the fetch, never before it, so the
truncation check sees the whole set.

**Extract criteria.** A criterion is a checkbox line under an "Acceptance criteria" or "Definition
of done" heading, or a line in a done contract. Each criterion gets its own row. An issue with no
extractable criteria is counted separately as `no-criteria`, and it is not a finding.
`/closure-audit` pass E already reports thin issues.

**Denominator.** Criteria extracted, over issues fetched in scope. A nonzero issue count with zero
criteria means the extraction broke, unless every issue in scope is genuinely thin. Check three
issue bodies by hand before calling it either.

**`n/a`.** No closed issue in scope and no `Shipped` matrix row. A repository whose backlog lives
in a file uses the checked items in that file instead, per `/closure-audit` Step 1.2.

**Verify each criterion.** Find the code that implements the criterion and the test that exercises
it. Quote both.

| Verdict | When |
|---|---|
| CONFIRMED unmet | the code contradicts the criterion, or the behavior is absent and you can name where it should be |
| PLAUSIBLE unmet | the code exists and no test exercises the criterion, or the behavior depends on configuration you cannot see |
| REFUTED | the code satisfies it and a test proves it. Drop the row |

| Rule slug | Finding |
|---|---|
| `criterion-unmet` | the behavior the criterion describes does not exist or is wrong |
| `criterion-untested` | the behavior exists, and no test references it |
| `matrix-overclaims` | a `Shipped` row whose capability fails one of its criteria |

**Sorting.** `criterion-unmet` is high and passes the ticket test by construction, because the
criterion is the acceptance check. `criterion-untested` is medium. It becomes a ticket only when
the criterion touches a security boundary or data integrity, and it is parked otherwise.
`matrix-overclaims` is `report`, since the fix is a matrix edit.

**The closed issue is never reopened.** Its disposition is the user's call. After the gate, the
lens comments on the closed issue with the evidence and the new issue's number, and creates the
new issue with the finding ID in its title.
