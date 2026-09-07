#!/usr/bin/env bash
# claude.sh — install this repository's Claude Code configuration into ~/.claude.
#
# WHY A SCRIPT AND NOT `ln -s`. Thirteen files in claude/ carry the token
# __CLAUDE_HOME__ where an absolute path has to appear. Claude Code does not expand
# `~` or `$HOME` in a skill's `allowed-tools` grant, in a !`cmd` dynamic-context
# injection, or reliably in a hook `command` string, and tests/reference-integrity.sh
# asserts every injection names an absolute path to an executable. Those files must be
# rendered with this machine's home directory, so they are real copies. Everything else
# is symlinked back to the clone and stays live.
#
#   install [--link|--copy] [--dry-run] [--force]   repo  -> ~/.claude
#   capture [--dry-run]                             ~/.claude -> repo (re-tokenized)
#   diff                                            report drift, exit 1 if any
#   uninstall [--dry-run]                           remove what install placed
#   plugins                                         print the plugin install commands
#
# CLAUDE_HOME overrides the destination, which is how the suite is tested against a
# scratch tree without touching the live one.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO_ROOT/claude"
DEST="${CLAUDE_HOME:-$HOME/.claude}"
TOKEN='__CLAUDE_HOME__'

MODE=link
DRY=0
FORCE=0
CMD="${1:-}"
[ $# -gt 0 ] && shift || true

for a in "$@"; do
  case "$a" in
    --link)    MODE=link ;;
    --copy)    MODE=copy ;;
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    *) printf 'unknown option: %s\n' "$a" >&2; exit 64 ;;
  esac
done

[ -d "$SRC" ] || { printf 'no claude/ tree at %s\n' "$SRC" >&2; exit 64; }

# ---------------------------------------------------------------- helpers

# Every managed file, repo-relative, in a stable order.
files() { (cd "$SRC" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | LC_ALL=C sort); }

# A file is rendered rather than linked when it carries the token, or when Claude Code
# rewrites it at runtime. settings.json is the second case: the app rewrites it on every
# model, effort or output-style change, and a symlink would make that dirty the clone.
needs_render() {
  [ "$1" = settings.json ] && return 0
  [ "$MODE" = copy ] && return 0
  grep -q "$TOKEN" "$SRC/$1" 2>/dev/null
}

# Render one repo file to stdout with the token resolved to this machine's tree.
render() { TOKEN="$TOKEN" DEST="$DEST" perl -pe 's/\Q$ENV{TOKEN}\E/$ENV{DEST}/g' "$1"; }

# Re-tokenize one live file to stdout, the inverse of render.
tokenize() { TOKEN="$TOKEN" DEST="$DEST" perl -pe 's/\Q$ENV{DEST}\E/$ENV{TOKEN}/g' "$1"; }

# The backup directory is computed ONCE, in the parent shell. An earlier version called a
# function from a command substitution, so the assignment landed in a subshell, every call
# recomputed the timestamp, and a run that crossed a second created the directory under one
# name and moved the file under another. The move then failed and the install stopped
# halfway.
BACKUP=""
BACKED_UP=0
stash() {
  local rel="$1"
  [ -n "$BACKUP" ] || BACKUP="$DEST/backups/config-$(date -u +%Y%m%dT%H%M%SZ)"
  if [ $DRY -eq 0 ]; then
    mkdir -p "$BACKUP/$(dirname "$rel")"
    mv "$DEST/$rel" "$BACKUP/$rel"
  fi
  BACKED_UP=$((BACKED_UP+1))
}

say() { printf '  %-9s %s\n' "$1" "$2"; }

# ---------------------------------------------------------------- install

do_install() {
  printf '%s -> %s  (%s mode%s)\n\n' "$SRC" "$DEST" "$MODE" "$([ $DRY -eq 1 ] && printf ', dry run')"
  local rel src dst tmp linked=0 rendered=0 skipped=0
  while IFS= read -r rel; do
    src="$SRC/$rel"; dst="$DEST/$rel"

    if needs_render "$rel"; then
      tmp=$(mktemp); render "$src" > "$tmp"
      if [ -e "$dst" ] && [ ! -L "$dst" ] && ! cmp -s "$tmp" "$dst"; then
        # The live file differs. If it also differs from what the repo last rendered,
        # a local edit is at stake — refuse rather than discard it silently.
        if [ $FORCE -eq 0 ] && [ -f "$dst" ]; then
          say REFUSED "$rel  (local edit; run capture, or pass --force)"
          skipped=$((skipped+1)); rm -f "$tmp"; continue
        fi
      fi
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
          say ok "$rel"; rendered=$((rendered+1)); rm -f "$tmp"; continue
        fi
        stash "$rel"
      fi
      if [ $DRY -eq 0 ]; then
        mkdir -p "$(dirname "$dst")"
        cat "$tmp" > "$dst"
        chmod "$(stat -f '%Lp' "$src")" "$dst"
      fi
      rm -f "$tmp"
      say rendered "$rel"
      rendered=$((rendered+1))
    else
      if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        say ok "$rel"; linked=$((linked+1)); continue
      fi
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        stash "$rel"
      fi
      if [ $DRY -eq 0 ]; then
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
      fi
      say linked "$rel"
      linked=$((linked+1))
    fi
  done < <(files)

  printf '\n%d linked, %d rendered, %d refused, %d backed up' "$linked" "$rendered" "$skipped" "$BACKED_UP"
  [ -n "$BACKUP" ] && printf ' to %s' "$BACKUP"
  printf '\n'
  [ $skipped -gt 0 ] && printf '\nRefused files keep their local edits. Run `capture` to pull them into the repo.\n'
  printf '\nPlugins are not installed by this script. Run `%s plugins` for the commands.\n' "$0"
  return 0
}

# ---------------------------------------------------------------- capture

do_capture() {
  printf '%s -> %s  (re-tokenizing%s)\n\n' "$DEST" "$SRC" "$([ $DRY -eq 1 ] && printf ', dry run')"
  local rel src dst tmp changed=0 same=0 missing=0
  while IFS= read -r rel; do
    src="$SRC/$rel"; dst="$DEST/$rel"
    [ -e "$dst" ] || { say missing "$rel"; missing=$((missing+1)); continue; }
    # A symlink already IS the repo file. Nothing to pull back.
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then same=$((same+1)); continue; fi
    tmp=$(mktemp); tokenize "$dst" > "$tmp"
    if cmp -s "$tmp" "$src"; then same=$((same+1)); rm -f "$tmp"; continue; fi
    [ $DRY -eq 0 ] && cat "$tmp" > "$src"
    rm -f "$tmp"
    say captured "$rel"
    changed=$((changed+1))
  done < <(files)
  printf '\n%d captured, %d unchanged, %d missing from %s\n' "$changed" "$same" "$missing" "$DEST"
  return 0
}

# ---------------------------------------------------------------- diff

do_diff() {
  local rel src dst tmp drift=0 ok=0
  while IFS= read -r rel; do
    src="$SRC/$rel"; dst="$DEST/$rel"
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then say MISSING "$rel"; drift=$((drift+1)); continue; fi
    if [ -L "$dst" ]; then
      if [ "$(readlink "$dst")" = "$src" ]; then ok=$((ok+1)); else say FOREIGN "$rel -> $(readlink "$dst")"; drift=$((drift+1)); fi
      continue
    fi
    tmp=$(mktemp); render "$src" > "$tmp"
    if cmp -s "$tmp" "$dst"; then ok=$((ok+1)); else say DRIFT "$rel"; drift=$((drift+1)); fi
    rm -f "$tmp"
  done < <(files)
  printf '\n%d in sync, %d drifted\n' "$ok" "$drift"
  [ "$drift" -eq 0 ]
}

# ---------------------------------------------------------------- uninstall

do_uninstall() {
  printf 'removing managed files from %s%s\n\n' "$DEST" "$([ $DRY -eq 1 ] && printf '  (dry run)')"
  local rel src dst tmp removed=0 kept=0
  while IFS= read -r rel; do
    src="$SRC/$rel"; dst="$DEST/$rel"
    [ -e "$dst" ] || [ -L "$dst" ] || continue
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      [ $DRY -eq 0 ] && rm -f "$dst"; say removed "$rel"; removed=$((removed+1)); continue
    fi
    tmp=$(mktemp); render "$src" > "$tmp"
    if cmp -s "$tmp" "$dst"; then
      [ $DRY -eq 0 ] && rm -f "$dst"; say removed "$rel"; removed=$((removed+1))
    else
      say kept "$rel  (modified locally)"; kept=$((kept+1))
    fi
    rm -f "$tmp"
  done < <(files)
  printf '\n%d removed, %d kept because they differ from the repo\n' "$removed" "$kept"
  local newest
  newest=$(ls -1d "$DEST"/backups/config-* 2>/dev/null | tail -1 || true)
  [ -n "$newest" ] && printf 'newest backup: %s\n' "$newest"
  return 0
}

# ---------------------------------------------------------------- plugins

do_plugins() {
  local list="$REPO_ROOT/install/claude-plugins.txt"
  printf 'claude plugin marketplace add anthropics/claude-plugins-official\n'
  grep -v '^\s*#' "$list" | grep -v '^\s*$' | while IFS= read -r p; do
    printf 'claude plugin install %s\n' "$p"
  done
}

# ---------------------------------------------------------------- dispatch

case "$CMD" in
  install)   do_install ;;
  capture)   do_capture ;;
  diff)      do_diff ;;
  uninstall) do_uninstall ;;
  plugins)   do_plugins ;;
  ""|-h|--help|help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) printf 'unknown command: %s\n' "$CMD" >&2; exit 64 ;;
esac
