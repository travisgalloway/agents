# Gemini and Antigravity configuration

Not populated yet. This directory is reserved for the Gemini and Antigravity side of the
same setup, so both toolchains share one repository.

On this machine the configuration lives in two places.

| Path | Holds |
|---|---|
| `~/.gemini/config/` | `config.json`, `mcp_config.json`, and per-project settings. |
| `~/.antigravity-ide/` | `argv.json` and installed extensions. |

The rest of `~/.gemini` is runtime state: conversations, caches, logs, crash reports, and
per-session scratch. None of it belongs in version control.

When this side is populated, follow the shape the Claude side already uses. Keep
`gemini/` a plain mirror of the shareable files, add an installer beside
`install/claude.sh`, and describe every tracked file in `docs/`. Where an absolute path
has to appear in a file, write `__GEMINI_HOME__` and let the installer render it, so no
username reaches this public repository.
