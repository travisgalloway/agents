#!/usr/bin/env bash
# precommit-hook.sh (test) — pin git-hooks/pre-commit, the per-repo commit gate.
#
# Every external tool the hook calls (act, docker, claude) is a stub on PATH driven by STUB_*
# variables, so the suite runs with Docker down and no network. Fixture JSON carries its own
# anchors (STUBMSG, STUBSUM, STUBERR, STUBREVIEW) so no assertion matches static hook prose except
# the bypass hints the hook must print.
#
# Two refusals are the point: a check that cannot run (Docker down, claude erroring or timing out
# twice) rejects the commit rather than passing, and a high finding rejects with file:line.
# The claude stub answers two call shapes: the /code-review session (logged as `CALL claude
# review`) and the tool-less classifier carrying --json-schema (logged as `CALL claude classify`).

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

# Resolve the hook BEFORE HOME is redirected below; it lives under the real ~/.claude.
ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
HOOK="$ROOT/git-hooks/pre-commit"
[ -x "$HOOK" ] || { bad "hook not found or not executable: $HOOK"; summary; exit 1; }
command -v jq >/dev/null 2>&1 || { bad "jq missing; the hook cannot parse claude output"; summary; exit 1; }
ok "hook present and executable"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/precommit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
BIN="$WORK/bin"; REPO="$WORK/repo"; FAKEHOME="$WORK/home"; FX="$WORK/fx"
mkdir -p "$BIN" "$REPO" "$FAKEHOME" "$FX"

export STUB_LOG="$WORK/calls.log" STUB_MODELS="$WORK/models.log" \
       STUB_SCHEMA="$WORK/schema.json" STUB_PROMPT="$WORK/prompt.txt" \
       STUB_REVIEW_PROMPT="$WORK/review-prompt.txt" STUB_PATCH="$WORK/patch.txt"
# System directories only, so no case can reach the real claude and spend a review.
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
# ~/.actrc and ~/.claude settings are never read, and a real core.hooksPath cannot disable the scratch
# repo's hook: git honors GIT_CONFIG_GLOBAL over HOME.
export HOME="$FAKEHOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name Test
git config --global init.defaultBranch main

cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
kind=review
for a in "$@"; do [ "$a" = "--json-schema" ] && kind=classify; done
n=$(grep -c "^CALL claude $kind\$" "$STUB_LOG" 2>/dev/null || true); n=$((n+1))
printf 'CALL claude %s\n' "$kind" >> "$STUB_LOG"; printf '%s\n' "$@" >> "$STUB_LOG"
prev=""
for a in "$@"; do
  case "$prev" in
    --json-schema) printf '%s' "$a" > "$STUB_SCHEMA" ;;
    --model)       [ "$kind" = review ] && printf '%s\n' "$a" >> "$STUB_MODELS" ;;
    -p)            if [ "$kind" = review ]; then
                     printf '%s' "$a" > "$STUB_REVIEW_PROMPT"
                     # The patch the hook hands over lives in its temp dir, gone after the commit.
                     tgt=${a##* }; [ -f "$tgt" ] && cp "$tgt" "$STUB_PATCH"
                   else printf '%s' "$a" > "$STUB_PROMPT"; fi ;;
  esac
  prev=$a
done
if [ "$kind" = review ]; then
  [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
  cat "${STUB_REVIEW_JSON:-$STUB_REVIEW_DEFAULT}"
  exit 0
fi
# A second classify call may be answered by a different fixture; that exercises the retry path.
if [ "$n" -ge 2 ] && [ -n "${STUB_CLAUDE_JSON_2:-}" ]; then cat "$STUB_CLAUDE_JSON_2"; else cat "$STUB_CLAUDE_JSON"; fi
STUB
# STUB_DOCKER_RC fails `docker info`. STUB_DOCKER_LEFTOVER=1 makes the label query find STUBCID.
# STUB_DOCKER_PATHLEFT=1 makes the repo-path query find STUBPATH after the run only, and
# STUB_DOCKER_PATHPRE=1 makes it find STUBPRE before and after, as a container the run did not start.
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf 'CALL docker %s\n' "$*" >> "$STUB_LOG"
case "$1" in
  info)    exit "${STUB_DOCKER_RC:-0}" ;;
  ps)
    case "$*" in
      *volume=*)
        [ "${STUB_DOCKER_PATHPRE:-0}" = 1 ] && echo STUBPRE
        n=$(grep -c 'CALL docker ps.*volume=' "$STUB_LOG")
        [ "${STUB_DOCKER_PATHLEFT:-0}" = 1 ] && [ "$n" -ge 2 ] && echo STUBPATH ;;
      *) [ "${STUB_DOCKER_LEFTOVER:-0}" = 1 ] && echo STUBCID ;;
    esac
    exit 0 ;;
  inspect) echo "act-STUBVOL-env act-toolcache " ;;
esac
exit 0
STUB
# STUB_ACT_SLEEP keeps the run alive, as a foreground sleep child, so a stop must reach the tree.
cat > "$BIN/act" <<'STUB'
#!/usr/bin/env bash
printf 'CALL act %s\n' "$*" >> "$STUB_LOG"
# STUB_ACT_IGNORE_TERM=1 ignores TERM in the stub and its sleep, so only KILL ends the run.
[ "${STUB_ACT_IGNORE_TERM:-0}" = 1 ] && trap '' TERM
[ -z "${STUB_ACT_SLEEP:-}" ] || sleep "$STUB_ACT_SLEEP"
[ "${STUB_ACT_RC:-0}" = "0" ] || echo "STUBACT step failed"
exit "${STUB_ACT_RC:-0}"
STUB
chmod +x "$BIN/claude" "$BIN/docker" "$BIN/act"
[ "$(command -v claude)" = "$BIN/claude" ] || { bad "claude on PATH is not the stub: $(command -v claude)"; summary; exit 1; }
ok "claude on PATH is the stub"

printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"reviewed":true,"summary":"STUBSUM no defects","findings":[]}}' > "$FX/clean.json"
printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"reviewed":true,"summary":"STUBSUM one blocker","findings":[{"file":"src.txt","line":3,"severity":"high","message":"STUBMSG null dereference","suggestion":"STUBFIX add a guard"}]}}' > "$FX/high.json"
printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"reviewed":true,"summary":"STUBSUM advisory only","findings":[{"file":"src.txt","line":2,"severity":"medium","message":"STUBMED unhandled edge case","suggestion":"STUBFIX check the empty case"},{"file":"src.txt","line":1,"severity":"low","message":"STUBLOW naming","suggestion":"rename"}]}}' > "$FX/advisory.json"
printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"STUBERR quota exhausted"}' > "$FX/error.json"
# A success that ignored the schema is not observable either.
printf '%s\n' '{"type":"result","is_error":false,"result":"free text"}' > "$FX/noschema.json"
# An error flag outranks a structured_output that happens to be present.
printf '%s\n' '{"type":"result","is_error":true,"result":"STUBERR partial","structured_output":{"reviewed":true,"summary":"STUBSUM no defects","findings":[]}}' > "$FX/erroredschema.json"
# A session that never reviewed anything ("Unknown command") classifies as reviewed=false.
printf '%s\n' '{"type":"result","is_error":false,"structured_output":{"reviewed":false,"summary":"STUBSUM not a review","findings":[]}}' > "$FX/notreview.json"
# The /code-review session's own answers.
printf '%s\n' '{"type":"result","is_error":false,"result":"STUBREVIEW src.txt:3 null dereference"}' > "$FX/review.json"
printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"STUBERR review session failed"}' > "$FX/review-error.json"
printf '%s\n' '{"type":"result","is_error":false,"result":"STUBREVIEW partial","permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/x"}}]}' > "$FX/review-denied.json"
export STUB_CLAUDE_JSON="$FX/clean.json" STUB_REVIEW_DEFAULT="$FX/review.json"

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
assert_eq "no claude call when nothing is staged" "0" "$(calls "claude review")"
assert_eq "no act call when nothing is staged" "0" "$(calls act)"

stage; try_commit SKIP_HOOKS=1
assert_eq "SKIP_HOOKS=1 passes" "0" "$RC"
assert_contains "SKIP_HOOKS=1 says so" "$OUT" "SKIP_HOOKS=1"
assert_eq "SKIP_HOOKS=1 calls no claude" "0" "$(calls "claude review")"
assert_eq "SKIP_HOOKS=1 calls no act" "0" "$(calls act)"
assert_eq "SKIP_HOOKS=1 calls no docker" "0" "$(calls docker)"

# ============================================================ phase A
section "No local-commit-check job: act phase is skipped, review still runs"
stage; try_commit
assert_eq "commit passes" "0" "$RC"
assert_eq "act not called without the job" "0" "$(calls act)"
assert_eq "docker not probed without the job" "0" "$(calls docker)"
assert_eq "review ran once" "1" "$(calls "claude review")"
assert_contains "summary from the fixture is printed" "$OUT" "STUBSUM no defects"

section "Docker down rejects before act and before the review"
add_workflow
before=$(head_sha)
stage; try_commit STUB_DOCKER_RC=1
assert_eq "docker down → rejected" "1" "$RC"
assert_contains "names the bypass" "$OUT" "SKIP_ACT=1"
assert_eq "docker was probed" "1" "$(calls docker)"
assert_eq "act not run with docker down" "0" "$(calls act)"
assert_eq "no review spent on a commit act could not check" "0" "$(calls "claude review")"
assert_eq "HEAD unchanged" "$before" "$(head_sha)"

section "A failing act run rejects"
try_commit STUB_ACT_RC=1
assert_eq "act failure → rejected" "1" "$RC"
assert_contains "names the bypass" "$OUT" "SKIP_ACT=1"
assert_contains "act was invoked by workflow_dispatch and job id" "$(cat "$STUB_LOG")" "workflow_dispatch -j local-commit-check"
assert_contains "act removes containers after a failure" "$(cat "$STUB_LOG")" "CALL act --rm"
assert_contains "act labels this run's containers" "$(cat "$STUB_LOG")" "--container-options --label claude.githook.run=pre-commit-"
assert_contains "the label sweep ran" "$(cat "$STUB_LOG")" "CALL docker ps -aq --filter label=claude.githook.run=pre-commit-"
assert_eq "nothing removed when the sweep finds nothing" "0" "$(calls "docker rm")"
assert_contains "act's own output is shown" "$OUT" "STUBACT step failed"
assert_eq "no review after a failed act run" "0" "$(calls "claude review")"

section "The sweep removes a container act left behind"
try_commit STUB_ACT_RC=1 STUB_DOCKER_LEFTOVER=1
assert_eq "act failure → rejected" "1" "$RC"
assert_contains "the leftover container is removed" "$(cat "$STUB_LOG")" "CALL docker rm -f STUBCID"
assert_contains "its named act volume is removed" "$(cat "$STUB_LOG")" "CALL docker volume rm act-STUBVOL-env"
assert_not_contains "the shared tool cache is kept" "$(grep 'volume rm' "$STUB_LOG")" "act-toolcache"
assert_contains "says so" "$OUT" "1 leftover act container"

section "The sweep finds a container by repo path when the label cannot reach it"
try_commit STUB_ACT_RC=1 STUB_DOCKER_PATHLEFT=1 STUB_DOCKER_PATHPRE=1
assert_eq "act failure → rejected" "1" "$RC"
assert_contains "a path-matched container the run started is removed" "$(cat "$STUB_LOG")" "STUBPATH"
assert_not_contains "a path-matched container that predates the run is kept" "$(grep '^CALL docker rm' "$STUB_LOG")" "STUBPRE"

section "An act run that outlives PRECOMMIT_ACT_TIMEOUT rejects"
start=$(date +%s)
try_commit STUB_ACT_SLEEP=8 PRECOMMIT_ACT_TIMEOUT=1
assert_eq "act timeout → rejected" "1" "$RC"
assert_contains "names the knob" "$OUT" "PRECOMMIT_ACT_TIMEOUT"
[ $(( $(date +%s) - start )) -lt 6 ] && ok "the watchdog ended act early" || bad "the watchdog did not end act"
assert_eq "no review after an act timeout" "0" "$(calls "claude review")"

section "A child that ignores TERM is KILLed by the watchdog"
start=$(date +%s)
try_commit STUB_ACT_SLEEP=9.41 STUB_ACT_IGNORE_TERM=1 PRECOMMIT_ACT_TIMEOUT=1 HOOK_STOP_GRACE=1
assert_eq "act timeout → rejected" "1" "$RC"
[ $(( $(date +%s) - start )) -lt 7 ] && ok "the watchdog escalated to KILL" || bad "the hook waited on a TERM-ignoring child"
if pgrep -f 'sleep 9.41' >/dev/null; then bad "the TERM-ignoring child outlived the hook"; pkill -KILL -f 'sleep 9.41'; else ok "no process outlived the hook"; fi

section "TERM to the hook stops act's whole tree and sweeps"
: > "$STUB_LOG"
( cd "$REPO" && exec env STUB_ACT_SLEEP=9.37 STUB_DOCKER_LEFTOVER=1 bash "$HOOK" >"$WORK/term.out" 2>&1 ) &
hp=$!
for _ in $(seq 1 50); do grep -q '^CALL act' "$STUB_LOG" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$hp"; wait "$hp"; RC=$?
assert_eq "hook exits 143 on TERM" "143" "$RC"
if pgrep -f 'sleep 9.37' >/dev/null; then bad "act's child outlived the hook"; pkill -f 'sleep 9.37'; else ok "no act process outlived the hook"; fi
assert_contains "the sweep ran on the way out" "$(cat "$STUB_LOG")" "CALL docker rm -f STUBCID"

# ============================================================ phase B
section "A high finding rejects with file:line"
before=$(head_sha)
try_commit STUB_CLAUDE_JSON="$FX/high.json"
assert_eq "high → rejected" "1" "$RC"
assert_contains "file:line printed" "$OUT" "src.txt:3"
assert_contains "message printed" "$OUT" "STUBMSG null dereference"
assert_contains "suggestion printed" "$OUT" "STUBFIX add a guard"
assert_contains "names the bypass" "$OUT" "SKIP_REVIEW=1"
assert_eq "act ran before the review" "1" "$(calls act)"
assert_eq "HEAD unchanged" "$before" "$(head_sha)"

section "Medium and low findings are advisory"
before=$(head_sha)
try_commit STUB_CLAUDE_JSON="$FX/advisory.json"
assert_eq "advisory → passes" "0" "$RC"
assert_contains "medium finding listed" "$OUT" "STUBMED unhandled edge case"
assert_contains "low findings counted" "$OUT" "1 low"
assert_not_contains "low finding not listed" "$OUT" "STUBLOW naming"
[ "$(head_sha)" != "$before" ] && ok "HEAD advanced" || bad "HEAD did not advance"

section "An unobservable review is not a pass: retry once, then reject"
stage; try_commit STUB_CLAUDE_JSON="$FX/error.json"
assert_eq "error twice → rejected" "1" "$RC"
assert_eq "two review sessions" "2" "$(calls "claude review")"
assert_eq "two classifier calls" "2" "$(calls "claude classify")"
assert_eq "first attempt on the default model" "sonnet" "$(sed -n 1p "$STUB_MODELS")"
assert_eq "retry on the fallback model" "opus" "$(sed -n 2p "$STUB_MODELS")"
assert_contains "claude's error text is shown" "$OUT" "STUBERR quota exhausted"
assert_contains "names the bypass" "$OUT" "SKIP_REVIEW=1"

try_commit STUB_CLAUDE_JSON="$FX/noschema.json"
assert_eq "success without structured_output → rejected" "1" "$RC"
assert_eq "schema-less success was retried" "2" "$(calls "claude review")"

try_commit STUB_CLAUDE_JSON="$FX/notreview.json"
assert_eq "text that was not a review → rejected" "1" "$RC"
assert_eq "it was retried once" "2" "$(calls "claude review")"

try_commit STUB_CLAUDE_JSON="$FX/erroredschema.json"
assert_eq "is_error with structured_output → rejected" "1" "$RC"
assert_contains "the error text is shown" "$OUT" "STUBERR partial"

try_commit STUB_REVIEW_JSON="$FX/review-denied.json"
assert_eq "a review with a denied tool call → rejected" "1" "$RC"
assert_eq "no classifier call for a degraded review" "0" "$(calls "claude classify")"

try_commit STUB_REVIEW_JSON="$FX/review-error.json"
assert_eq "review session error twice → rejected" "1" "$RC"
assert_eq "no classifier call after a failed review" "0" "$(calls "claude classify")"
assert_contains "the review session's error is shown" "$OUT" "STUBERR review session failed"

section "A review that outlives PRECOMMIT_REVIEW_TIMEOUT is a failed attempt"
start=$(date +%s)
try_commit STUB_SLEEP=5 PRECOMMIT_REVIEW_TIMEOUT=1
assert_eq "timeout twice → rejected" "1" "$RC"
assert_contains "names the timeout" "$OUT" "timed out after 1s"
[ $(( $(date +%s) - start )) -lt 5 ] && ok "the watchdog ended both attempts early" || bad "the watchdog did not end the stalled review"

try_commit STUB_CLAUDE_JSON="$FX/error.json" STUB_CLAUDE_JSON_2="$FX/clean.json"
assert_eq "error then success → passes" "0" "$RC"
assert_eq "two review sessions" "2" "$(calls "claude review")"
assert_contains "second answer is used" "$OUT" "STUBSUM no defects"

section "Model override and SKIP_REVIEW"
stage; try_commit PRECOMMIT_REVIEW_MODEL=haiku PRECOMMIT_REVIEW_LEVEL=high
assert_eq "PRECOMMIT_REVIEW_MODEL honored" "haiku" "$(sed -n 1p "$STUB_MODELS")"
assert_contains "PRECOMMIT_REVIEW_LEVEL reaches /code-review" "$(cat "$STUB_REVIEW_PROMPT")" "/code-review high "
stage; try_commit SKIP_REVIEW=1
assert_eq "SKIP_REVIEW=1 passes" "0" "$RC"
assert_eq "SKIP_REVIEW=1 calls no claude" "0" "$(calls "claude review")"
assert_eq "SKIP_REVIEW=1 still runs act" "1" "$(calls act)"
assert_contains "SKIP_REVIEW says so" "$OUT" "SKIP_REVIEW"

section "Oversized diff is skipped loudly, never silently"
stage; try_commit PRECOMMIT_REVIEW_MAX_BYTES=10
assert_eq "oversized → passes" "0" "$RC"
assert_contains "warns" "$OUT" "WARNING"
assert_contains "says review was skipped" "$OUT" "review skipped"
assert_contains "names the knob" "$OUT" "PRECOMMIT_REVIEW_MAX_BYTES"
assert_eq "claude not called" "0" "$(calls "claude review")"

section "The review runs /code-review, and the classifier reads its text"
stage
mkdir -p "$REPO/sub"
printf 'LOCKCONTENT\n' > "$REPO/deps.lock"; printf 'NESTEDLOCK\n' > "$REPO/sub/package-lock.json"
git -C "$REPO" add deps.lock sub/package-lock.json
try_commit
assert_eq "commit passes" "0" "$RC"
assert_contains "review prompt is the skill at the default level" "$(cat "$STUB_REVIEW_PROMPT")" "/code-review medium "
assert_contains "its target is the staged patch" "$(cat "$STUB_PATCH" 2>/dev/null)" "+line "
assert_not_contains "the patch excludes lockfiles" "$(cat "$STUB_PATCH" 2>/dev/null)" "NESTEDLOCK"
assert_contains "classifier carries the review text" "$(cat "$STUB_PROMPT")" "STUBREVIEW src.txt:3"
assert_contains "classifier input is fenced" "$(cat "$STUB_PROMPT")" "=== REVIEW "
tok=$(sed -n 's/^=== REVIEW \([0-9a-f]*\) ===$/\1/p' "$STUB_PROMPT")
[ "${#tok}" -ge 16 ] && ok "the fence carries a random token" || bad "the fence has no token" "$tok"
assert_contains "the closing fence carries the same token" "$(cat "$STUB_PROMPT")" "=== END REVIEW $tok ==="

printf 'MORELOCK\n' >> "$REPO/deps.lock"; git -C "$REPO" add deps.lock
try_commit
assert_eq "only a lockfile staged → passes" "0" "$RC"
assert_eq "claude not called for a lockfile-only change" "0" "$(calls "claude review")"
assert_contains "says nothing reviewable" "$OUT" "nothing reviewable"

section "The recorded schema is well formed"
stage; try_commit
assert_contains "--json-schema flag present" "$(cat "$STUB_LOG")" "--json-schema"
assert_contains "--output-format json" "$(cat "$STUB_LOG")" "--output-format"
assert_not_contains "slash commands stay enabled for /code-review" "$(cat "$STUB_LOG")" "--disable-slash-commands"
assert_not_contains "no --bare, which drops the skill" "$(cat "$STUB_LOG")" "--bare"
assert_contains "the user's hooks are off in the nested sessions" "$(cat "$STUB_LOG")" '"disableAllHooks":true'
assert_contains "no MCP server is loaded" "$(cat "$STUB_LOG")" "--strict-mcp-config"
assert_not_contains "the review gets no Bash, which writes files via --output" "$(sed -n '/^CALL claude review$/,/^CALL claude classify$/p' "$STUB_LOG")" "Bash"
assert_not_contains "the review never runs in bypass mode" "$(cat "$STUB_LOG")" "bypassPermissions"
assert_not_contains "no unrestricted permission mode either" "$(cat "$STUB_LOG")" "--permission-mode"
assert_not_contains "no write tool reaches the review" "$(sed -n '/^CALL claude review$/,/^CALL claude classify$/p' "$STUB_LOG")" "Edit"
assert_rc "findings array carries items" 0 jq -e '.properties.findings.items' "$STUB_SCHEMA"
assert_rc "severity enum is low/medium/high" 0 jq -e '.properties.findings.items.properties.severity.enum == ["low","medium","high"]' "$STUB_SCHEMA"
assert_rc "findings is required" 0 jq -e '.required | index("findings")' "$STUB_SCHEMA"
assert_rc "reviewed is a required boolean" 0 jq -e '(.required | index("reviewed")) and .properties.reviewed.type == "boolean"' "$STUB_SCHEMA"

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

# ============================================================ claude absent
section "claude absent from PATH is advisory, not a rejection"
# A restricted PATH, not a removed stub: with the stub gone the hook would find the REAL claude
# further down PATH and spend a review. Only the two other stubs and the system directories are
# reachable here.
mkdir -p "$WORK/noclaude"; cp "$BIN/act" "$BIN/docker" "$WORK/noclaude/"
before=$(head_sha)
stage; try_commit PATH="$WORK/noclaude:/usr/bin:/bin"
assert_eq "commit passes without claude" "0" "$RC"
assert_contains "says review was not performed" "$OUT" "claude not on PATH"
assert_eq "no claude stub call either" "0" "$(calls "claude review")"
[ "$(head_sha)" != "$before" ] && ok "HEAD advanced" || bad "HEAD did not advance"

summary
