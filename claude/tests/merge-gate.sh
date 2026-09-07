#!/usr/bin/env bash
# merge-gate.sh — exercise lib/merge-gate.sh, the pre-dispatch gate for the serialized merge slot
# in /work and /backlog. `gh` is a stub on PATH; no network, no live PRs.
#
# THE BUGS THESE PIN:
#
#  1. jq's `//` treats `false` as empty. `.isDraft // ""` therefore returns "" for a PR that is
#     simply not a draft, indistinguishable from a null field — so every healthy PR would degrade
#     to UNKNOWN and halt the run. The field goes through `tostring` for that reason.
#
#  2. A MERGED PR reports `mergeable: null` and `mergeStateStatus: null`. Joining the fields on a
#     SPACE lost those trailing empties to word splitting, the read came back short, and the gate
#     retried a finished PR into UNKNOWN instead of rc 3. A resumed run depends on rc 3 to skip a
#     PR that landed while the session was gone.
#
#  3. `mergeable` is computed LAZILY by GitHub, so UNKNOWN is the expected first read for every PR
#     still open right after a merge lands. Resolving it either way on the first read is wrong in
#     both directions: pessimistic halts the run on the first queued PR, optimistic dispatches a
#     merge stage against a PR that conflicts. It must retry, then report UNKNOWN.
#
#  4. A draft reports `mergeable: MERGEABLE` and would sail through as ready. Same trap
#     automerge-merge-gate.sh pins for /automerge Step 3.
#
#  5. An unreadable state is never the optimistic answer. A gh that fails, and a mergeable value gh
#     has not documented yet, are both rc 2 — not rc 0.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

GATE="$HOME/.claude/lib/merge-gate.sh"
[ -f "$GATE" ] || { bad "script not found at $GATE"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/merge-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- the gh stub -------------------------------------------------------------------
# Serves canned JSON through the real jq, so the -q expression under test is the one that runs.
# $GH_JSON is the object. $GH_JSON2 (optional) is served from the second call onward, which is how
# the lazy-mergeability retry is exercised. $GH_FAIL=1 makes the call fail outright.
mkdir -p "$WORK/bin" "$WORK/nogh"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = "1" ] && exit 1
n=0
[ -f "$GH_COUNT" ] && n=$(cat "$GH_COUNT")
printf '%s' $((n + 1)) > "$GH_COUNT"
body="${GH_JSON:-}"
[ "$n" -ge 1 ] && [ -n "${GH_JSON2:-}" ] && body="$GH_JSON2"
printf '%s' "$body" | jq -r "${@: -1}"
STUB
chmod +x "$WORK/bin/gh"
export GH_COUNT="$WORK/count"

command -v jq >/dev/null 2>&1 || { bad "jq is unavailable — the stub cannot serve the -q expression"; summary; exit 1; }

# gate <json> [json-from-2nd-call] [extra args...] -> "rc|output"
gate() {
  local j="$1" j2="${2:-}"; shift 2 2>/dev/null || shift $#
  : > "$GH_COUNT"
  local out
  out=$(GH_JSON="$j" GH_JSON2="$j2" PATH="$WORK/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
        bash "$GATE" 7 --repo o/r --retries "${RETRIES:-0}" --sleep 0 "$@" 2>&1)
  printf '%s|%s' "$?" "$out"
}
rc_of()  { printf '%s' "${1%%|*}"; }
out_of() { printf '%s' "${1#*|}"; }

OPEN='"state":"OPEN","isDraft":false'

# ─────────────────────────────────────────────────────────────────────────────
section "Ready states dispatch: the gate asks 'does it still apply', not 'is it green'"

r=$(gate "{$OPEN,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\"}")
assert_eq "CLEAN is rc 0" "0" "$(rc_of "$r")"
assert_contains "and says READY" "$(out_of "$r")" "READY"

for st in HAS_HOOKS UNSTABLE BLOCKED; do
  r=$(gate "{$OPEN,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"$st\"}")
  assert_eq "$st is rc 0 — remediating CI and reviews is /automerge's cycle" "0" "$(rc_of "$r")"
done

# BLOCKED is the one that matters: a PR reads BLOCKED merely because a required review has not
# landed yet, and treating it as a blocker here would halt a run on every PR in a reviewed repo.

# ─────────────────────────────────────────────────────────────────────────────
section "BEHIND is rc 1, not a blocker — it is the normal reading after the base moves"

r=$(gate "{$OPEN,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"BEHIND\"}")
assert_eq "BEHIND is rc 1" "1" "$(rc_of "$r")"
assert_contains "and names the branch update the merge stage will do" "$(out_of "$r")" "update"
r=$(gate "{$OPEN,\"mergeable\":\"UNKNOWN\",\"mergeStateStatus\":\"BEHIND\"}")
assert_eq "BEHIND wins over an unresolved mergeable — the base moved, that much is known" "1" "$(rc_of "$r")"

# ─────────────────────────────────────────────────────────────────────────────
section "Conflict is rc 5 (blocker), from either field"

r=$(gate "{$OPEN,\"mergeable\":\"CONFLICTING\",\"mergeStateStatus\":\"DIRTY\"}")
assert_eq "CONFLICTING/DIRTY is rc 5" "5" "$(rc_of "$r")"
r=$(gate "{$OPEN,\"mergeable\":\"CONFLICTING\",\"mergeStateStatus\":\"UNKNOWN\"}")
assert_eq "CONFLICTING alone is rc 5, not a retry" "5" "$(rc_of "$r")"
r=$(gate "{$OPEN,\"mergeable\":\"UNKNOWN\",\"mergeStateStatus\":\"DIRTY\"}")
assert_eq "DIRTY alone is rc 5, not a retry" "5" "$(rc_of "$r")"

# ─────────────────────────────────────────────────────────────────────────────
section "A draft is rc 6 even though it reports mergeable: MERGEABLE"

r=$(gate '{"state":"OPEN","isDraft":true,"mergeable":"MERGEABLE","mergeStateStatus":"DRAFT"}')
assert_eq "isDraft true is rc 6" "6" "$(rc_of "$r")"
r=$(gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"DRAFT"}')
assert_eq "mergeStateStatus DRAFT is rc 6 even when isDraft disagrees" "6" "$(rc_of "$r")"

# isDraft:false must NOT read as a null field — jq's `//` treats false as empty, which is the
# whole reason the field goes through tostring.
r=$(gate "{$OPEN,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\"}")
assert_eq "isDraft:false is a value, not an empty field" "0" "$(rc_of "$r")"

# ─────────────────────────────────────────────────────────────────────────────
section "Terminal states are rc 3 — readable when mergeability is null, which is what a resume needs"

r=$(gate '{"state":"MERGED","isDraft":false,"mergeable":null,"mergeStateStatus":null}')
assert_eq "MERGED is rc 3, not UNKNOWN" "3" "$(rc_of "$r")"
assert_contains "and says so" "$(out_of "$r")" "MERGED"
r=$(gate '{"state":"CLOSED","isDraft":false,"mergeable":null,"mergeStateStatus":null}')
assert_eq "CLOSED is rc 3" "3" "$(rc_of "$r")"

# ─────────────────────────────────────────────────────────────────────────────
section "Unknown is never resolved to the optimistic answer"

r=$(gate "{$OPEN,\"mergeable\":\"UNKNOWN\",\"mergeStateStatus\":\"UNKNOWN\"}")
assert_eq "UNKNOWN after the retries is rc 2" "2" "$(rc_of "$r")"
assert_not_contains "and never prints READY" "$(out_of "$r")" "READY"

r=$(gate "{$OPEN,\"mergeable\":null,\"mergeStateStatus\":\"CLEAN\"}")
assert_eq "a null mergeable is rc 2, not rc 0" "2" "$(rc_of "$r")"
r=$(gate "{$OPEN,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":null}")
assert_eq "a null mergeStateStatus is rc 2, not rc 0" "2" "$(rc_of "$r")"
r=$(gate '{"state":null,"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}')
assert_eq "a null state is rc 2 — an unreadable PR is not a merge" "2" "$(rc_of "$r")"

r=$(GH_FAIL=1 gate "{$OPEN,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\"}")
assert_eq "a gh that fails outright is rc 2" "2" "$(rc_of "$r")"
assert_not_contains "and prints no READY line" "$(out_of "$r")" "READY"

r=$(gate "{$OPEN,\"mergeable\":\"SOMETHING_NEW\",\"mergeStateStatus\":\"CLEAN\"}")
assert_eq "an undocumented mergeable value is rc 2, not rc 0" "2" "$(rc_of "$r")"

assert_eq "gh missing from PATH is rc 2" "2" \
  "$(PATH="$WORK/nogh:/usr/bin:/bin" bash "$GATE" 7 --repo o/r --retries 0 --sleep 0 >/dev/null 2>&1; printf '%s' $?)"

# ─────────────────────────────────────────────────────────────────────────────
section "Lazy mergeability: UNKNOWN retries and resolves, rather than halting the run"

RETRIES=3
r=$(gate "{$OPEN,\"mergeable\":\"UNKNOWN\",\"mergeStateStatus\":\"UNKNOWN\"}" \
         "{$OPEN,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\"}")
assert_eq "UNKNOWN first, MERGEABLE after, is rc 0" "0" "$(rc_of "$r")"
assert_eq "the retry actually re-read gh" "2" "$(cat "$GH_COUNT")"

r=$(gate "{$OPEN,\"mergeable\":\"UNKNOWN\",\"mergeStateStatus\":\"UNKNOWN\"}" \
         "{$OPEN,\"mergeable\":\"CONFLICTING\",\"mergeStateStatus\":\"DIRTY\"}")
assert_eq "UNKNOWN first, CONFLICTING after, is rc 5 — the retry decides, not the first read" "5" "$(rc_of "$r")"

r=$(gate "{$OPEN,\"mergeable\":\"UNKNOWN\",\"mergeStateStatus\":\"UNKNOWN\"}")
assert_eq "still UNKNOWN after every retry is rc 2" "2" "$(rc_of "$r")"
assert_eq "and it spent all of them" "4" "$(cat "$GH_COUNT")"
RETRIES=0

# ─────────────────────────────────────────────────────────────────────────────
section "Usage errors are rc 64, and never a verdict"

assert_eq "no arguments" "64" \
  "$(PATH="$WORK/bin:/usr/bin:/bin" bash "$GATE" >/dev/null 2>&1; printf '%s' $?)"
assert_eq "a non-numeric PR" "64" \
  "$(PATH="$WORK/bin:/usr/bin:/bin" bash "$GATE" abc --repo o/r >/dev/null 2>&1; printf '%s' $?)"
assert_eq "--repo missing" "64" \
  "$(PATH="$WORK/bin:/usr/bin:/bin" bash "$GATE" 7 >/dev/null 2>&1; printf '%s' $?)"
assert_eq "--repo without a slash" "64" \
  "$(PATH="$WORK/bin:/usr/bin:/bin" bash "$GATE" 7 --repo justname >/dev/null 2>&1; printf '%s' $?)"
assert_eq "a non-numeric --retries" "64" \
  "$(PATH="$WORK/bin:/usr/bin:/bin" bash "$GATE" 7 --repo o/r --retries x >/dev/null 2>&1; printf '%s' $?)"
assert_eq "an unknown option" "64" \
  "$(PATH="$WORK/bin:/usr/bin:/bin" bash "$GATE" 7 --repo o/r --nope >/dev/null 2>&1; printf '%s' $?)"

summary
