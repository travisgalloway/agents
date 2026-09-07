#!/usr/bin/env bash
# merge-gate.sh <pr> --repo OWNER/NAME [--retries N] [--sleep S]
#
# The pre-dispatch gate for the merge slot in /work and /backlog. Merges are serialized, so by the
# time a queued PR reaches the front of the queue the base has moved under it. This answers one
# question: does this PR still apply to the base as it now stands? It does NOT answer "is it
# green" — remediating CI and reviews is /automerge's cycle, which is why BLOCKED and UNSTABLE are
# rc 0 here. A PR reads BLOCKED merely because a required review has not landed yet.
#
# WHY A SCRIPT: same reason as backlog-preflight.sh. A run long enough to compact turns a
# remembered checklist into a paraphrase — one that keeps "check the PR state" and drops the jq
# null guard. Calling this costs ~120 tokens; remembering it costs 40 lines that decay.
#
# THE FAILURE THIS FILE EXISTS FOR:
# `mergeable` is computed LAZILY by GitHub. The first read after a merge lands is very likely
# UNKNOWN, for every PR still open against that base. A gate that resolved UNKNOWN to a verdict
# would either halt the run on the first queued PR (pessimistic) or dispatch a merge stage against
# a PR that conflicts (optimistic). It retries instead, and reports UNKNOWN only after the retries
# are spent — an unreadable state is never resolved to the optimistic answer.
#
# CONTRACT: act on the exit code and on nothing else. Every path prints a one-line reason to
# stdout first. Never parse the prose; it is for the human reading the transcript.
#
#   0   ready to dispatch (CLEAN, HAS_HOOKS, UNSTABLE, BLOCKED)
#   1   BEHIND — dispatch anyway; /automerge Step 3 exit 4 runs `gh pr update-branch` and re-waits CI
#   2   UNKNOWN — gh unreachable, a null field, or mergeable never resolved. Not a merge
#   3   already MERGED or CLOSED — skip it, so a resumed run does not re-dispatch a finished PR
#   5   DIRTY or CONFLICTING — conflicts with the base as it now stands. Blocker
#   6   DRAFT — never dispatch a merge for a draft
#   64  usage error
set -u

usage() {
  cat <<'EOF'
usage: merge-gate.sh <pr-number> --repo OWNER/NAME [--retries N] [--sleep S]

  --repo OWNER/NAME  passed to gh (required — the caller always knows it, and letting gh
                     auto-detect would read whatever repo the cwd happens to be)
  --retries N        extra reads when mergeable is UNKNOWN (default 5)
  --sleep S          seconds between those reads (default 3)
EOF
}

pr=""; repo=""; retries=5; nap=3

[ $# -ge 1 ] || { usage >&2; exit 64; }
pr="$1"; shift
case "$pr" in ''|*[!0-9]*) printf 'usage: first argument must be a PR number\n'; usage >&2; exit 64 ;; esac

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    repo="${2:-}"; shift 2 ;;
    --retries) retries="${2:-}"; shift 2 ;;
    --sleep)   nap="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1"; usage >&2; exit 64 ;;
  esac
done

case "$repo" in
  */*) ;;
  *) printf 'usage: --repo OWNER/NAME is required\n'; usage >&2; exit 64 ;;
esac
case "$retries" in ''|*[!0-9]*) printf 'usage: --retries must be a non-negative integer\n'; exit 64 ;; esac
case "$nap"     in ''|*[!0-9]*) printf 'usage: --sleep must be a non-negative integer\n';   exit 64 ;; esac

command -v gh >/dev/null 2>&1 || { printf 'UNKNOWN: gh is unavailable — an unreadable state is not a merge\n'; exit 2; }

# `.isDraft` goes through tostring, NOT through `// ""`. jq's `//` treats `false` as empty, so
# `.isDraft // ""` returns "" for a PR that is simply not a draft — indistinguishable from a null
# field, and the whole read would degrade to UNKNOWN on every healthy PR.
# Joined on '|', not on spaces: word splitting drops trailing empty fields, so a MERGED PR
# (whose mergeable and mergeStateStatus are both null) came back as two fields and was retried
# into UNKNOWN instead of being recognized as finished. The delimiter has to survive empties.
read_pr() {
  gh pr view "$pr" --repo "$repo" --json state,isDraft,mergeable,mergeStateStatus \
    -q '[(.state // ""), (.isDraft|tostring), (.mergeable // ""), (.mergeStateStatus // "")]|join("|")' 2>/dev/null
}

attempt=0
while : ; do
  fields=$(read_pr) || fields=""
  IFS='|' read -r state draft mergeable status <<EOF
$fields
EOF
  state="${state:-}"; draft="${draft:-}"; mergeable="${mergeable:-}"; status="${status:-}"

  # An unreadable state is UNKNOWN, never "nothing wrong with it". This is the same guard
  # /work step 10 and /backlog §6g carry: a failed lookup is not a merge.
  if [ -z "$state" ]; then
    if [ "$attempt" -ge "$retries" ]; then
      printf 'UNKNOWN: could not read PR #%s from gh after %s attempt(s)\n' "$pr" "$((attempt + 1))"
      exit 2
    fi
    attempt=$((attempt + 1)); [ "$nap" -gt 0 ] && sleep "$nap"; continue
  fi

  # Checked before mergeability, which is null on a merged PR — the terminal states are readable
  # when nothing else is, and a resumed run depends on that to skip a PR that landed while the
  # session was gone.
  case "$state" in
    MERGED) printf 'SKIP: PR #%s is already MERGED\n' "$pr"; exit 3 ;;
    CLOSED) printf 'SKIP: PR #%s is CLOSED without merging\n' "$pr"; exit 3 ;;
  esac

  # Draft is checked before mergeable resolves. A draft reports `mergeable: MERGEABLE` and would
  # otherwise sail through as ready — the same trap automerge-merge-gate.sh pins for Step 3.
  if [ "$draft" = "true" ] || [ "$status" = "DRAFT" ]; then
    printf 'BLOCKER: PR #%s is a draft (%s/%s)\n' "$pr" "$mergeable" "$status"
    exit 6
  fi

  case "$mergeable:$status" in
    CONFLICTING:*|*:DIRTY)
      printf 'BLOCKER: PR #%s conflicts with the base as it now stands (%s/%s)\n' "$pr" "$mergeable" "$status"
      exit 5 ;;
    *:BEHIND)
      printf 'BEHIND: PR #%s is behind the base (%s/%s) — the merge stage updates the branch and re-waits CI\n' "$pr" "$mergeable" "$status"
      exit 1 ;;
    UNKNOWN:*|*:UNKNOWN|:*|*:)
      if [ "$attempt" -ge "$retries" ]; then
        printf 'UNKNOWN: PR #%s mergeability unresolved after %s attempt(s) (%s/%s)\n' "$pr" "$((attempt + 1))" "$mergeable" "$status"
        exit 2
      fi
      attempt=$((attempt + 1)); [ "$nap" -gt 0 ] && sleep "$nap"; continue ;;
    MERGEABLE:*)
      printf 'READY: PR #%s (%s/%s)\n' "$pr" "$mergeable" "$status"
      exit 0 ;;
    *)
      # A mergeable value gh has not documented yet. Unknown is the safe reading, not ready.
      printf 'UNKNOWN: PR #%s reported an unrecognized mergeable value (%s/%s)\n' "$pr" "$mergeable" "$status"
      exit 2 ;;
  esac
done
