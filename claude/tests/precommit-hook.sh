#!/usr/bin/env bash
# precommit-hook.sh (test) — pin git-hooks/pre-commit, the per-repo commit gate.
#
# Every external tool the hook calls (act, docker, agy) is a stub on PATH driven by STUB_*
# variables, so the suite runs with Docker down and no network. Fixture JSON carries its own
# anchors (STUBMSG, STUBSUM, STUBERR) so no assertion matches static hook prose except the
# bypass hints the hook must print.
#
# Two refusals are the point: a check that cannot run (Docker down, agy erroring twice) rejects
# the commit rather than passing, and a high finding rejects with file:line in the output.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

# Resolve the hook BEFORE HOME is redirected below; it lives under the real ~/.claude.
ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
HOOK="$ROOT/git-hooks/pre-commit"
[ -x "$HOOK" ] || { bad "hook not found or not executable: $HOOK"; summary; exit 1; }
command -v jq >/dev/null 2>&1 || { bad "jq missing; the hook cannot parse agy output"; summary; exit 1; }
ok "hook present and executable"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/precommit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
BIN="$WORK/bin"; REPO="$WORK/repo"; FAKEHOME="$WORK/home"; FX="$WORK/fx"
mkdir -p "$BIN" "$REPO" "$FAKEHOME" "$FX"

export STUB_LOG="$WORK/calls.log" STUB_MODELS="$WORK/models.log" \
       STUB_SCHEMA="$WORK/schema.json" STUB_PROMPT="$WORK/prompt.txt"
# System directories only, so no case can reach the real agy (its OAuth login opens a browser).
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
# ~/.actrc and agy settings are never read, and a real core.hooksPath cannot disable the scratch
# repo's hook: git honors GIT_CONFIG_GLOBAL over HOME.
export HOME="$FAKEHOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name Test
git config --global init.defaultBranch main

cat > "$BIN/agy" <<'STUB'
#!/usr/bin/env bash
n=$(grep -c '^CALL agy$' "$STUB_LOG" 2>/dev/null || true); n=$((n+1))
printf 'CALL agy\n' >> "$STUB_LOG"; printf '%s\n' "$@" >> "$STUB_LOG"
prev=""
for a in "$@"; do
  case "$prev" in
    --json-schema) printf '%s' "$a" > "$STUB_SCHEMA" ;;
    --model)       printf '%s\n' "$a" >> "$STUB_MODELS" ;;
    -p)            printf '%s' "$a" > "$STUB_PROMPT" ;;
  esac
  prev=$a
done
# A second call may be answered by a different fixture; that is how the retry path is exercised.
if [ "$n" -ge 2 ] && [ -n "${STUB_AGY_JSON_2:-}" ]; then cat "$STUB_AGY_JSON_2"; else cat "$STUB_AGY_JSON"; fi
STUB
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf 'CALL docker %s\n' "$*" >> "$STUB_LOG"
exit "${STUB_DOCKER_RC:-0}"
STUB
cat > "$BIN/act" <<'STUB'
#!/usr/bin/env bash
printf 'CALL act %s\n' "$*" >> "$STUB_LOG"
[ "${STUB_ACT_RC:-0}" = "0" ] || echo "STUBACT step failed"
exit "${STUB_ACT_RC:-0}"
STUB
chmod +x "$BIN/agy" "$BIN/docker" "$BIN/act"
[ "$(command -v agy)" = "$BIN/agy" ] || { bad "agy on PATH is not the stub: $(command -v agy)"; summary; exit 1; }
ok "agy on PATH is the stub"

printf '%s\n' '{"status":"SUCCESS","structured_output":{"summary":"STUBSUM no defects","findings":[]}}' > "$FX/clean.json"
printf '%s\n' '{"status":"SUCCESS","structured_output":{"summary":"STUBSUM one blocker","findings":[{"file":"src.txt","line":3,"severity":"high","message":"STUBMSG null dereference","suggestion":"STUBFIX add a guard"}]}}' > "$FX/high.json"
printf '%s\n' '{"status":"SUCCESS","structured_output":{"summary":"STUBSUM advisory only","findings":[{"file":"src.txt","line":2,"severity":"medium","message":"STUBMED unhandled edge case","suggestion":"STUBFIX check the empty case"},{"file":"src.txt","line":1,"severity":"low","message":"STUBLOW naming","suggestion":"rename"}]}}' > "$FX/advisory.json"
printf '%s\n' '{"status":"ERROR","response":"","error":"STUBERR quota exhausted"}' > "$FX/error.json"
# A SUCCESS that ignored the schema is not observable either.
printf '%s\n' '{"status":"SUCCESS","response":"free text"}' > "$FX/noschema.json"
export STUB_AGY_JSON="$FX/clean.json"

# try_commit [VAR=val ...]: commit the staged index under the given env; sets OUT and RC.
try_commit() { : > "$STUB_LOG"; : > "$STUB_MODELS"; OUT=$(cd "$REPO" && env "$@" git commit -qm x 2>&1); RC=$?; }
stage()      { printf 'line %s\n' "$RANDOM$RANDOM" >> "$REPO/src.txt"; git -C "$REPO" add src.txt; }
calls()      { grep -c "^CALL $1" "$STUB_LOG" 2>/dev/null || true; }
head_sha()   { git -C "$REPO" rev-parse HEAD; }
# The shim is the contract install/install-hooks.sh writes; the suite writes the same two lines.
install_shim() { printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOOK" > "$REPO/.git/hooks/pre-commit"; chmod +x "$REPO/.git/hooks/pre-commit"; }
add_workflow() {
  mkdir -p "$REPO/.github/workflows"
  printf 'on: [pull_request, workflow_dispatch]\njobs:\n  local-commit-check:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' > "$REPO/.github/workflows/ci.yml"
  git -C "$REPO" add .github
  try_commit SKIP_HOOKS=1
}

git -C "$REPO" init -q
printf 'line 0\n' > "$REPO/src.txt"
git -C "$REPO" add src.txt
git -C "$REPO" commit -qm init
install_shim
[ -x "$REPO/.git/hooks/pre-commit" ] && ok "shim installed" || bad "shim not installed"

# ============================================================ guards
section "Nothing staged and SKIP_HOOKS call nothing"
: > "$STUB_LOG"
OUT=$(cd "$REPO" && git commit --allow-empty -qm x 2>&1); RC=$?
assert_eq "empty commit passes" "0" "$RC"
assert_eq "no agy call when nothing is staged" "0" "$(calls agy)"
assert_eq "no act call when nothing is staged" "0" "$(calls act)"

stage; try_commit SKIP_HOOKS=1
assert_eq "SKIP_HOOKS=1 passes" "0" "$RC"
assert_contains "SKIP_HOOKS=1 says so" "$OUT" "SKIP_HOOKS=1"
assert_eq "SKIP_HOOKS=1 calls no agy" "0" "$(calls agy)"
assert_eq "SKIP_HOOKS=1 calls no act" "0" "$(calls act)"
assert_eq "SKIP_HOOKS=1 calls no docker" "0" "$(calls docker)"

# ============================================================ phase A
section "No local-commit-check job: act phase is skipped, review still runs"
stage; try_commit
assert_eq "commit passes" "0" "$RC"
assert_eq "act not called without the job" "0" "$(calls act)"
assert_eq "docker not probed without the job" "0" "$(calls docker)"
assert_eq "review ran once" "1" "$(calls agy)"
assert_contains "summary from the fixture is printed" "$OUT" "STUBSUM no defects"

section "Docker down rejects before act and before the review"
add_workflow
before=$(head_sha)
stage; try_commit STUB_DOCKER_RC=1
assert_eq "docker down → rejected" "1" "$RC"
assert_contains "names the bypass" "$OUT" "SKIP_ACT=1"
assert_eq "docker was probed" "1" "$(calls docker)"
assert_eq "act not run with docker down" "0" "$(calls act)"
assert_eq "no review spent on a commit act could not check" "0" "$(calls agy)"
assert_eq "HEAD unchanged" "$before" "$(head_sha)"

section "A failing act run rejects"
try_commit STUB_ACT_RC=1
assert_eq "act failure → rejected" "1" "$RC"
assert_contains "names the bypass" "$OUT" "SKIP_ACT=1"
assert_contains "act was invoked by workflow_dispatch and job id" "$(cat "$STUB_LOG")" "CALL act workflow_dispatch -j local-commit-check"
assert_contains "act's own output is shown" "$OUT" "STUBACT step failed"
assert_eq "no review after a failed act run" "0" "$(calls agy)"

# ============================================================ phase B
section "A high finding rejects with file:line"
before=$(head_sha)
try_commit STUB_AGY_JSON="$FX/high.json"
assert_eq "high → rejected" "1" "$RC"
assert_contains "file:line printed" "$OUT" "src.txt:3"
assert_contains "message printed" "$OUT" "STUBMSG null dereference"
assert_contains "suggestion printed" "$OUT" "STUBFIX add a guard"
assert_contains "names the bypass" "$OUT" "SKIP_REVIEW=1"
assert_eq "act ran before the review" "1" "$(calls act)"
assert_eq "HEAD unchanged" "$before" "$(head_sha)"

section "Medium and low findings are advisory"
before=$(head_sha)
try_commit STUB_AGY_JSON="$FX/advisory.json"
assert_eq "advisory → passes" "0" "$RC"
assert_contains "medium finding listed" "$OUT" "STUBMED unhandled edge case"
assert_contains "low findings counted" "$OUT" "1 low"
assert_not_contains "low finding not listed" "$OUT" "STUBLOW naming"
[ "$(head_sha)" != "$before" ] && ok "HEAD advanced" || bad "HEAD did not advance"

section "An unobservable review is not a pass: retry once, then reject"
stage; try_commit STUB_AGY_JSON="$FX/error.json"
assert_eq "ERROR twice → rejected" "1" "$RC"
assert_eq "two agy calls" "2" "$(calls agy)"
assert_eq "first attempt on the default model" "gemini-3.8-flash-high" "$(sed -n 1p "$STUB_MODELS")"
assert_eq "retry on the fallback model" "gemini-3.7-flash-high" "$(sed -n 2p "$STUB_MODELS")"
assert_contains "agy's error text is shown" "$OUT" "STUBERR quota exhausted"
assert_contains "names the bypass" "$OUT" "SKIP_REVIEW=1"

try_commit STUB_AGY_JSON="$FX/noschema.json"
assert_eq "SUCCESS without structured_output → rejected" "1" "$RC"
assert_eq "schema-less success was retried" "2" "$(calls agy)"

try_commit STUB_AGY_JSON="$FX/error.json" STUB_AGY_JSON_2="$FX/clean.json"
assert_eq "ERROR then SUCCESS → passes" "0" "$RC"
assert_eq "two agy calls" "2" "$(calls agy)"
assert_contains "second answer is used" "$OUT" "STUBSUM no defects"

section "Model override and SKIP_REVIEW"
stage; try_commit PRECOMMIT_REVIEW_MODEL=claude-sonnet-4-6
assert_eq "PRECOMMIT_REVIEW_MODEL honored" "claude-sonnet-4-6" "$(sed -n 1p "$STUB_MODELS")"
stage; try_commit SKIP_REVIEW=1
assert_eq "SKIP_REVIEW=1 passes" "0" "$RC"
assert_eq "SKIP_REVIEW=1 calls no agy" "0" "$(calls agy)"
assert_eq "SKIP_REVIEW=1 still runs act" "1" "$(calls act)"
assert_contains "SKIP_REVIEW says so" "$OUT" "SKIP_REVIEW"

section "Oversized diff is skipped loudly, never silently"
stage; try_commit PRECOMMIT_REVIEW_MAX_BYTES=10
assert_eq "oversized → passes" "0" "$RC"
assert_contains "warns" "$OUT" "WARNING"
assert_contains "says review was skipped" "$OUT" "review skipped"
assert_contains "names the knob" "$OUT" "PRECOMMIT_REVIEW_MAX_BYTES"
assert_eq "agy not called" "0" "$(calls agy)"

section "Lockfiles never reach the prompt"
stage
mkdir -p "$REPO/sub"
printf 'LOCKCONTENT\n' > "$REPO/deps.lock"; printf 'NESTEDLOCK\n' > "$REPO/sub/package-lock.json"
git -C "$REPO" add deps.lock sub/package-lock.json
try_commit
assert_eq "commit passes" "0" "$RC"
assert_contains "prompt carries the source change" "$(cat "$STUB_PROMPT")" "+line "
assert_contains "prompt is fenced" "$(cat "$STUB_PROMPT")" "=== STAGED DIFF ==="
assert_not_contains "top-level lockfile excluded" "$(cat "$STUB_PROMPT")" "LOCKCONTENT"
assert_not_contains "nested lockfile excluded" "$(cat "$STUB_PROMPT")" "NESTEDLOCK"

printf 'MORELOCK\n' >> "$REPO/deps.lock"; git -C "$REPO" add deps.lock
try_commit
assert_eq "only a lockfile staged → passes" "0" "$RC"
assert_eq "agy not called for a lockfile-only change" "0" "$(calls agy)"
assert_contains "says nothing reviewable" "$OUT" "nothing reviewable"

section "The recorded schema is well formed"
stage; try_commit
assert_contains "--json-schema flag present" "$(cat "$STUB_LOG")" "--json-schema"
assert_contains "--output-format json" "$(cat "$STUB_LOG")" "--output-format"
assert_contains "slash commands disabled" "$(cat "$STUB_LOG")" "--disable-slash-commands"
assert_contains "print timeout set" "$(cat "$STUB_LOG")" "--print-timeout"
assert_rc "findings array carries items (agy rejects it otherwise)" 0 jq -e '.properties.findings.items' "$STUB_SCHEMA"
assert_rc "severity enum is low/medium/high" 0 jq -e '.properties.findings.items.properties.severity.enum == ["low","medium","high"]' "$STUB_SCHEMA"
assert_rc "findings is required" 0 jq -e '.required | index("findings")' "$STUB_SCHEMA"

# ============================================================ chaining
section "pre-commit.local runs last and its exit code propagates"
printf '#!/bin/sh\necho LOCALHOOK ran >&2\nexit 7\n' > "$REPO/.git/hooks/pre-commit.local"
chmod +x "$REPO/.git/hooks/pre-commit.local"
stage
: > "$STUB_LOG"
OUT=$(cd "$REPO" && bash "$HOOK" 2>&1); RC=$?
assert_eq "direct run propagates the local hook's rc" "7" "$RC"
assert_contains "local hook ran" "$OUT" "LOCALHOOK ran"
assert_contains "review finished before the local hook" "${OUT%%LOCALHOOK*}" "STUBSUM"
try_commit
assert_eq "git rejects on the local hook" "1" "$RC"
assert_contains "local hook output shown through git" "$OUT" "LOCALHOOK ran"
printf '#!/bin/sh\nexit 0\n' > "$REPO/.git/hooks/pre-commit.local"
try_commit
assert_eq "passing local hook lets the commit through" "0" "$RC"
chmod -x "$REPO/.git/hooks/pre-commit.local"
printf '#!/bin/sh\necho LOCALHOOK ran >&2\nexit 7\n' > "$REPO/.git/hooks/pre-commit.local"
stage; try_commit
assert_eq "non-executable local hook is ignored" "0" "$RC"
assert_not_contains "non-executable local hook did not run" "$OUT" "LOCALHOOK"
rm -f "$REPO/.git/hooks/pre-commit.local"

# ============================================================ agy absent
section "agy absent from PATH is advisory, not a rejection"
# A restricted PATH, not a removed stub: with the stub gone the hook would find the REAL agy
# further down PATH, and under the scratch HOME that launches its OAuth login (observed
# 2026-09-12). Only the two other stubs and the system directories are reachable here.
mkdir -p "$WORK/noagy"; cp "$BIN/act" "$BIN/docker" "$WORK/noagy/"
before=$(head_sha)
stage; try_commit PATH="$WORK/noagy:/usr/bin:/bin"
assert_eq "commit passes without agy" "0" "$RC"
assert_contains "says review was not performed" "$OUT" "agy not on PATH"
assert_eq "no agy stub call either" "0" "$(calls agy)"
[ "$(head_sha)" != "$before" ] && ok "HEAD advanced" || bad "HEAD did not advance"

summary
