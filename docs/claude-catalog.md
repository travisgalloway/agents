# Catalog of the Claude configuration

Every file this repository installs into `~/.claude`, with one line saying what it does.
The tables follow the directory layout under `claude/`. For how the parts work together,
read [claude-workflow.md](claude-workflow.md).

Sixty-two files are tracked. Thirteen of them carry the `__CLAUDE_HOME__` token and are
rendered at install time rather than symlinked, because Claude Code needs a literal
absolute path in those positions.

## Root documents

| File | What it does |
|---|---|
| `CLAUDE.md` | Global user memory, loaded into every session. Imports `style.md`, then states three standing rules: how to wait on long-running work, why a check that cannot observe its target reports blind, and why completion is an observation rather than a claim. |
| `style.md` | Writing rules applied to all output. Register, a banned-constructions list, inclusive and non-militaristic term tables, rhythm, volume, numbers in prose, and a pre-send checklist. |
| `mechanics.md` | The backing detail for `style.md`. Twenty grammar rules, the full number and unit rules, and the content rules for tables and figures. |
| `COMMAND-AUDIT.md` | Historical record of a 20-bug audit of the command suite, with a disposition per item. Its own header discloses that its paths predate the move to skills. |
| `settings.json` | Hook registrations, the status line, permissions, enabled plugins, and model preferences. Always rendered, never symlinked, because Claude Code rewrites it at runtime. |
| `statusline-command.sh` | Renders the status line in Starship style: user, directory, git branch, model, context used, and a clock. |
| `reap-orphans.conf` | Configuration for the orphan sweeper. Names the project roots to sweep, a protect pattern, and a minimum age. Every value is overridable by an environment variable. |

## `agents/` — subagent definitions

| File | What it does |
|---|---|
| `code-reviewer.md` | Reviews a diff against a quality and security checklist, bucketing findings as critical, warning, or suggestion. |
| `debugger.md` | Runs root-cause analysis on errors, test failures, and unexpected behavior. |
| `remediator.md` | Runs `/reviews auto` or `/ci auto` for one pull request on behalf of `/automerge`, and reports a one-line outcome. |
| `work-plan.md` | Plan stage of the `/work` pipeline. Explores the codebase for one issue and writes a plan file carrying a definition of done. |
| `work-exec.md` | Exec stage. Implements an approved plan file to a finished pull request, parking every out-of-scope discovery. |
| `work-exec-opus.md` | The same body as `work-exec.md`, pinned to opus at medium effort. Selected by the `opus` token on a `/work` invocation. |

## `commands/` — slash commands

| File | What it does |
|---|---|
| `deslop.md` | `/deslop`. Rewrites the prose in a named file against `style.md` and `mechanics.md`, showing a diff before writing. |

## `hooks/` — event handlers

| File | Registered on | What it does |
|---|---|---|
| `bg-snapshot.sh` | `Stop`, first | Persists the payload's in-flight background work to a per-session file, so `/reap` can enumerate what is running. Three-valued: absent means unknown, never none. |
| `automerge-rewake.sh` | `Stop`, `TeammateIdle`, `Notification`, `SubagentStop` | Guards the bounded waits in `/automerge` and `/work`. Reads sentinel files and exits 2 with a nudge when a wait looks abandoned. |
| `reap-orphans.sh` | `SessionStart` | Ends orphaned development-server processes under the configured project roots, owned by the current user and older than a floor. |
| `session-cleanup.sh` | `SessionEnd` | Releases what one session leaves behind: its snapshot, its own sentinels, its monitor, and its clean worktrees. Never uses force. |

## `lib/` — shared shell libraries

| File | What it does |
|---|---|
| `branches.sh` | Emits the repository facts every skill needs as key-value pairs. Injected into eight skills. Contractually never exits non-zero and never writes to standard error. |
| `branch-name.sh` | The single definition of what a branch name means. Sourced by the other three libraries, never executed. |
| `merge-gate.sh` | Answers one question before a queued pull request takes the merge slot: does it still apply to the base as the base now stands. |
| `backlog-preflight.sh` | The twelve guards `/backlog` runs before dispatching a stage. A dirty tree is stashed rather than discarded. |
| `backlog-teardown.sh` | Releases one `/backlog` stage's on-disk state on every exit path, including failure and abandonment. |
| `stage-processes.sh` | Records the process table before a stage, then ends the processes that stage orphaned. A process is attributable only when it is absent from the snapshot and its parent is the init process. |

## `skills/` — authored skills

Twelve skills, 17 files. The vendored Cloudflare skills are not tracked here; see
[vendored-skills.md](vendored-skills.md).

| Skill | Model | What it does |
|---|---|---|
| `work` | opus | Starts or resumes work on one or more issues and drives each to a pull request. Plans in an opus subagent, executes in a sonnet subagent, hands off through a written plan file. |
| `backlog` | opus | Drives an entire open backlog to merged pull requests, dependency-ordered, one issue at a time. Ledger-backed, so a run survives compaction and a session restart. |
| `automerge` | inherited | Drives already-open pull requests to a squash merge, remediating reviews and continuous integration without asking. Plan mode and questions are disallowed by frontmatter. |
| `closure-audit` | opus | Audits a repository and its backlog for half-finished work, coverage gaps, and contract drift, then grooms the backlog so it can be closed. |
| `reviews` | inherited | Fetches, analyzes, and remediates pull-request review comments, then resolves the threads. |
| `ci` | inherited | Checks continuous-integration status for the current pull request and remediates failures. |
| `pr` | inherited | Pushes the current feature branch and opens its pull request. Deliberately narrow, so it is not treated as a general git helper. |
| `feature-closure` | inherited | Keeps coding work converging on an agreed scope. Five reference files cover decomposition, execution, repository norms, living documentation, and gap detection. |
| `reap` | sonnet | Tears down everything a session still has running before a clear: agents, monitors, teammates, orphaned processes, sentinels, and worktrees. |
| `commit` | inherited | Makes a formatted commit carrying its issue reference. |
| `status` | sonnet | Shows development status for the active feature branch: issue, checklist progress, and git statistics. |
| `sync` | sonnet | Syncs the release, integration, and current branches with the remote. |

## `tests/` — regression suites

Twenty-one files. Run them with `bash ~/.claude/tests/run-all.sh`. No suite touches the
network, every GitHub call is served by a stub on the path, and git scenarios build
throwaway repositories under the temporary directory. Each suite exports its own git
configuration first, so the real git identity is never written.

| File | What it pins |
|---|---|
| `run-all.sh` | Runs all 18 suites in a fixed order and sums their assertion tallies. An unparseable tally reports as unknown rather than zero. |
| `lib.sh` | Shared assertion helpers, plus block extraction and the shell those blocks run under. |
| `README.md` | Documents every suite, and explains why extracted blocks run under zsh. |
| `lint-frontmatter.sh` | Only documented frontmatter keys appear in skills and agents. Catches the kebab-case and camel-case spelling mixup that silently disables enforcement. |
| `jq-run-lookup.sh` | The workflow-run lookup shared by `automerge` and the rewake hook. A null field must not abort the query. |
| `ledger-sweep.sh` | The query that pairs an armed stage with its teardown. A stage armed and never torn down is a leak, and a malformed ledger line is reported rather than skipped. |
| `git-scenarios.sh` | Post-merge branch classification. Proves a three-dot diff cannot detect a squash merge and a two-dot diff can. |
| `hook-sentinels.sh` | Ownership is checked before expiry, so another session's sentinel survives even past its cap. |
| `branches.sh` | The `branches.sh` contract and the branch grammar, including three traps that a well-meaning rewrite would break. |
| `rewake-observability.sh` | A failed lookup stays silent and keeps the sentinel, and never emits the all-clear that instructs a merge. |
| `bg-snapshot.sh` | The three-valued snapshot contract, and that every path is silent and exits zero. |
| `automerge-merge-gate.sh` | The two decision scripts inside the automerge skill, extracted from the markdown and run under both bash and zsh. |
| `merge-gate.sh` | Unknown never resolves to the optimistic answer. A null field, a failed call, and an undocumented value are all refusals. |
| `work-probes.sh` | The arm-time monitor probe, including a scope-bearing branch name under zsh. |
| `backlog-guards.sh` | The asymmetry between the two branch scans: the guard refuses broadly, the teardown deletes exactly. |
| `closure-audit-guards.sh` | Three irreversible-act invariants, and the three distinct meanings of a zero denominator. |
| `stage-processes.sh` | The sweep that ends a stage's orphaned processes. Reproduces the leak rather than describing it, and pins that a missing snapshot reports blind rather than clean. |
| `reference-integrity.sh` | Every section citation resolves, every referenced document exists, and every dynamic-context injection names an absolute path. |
| `skill-blocks-portability.sh` | Every bash fence in an authored skill runs under zsh, which is the shell that actually runs it. |
| `reap-orphans.sh` | Which orphaned processes are adoptable, and that another session's process is never ended. |
| `session-cleanup.sh` | The shared budget for the session-end hook, and that silence outside a repository reports as not performed. |
