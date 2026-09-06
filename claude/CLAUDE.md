# Personal preferences

@~/.claude/style.md

# Standing rules

Cross-cutting lessons that cost real time to learn. Each one is here because the failure it
prevents is *quiet* — it looks like success until much later.

## Waiting on long-running work

- **The Bash tool's ceiling is 600 s (`timeout: 600000`); its default is 120 s.** Anything that
  might exceed that cannot be held open in a foreground call — a bare `sleep`-loop is killed on its
  first iteration and silently ends the turn.
- **Detach it, don't wait on it.** `nohup {cmd} > {log} 2>&1 & disown`, record the PID, then poll
  `{log}` with short foreground reads. A background Bash task is not a place to park a wait.
- **Never stack waiters.** One poll at a time, and never a second waiter on something a first is
  already waiting for. Background slots are finite: six stacked waiters on one 66-minute job
  evicted the task that owned the job itself, and the work was lost. Before arming any watcher,
  check whether one already exists and reuse it.
- **`disown`ed processes outlive `TaskStop`** — they reparent to init and keep running for the rest
  of the session. Whatever you detach, report its PID and log path so it can be reaped
  (`/reap`; config in `~/.claude/reap-orphans.conf`).
- **This whole section is off inside a `/work` or `/backlog` stage.** Those stages run unattended
  and then tear down, so there is nobody to read a PID and nothing to reap against. Their exec
  prompts require every process to end before the stage returns, and their teardown sweeps for
  orphans with `lib/stage-processes.sh`. Where that rule and this one disagree, the stage prompt
  wins.
- **`jobs -p` is not a cleanup mechanism.** Under a non-interactive `zsh -c` it returns nothing, so
  `kill $(jobs -p)` ends nothing and the shell still prints whatever success message follows it.
  On 2026-09-04 that idiom left twenty busy loops running for 3h26m at 601.8% CPU, with the load
  average at 195.63. Capture each PID from `$!` on the line that starts the process.

## Monitors and health checks

**A check that cannot observe its target reports BLIND, never healthy.** This is the most expensive
failure shape there is, because its output is indistinguishable from the good outcome.

- Validate probes **at arm time**: does the path exist, does the PID exist, does the branch resolve?
  A monitor pointed at a valid-but-wrong directory emits nothing forever and reads as healthy.
- **An empty result is *unknown*, not *good news*.** `cmd 2>/dev/null || true` makes a network
  failure look identical to "there is nothing there" — check the exit status separately and
  distinguish the two. Two of four monitor revisions shipped for one job reported "healthy" while
  unable to see the process at all.
- Prefer designs that fail loud: emit on change with an explicit stall timeout, rather than
  inferring health from silence.

## Completion is an observation, not a claim

Before recording anything as done, check the thing itself:

| Claim | Evidence |
|---|---|
| merged | `gh pr view --json state` reads `MERGED` |
| committed / pushed | `git log -1`, `git status --porcelain` |
| file written | `stat` it, and check it is newer than the run that wrote it |
| process finished | the PID is gone, and the log's last line says so |

A subagent's report, a task's status field, and a command's exit code are all *claims*. Verify
sweeps against `git`/`gh` directly.

**Use the tool that tracks the thing you are asking about.** `TaskList` is the `TaskCreate` to-do
board — subject, status, owner, `blockedBy`. It does not track live work and never has, so an empty
`TaskList` is not weak evidence of an idle session; it is *no* evidence, and reading it as one is
how `/reap` reported a clean teardown while 52 agents were running (2026-08-18). What answers the
liveness question:

| Live work | Where it is visible |
|---|---|
| subagents this session spawned | `ListAgents` (peer-session rows are other sessions' — never stop those) |
| monitors, teammates, background shells | the `Stop` payload's `background_tasks`, persisted by `hooks/bg-snapshot.sh` to `~/.claude/run/bg-tasks-<session>.json`; or the task IDs recorded in the ledger at arm time |
| detached `nohup … & disown` processes | `ps`; they survive `TaskStop` entirely |

Each of those is still three-valued — unreadable is *unknown*, never empty.

When two views disagree, resolve toward the **cheaper failure** — a duplicate poller beats an
unmonitored job — and say that they disagreed.
