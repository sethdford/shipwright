#!/usr/bin/env bash
# Hook: PostToolUse — Error capture after Bash tool failures

# Read tool input from stdin (JSON)
input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
exit_code=$(echo "$input" | jq -r '.tool_result.exit_code // 0' 2>/dev/null)

# Only capture Bash tool failures
if [[ "$tool_name" == "Bash" ]] && [[ "${exit_code:-0}" != "0" ]]; then
    error_log=".claude/pipeline-artifacts/error-log.jsonl"
    mkdir -p "$(dirname "$error_log")"

    # Extract error snippet (last 5 lines of stderr/output)
    error_snippet=$(echo "$input" | jq -r '.tool_result.stderr // .tool_result.stdout // ""' 2>/dev/null | tail -5)
    command_run=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

    # Classify error type
    error_type="unknown"
    case "$error_snippet" in
        *"test"*|*"FAIL"*|*"assert"*) error_type="test" ;;
        *"syntax"*|*"unexpected"*)     error_type="syntax" ;;
        *"not found"*|*"No such"*)     error_type="missing" ;;
        *"permission"*|*"denied"*)     error_type="permission" ;;
        *"timeout"*|*"timed out"*)     error_type="timeout" ;;
    esac

    # Append to JSONL log
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg cmd "$command_run" \
           --arg err "$error_snippet" \
           --arg type "$error_type" \
           --arg code "$exit_code" \
        '{timestamp:$ts, command:$cmd, error:$err, type:$type, exit_code:$code}' >> "$error_log" 2>/dev/null
fi

exit 0
