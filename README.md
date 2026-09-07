# agents

Configuration for coding agents, shared between machines and readable by other people.
Claude Code is populated. Gemini and Antigravity are reserved.

## Layout

| Path | Holds |
|---|---|
| `claude/` | A mirror of the shareable part of `~/.claude`. Sixty-two files, no repository metadata mixed in. |
| `install/claude.sh` | Installs that mirror into `~/.claude`, and pulls edits back out again. |
| `install/claude-plugins.txt` | The eight marketplace plugins to re-install. No plugin code is vendored. |
| `docs/` | What every tracked file does, how the parts work together, and what was deliberately left out. |
| `gemini/` | Reserved. See [gemini/README.md](gemini/README.md). |

Start with [docs/claude-catalog.md](docs/claude-catalog.md) for a file-by-file listing,
and [docs/claude-workflow.md](docs/claude-workflow.md) for how the pipeline fits together.

## Read this before you install

These are one person's settings, and three of the choices in them weaken defaults that
exist for good reason. Installing replaces your `~/.claude/settings.json`, so read it
first and decide for yourself.

**Two permission prompts are switched off.** `skipDangerousModePermissionPrompt` and
`skipAutoPermissionPrompt` remove the confirmations in front of the mode that skips
permission checks. Delete both keys if you want those prompts back.

**The allowlist is broader than it looks.** It reads as six narrow entries, but
`Bash(xargs:*)` runs any program named in its own arguments, and `Bash(git:*)` covers
`git -c core.pager=...` and a force push. Together they approach unrestricted execution
without a prompt. Four subagent definitions also declare `permissionMode: bypassPermissions`,
which is deliberate for unattended runs and worth understanding before you use them.

**A linked install makes the clone live code.** Under the default mode, hooks and libraries
in `~/.claude` are symlinks into this working copy, and `settings.json` runs four of them
automatically at session start, session end, and on every stop. Pulling a change here
deploys it to the next session with no review step. Treat `git pull` as a deploy, or install
with `--copy` instead.

## Installing on a new machine

```bash
git clone git@github.com:travisgalloway/agents.git ~/github/agents
cd ~/github/agents
bash install/claude.sh install --dry-run     # read the plan first
bash install/claude.sh install
bash install/claude.sh plugins               # prints the plugin commands to run
bash ~/.claude/tests/run-all.sh              # expect ALL SUITES PASS
```

The installer writes only inside `~/.claude`, one file at a time. It never replaces a
directory, never touches a path it does not track, and moves any file it would overwrite
into `~/.claude/backups/config-<timestamp>/` first. Set `CLAUDE_HOME` to install
somewhere else, which is how the suite is tested against a scratch tree.

## Symlinks and the rendered exceptions

Most files are symlinked back to the clone, so editing the repository changes the live
configuration immediately. Thirteen files cannot be, because they carry the token
`__CLAUDE_HOME__` where a literal absolute path has to appear.

Claude Code does not expand `~` or `$HOME` in a skill's `allowed-tools` grant, in a
dynamic-context injection, or reliably in a hook command string. One test suite asserts
that every injection names an absolute path to an executable. So the repository stores a
token, keeping the username out of a public repository, and the installer renders it with
the home directory of whoever is installing.

`settings.json` is rendered for a second reason. Claude Code rewrites it whenever the
model, effort level, or output style changes, and a symlink would make every such change
dirty the clone.

## Working with the rendered files

| Command | Effect |
|---|---|
| `install/claude.sh install` | Repository to `~/.claude`. Refuses a rendered file with local edits rather than discarding them. |
| `install/claude.sh capture` | `~/.claude` back to the repository, restoring the token. |
| `install/claude.sh diff` | Reports drift on every tracked file. Exits non-zero if any is found. |
| `install/claude.sh uninstall` | Removes what install placed, keeping anything modified locally. |

Editing a symlinked file needs nothing further. Editing a rendered file in `~/.claude`
needs a `capture` before committing. Adding a file to the repository needs `install`
re-run, since the installer works per file rather than linking whole directories.

## What is deliberately not here

Runtime state is excluded and blocked by name in `.gitignore`: background job state at
1.0 GB, per-session team rosters, transcripts, caches, and telemetry. That material
carries private repository names and account identifiers, and none of it is
configuration.

Third-party content is recorded rather than vendored. The eight plugins are listed by
name, and the eleven Cloudflare skills are described in
[docs/vendored-skills.md](docs/vendored-skills.md).
