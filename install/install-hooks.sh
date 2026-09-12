#!/usr/bin/env bash
# install-hooks.sh: point a repository at the shared pre-commit gate.
#
#   install/install-hooks.sh [repo-path]   shim into that repo's hooks directory (default: cwd)
#   install/install-hooks.sh --global      shim into ~/.config/git/hooks and set core.hooksPath
#
# The shim is two lines that exec ~/.claude/git-hooks/pre-commit, so an edit to the repository
# reaches every installed repo through the symlink. An existing hook that is not the shim is
# moved to pre-commit.local, which the gate runs last.
set -euo pipefail

usage() {
  printf 'usage: %s [repo-path] | --global\n' "$0" >&2
  exit 64
}

HOOK_SRC="${CLAUDE_HOME:-$HOME/.claude}/git-hooks/pre-commit"

is_shim() { grep -qF '/.claude/git-hooks/pre-commit' "$1" 2>/dev/null; }

displace_existing() {
  local dir="$1"
  [ -e "$dir/pre-commit" ] || return 0
  is_shim "$dir/pre-commit" && return 0
  if [ -e "$dir/pre-commit.local" ]; then
    printf 'error: %s/pre-commit.local already exists; merge the two by hand\n' "$dir" >&2
    exit 1
  fi
  mv "$dir/pre-commit" "$dir/pre-commit.local"
  printf 'moved existing pre-commit to pre-commit.local; it still runs after the checks\n'
}

write_shim() {
  local dir="$1"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOOK_SRC" >"$dir/pre-commit"
  chmod +x "$dir/pre-commit"
}

main() {
  [ "$#" -le 1 ] || usage
  if [ ! -x "$HOOK_SRC" ]; then
    printf 'error: %s is not executable; run install/claude.sh install first\n' "$HOOK_SRC" >&2
    exit 64
  fi
  case "${1:-}" in
    --global)
      local dir="$HOME/.config/git/hooks"
      mkdir -p "$dir"
      displace_existing "$dir"
      write_shim "$dir"
      git config --global core.hooksPath "$dir"
      printf 'installed global pre-commit shim at %s/pre-commit\n' "$dir"
      printf 'note: core.hooksPath makes git ignore every repository'"'"'s own .git/hooks; rename such a hook to pre-commit.local under %s to keep it running\n' "$dir"
      ;;
    -*) usage ;;
    *)
      local repo="${1:-.}" common dir
      common=$(cd "$repo" && git rev-parse --git-common-dir 2>/dev/null) || {
        printf 'error: %s is not a git repository\n' "$repo" >&2; exit 1; }
      case "$common" in /*) dir="$common/hooks" ;; *) dir="$(cd "$repo" && pwd)/$common/hooks" ;; esac
      mkdir -p "$dir"
      displace_existing "$dir"
      write_shim "$dir"
      printf 'installed pre-commit shim at %s/pre-commit\n' "$dir"
      ;;
  esac
}

main "$@"
