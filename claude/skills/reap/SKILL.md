---
name: reap
model: sonnet
effort: medium
description: Tear down everything this session still has running — background agents and tasks, monitors, teammates, orphaned dev-server processes, sentinels and worktrees — before you /clear.
argument-hint: ""
# User-invoked only. This stops live work and kills processes; it is never Claude's call to
# decide the moment for that. (Same reasoning as /work and /commit. Nothing in the suite
# invokes /reap programmatically, so denying model invocation breaks no handoff.)
disable-model-invocation: true
# `TaskList` is DELIBERATELY ABSENT. It is the TaskCreate to-do board — subject, status,
# owner, blockedBy — and has never listed running agents, monitors or background shells.
# Enumerating live work with it is what made this command report a clean teardown on
# 2026-08-18 while 52 background agents were running. `ListAgents` and the bg-snapshot file
# are the two views that answer the question; re-adding TaskList here recreates the bug.
#
# `effort: medium`, not low: the job is now two readings that have to be reconciled, and
# the whole point of the command is that it does not paper over a disagreement between them.
allowed-tools: ListAgents, TaskStop, Read, Bash(bash __CLAUDE_HOME__/hooks/session-cleanup.sh), Bash(date:*)
---

> **Output convention — timestamp every turn.** At the end of each turn, run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-07-03 10:17:13 CDT`. Never hand-write the time; always read it from `date`.

Release everything this session is still holding, so a `/clear` starts genuinely clean.

**This command cannot run `/clear` itself.** `/clear` is a built-in, and built-ins are not
reachable from a skill, a hook, or the model — there is no `SlashCommand` tool and no hook output
that resets context. So this does the teardown and hands you the last step. Say that plainly at the
end; it is a documented limitation, not a step that failed.

**And `/clear` would not stop this work anyway.** In-process agents survive it: the 2026-08-18 run
that motivated this rewrite was invoked *after* a `/clear`, and 52 agents were still running when
the user pressed `Esc`. Clearing the conversation is not a teardown; this command is.

You do not need this before every `/clear`: the `SessionStart` hook already reaps orphaned
processes on `clear`. Use `/reap` when you also want live work stopped, or to clean up mid-session
without clearing at all.

## Step 1: Read what is live — from two independent views

Only the model can stop this half. Monitors, teammates and subagents are **in-process threads**,
not OS processes — no shell hook can reach them, which is why `session-cleanup.sh` cannot and does
not try (see its header). `TaskStop` is the only thing that stops them.

Neither view sees everything, and they fail in different directions. Take both.

**View A — `ListAgents`.** The model-side list. It shows in-process subagents this session spawned
**and** peer sessions (other local `claude` sessions, Remote Control, cloud), each row labelled by
kind.

- **Only this session's own subagents are `TaskStop` candidates.** A peer session belongs to
  someone else's run; never stop one. Count them in the report and move on.
- It does **not** list Monitors or backgrounded shells. That is View B's job.

**View B — the background-work snapshot.**

```
Read ~/.claude/run/bg-tasks-$CLAUDE_CODE_SESSION_ID.json
```

`hooks/bg-snapshot.sh` writes it at every turn end from the `Stop` payload's `background_tasks` —
"in-flight background work (running/pending + backgrounded) registered in this session", the same
field `automerge-rewake.sh` reads. It is the only view that covers Monitors and background shells.

Read its `seen` field as three-valued, exactly as the rewake hook does:

| `seen` | Means | What you do |
|---|---|---|
| `listed` | that array was in flight at the last turn end | `TaskStop` each `id`, by kind |
| `none` | observed empty | nothing of this class was live |
| `absent`, or **no file at all** | the payload did not carry it, or the hook never ran | **BLIND** — say so |

The snapshot is one turn stale, and that is bounded and safe: your own turn spawns nothing, so it
can only *over*-report. A `TaskStop` against an id that already finished is free; a missed live
monitor is not.

## Step 2: Stop all of it

`TaskStop` **every** candidate from both views — do not prompt, do not triage, do not ask which
ones to keep. This command was invoked deliberately, and a half-torn-down session is precisely the
failure mode `/work`'s teardown discipline exists to prevent.

- Note each one's kind for the summary: subagent, monitor, teammate, or background bash.
- **A `TaskStop` that fails is reported as not stopped.** Never fold a failure into the stopped
  count — that is the same lie as reporting an unobserved session as clean.

## Step 3: Release session state and orphaned processes

Delegate to `session-cleanup.sh` — do **not** reimplement any of it here. That script is already
the single source of truth for orphan reaping, session-scoped sentinel sweeping, worktree release
(never `--force`, dirty trees reported rather than destroyed), and removing this session's
bg-snapshot file. It normally runs as a `SessionEnd` hook and reads its parameters from the hook
payload on stdin, so hand it a synthetic one:

```bash
printf '{"session_id":"%s","cwd":"%s"}' "$CLAUDE_CODE_SESSION_ID" "$PWD" \
  | bash ~/.claude/hooks/session-cleanup.sh
```

`$CLAUDE_CODE_SESSION_ID` is already exported into every Bash call. Passing it is what scopes the
sentinel and worktree sweep to **this** session — several `claude` sessions often share a repo, and
the script will refuse to touch another session's state.

What it does, in order:

- **Orphaned dev-server processes** — `workerd`, `vite`, and friends whose parent is already dead.
  Machine-wide by nature: an orphan has no owning session, which is exactly what makes reaping it
  safe while other sessions are live. Runs regardless of whether you are inside a repo.
- **The bg-snapshot** for this session.
- **Sentinels** — `.claude/work-active-*` and `.claude/automerge-active-*` stamped with this
  session, plus their `.rewakes`, `.capped` and `.progress` side files.
- **Worktrees** — `.claude-work/$SESSION/` entries, removed only when clean.

Report its output verbatim if it printed anything; it is silent when there was nothing to do —
with one exception you must not flatten: **`sentinel/worktree sweep NOT PERFORMED`** means the cwd
was not a git repo, so that half could not run at all. That is blind, not clean.

## Step 4: Cross-check the views against each other

Say out loud what disagreed. Each pairing means something specific:

- **Snapshot listed work `ListAgents` did not show** → expected for a monitor or a background
  shell. Stop it and name its kind.
- **`ListAgents` showed agents the snapshot did not** → the snapshot was stale or absent. Say that;
  do not present it as an authoritative empty.
- **Both views empty but `session-cleanup.sh` swept sentinels or worktrees anyway** → something was
  live that neither view carried. Say so rather than printing a clean summary.
- **Detached (`nohup … & disown`) processes** are the same story from the other side — they survive
  `TaskStop` entirely, and only the orphan sweep finds them.

## Step 5: Report, then hand off

```
Reaped

  Stopped           4  (2 subagents, 1 monitor, 1 background bash)
  Not stopped       1  (TaskStop failed: work-exec-7 — press Esc)
  Peer sessions     18 left alone (not this session's to stop)
  Processes reaped  51 (~1020 threads)
  Sentinels removed work-active-7, automerge-active-58
  Worktrees         1 released, 1 left dirty (path)
  Could not observe monitors + background shells (no snapshot for this session)

Session state is clear. Press /clear to reset the conversation —
this command can't run built-in commands for you. Note that /clear does not
stop background work; Esc is the backstop for anything listed above as not stopped.
```

Omit any row that was zero; a report of zeros is noise. If a worktree was left dirty, name its
path — that is recoverable work and the user has to decide about it.

**The one claim you may not make.** "Nothing is live" requires *both* views to have been readable
and empty. If either was blind — no snapshot, `seen: absent`, a `ListAgents` error — the line is
**"could not observe — press Esc to be certain"**. A clean four-zero summary printed off an
unreadable view is exactly the failure this command was rewritten to stop making.

## Important notes

- **Stops everything, unconditionally.** If you have a long build running in the background that
  you care about, do not run this.
- **Never touches another session's work.** Peer sessions in `ListAgents`, foreign sentinels and
  foreign worktrees are all left alone; only orphan reaping is machine-wide, because an orphan by
  definition has no living owner.
- **Never force-removes a worktree.** A dirty one is reported and left alone.
- Configure what counts as reapable in `~/.claude/reap-orphans.conf` (`REAP_ROOTS`,
  `REAP_PROTECT`, `REAP_MIN_AGE`).
