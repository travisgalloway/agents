#!/usr/bin/env bash
# repo-map.sh (test) — pin the contract of ~/.claude/lib/repo-map.sh.
#
# The cache must resolve to one file from every worktree, and a missing or unusable stamp must
# request a full rebuild rather than an empty (apparently clean) diff.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

SCRIPT="$(cd .. && pwd)/lib/repo-map.sh"
[ -x "$SCRIPT" ] || { bad "not executable: $SCRIPT"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/repo-map.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name Test
git config --global init.defaultBranch main

REPO="$WORK/repo"; git init -q "$REPO"
echo a > "$REPO/a"; echo b > "$REPO/b"
git -C "$REPO" add -A; git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" worktree add -q "$WORK/wt" -b side

section "path resolves identically from the main checkout and a linked worktree"
P_MAIN=$(cd "$REPO" && bash "$SCRIPT" path)
P_WT=$(cd "$WORK/wt" && bash "$SCRIPT" path)
assert_eq "same cache path" "$P_MAIN" "$P_WT"
case "$P_MAIN" in /*) ok "path is absolute" ;; *) bad "path is absolute" "$P_MAIN" ;; esac
[ -d "$(dirname "$P_MAIN")" ] && ok "cache directory created" || bad "cache directory created"

section "missing stamp requests a full rebuild"
assert_eq "stale-paths prints FULL" "FULL" "$(cd "$REPO" && bash "$SCRIPT" stale-paths)"
assert_rc "sha exits 1" 1 bash -c "cd '$REPO' && bash '$SCRIPT' sha"

section "valid stamp lists only changed files"
printf '<!-- sha: %s -->\nbody\n' "$BASE" > "$P_MAIN"
echo a2 > "$REPO/a"; echo c > "$REPO/c"
git -C "$REPO" add -A; git -C "$REPO" commit -qm change
assert_eq "sha prints the stamp" "$BASE" "$(cd "$REPO" && bash "$SCRIPT" sha)"
assert_eq "only changed files" "a c" "$(cd "$REPO" && bash "$SCRIPT" stale-paths | tr '\n' ' ' | sed 's/ $//')"

section "stamp naming an unknown commit requests a full rebuild"
printf '<!-- sha: %s -->\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$P_MAIN"
assert_eq "unknown commit gives FULL" "FULL" "$(cd "$REPO" && bash "$SCRIPT" stale-paths)"
printf 'no stamp here\n' > "$P_MAIN"
assert_eq "unparseable stamp gives FULL" "FULL" "$(cd "$REPO" && bash "$SCRIPT" stale-paths)"

section "outside a git repository"
NOREPO="$WORK/plain"; mkdir -p "$NOREPO"
for sub in path sha stale-paths; do
  assert_rc "$sub exits 2" 2 bash -c "cd '$NOREPO' && GIT_CEILING_DIRECTORIES='$WORK' bash '$SCRIPT' $sub"
done
ERR=$(cd "$NOREPO" && GIT_CEILING_DIRECTORIES="$WORK" bash "$SCRIPT" path 2>&1 >/dev/null || true)
assert_contains "message on stderr" "$ERR" "not a git repository"

summary
