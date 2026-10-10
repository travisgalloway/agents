#!/usr/bin/env bash
# install-hooks.sh: point a repository at the shared pre-commit and pre-push gates.
#
#   install/install-hooks.sh [repo-path]   shims into that repo's hooks directory (default: cwd)
#   install/install-hooks.sh --global      shims into ~/.config/git/hooks and set core.hooksPath
#
# Each shim is two lines that exec ~/.claude/git-hooks/<hook>, so an edit to the repository
# reaches every installed repo through the symlink. An existing hook that is not the shim is
# moved to <hook>.local, which the gate runs last.
set -euo pipefail

usage() {
  printf 'usage: %s [repo-path] | --global\n' "$0" >&2
  exit 64
}

HOOKS="pre-commit pre-push"
HOOK_DIR="${CLAUDE_HOME:-$HOME/.claude}/git-hooks"

is_shim() { grep -qF "/.claude/git-hooks/$2" "$1" 2>/dev/null; }

displace_existing() {
  local dir="$1" hook="$2"
  [ -e "$dir/$hook" ] || return 0
  is_shim "$dir/$hook" "$hook" && return 0
  if [ -e "$dir/$hook.local" ]; then
    printf 'error: %s/%s.local already exists; merge the two by hand\n' "$dir" "$hook" >&2
    exit 1
  fi
  mv "$dir/$hook" "$dir/$hook.local"
  printf 'moved existing %s to %s.local; it still runs after the checks\n' "$hook" "$hook"
}

write_shim() {
  local dir="$1" hook="$2"
  printf '#!/bin/sh\nexec "%s/%s" "$@"\n' "$HOOK_DIR" "$hook" >"$dir/$hook"
  chmod +x "$dir/$hook"
}

install_all() {
  local dir="$1" hook
  for hook in $HOOKS; do
    displace_existing "$dir" "$hook"
    write_shim "$dir" "$hook"
  done
}

main() {
  [ "$#" -le 1 ] || usage
  local hook
  for hook in $HOOKS; do
    if [ ! -x "$HOOK_DIR/$hook" ]; then
      printf 'error: %s/%s is not executable; run install/claude.sh install first\n' "$HOOK_DIR" "$hook" >&2
      exit 64
    fi
  done
  case "${1:-}" in
    --global)
      local dir="$HOME/.config/git/hooks"
      mkdir -p "$dir"
      install_all "$dir"
      git config --global core.hooksPath "$dir"
      printf 'installed global pre-commit and pre-push shims in %s\n' "$dir"
      printf 'note: core.hooksPath makes git ignore every repository'"'"'s own .git/hooks; rename such a hook to <hook>.local under %s to keep it running\n' "$dir"
      ;;
    -*) usage ;;
    *)
      local repo="${1:-.}" common dir
      common=$(cd "$repo" && git rev-parse --git-common-dir 2>/dev/null) || {
        printf 'error: %s is not a git repository\n' "$repo" >&2; exit 1; }
      case "$common" in /*) dir="$common/hooks" ;; *) dir="$(cd "$repo" && pwd)/$common/hooks" ;; esac
      mkdir -p "$dir"
      install_all "$dir"
      printf 'installed pre-commit and pre-push shims in %s\n' "$dir"
      ;;
  esac
}

main "$@"
