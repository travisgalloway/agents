# How the pieces fit together

The catalog names each file. This document explains the machine they form, because the
individual descriptions do not convey it. Read it before changing anything, since most
of the design exists to prevent a specific failure that already happened once.

## The pipeline

One issue travels a fixed path from the backlog to a merged pull request.

```
/backlog  enumerate, topologically sort, confirm once
   └── per issue:
         /work        plan stage  -> work-plan agent (opus)   writes a plan file
                      exec stage  -> work-exec agent (sonnet) implements it
         /pr          push the branch, open the pull request
         /automerge   drive to a squash merge
               ├── /reviews   fetch, remediate, resolve threads
               └── /ci        read the failure, fix it
         merge-gate.sh        does the pull request still apply to the base
```

The handoff between the plan and exec stages is a written file rather than conversation
state. A run long enough to compact turns a remembered plan into a paraphrase, so the
plan is written down and the exec agent reads it back.

`/work` runs a single issue inline with full gating. Multiple issues or a description
trigger orchestrated mode, where the main session only dispatches and verifies.

## Repository facts come from one place

Eight skills need the same facts: the owner, the repository, the root, the current
branch, the integration and release branches, and the issue the branch refers to.
`lib/branches.sh` resolves all of them and emits key-value pairs, and each skill injects
its output with the dynamic-context form.

That library has an unusual contract. It always exits zero and never writes to standard
error, because a skill that fails to load takes the whole command down. It also emits
only slow-moving facts, never a commit hash or a dirty-tree flag. Invoked skill content
persists for a whole session, and a re-invocation whose rendered content differs appends
the entire skill body again. Since `/automerge` runs up to five cycles per pull request,
a volatile fact would re-append tens of thousands of tokens per run.

`lib/branch-name.sh` holds the branch grammar the other three libraries share. Nothing
executes it, everything sources it.

## Bounded waits, sentinels, and the rewake hook

A long autonomous run spends most of its time waiting: for continuous integration, for a
review, for a merge to become possible. A session that waits by going idle never wakes
up on its own. Three mechanisms address that.

A **sentinel file** in the repository records that a wait is active, which pull request
or issue it belongs to, and which session owns it. `automerge-rewake.sh` reads the
sentinels on every stop, teammate-idle, notification, and subagent-stop event. When a
wait looks abandoned, the hook exits 2 with a message, and the harness wakes the session.

Ownership is checked **before** expiry. Another session's sentinel survives even past its
cap, because ending a wait that belongs to someone else is worse than leaving a stale
file behind.

The hook refuses to report an all-clear it cannot substantiate. A failed or malformed
lookup stays silent and keeps the sentinel. Only a literal not-found response counts as
evidence that no review workflow exists.

## Knowing what is actually running

`/reap` once used the to-do board to enumerate live work. The board tracks to-do items
and has never listed running agents, monitors, or background shells. On 2026-08-18 it
returned nothing while 52 background agents were live, and the teardown reported clean.

`bg-snapshot.sh` fixes that. The harness hands each stop hook the real list of in-flight
background work, and the hook writes it to a per-session file that `/reap` reads. The
value is three-valued on purpose. Absent means the field was missing and the answer is
unknown. Empty means the harness observed nothing running. Collapsing the first into the
second is exactly how a teardown reports clean while work continues.

`session-cleanup.sh` runs at session end and removes only what this session owns: its own
snapshot, sentinels whose recorded session matches, its monitor, and worktrees that are
clean. It never forces a removal, and it never touches a plan file.

Agents and monitors are only two thirds of the answer. A stage also starts operating-system
processes, and those outlive it. On 2026-09-04 a stage backgrounded twenty subshells and
cleaned up with the shell's own job list, which returns nothing in a non-interactive shell.
The cleanup ended nothing, printed success, and the subshells reparented to the init process
and ran for three and a half hours at 601.8 percent processor use.

`lib/stage-processes.sh` closes that gap with the same shape the rest of the suite uses.
It records the process table before a stage is dispatched, and sweeps afterward. Two
conditions together identify a stage orphan, never one alone: the process is absent from
the snapshot, and its parent is the init process. A stage runs for up to 90 minutes while
the operator keeps working, so newness on its own would sweep up unrelated jobs. Among
those orphans, only the ones whose working directory sits inside the stage's tree are
ended. Everything else is printed and left alone.

A missing or unreadable snapshot exits blind rather than reporting a clean sweep. The
backlog teardown calls the sweep before releasing the worktree, because a process still
holding a working directory inside it makes the removal fail, and the failure then reads
as uncommitted work.

Subagents need the same treatment, and for the same reason. A backlog run over 20 issues
ended on 2026-09-06 with 41 agents still registered, one plan and one exec for each issue.
Two faults combined. The identifier was written to the ledger before the dispatch call
returned, so it was never recorded and the final sweep had nothing to stop. A resumed
session then wrote its stage lines under the wrong key, so a sweep reading the expected
schema skipped that session completely. The ledger now records a line when a stage is armed
and another on every exit path, and `ledger-sweep.sh` pins the query that pairs them.

## Orphaned processes

Development servers survive the sessions that started them. `reap-orphans.sh` runs at
session start and ends processes that are orphaned, owned by the current user, under a
configured project root, and older than a floor. `reap-orphans.conf` holds the roots, a
protect pattern for things that must never be ended, and the age floor. Every value is
overridable by an environment variable, which is how the test suite drives it.

## Why the tests exist

Twenty-one test files guard a personal configuration, which needs justifying. Each suite
exists because a specific bug shipped and was expensive to find. The suite prints its own
assertion total when it runs, and no document here restates that number, because a
restated count is wrong on the next commit and nothing notices. Five examples show the
pattern.

**The shell is zsh, not bash.** Claude Code's Bash tool runs the login shell. A fence
labeled `bash` in a skill is zsh input. The automerge skill once compared timestamps with
an operator zsh does not have, so the branch never fired, and every run rode to its cap
and stopped. The suite that extracted that block reported it green, because the suite ran
it under bash. `skill-blocks-portability.sh` now runs every fence under zsh.

**A stale cross-reference reads as authoritative.** Four references pointed at things
that no longer existed, all shipped within one week. `reference-integrity.sh` resolves
every section citation and every referenced document mechanically.

**Unknown must not resolve to the optimistic answer.** GitHub computes mergeability
lazily, so unknown is the expected first read for every pull request still open after a
merge lands. `merge-gate.sh` retries rather than deciding, and the suite pins that a null
field, a failed call, and an undocumented value are all refusals.

**A guard and a teardown want opposite scans.** The preflight guard refuses, so it matches
branches broadly, because a missed stale branch costs a duplicate branch and a run that
reports clean. The teardown deletes, so it takes the exact branch name it was given, and
a same-issue branch nobody told it about must survive.

**A cleanup that ends nothing still prints success.** The shell's job list is empty in a
non-interactive shell, so the idiom that reads as tearing down background work is a no-op
there, and the message after it runs anyway. `stage-processes.sh` pins that behavior
directly, so the rule in both exec prompts fails here first if the shell ever changes.
