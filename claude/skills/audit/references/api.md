# API lens

Method for `/api-audit` and the API lens of `/audit`. Read `review-method.md` first. This file adds
the two passes, their denominators, and their `n/a` conditions. Finding prefix: `API`.

## Pass P1: the API surface

**Question.** Is the API consistent with itself, and safe for a caller to retry?

**Enumerate first.** List every externally reachable endpoint, RPC (remote procedure call)
method, GraphQL resolver, or CLI subcommand the repository exposes. The list is the denominator.
The positive control is the router or schema file itself: a registered route count of zero next
to a nonzero router file count means the probe is wrong.

**`n/a`.** Nothing corroborates an external API: no router, no server dependency, no schema file,
no `bin` entry. A static site or a pure library reports `n/a`. A library with public exports
reviews those exports under P1 instead, and says so.

**Establish the convention before judging.** For each dimension below, count what the majority of
endpoints do, and print that count. The majority is the convention, unless `docs/contracts/` or an
ADR states a different one. A deviation from the convention is the finding.

| Rule slug | Dimension |
|---|---|
| `naming-inconsistent` | path and field casing, plural or singular resources, verb placement |
| `status-code-misuse` | 200 on failure, 500 for a validation error, 404 and 403 conflated where that leaks existence |
| `error-envelope-drift` | an error body shape that differs from the convention |
| `pagination-inconsistent` | cursor on one list and offset on another, or an unbounded list endpoint |
| `unversioned-breaking-change` | a field removed or retyped with no version bump, judged against `git log` on the handler |
| `non-idempotent-mutation` | a create or payment path with no idempotency key and no natural unique constraint |
| `unvalidated-input` | a handler that reads request input with no schema or validation at the boundary |

**Sorting.** `non-idempotent-mutation` on a path that moves money or creates records a caller
cannot deduplicate is high. `unvalidated-input` on a mutating handler is high. An unbounded list
endpoint is medium. Naming drift is low.

## Pass P2: the data model

**Question.** Can the schema change safely, and does it agree with the code that reads it?

**Enumerate first.** Migrations, and tables or collections. Print both counts. The positive control
is the migration directory's file count against the migration tool's own listing, for example
`prisma migrate status`, `alembic history`, or `rails db:migrate:status`. Use the listing only when
it runs without a live database, and say which one ran.

**`n/a`.** Nothing corroborates a persistent store: no ORM (object-relational mapper), no
migration tool, no database driver in the dependencies, no schema file. When any one of those
exists and the migration count is zero, P2 is BLIND.

| Rule slug | Check |
|---|---|
| `migration-not-null-no-default` | a `NOT NULL` column added to an existing table with no default and no backfill |
| `migration-destructive` | a column or table drop, or a rename, with no preceding step that moves readers off it |
| `migration-locking` | an operation that rewrites or locks a large table, such as a non-concurrent index build on Postgres |
| `missing-index` | a foreign key, or a column used in a query predicate, with no index |
| `enum-drift` | a database enum and the code's enum or union type disagree |
| `nullability-drift` | a nullable column typed as non-null in the code, or the reverse |
| `duplicate-source-of-truth` | the same fact stored in two places with no stated owner |

**Reading query predicates.** Collect the columns in `WHERE`, `JOIN` and `ORDER BY` clauses, and in
ORM `where` and `orderBy` calls. A predicate built at runtime makes `missing-index` PLAUSIBLE.

**Sorting.** `migration-destructive` and `migration-not-null-no-default` on an unapplied migration
are high. On a migration already applied in production they are `report`, because nothing can be
changed and the finding documents the risk. The lens cannot see production, so it asks at the gate
when the applied state is not stated in the repository. `missing-index` is medium.
