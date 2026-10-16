#!/usr/bin/env bash
# Hook: PreToolUse — Security checks and context injection
# Triggered before Write/Edit tools

# Read tool input from stdin (JSON)
input=$(cat)

# Extract tool name and file path
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
new_string=$(echo "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
tool_input=$(echo "$input" | jq -r '.tool_input // empty' 2>/dev/null)

# Security check: Block git push --no-verify (bypasses pre-commit hooks)
if echo "$tool_input" | grep >/dev/null -E 'git\s+push.*--no-verify'; then
    echo '{"message":"Blocked: git push --no-verify bypasses safety checks. Remove --no-verify flag."}'
    exit 2
fi

# Security check: Detect secrets being written to non-secret files
if [[ "$tool_name" == "Edit" || "$tool_name" == "Write" ]]; then
    # Sensitive files that should not be added to version control
    if [[ ! "$file_path" =~ (\.env|\.secret|secret|credential|key|token|private) ]]; then
        # Check for common secret patterns
        secret_patterns="sk-ant-|ANTHROPIC_API_KEY|GITHUB_TOKEN|OPENAI_API_KEY|AWS_SECRET|DATABASE_URL|PRIVATE_KEY|api_key|BEGIN RSA PRIVATE KEY|BEGIN PRIVATE KEY"

        if echo "$new_string" | grep >/dev/null -E "$secret_patterns"; then
            cat << "SECURITY_WARNING"
⚠️  SECURITY WARNING: Secret pattern detected in non-secret file

The content being written to this file contains a potential secret.
File: $file_path

Sensitive data should NEVER be committed to version control.

If this is intentional (e.g., example code), please review carefully.
SECURITY_WARNING
            exit 2
        fi
    fi
fi

# Shell script context injection
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
