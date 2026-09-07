# Vendored skills, and why they are not here

Eleven skills under `~/.claude/skills` come from Cloudflare rather than from this
repository. Together they hold 380 files and 2.0 MB, which is roughly 95 percent of the
skills tree by size and none of it authored here. Tracking them would mean carrying
third-party documentation that nobody in this repository maintains, and that goes stale
against its upstream.

The authored skills are tracked. These are not.

| Skill | Covers |
|---|---|
| `cloudflare` | Umbrella platform skill routing to 63 per-product reference directories. |
| `agents-sdk` | Building agents on Workers: state, callable methods, durable execution, queues, observability. |
| `workers-best-practices` | Reviewing and authoring Workers code against production practices. |
| `wrangler` | The Workers command-line interface across every binding type. |
| `durable-objects` | Stateful coordination, remote calls, storage, alarms, and sockets. |
| `sandbox-sdk` | Sandboxed code execution. |
| `cloudflare-email-service` | Transactional email sending and routing. |
| `cloudflare-one` | Zero Trust and secure-access work. |
| `cloudflare-one-migrations` | Migration planning onto Cloudflare One. |
| `turnstile-spin` | End-to-end Turnstile setup, including a deployable worker template. |
| `web-perf` | Page performance auditing through a browser tooling server. |

## Getting them on a new machine

Fetch them from `github.com/cloudflare/skills` into `~/.claude/skills/`. Each skill is a
directory holding a `SKILL.md` and, for the larger ones, a `references/` tree.

## Why the test suite does not mind their absence

Three suites walk the skills tree, and each one carries a denylist naming these eleven.
`skill-blocks-portability.sh` states the reason: their fenced blocks are documentation
snippets rather than scripts anyone runs, so linting them produces noise and no signal.
A denylist rather than an allowlist means a newly authored skill is covered the day it
lands. The suites pass with these skills absent, which is what the clean-install
verification relies on.
