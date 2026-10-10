---
name: ux-audit
model: opus
effort: high
description: Review a user interface statically and in a running browser. Pass U1 reads component source for missing labels and alt text, focus handling, missing loading/error/empty states, destructive actions without confirmation, hardcoded colors and inconsistent copy. Pass U2 starts the app, drives it with Playwright at three widths, and records screenshots, axe violations, keyboard focus problems, overflow and console errors. Writes a dated report under docs/reviews/, parks low findings, and creates issues for the rest behind one confirmation gate. Never for exploratory use; it creates issues in bulk and starts the dev server.
argument-hint: "[area=<path>] [live=off] [dry-run]"
# `model: opus` + `effort: high` mirror /closure-audit: classifying a finding and deciding
# ticket-vs-report is judgement work. Step 0 still runs the settings.json drift check, because the
# gate ends a turn and a command's `model:` is not sticky past it.
# Scanning runs on sonnet at dispatch (`model: "sonnet"` on each `Agent` call), never on opus.
#
# Deliberately NOT `arguments: [...]`: Step 1 strips tokens from anywhere in the string.
#
# User-invoked only. This CREATES issues and writes into the repo. /audit runs this lens by reading
# this file and the method files, never through the Skill tool, so denying model invocation costs
# no handoff.
disable-model-invocation: true
allowed-tools: Bash(__CLAUDE_HOME__/lib/branches.sh)
---

Repo context, pre-resolved (see `~/.claude/lib/branches.sh`; empty values mean unresolved —
fall back to the per-step instructions below):

!`__CLAUDE_HOME__/lib/branches.sh`

> **Output convention — timestamp every turn.** At the end of each turn (every time you finish responding while running this command), run `date '+%Y-%m-%d %H:%M:%S %Z'` and print its result on its own final line as a footer, e.g. `🕐 2026-08-15 10:17:13 CDT`. Do this on every turn — intermediate progress turns, gate turns, and the final summary alike. Never hand-write the time; always read it from `date` so it reflects the machine's real local timezone.

Review the user interface from its source, and in a running browser.

## Operating context & gates

- **Read `~/.claude/skills/audit/references/review-method.md` and
  `~/.claude/skills/audit/references/ux.md` first.** Also read
  `~/.claude/skills/feature-closure/references/gap-detection.md`, which owns the denominator rule.
  The method files hold the passes, the finding ID, severity, sorting, and the report format. This
  command is their procedure and does not restate them.
- **Everything before Step 6 is read-only.** Nothing is written to the repo or the backlog until
  the gate clears.
- **`dry-run` stops after Step 5.** It prints the proposal and exits.
- **This command never branches, commits, opens a PR, or merges.**

## Step 0: Detect repository and stack

Follow `/closure-audit` Step 0 exactly: take `{owner}`, `{repo}` and `{repo_root}` from the block
above, run the model drift check, detect the stack from its manifests, and read `CLAUDE.md`. If
you cannot identify the stack, **say so and stop.** Do not scan with guessed patterns.

Set `{run}` to `date '+%Y%m%d-%H%M%S'` and `{run_dir}` to `{repo_root}/.claude/audit/{run}`.
Check `git -C {repo_root} check-ignore -q .claude/audit`. When the path is not ignored, carry a
`⚠` line to the gate. Never edit `.gitignore` yourself.

## Step 1: Parse scope

Strip these tokens from anywhere in `$ARGUMENTS`, in any order:

- `area=<path>`: restrict U1, and the routes U2 visits, to a subtree. At most one. Repo-relative.
- `live=off`: skip U2. The gate prints `U2 skipped (live=off)`, which is neither `n/a` nor BLIND.
- `dry-run`: stop after Step 5. U2 still runs, because it only reads the app.

**Anything else is a hard usage error.** A fuzzy match produces a scope nobody chose, and this
command writes to the backlog.

## Step 2: Run the passes

Dispatch U1 and U2 as **two parallel subagents** (`Agent` tool). Give each the stack, the scope,
the pass section of `ux.md`, the path to `review-method.md`, and the absolute path of its
output file: `{run_dir}/ux-U1.jsonl` or `{run_dir}/ux-U2.jsonl`. Pass `model: "sonnet"` on both.

Each pass returns **a path, a denominator, a count, and one line.** Never findings as text.

**U2 holds a browser and a dev server**, so give its subagent these extra instructions:

- Use `subagent_type: general-purpose`, which carries the Playwright MCP tools, with `model: "sonnet"`.
- Start the server and end it exactly as `ux.md` "Starting the app" shows. The PID comes from `$!`
  on the starting line.
- **End the server before returning, on every path.** The one-line return names the PID and
  whether `ps` still lists it. A PID still listed is a blocker at the gate.
- Write screenshots under `{run_dir}/ux/`, never into the repository's tracked tree.

**A pass that cannot see its target reports BLIND, never clean.** Resolve every zero to `n/a`,
`BLIND` or `clean` per `gap-detection.md` before it reaches the gate. A BLIND pass halts and goes
to the gate as UNAUDITED. The other pass continues.

## Step 3: Verify and sort

Read the JSONL rows. Drop REFUTED rows. Assign severity per `review-method.md` Rule 3 and
`proposed` per Rule 4. Compute every finding ID per Rule 2.

## Step 4: Reconcile against the backlog

Follow `review-method.md` Rule 5: one full fetch, the truncation check, and a match on finding ID.
Fetch the labels and mark `review:ux` as proposed when it is absent.

## Step 5: Build the proposal

Assemble without writing anything: the report `docs/reviews/{YYYY-MM-DD}-ux.md`, the
`docs/parked-findings.md` appends, the issues to create, the comments to post, and the labels to
create. If `dry-run`, print the proposal and stop.

## Step 6: The gate

Print the proposal, send a `PushNotification`, and **wait**. This is the only gate.

```
/ux-audit ({owner}/{repo})  scope: {scope}  —  {date}

stack: SvelteKit / vitest + playwright      server: npm run dev, PID 48113, ended
coverage:  U1 64 components, 19 routes / 12   control: 64 `<script` hits
           U2 17/19 routes visited / 9        2 routes UNAUDITED (auth, no storageState)
              axe: node_modules/axe-core     screenshots: .claude/audit/20260922-101500/ux/

report     docs/reviews/2026-09-22-ux.md   21 findings, 1 decision needed
parked     docs/parked-findings.md         +6

new labels (1)    review:ux         — decline and these issues land unlabelled

create (4)
  UX-5a1e02bb  Delete project has no confirmation or undo             high    CONFIRMED
  UX-c8f3d410  /settings overflows horizontally at 375 px             medium  CONFIRMED
  …

⚠ /admin and /billing UNAUDITED: redirect to /login, no storageState in .claude/ux-audit.json
```

Every number carries its denominator. A BLIND pass appears as `⚠ … UNAUDITED`, never by omission.
`n/a` and UNAUDITED are different words and are never swapped.

## Step 7: Write

Only after the gate, in the order `review-method.md` gives under "The gate and the write". An
issue exists only when `gh issue view {n}` returns it. After a partial write, record what landed
and stop. **Do not retry the whole batch.**

## Step 8: Summary

Build every row from `gh` and the filesystem:

```bash
# Filter locally: GitHub search tokenizes on the hyphen and would match unrelated titles.
gh issue list --repo {owner}/{repo} --state open --limit 1000 --json number,title \
  --jq '.[] | select(.title | startswith("UX-")) | "#\(.number) \(.title)"'
git -C {repo_root} status --porcelain -- docs/
```

Read the exit status: `0` means the output is the answer, and anything else means the state is
**unverified**, never `none`. Do not append `|| true`. Confirm the U2 server is gone with
`ps -p "$(cat {run_dir}/ux/server.pid)"`, and print its PID on the summary when `ps` still lists
it. Then send a final `PushNotification`.

## Important Notes

- **Read-only until Step 6.** Everything before the gate can be re-run freely.
- **Idempotent by finding ID.** A second run on an unchanged repo must propose **zero creates**.
- **Never closes or reopens an issue.**
- **Never creates a label outside the gate.**
- **Never branches, commits, or merges.**
- **Never leaves the dev server running.** U2 ends it before returning, and Step 8 checks.
