#!/usr/bin/env bash
# Hook: PreToolUse — Context injection for .sh file editing
# Triggered before Write/Edit tools

# Read tool input from stdin (JSON)
input=$(cat)

# Extract file path from tool input
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Only trigger for shell script files
if [[ "$file_path" == *.sh ]]; then
    cat << 'REMINDER'
SHIPWRIGHT SHELL RULES:
- Bash 3.2 compatible: no declare -A, no readarray, no ${var,,}/${var^^}
- set -euo pipefail at top
- grep -c: use || true, then ${var:-0}
- Atomic writes: tmp + mv, never direct echo > file
- JSON: jq --arg, never string interpolation
- cd in functions: use subshells ( cd dir && ... )
- Check $NO_GITHUB before GitHub API calls
REMINDER
fi

exit 0
