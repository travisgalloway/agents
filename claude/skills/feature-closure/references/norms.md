# Part C. Codebase norms in CLAUDE.md

Load this **once per repository**, when its `CLAUDE.md` has no norms section or a stale one.
Revisit when the stack changes.

A definition of done is only checkable if the codebase's conventions are written down. Otherwise
every issue re-litigates where files go, which test runner to use, and what an error response
looks like.

## C1. Derive the norms, do not invent them

**Read the repository before writing anything:**

- Package manifests and lockfiles, for the stack and versions
- Config for the linter, formatter and typechecker
- The test setup, and how suites are actually invoked
- The directory layout, and where recent features actually landed
- Two or three recent merged changes, to see the real house style rather than the aspirational one

Where the codebase is **inconsistent**, say so and ask which way is correct rather than silently
picking one. Where it is **consistent**, describe what is already true. A norms file that
documents an aspiration instead of the code is worse than no norms file, because every future task
trusts it.

## C2. What to write

Add or update a norms section in the repository's `CLAUDE.md`. Keep it **dense and specific to
this stack**. Cover at least:

- **Stack and versions**, including anything with a migration in flight
- **Directory layout**, and where a new feature's files belong on each layer
- **A Repo map** of 40 lines or fewer: layout, entry points, build and test commands, and where
  each concern lives. Agents read it before searching, so keep it current when structure moves
- **Naming conventions** for files, components, hooks, endpoints, database objects
- **State management and data fetching**, with the one blessed way to do it
- **API contract conventions** — request and response shapes, status codes, error envelope,
  pagination, versioning
- **Validation and error handling**, on both client and server, including what the user sees
- **Database and migration conventions** — how migrations are generated, reviewed, rolled back
- **Test layout**, what belongs at each level, and the exact commands for unit, integration and
  Playwright runs
- **Playwright specifics** — selector strategy, whether `data-testid` is required, fixtures, and
  how test data is seeded and cleaned up
- **Lint, format, typecheck and build commands**, and which of them gate a merge
- **Logging, telemetry and feature flags**, including how a flag is retired
- **Commit, branch and pull request conventions**
- **The `docs/` layout** from `living-docs.md` — what lives where, and the rule that contracts,
  feature matrix and test plan are updated in the same change as the code they describe
- **Anything the codebase deliberately does not do** — often the most useful section

## C3. Write the shared definition of done into CLAUDE.md

Add a section stating that **every functionality request — whether it arrives as an issue, a
design doc, or a message in a chat — must have an explicit definition of done before
implementation starts**, and that the default criteria are the ones in `decomposition.md` §A2.
Include the template **inline** so nobody has to go looking for it, and name the parking file
location.

State the escalation plainly: **if a request arrives without criteria, the first step is to write
them and confirm them, not to start coding.**

## C4. Keep it honest

`CLAUDE.md` is load bearing, so **stale content is worse than missing content**.

- When you change a convention as part of an issue, update the norms **in the same change**.
- When you notice `CLAUDE.md` contradicts the codebase, that is a finding worth parking — and
  worth **raising in the close-out** rather than burying in the list. A wrong document misleads
  every future task in a way a parked improvement does not.

## Scope note

Writing the norms section is itself a task, and it obeys Part B: it is **not** a licence to fix
the inconsistencies you find while reading. Document what is true, park what is wrong, and let the
user decide which to reconcile. A norms pass that quietly renames things is exactly the divergence
this skill exists to prevent, arriving under the banner of the skill itself.
