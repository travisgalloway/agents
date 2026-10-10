# Design lens

Method for `/design-audit` and the design lens of `/audit`. Read `review-method.md` first. This
file adds the two passes, their denominators, and their `n/a` conditions. Finding prefix: `DSN`.

## Pass D1: conformance to the written design

**Question.** Does the code do what the repository's design documents say it does?

**Sources, in this order:**

1. `docs/design/` and any design notes the repository keeps elsewhere
2. accepted ADRs under `docs/design/adr/` or `docs/adr/`. Skip a superseded ADR and follow its
   successor
3. `docs/contracts/`
4. the architecture or norms section of `CLAUDE.md`

**Method.** Extract every checkable claim from those sources. A claim is checkable when code can
confirm or contradict it: "every write goes through `repo/`", "exports are streamed, never
buffered", "the session token lives in an httpOnly cookie". Then verify each claim against the
code, and quote the line that confirms or contradicts it.

**Denominator.** Claims extracted, over documents read. Print both.

**`n/a`.** None of the four sources exists. A repository with no design documents has nothing to
conform to, and D1 reports `n/a` with the list of paths it checked. D2 still runs.

**When `/audit` also runs the closure lens.** Closure pass D owns `docs/contracts/` drift and
dangling references. D1 skips `docs/contracts/` in that case and says so on its coverage line, so
the gate never shows one contradiction twice.

**Sorting.** A contradicted claim is `report` by default, per `living-docs.md` §D5, because the
document or the code could be the wrong one. It becomes `ticket` only when the claim is a
security or data-integrity property, since the code is then the side that must change.

| Rule slug | Finding |
|---|---|
| `doc-contradicted` | the code does the opposite of the claim |
| `doc-unimplemented` | the claim describes behavior that no code implements |
| `adr-violated` | an accepted ADR's decision is not followed |

## Pass D2: architectural soundness

**Question.** Independent of any document, does the structure hold together?

**Dependency graph.** Use the stack's own tool when it is installed, and state which one ran:

| Stack | Tool | Fallback |
|---|---|---|
| JavaScript / TypeScript | `madge --json` or `depcruise --output-type json` | parse `import` and `require` with `rg` |
| Go | `go list -deps -json ./...` | none needed |
| Python | `pydeps --show-deps` | parse `import` and `from` with `rg` |
| Rust | `cargo modules dependencies` | parse `use crate::` with `rg` |

The positive control is the module count. A graph with zero edges over a nonzero module count
means the parse broke, and D2 is BLIND.

**Checks, each with its own denominator:**

| Rule slug | Check | Denominator |
|---|---|---|
| `import-cycle` | a cycle in the module graph | modules in the graph |
| `layering-violation` | an import against the stated or inferred layer order, for example UI importing the database client | edges checked |
| `handler-no-authz` | a registered handler that mutates state or reads user data with no authorization check on its path | handlers enumerated |
| `swallowed-error` | a catch or `except` that neither rethrows, returns an error, nor logs with context | catch sites enumerated |
| `unawaited-async` | a promise or future whose result and failure are both dropped | async call sites enumerated |
| `shared-mutable-state` | module-level mutable state written from request or job paths | module-level bindings enumerated |
| `read-modify-write-race` | a read, a computation, and a write to the same record with no transaction, lock, or version check | write sites enumerated |

**Inferring the layer order.** Prefer an order the repository states in `CLAUDE.md` or an ADR.
Otherwise infer it from directory names (`routes` → `services` → `repo` → `db`) and state the
inferred order on the coverage line. An inferred order makes every `layering-violation` finding
PLAUSIBLE, never CONFIRMED.

**Sorting.** `handler-no-authz` and `read-modify-write-race` are high severity. A single
`layering-violation` is low. When one rule fires in more than five places, collapse the findings
into one `decision` item with the count. The question for a person is whether the rule still
holds, and five near-identical tickets do not ask it.

**Framework conventions.** Authorization applied by a router-level middleware, a decorator, or a
framework hook counts as present. When the probe cannot see such a mechanism, the finding is
PLAUSIBLE, and the evidence says which mechanism could not be checked.
