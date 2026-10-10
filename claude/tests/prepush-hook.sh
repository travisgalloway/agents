#!/usr/bin/env bash
# prepush-hook.sh (test) — pin git-hooks/pre-push, the per-repo push gate, and the pre-commit and
# pre-push shims that install/install-hooks.sh writes.
#
# act and docker are stubs on PATH driven by STUB_* variables, so the suite runs with
# Docker down and no network. Pushes go to a local bare remote through the real git, so the
# hook sees the stdin format git produces.
#
# The refusals are the point: Docker down, a failing act run, and a timeout each reject the push.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

# Resolve the hook and the installer BEFORE HOME is redirected below. The hook carries no
# __CLAUDE_HOME__ token, so the repository copy is the one under test even before install.
ROOT="${CLAUDE_ROOT:-$(cd .. && pwd)}"
HOOK="$ROOT/git-hooks/pre-push"
INSTALLER="$(cd .. && cd .. && pwd)/install/install-hooks.sh"
[ -x "$HOOK" ] || { bad "hook not found or not executable: $HOOK"; summary; exit 1; }
ok "hook present and executable"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/prepush.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
BIN="$WORK/bin"; REPO="$WORK/repo"; REMOTE="$WORK/remote.git"; FAKEHOME="$WORK/home"
mkdir -p "$BIN" "$REPO" "$FAKEHOME"

export STUB_LOG="$WORK/calls.log"
# System directories only, so no case reaches a real act or docker.
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$FAKEHOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name Test
git config --global init.defaultBranch main

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
[ -z "${STUB_ACT_SLEEP:-}" ] || sleep "$STUB_ACT_SLEEP"
[ "${STUB_ACT_RC:-0}" = "0" ] || echo "STUBACT step failed"
exit "${STUB_ACT_RC:-0}"
STUB
chmod +x "$BIN/docker" "$BIN/act"
[ "$(command -v act)" = "$BIN/act" ] || { bad "act on PATH is not the stub: $(command -v act)"; summary; exit 1; }
ok "act on PATH is the stub"

N=0
# try_push [VAR=val ...]: push a fresh branch under the given env; sets OUT and RC.
try_push() {
  N=$((N+1)); : > "$STUB_LOG"
  OUT=$(cd "$REPO" && env "$@" git push -q origin "HEAD:refs/heads/b$N" 2>&1); RC=$?
}
calls()      { grep -c "^CALL $1" "$STUB_LOG" 2>/dev/null || true; }
install_shim() { printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOOK" > "$REPO/.git/hooks/pre-push"; chmod +x "$REPO/.git/hooks/pre-push"; }
write_wf() { # <file> <on-clause>
  mkdir -p "$REPO/.github/workflows"
  printf 'name: x\non: %s\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' "$2" > "$REPO/.github/workflows/$1"
}

git init -q --bare "$REMOTE"
git -C "$REPO" init -q
printf 'line 0\n' > "$REPO/src.txt"
git -C "$REPO" add src.txt
git -C "$REPO" commit -qm init
git -C "$REPO" remote add origin "$REMOTE"
install_shim

# ============================================================ skips
section "No workflows passes without calling act"
try_push
assert_eq "push passes" "0" "$RC"
assert_eq "act not called" "0" "$(calls act)"
assert_eq "docker not probed" "0" "$(calls docker)"

section "A workflow without a pull_request trigger is not run"
write_wf deploy.yml "[push, workflow_dispatch]"
write_wf target.yml "pull_request_target"
try_push
assert_eq "push passes" "0" "$RC"
assert_eq "act not called" "0" "$(calls act)"

section "act not installed passes with a notice"
write_wf ci.yml "[pull_request, workflow_dispatch]"
mv "$BIN/act" "$WORK/act.off"
try_push
assert_eq "push passes" "0" "$RC"
assert_contains "notice names act" "$OUT" "act not installed"
assert_eq "docker not probed" "0" "$(calls docker)"
mv "$WORK/act.off" "$BIN/act"

section "A deletion-only push passes without running act"
try_push SKIP_HOOKS=1
branch="b$N"
: > "$STUB_LOG"
OUT=$(cd "$REPO" && git push -q origin ":refs/heads/$branch" 2>&1); RC=$?
assert_eq "deletion passes" "0" "$RC"
assert_eq "act not called" "0" "$(calls act)"
assert_eq "docker not probed" "0" "$(calls docker)"

# ============================================================ gate
section "Docker down rejects before act"
try_push STUB_DOCKER_RC=1
assert_eq "docker down rejected" "1" "$RC"
assert_contains "names the bypass" "$OUT" "SKIP_PREPUSH_ACT=1"
assert_eq "act not run" "0" "$(calls act)"

section "A failing act run rejects"
try_push STUB_ACT_RC=1
assert_eq "act failure rejected" "1" "$RC"
assert_contains "names the bypass" "$OUT" "SKIP_PREPUSH_ACT=1"
assert_contains "act output shown" "$OUT" "STUBACT step failed"
assert_contains "act ran the pull_request event on the file" "$(cat "$STUB_LOG")" "pull_request -W .github/workflows/ci.yml"
assert_contains "act removes containers after a failure" "$(cat "$STUB_LOG")" "CALL act --rm"
assert_contains "act labels this run's containers" "$(cat "$STUB_LOG")" "--container-options --label claude.githook.run=pre-push-"
try_push STUB_ACT_RC=1 STUB_DOCKER_LEFTOVER=1
assert_eq "act failure rejected" "1" "$RC"
assert_contains "the label sweep removes a leftover container" "$(cat "$STUB_LOG")" "CALL docker rm -f STUBCID"
assert_eq "branch absent on the remote" "" "$(git -C "$REMOTE" branch --list "b$N")"

section "A passing act run allows the push"
try_push
assert_eq "push passes" "0" "$RC"
assert_eq "act ran once" "1" "$(calls act)"
assert_not_contains "no deploy workflow run" "$(cat "$STUB_LOG")" "deploy.yml"
assert_not_contains "no pull_request_target workflow run" "$(cat "$STUB_LOG")" "target.yml"
assert_eq "branch present on the remote" "b$N" "$(git -C "$REMOTE" branch --list "b$N" | tr -d ' *')"

section "Excluded workflows are not run"
write_wf claude-review.yml "pull_request"
try_push
assert_eq "push passes" "0" "$RC"
assert_not_contains "default exclusion honored" "$(cat "$STUB_LOG")" "claude-review.yml"
try_push PREPUSH_ACT_EXCLUDE="ci.yml claude-review.yml"
assert_eq "custom exclusion passes" "0" "$RC"
assert_eq "no act run when all are excluded" "0" "$(calls act)"
rm "$REPO/.github/workflows/claude-review.yml"

# ============================================================ bypasses
section "Bypass variables call nothing"
try_push SKIP_PREPUSH_ACT=1 STUB_ACT_RC=1
assert_eq "SKIP_PREPUSH_ACT=1 passes" "0" "$RC"
assert_contains "says so" "$OUT" "SKIP_PREPUSH_ACT=1"
assert_eq "no act call" "0" "$(calls act)"
try_push SKIP_HOOKS=1 STUB_ACT_RC=1
assert_eq "SKIP_HOOKS=1 passes" "0" "$RC"
assert_contains "says so" "$OUT" "SKIP_HOOKS=1"
assert_eq "no act call" "0" "$(calls act)"
assert_eq "no docker call" "0" "$(calls docker)"

# ============================================================ timeout
section "PREPUSH_ACT_TIMEOUT"
start=$(date +%s)
try_push PREPUSH_ACT_TIMEOUT=1s STUB_ACT_SLEEP=8
assert_eq "timeout rejected" "1" "$RC"
assert_contains "output names the timeout" "$OUT" "timed out after 1s"
assert_contains "names the bypass" "$OUT" "SKIP_PREPUSH_ACT=1"
[ $(( $(date +%s) - start )) -lt 6 ] && ok "the watchdog ended act early" || bad "the watchdog did not end act"
if pgrep -f 'sleep 8$' >/dev/null; then bad "act's child outlived the timeout"; else ok "no act process outlived the timeout"; fi
try_push PREPUSH_ACT_TIMEOUT=2m
assert_eq "minutes accepted" "0" "$RC"
try_push PREPUSH_ACT_TIMEOUT=soon
assert_eq "a malformed duration rejects" "1" "$RC"
assert_contains "names the knob" "$OUT" "PREPUSH_ACT_TIMEOUT=soon"

# ============================================================ chaining
section "pre-push.local runs last with the original args and stdin"
printf '#!/bin/sh\necho "LOCALARG $1" >&2\ncat > "%s/local.stdin"\nexit 7\n' "$WORK" > "$REPO/.git/hooks/pre-push.local"
chmod +x "$REPO/.git/hooks/pre-push.local"
try_push
assert_eq "local hook exit code propagates" "1" "$RC"
assert_contains "local hook ran with the remote name" "$OUT" "LOCALARG origin"
assert_contains "local hook received git's stdin" "$(cat "$WORK/local.stdin" 2>/dev/null)" "refs/heads/b$N"
assert_eq "act ran before the local hook" "1" "$(calls act)"
try_push SKIP_HOOKS=1
assert_not_contains "SKIP_HOOKS=1 skips the local hook" "$OUT" "LOCALARG"
: > "$STUB_LOG"
try_push SKIP_PREPUSH_ACT=1
assert_contains "SKIP_PREPUSH_ACT=1 still runs the local hook" "$OUT" "LOCALARG origin"
assert_eq "SKIP_PREPUSH_ACT=1 skips act" "0" "$(calls act)"
try_push SKIP_HOOKS=1
branch="b$N"
: > "$STUB_LOG"
OUT=$(cd "$REPO" && git push -q origin ":refs/heads/$branch" 2>&1); RC=$?
assert_contains "a deletion-only push still runs the local hook" "$OUT" "LOCALARG origin"
assert_eq "a deletion-only push skips act" "0" "$(calls act)"
printf '#!/bin/sh\nexit 0\n' > "$REPO/.git/hooks/pre-push.local"
try_push
assert_eq "local hook exit 0 allows the push" "0" "$RC"
chmod -x "$REPO/.git/hooks/pre-push.local"
printf '#!/bin/sh\nexit 7\n' > "$REPO/.git/hooks/pre-push.local"
try_push
assert_eq "non-executable local hook is ignored" "0" "$RC"
rm -f "$REPO/.git/hooks/pre-push.local"

# ============================================================ installer
section "install-hooks.sh writes both shims"
FAKE_CLAUDE="$WORK/claude-home"
mkdir -p "$FAKE_CLAUDE/git-hooks"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CLAUDE/git-hooks/pre-commit"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CLAUDE/git-hooks/pre-push"
chmod +x "$FAKE_CLAUDE/git-hooks/pre-commit" "$FAKE_CLAUDE/git-hooks/pre-push"
# is_shim keys on a /.claude/ path segment, so the fake home needs that directory name.
mkdir -p "$WORK/h"; mv "$FAKE_CLAUDE" "$WORK/h/.claude"
FAKE_CLAUDE="$WORK/h/.claude"
INST="$WORK/inst"; mkdir -p "$INST"; git -C "$INST" init -q
printf '#!/bin/sh\necho old-push\n' > "$INST/.git/hooks/pre-push"; chmod +x "$INST/.git/hooks/pre-push"
OUT=$(CLAUDE_HOME="$FAKE_CLAUDE" bash "$INSTALLER" "$INST" 2>&1); RC=$?
assert_eq "installer succeeds" "0" "$RC"
for h in pre-commit pre-push; do
  assert_contains "$h shim execs the shared hook" "$(cat "$INST/.git/hooks/$h" 2>/dev/null)" "$FAKE_CLAUDE/git-hooks/$h"
  [ -x "$INST/.git/hooks/$h" ] && ok "$h shim executable" || bad "$h shim not executable"
done
assert_contains "existing pre-push preserved" "$(cat "$INST/.git/hooks/pre-push.local" 2>/dev/null)" "old-push"
OUT=$(CLAUDE_HOME="$FAKE_CLAUDE" bash "$INSTALLER" "$INST" 2>&1); RC=$?
assert_eq "second run is idempotent" "0" "$RC"
assert_contains "pre-push.local still holds the original" "$(cat "$INST/.git/hooks/pre-push.local")" "old-push"
OUT=$(CLAUDE_HOME="$FAKE_CLAUDE" bash "$INSTALLER" --global 2>&1); RC=$?
assert_eq "--global succeeds" "0" "$RC"
assert_eq "--global sets core.hooksPath" "$FAKEHOME/.config/git/hooks" "$(git config --global core.hooksPath)"
[ -x "$FAKEHOME/.config/git/hooks/pre-push" ] && [ -x "$FAKEHOME/.config/git/hooks/pre-commit" ] \
  && ok "--global writes both shims" || bad "--global missing a shim"

summary
