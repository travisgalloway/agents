#!/usr/bin/env bash
# branches.sh — resolve the repo-aware facts every command in the suite needs.
#
# Single source of truth for the resolution ladder that used to be copy-pasted verbatim into
# commit.md, pr.md, status.md, sync.md and work.md. Injected into each skill with
#   !`__CLAUDE_HOME__/lib/branches.sh`
# so the facts are already in context when the model starts, instead of costing 4-6 tool calls
# per invocation.
#
# CONTRACT — two rules, both load-bearing:
#
#   1. NEVER exit non-zero, and never write to stderr. A dynamic-context command that fails
#      would break skill loading for every consumer. Unresolvable values come back empty with a
#      note, and the skill body handles that case.
#
#   2. EMIT ONLY SLOW-MOVING FACTS. Invoked skill content persists for the session; a
#      re-invocation whose rendered content DIFFERS gets its full body appended again, while an
#      identical one is deduped to a short note. Emitting a commit SHA, an ahead/behind count or
#      dirty state would change on nearly every call and make /automerge re-append the whole of
#      reviews.md on each of its five cycles. Volatile state stays a normal tool call.
#
# Output: `key=value` lines, plus `# note: ...` lines for anything that could not be resolved.

set -u

emit() { printf '%s=%s\n' "$1" "${2:-}"; }
note() { printf '# note: %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# The branch grammar lives in a sibling so preflight and teardown cannot drift from what the
# skills are told. Sourcing is GUARDED because this script runs `set -u`, is injected into
# eight skills, and its contract (above) forbids a non-zero exit or a byte on stderr — an
# unreadable helper must degrade to empty values with a note, never take skill loading down.
_lib_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || _lib_dir=""
if [ -n "$_lib_dir" ] && [ -r "$_lib_dir/branch-name.sh" ]; then
  . "$_lib_dir/branch-name.sh" 2>/dev/null || true
fi

# emit_branch_facts <branch> — branch_issue and branch_recognized, on EVERY exit path.
# Deliberately only these two. branch_type/scope/slug have no consumer, and a `branch_type=fix`
# sitting in the model's context primes it to write `fix:` on every commit and PR title, which
# silently defeats the diff-derived type /commit and /pr are supposed to choose.
emit_branch_facts() {
  if command -v branch_parse >/dev/null 2>&1 && branch_parse "${1:-}"; then
    emit branch_issue "$bn_issue"; emit branch_recognized "true"
  else
    emit branch_issue ""; emit branch_recognized "false"
  fi
}

if ! have git || ! git rev-parse --git-dir >/dev/null 2>&1; then
  emit owner ""; emit repo ""; emit integration_branch ""; emit release_branch ""
  emit current_branch ""; emit repo_root ""
  emit branch_config ""; emit branch_issue ""; emit branch_recognized "false"
  note "not inside a git repository — all values unresolved"
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
current_branch=$(git branch --show-current 2>/dev/null || true)

# --- owner/repo ------------------------------------------------------------------
owner=""; repo=""
if have gh; then
  slug=$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || true)
  owner=${slug%%/*}; repo=${slug#*/}
  [ "$owner" = "$repo" ] && { owner=""; repo=""; }   # slug was empty
fi
if [ -z "$owner" ]; then
  # Fall back to the origin remote URL: git@host:owner/repo.git or https://host/owner/repo.git
  url=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$url" ]; then
    trimmed=${url%.git}; trimmed=${trimmed%/}
    repo=${trimmed##*/}
    rest=${trimmed%/*}
    owner=${rest##*[:/]}
  fi
fi

# --- branch-config.json ----------------------------------------------------------
cfg="$repo_root/.claude/branch-config.json"
cfg_base=""; cfg_release=""
if [ -f "$cfg" ] && have jq; then
  cfg_base=$(jq -r '.baseBranch // empty'    "$cfg" 2>/dev/null || true)
  cfg_release=$(jq -r '.releaseBranch // empty' "$cfg" 2>/dev/null || true)
fi

# exists_local_or_remote <branch>
exists() {
  git show-ref --verify --quiet "refs/heads/$1" 2>/dev/null && return 0
  git show-ref --verify --quiet "refs/remotes/origin/$1" 2>/dev/null && return 0
  return 1
}

first_of_main_master() {
  if exists main; then echo main
  elif exists master; then echo master
  else echo ""; fi
}

# --- integration branch ----------------------------------------------------------
# 1. config baseBranch  2. GitHub default  3. origin/HEAD symbolic-ref  4. main|master
integration=""
[ -n "$cfg_base" ] && integration="$cfg_base"
if [ -z "$integration" ] && have gh; then
  integration=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
fi
if [ -z "$integration" ]; then
  integration=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
                | sed 's@^refs/remotes/origin/@@' || true)
fi
[ -z "$integration" ] && integration=$(first_of_main_master)

# --- release branch --------------------------------------------------------------
# 1. config releaseBranch  2. main|master
release=""
[ -n "$cfg_release" ] && release="$cfg_release"
[ -z "$release" ] && release=$(first_of_main_master)

emit owner             "$owner"
emit repo              "$repo"
emit repo_root         "$repo_root"
emit current_branch    "$current_branch"
emit integration_branch "$integration"
emit release_branch    "$release"

[ -f "$cfg" ] && emit branch_config "$cfg" || emit branch_config ""

# Derived purely from current_branch, so exactly as slow-moving as it already is — the
# stability contract above holds and /automerge's five cycles still dedupe. Detached HEAD
# leaves current_branch empty, which lands here as branch_recognized=false and an empty
# branch_issue: emitted, never omitted.
emit_branch_facts "$current_branch"

command -v branch_parse >/dev/null 2>&1 || note "lib/branch-name.sh unreadable — branch_issue/branch_recognized are degraded, not observed"
have gh || note "gh not on PATH — owner/repo came from the origin remote, if at all"
[ -n "$owner" ] || note "could not resolve owner/repo; commands requiring gh should error per their own step 1"
[ -n "$integration" ] || note "could not resolve the integration branch"
[ -n "$current_branch" ] || note "detached HEAD — current_branch is empty"

exit 0
