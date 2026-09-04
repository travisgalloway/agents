#!/usr/bin/env bash
# Claude Code status line — mirrors default Starship prompt style
input=$(cat)

user=$(whoami)
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
short_dir=$(basename "$dir")
model=$(echo "$input" | jq -r '.model.display_name')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Git branch (skip optional locks to avoid contention)
branch=""
if git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$dir" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null \
           || git -C "$dir" -c core.fsmonitor=false rev-parse --short HEAD 2>/dev/null)
fi

# Build output using printf for ANSI colors
# Colors: bold green for user, bold blue for dir, bold cyan for branch, dim for model/context
printf "\033[1;32m%s\033[0m" "$user"
printf "\033[0;37m in \033[0m"
printf "\033[1;34m%s\033[0m" "$short_dir"

if [ -n "$branch" ]; then
  printf "\033[0;37m on \033[0m"
  printf "\033[1;36m%s\033[0m" "$branch"
fi

printf "\033[0;37m [%s]\033[0m" "$model"

if [ -n "$used" ]; then
  printf "\033[0;37m ctx:%s%%\033[0m" "$used"
fi

# Live clock — always current, independent of model behavior (see refreshInterval
# in settings.json to keep it ticking during idle periods).
printf "\033[0;37m 🕐 %s\033[0m" "$(date '+%H:%M:%S %Z')"
