#!/usr/bin/env bash
# lint-frontmatter.sh — assert every skill/command and agent file declares only documented
# frontmatter keys.
#
# The specific bug this exists to catch: skills spell the denylist `disallowed-tools`
# (kebab-case) while agents spell it `disallowedTools` (camelCase). Either spelling in the
# wrong file is silently ignored, which turns an enforcement mechanism into a no-op.
#
# Sources:
#   skills — https://code.claude.com/docs/en/skills#frontmatter-reference
#   agents — https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ROOT="$HOME/.claude"

SKILL_KEYS="name description when_to_use argument-hint arguments allowed-tools disallowed-tools \
disable-model-invocation user-invocable model effort context agent background hooks paths shell"

AGENT_KEYS="name description prompt tools disallowedTools model permissionMode maxTurns skills \
mcpServers hooks memory background effort isolation color initialPrompt"

# Emit the top-level keys of a file's YAML frontmatter, one per line.
# Skips comment lines, blank lines, and any nested (indented) mapping.
fm_keys() {
  awk '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^[[:space:]]*#/ { next }
    infm && /^[[:space:]]*$/ { next }
    infm && /^[^[:space:]#][^:]*:/ { sub(/:.*/,""); print }
  ' "$1"
}

check_file() {   # check_file <path> <valid-keys> <kind>
  local f="$1" valid="$2" kind="$3" base; base=$(basename "$(dirname "$f")")/$(basename "$f")
  [ "$kind" = agent ] && base=$(basename "$f")

  local keys; keys=$(fm_keys "$f")
  if [ -z "$keys" ]; then
    bad "$base: no YAML frontmatter found"
    return
  fi

  local bad_keys=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case " $valid " in
      *" $k "*) ;;
      *) bad_keys="$bad_keys $k" ;;
    esac
  done <<EOF
$keys
EOF

  if [ -n "$bad_keys" ]; then
    bad "$base: undocumented key(s):$bad_keys"
  else
    ok "$base"
  fi

  # A model pin outside the policy tiers (opus|sonnet|haiku|inherit) is a quiet routing bug.
  local mv; mv=$(awk 'NR==1{next} /^---$/{exit} /^model:/{sub(/^model:[[:space:]]*/,""); print; exit}' "$f")
  if [ -n "$mv" ]; then
    case "$mv" in
      opus|sonnet|haiku|inherit) ok "$base: model '$mv' is a policy tier" ;;
      *) bad "$base: model '$mv' is not one of opus|sonnet|haiku|inherit" ;;
    esac
  fi

  # Cross-spelling trap, in both directions.
  if [ "$kind" = skill ] && echo "$keys" | grep -qx 'disallowedTools'; then
    bad "$base: uses agent spelling 'disallowedTools'; skills need 'disallowed-tools'"
  fi
  if [ "$kind" = agent ] && echo "$keys" | grep -qx 'disallowed-tools'; then
    bad "$base: uses skill spelling 'disallowed-tools'; agents need 'disallowedTools'"
  fi
}

section "Skills / commands"
# Our own skills, by name — the directory also holds vendor/Cloudflare skills we do not lint.
# Adding a skill here is REQUIRED: a new skill missing from this list is silently skipped, which
# reads as a pass. Two false passes in this suite have already come from that shape.
OURS=" automerge backlog ci closure-audit commit feature-closure pr reap reviews status sync work "
EXPECTED=$(printf '%s' "$OURS" | wc -w | tr -d ' ')

found=0
for f in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  case "$f" in "$ROOT"/skills/*)
      d=$(basename "$(dirname "$f")")
      case "$OURS" in *" $d "*) ;; *) continue ;; esac ;;
  esac
  found=$((found+1)); check_file "$f" "$SKILL_KEYS" skill
done
assert_eq "linted every skill in the allowlist" "$EXPECTED" "$found"

section "Agents"
for f in "$ROOT"/agents/*.md; do
  [ -f "$f" ] || continue
  check_file "$f" "$AGENT_KEYS" agent
done

section "Settings"
SETTINGS="$(cd "$(dirname "$0")/.." && pwd)/settings.json"
if grep -qi fable "$SETTINGS"; then
  bad "settings.json mentions fable"
else
  ok "settings.json has no fable reference"
fi

summary
