#!/usr/bin/env bash
# repo-map.sh — locate and validate the per-repo scout cache shared by every worktree.
#
# The cache lives in the git common directory, so the main checkout and each linked worktree
# resolve the same file, and it is never committed. Its first line is `<!-- sha: <commit> -->`.
#
#   path         print the absolute cache path, creating its directory
#   sha          print the stamped commit; empty and rc 1 when the stamp is missing, unparseable,
#                or names a commit this repository does not know
#   stale-paths  print `git diff --name-only <sha>..HEAD`; print the literal FULL (rc 0) when no
#                valid stamp exists, so the caller rebuilds every entry
#
# Exit codes: 0 ok, 1 no valid stamp (`sha` only), 2 not a git repository or bad usage.

set -euo pipefail

die() { printf 'repo-map.sh: %s\n' "$1" >&2; exit 2; }

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not a git repository"
map="$common/claude/repo-map.md"

# Prints the stamped commit when it parses and resolves to a commit in this repository.
valid_sha() {
  local first sha
  [ -f "$map" ] || return 1
  first=$(head -n 1 "$map")
  sha=$(printf '%s\n' "$first" | sed -n 's/^<!-- sha: \([0-9a-f]\{7,64\}\) -->$/\1/p')
  [ -n "$sha" ] || return 1
  git cat-file -e "$sha^{commit}" 2>/dev/null || return 1
  printf '%s\n' "$sha"
}

case "${1:-}" in
  path)
    mkdir -p "$common/claude"
    printf '%s\n' "$map"
    ;;
  sha)
    valid_sha || exit 1
    ;;
  stale-paths)
    if sha=$(valid_sha); then
      git diff --name-only "$sha..HEAD"
    else
      echo FULL
    fi
    ;;
  *)
    die "usage: repo-map.sh path|sha|stale-paths"
    ;;
esac
