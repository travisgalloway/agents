# Regression tests for the `~/.claude` command suite

```bash
bash ~/.claude/tests/run-all.sh
```

No network calls, no live PRs. Every `gh` call is served by a stub on `PATH`; git scenarios build
throwaway repos under `$TMPDIR`.

`run-all.sh` prints the assertion total when it finishes. This file deliberately does **not**
restate it: a hardcoded count is wrong on the next commit and nothing notices, which is the exact
rot `reference-integrity.sh` exists to catch.

| Suite | Pins |
|---|---|
| `lint-frontmatter.sh` | Only documented frontmatter keys in `skills/*/SKILL.md` and `agents/*.md`. Catches the `disallowed-tools` (skills, kebab) vs `disallowedTools` (agents, camel) mixup — the wrong spelling is silently ignored, turning an enforcement mechanism into a no-op. |
| `jq-run-lookup.sh` | The claude-review workflow-run lookup in `skills/automerge` §2.4 and `hooks/automerge-rewake.sh`. A null `.workflow_runs` field must not abort jq, because both call sites swallow the error and read the empty result as "no review run for this commit". Also pins the two halves that make the answer the right one: the `select` on `.path`, without which CI's own run answers for the review, and `sort_by(.run_number)` before `last`, without which the API's newest-first order hands back a superseded run. |
| `ledger-sweep.sh` | The `armed`/`teardown` pairing query in `skills/backlog` Step 9 and Step 8. A `/backlog` run on 2026-09-06 ended with 41 agents still registered because the teammate `agentId` was never written to the ledger and the clean-return path skipped `TaskStop`. Pins that a stage with an `armed` line and no `teardown` line is listed with both IDs, that a torn-down stage and a re-armed stage torn down again are not, and that a stage line keyed `status` instead of `event` is found by its own probe rather than silently skipped. |
| `git-scenarios.sh` | Post-merge branch classification for `/pr` steps 6-7 and `/work` §3, and the `/sync` §5 count direction. Proves three-dot diff cannot detect a squash merge and two-dot can. |
| `hook-sentinels.sh` | Ownership-before-expiry ordering in `hooks/automerge-rewake.sh`: a foreign session's sentinel must survive even past its cap. |
| `branches.sh` | The `lib/branches.sh` contract — always exit 0, never write stderr, emit only slow-moving facts. Also the **branch grammar** in `lib/branch-name.sh` (Conventional Commits types as branch prefixes) and the two keys it feeds, `branch_issue` / `branch_recognized`. Three traps are pinned deliberately: a slug containing `/` must be **rejected**, because `for-each-ref` wildcards do not cross `/` and such a branch would be invisible to every scan; `feature/` must parse as type `feature`, not `feat`, so a future `case`-based rewrite cannot silently change what `/work` generates; and `fix/2024-01-migration` **does** read as issue #2024 — pinned so nobody "fixes" it in the regex, since the real fix is `/pr` degrading when `gh issue view` fails. Both emit paths carry both keys: the not-a-git-repo early exit already dropped `branch_config` once, and a key that vanishes reads as unset rather than empty. An unreadable `branch-name.sh` must degrade with a note, never take skill loading down — it is injected into eight skills. |
| `rewake-observability.sh` | "Cannot observe → do not report clean" in `hooks/automerge-rewake.sh`. A failed or malformed `gh` lookup must stay silent and keep the sentinel, never emit the all-clear that instructs a merge. Also pins that the all-clear message leads with the merge, and that the `/work` message steers the model **off** `TaskList` — the to-do board tracks no live work, so checking it answers "nothing" whatever is running. |
| `bg-snapshot.sh` | `hooks/bg-snapshot.sh`, which persists the `Stop` payload's `background_tasks` for `/reap`. Three-valued: `absent` (field missing or unparseable) must never render as `none` (observed empty) — that collapse is how a teardown reports clean while 52 agents run. Also pins that every path is silent and exits 0, since a `Stop` hook that writes stderr and exits 2 rewakes the agent. |
| `automerge-merge-gate.sh` | The two decision scripts in `skills/automerge` — extracted from the markdown, so doc and behavior cannot diverge, and run under **both bash and zsh**. Step 3 must verify `state = MERGED` rather than trusting `gh pr merge`'s exit code, must never invoke the merge from a blocking state (`DRAFT` included — it reports `mergeable=MERGEABLE`), and §2.4's review wait must not read a gh failure as "no review workflow" — only a literal 404 may. Also pins that the wait keys on the head commit, and the grace window that separates event-delivery lag from a workflow that never fired. |
| `merge-gate.sh` | `lib/merge-gate.sh`, the pre-dispatch gate for the serialized merge slot in `/work` §10 and `/backlog` §6f. Pins that unknown is never resolved to the optimistic answer: a null field, a failed `gh`, and a mergeable value gh has not documented yet are all rc 2, never ready. Three traps are pinned deliberately: jq's `//` treats `false` as empty, so `.isDraft // ""` would make every non-draft PR unreadable and halt the run; a MERGED PR reports `mergeable: null`, and joining the fields on a space lost those trailing empties to word splitting, retrying a finished PR into UNKNOWN instead of the rc 3 a resumed run needs to skip it; and `mergeable` is computed lazily, so UNKNOWN is the *expected* first read for every PR still open after a merge lands and must be retried rather than decided. A draft reports `mergeable: MERGEABLE` and is rc 6 anyway, the same trap `automerge-merge-gate.sh` pins for Step 3. |
| `work-probes.sh` | The arm-time monitor probe in `skills/work`, also extracted from the markdown. A wrong tree must be refused for both stages, but a **plan** stage's branch legitimately does not exist yet — the plan stage creates it — so requiring the ref there blocked every fresh issue. Also runs a **scope-bearing** branch (`feat(api)/3-scoped`) through the probe under zsh: an unquoted `{branch}` placeholder makes that rc=1 ("no matches found") whatever git says, the monitor then refuses to arm, and every stage on that branch is a blocker that reads exactly like a healthy refusal. |
| `skill-blocks-portability.sh` | Every ```bash fence in the locally-authored skills and `agents/*.md` must run under the shell that actually runs it. Two checks, because they catch different halves: a grep lint for constructs that *parse* in zsh and misbehave at runtime (`[ a \> b ]`, `${v,,}`, `mapfile`, `${a[0]}` — `zsh -n` cannot see these), and `zsh -n` on every block for the parse-level bashisms the list misses. Scoped by a *denylist* of vendored skills, so a new locally-authored skill is covered the day it lands. |
| `backlog-guards.sh` | `lib/backlog-preflight.sh` and `lib/backlog-teardown.sh`, the guards `/backlog` runs between issues. Pins the **asymmetry** between the two branch scans, which is the whole point of them being different: guard 6 **refuses**, so it matches broadly — any prefix, including `travis/12-notes` and a slug containing `/` that no glob can see — because a missed stale branch costs a duplicate branch and a run that reports clean; teardown **deletes**, so it takes the exact `--branch` name `/backlog` already owns, and a same-issue branch it was not told about must survive. They are scripts rather than skill prose because a run long enough to compact turns a remembered checklist into a paraphrase. Pins: a dirty tree is stashed, never discarded (at `parallel=1` the whole queue shares one tree, and `git checkout` silently carries modified files onto the next issue's branch); a commit landing straight on the base branch is caught by rc 4 even though the tree is clean; our own leaked sentinel is swept while another session's is a refusal; all three sentinel side files go, since a surviving `.progress` makes a fresh stage read as already stalled; a branch is deleted only after checking out away from it; and an unreadable parent is rc 11 (unknown), never "satisfied". |
| `reap-orphans.sh` | `hooks/reap-orphans.sh` — which orphaned processes are adoptable, and that a foreign session's process is never reaped. |
| `session-cleanup.sh` | `hooks/session-cleanup.sh` — the SessionEnd budget is ONE shared 1500ms floor, so an undeclared `timeout` truncates later steps silently. No forks in a per-item loop. Also pins that outside a git repo it says `NOT PERFORMED` rather than exiting quietly (`/reap` reports its silence as a clean teardown), and that this session's bg-snapshot is released while another session's survives. |
| `closure-audit-guards.sh` | `/closure-audit`'s three irreversible-act invariants: it never closes an issue, never creates a label outside the gate, and is idempotent by capability ID. Also pins the three meanings of a zero denominator (`n/a` / BLIND / clean) — collapsing them once fabricated a dozen findings against a fully covered repo. |
| `review-audit-guards.sh` | The review lenses and `/audit`. Runs the finding-ID fence under zsh and pins that its hash input carries no line number, so an unrelated edit never refiles a ticketed defect. Starts a server with a grandchild and proves `/ux-audit`'s stop fence ends all of it without signalling a process group. Also pins `--limit 1000` on both backlog fetches, the five-agent cap on each `/audit` wave, and that no command closes, reopens, or creates a label outside the gate. |
| `stage-processes.sh` | `lib/stage-processes.sh`, the sweep that ends the OS processes a `/work` or `/backlog` stage orphaned. Reproduces the 2026-09-04 leak rather than describing it: a stage backgrounded twenty subshells under a non-interactive `zsh -c`, cleaned up with `kill $(jobs -p)`, and printed success while ending nothing, leaving them at 601.8% CPU for 3h26m. Pins the `jobs -p` behavior itself, so the rule in both exec prompts fails here first if it ever changes. Pins the two-condition attribution (absent from the snapshot **and** reparented to PID 1), because either alone sweeps up the operator's own work; that an orphan outside the stage's tree is reported and left alone; and that a missing, empty or unreadable snapshot exits 5 as **BLIND** rather than reporting a clean sweep. Also pins the call order in `backlog-teardown.sh`, since a process holding a cwd inside the worktree makes `git worktree remove` fail and the release then blames uncommitted work. |
| `prepush-hook.sh` | `git-hooks/pre-push`, the per-repo push gate, driven through real `git push` to a local bare remote with `act`, `docker`, and `timeout` stubbed on a restricted PATH. Pins that Docker down, a failing `act pull_request` run, and a timeout (exit 124) each reject with the `SKIP_PREPUSH_ACT=1` hint, that a deletion-only push, absent `act`, no workflows, and `pull_request_target` or push-only workflows run nothing, and that `PREPUSH_ACT_EXCLUDE` (default `claude-review.yml`) is honored. Also pins `pre-push.local` chaining (original args and stdin, exit code propagates, non-executable ignored), and that `install/install-hooks.sh` writes both shims, preserves an existing `pre-push` as `pre-push.local`, and works with `--global`. |
| `repo-map.sh` | `lib/repo-map.sh`, the cached repo-map helper shared by the scout agent and tests. Pins that `path` resolves to one file from the main checkout and a linked worktree, that `stale-paths` lists only changed files, and that a missing stamp requests a full rebuild. |
| `precommit-hook.sh` | `git-hooks/pre-commit`, the per-repo commit gate. Every tool it calls (`act`, `docker`, `agy`) is a stub on a PATH restricted to system directories, because with the stub merely removed the hook found the real `agy` and, under the scratch `HOME`, launched its OAuth login. Pins the refusals: Docker down or a failing `local-commit-check` rejects with the `SKIP_ACT=1` hint, and a review that fails twice (second attempt on the fallback model, observed in the stub's `--model` sequence) rejects rather than passing an unobservable check, as does a `SUCCESS` that ignored the schema. Also pins that a `high` finding prints `file:line`, that lockfiles at any depth never reach the prompt, that an oversized diff is skipped with a `WARNING` naming the knob, that `pre-commit.local` runs last and its exit code propagates, and that the `--json-schema` carries `items` on the findings array, without which `agy` returns `INVALID_ARGUMENT`. |
| `reference-integrity.sh` | Every `§`/step citation resolves in its target, every referenced `.md` exists, nothing points at the removed `~/.claude/commands/`, and this README documents every suite in `run-all.sh`. Clause two of the fix-in-place rule, mechanically. Also pins that every `` !`cmd` `` injection is an absolute path to an executable — the form expands wherever it appears, so `/feature-closure` naming it in prose ran `branches.sh` off PATH and the skill failed to load. |

## Why extracted blocks run under zsh

Claude Code's Bash tool runs the user's **login shell** — zsh — so a ```bash fence in a `SKILL.md`
is zsh input, whatever the fence is labelled. The two shells disagree in ways that are silent in
the wrong direction: `[ "$a" \> "$b" ]` is a string comparison in bash and `condition expected: >`
(rc=2) in zsh.

`/automerge` §2.4 used exactly that to decide "the review is newer than the push". Under
zsh the branch could never fire, so the wait never reached its `exit 0` and every run rode to the
15-minute cap and stopped — while `automerge-merge-gate.sh`, which extracts and runs that very
block, reported it green because it ran the block with `bash`. Extracting the real block is only
half the guarantee; the other half is the interpreter. Hence `BLOCK_SHELL` in `lib.sh`, and
`skill-blocks-portability.sh` for the fences no suite extracts.

## Why `branches.sh` must stay stable

Invoked skill content persists for the whole session. A re-invocation whose *rendered* content
differs — including because a `` !`…` `` dynamic-context command produced new output — appends the
full skill body again; an identical one is deduped to a short note. `/automerge` runs up to five
cycles per PR, so if `branches.sh` emitted a SHA or a dirty-tree flag, each cycle would re-append
the whole of `reviews.md` and `ci.md`. The stability assertions guard that.

## Adding a call-site assertion

Two false-pass traps, both hit while writing these:

1. **Guessed substrings.** Asserting `rev-list --count origin/<b>..<b_before>` passed trivially
   because the file spelled it without the `rev-list --count` prefix. Match text that actually
   exists in the file.
2. **Globs that match nothing.** A `for f in …; do [ -f "$f" ] || continue; …` loop over paths that
   are all absent runs zero assertions and reports success. Count matches and assert the count.

## Deferred

`WorktreeCreate` / `WorktreeRemove` hooks for `/work`'s worktree bookkeeping (audit §3.6). Both
events are real, but their input JSON schema is undocumented. Probe before implementing: register a
hook that dumps stdin to a file, run one harness worktree create/remove, read the actual payload.
Do not write against a guessed schema.
