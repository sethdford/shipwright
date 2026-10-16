#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  compound-audit — Adaptive multi-agent audit cascade                    ║
# ║                                                                         ║
# ║  Runs specialized audit agents in parallel, deduplicates findings,      ║
# ║  escalates to specialists when needed, and converges when confidence    ║
# ║  is high. All functions fail-open with || return 0.                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_COMPOUND_AUDIT_LOADED:-}" ]] && return 0
_COMPOUND_AUDIT_LOADED=1

# ─── Agent prompt templates ────────────────────────────────────────────────
# Each agent gets the same context but a specialized lens.

_COMPOUND_AGENT_PROMPTS_logic="You are a Logic Auditor. Focus ONLY on:
- Control flow bugs, off-by-one errors, wrong conditions
- Algorithm errors, incorrect logic, null/undefined paths
- Race conditions, state management bugs
- Edge cases in arithmetic or string operations
Do NOT report style issues, missing features, or integration problems."

_COMPOUND_AGENT_PROMPTS_integration="You are an Integration Auditor. Focus ONLY on:
- Missing imports, broken call chains, unconnected components
- Mismatched interfaces between modules
- Functions called with wrong arguments or missing arguments
- Wiring gaps where new code isn't connected to existing code
Do NOT report logic bugs, style issues, or missing features."

_COMPOUND_AGENT_PROMPTS_completeness="You are a Completeness Auditor. Focus ONLY on:
- Spec vs. implementation gaps (does the code do what the plan says?)
- Missing test coverage for new functionality
- TODO/FIXME/placeholder code left behind
- Partial implementations (feature started but not finished)
Do NOT report logic bugs, style issues, or integration problems."

_COMPOUND_AGENT_PROMPTS_security="You are a Security Auditor. Focus ONLY on:
- Command injection, path traversal, input validation gaps
- Credential/secret exposure in code or logs
- Authentication/authorization bypass paths
- OWASP top 10 vulnerability patterns
Do NOT report non-security issues."

_COMPOUND_AGENT_PROMPTS_error_handling="You are an Error Handling Auditor. Focus ONLY on:
- Silent error swallowing (empty catch blocks, ignored return codes)
- Missing error paths (what happens when X fails?)
- Inconsistent error handling patterns
- Unchecked return values from external commands
Do NOT report non-error-handling issues."

_COMPOUND_AGENT_PROMPTS_performance="You are a Performance Auditor. Focus ONLY on:
- O(n^2) or worse patterns in loops
- Unbounded memory allocation or file reads
- Missing pagination or streaming for large data
- Repeated expensive operations that could be cached
Do NOT report non-performance issues."

_COMPOUND_AGENT_PROMPTS_edge_case="You are an Edge Case Auditor. Focus ONLY on:
- Zero-length inputs, empty strings, empty arrays
- Maximum/minimum boundary values
- Unicode, special characters, newlines in data
- Concurrent access, timing-dependent behavior
Do NOT report non-edge-case issues."

# ─── compound_audit_build_prompt ───────────────────────────────────────────
# Builds the full prompt for a specific agent type.
#
# Usage: compound_audit_build_prompt "logic" "$diff" "$plan" "$prev_findings_json"
compound_audit_build_prompt() {
    local agent_type="$1"
    local diff="$2"
    local plan_summary="$3"
    local prev_findings="$4"

    # Get agent-specific instructions
    local varname="_COMPOUND_AGENT_PROMPTS_${agent_type}"
    local specialization="${!varname:-"You are a code auditor. Review the changes for issues."}"

    cat <<EOF
${specialization}

## Code Changes (cumulative diff)
\`\`\`
${diff}
\`\`\`

## Implementation Plan/Spec
${plan_summary}

## Previously Found Issues (do NOT repeat these)
${prev_findings}

## Output Format
Return ONLY valid JSON (no markdown, no explanation):
{"findings":[{"severity":"critical|high|medium|low","category":"${agent_type}","file":"path/to/file","line":0,"description":"One sentence","evidence":"The specific code","suggestion":"How to fix"}]}

If no issues found, return: {"findings":[]}
EOF
}

# ─── compound_audit_parse_findings ─────────────────────────────────────────
# Parses agent output into a findings array. Handles malformed output.
#
# Usage: compound_audit_parse_findings "$agent_stdout"
# Output: JSON array of findings (or empty array on failure)
compound_audit_parse_findings() {
    local raw_output="$1"

    # Strip markdown code fences if present
    local cleaned
    cleaned=$(echo "$raw_output" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\r')

    # Try to extract findings array
    local findings
    findings=$(echo "$cleaned" | jq -r '.findings // []' 2>/dev/null) || findings="[]"

    # Validate it's actually an array
    if echo "$findings" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$findings"
    else
        echo "[]"
    fi
}

# ─── compound_audit_dedup_structural ───────────────────────────────────────
# Tier 1 dedup: same file + same category + lines within 5 = duplicate.
# Keeps the first (highest severity) finding in each group.
#
# Usage: compound_audit_dedup_structural "$findings_json_array"
# Output: Deduplicated JSON array
compound_audit_dedup_structural() {
    local findings="$1"

    [[ -z "$findings" || "$findings" == "[]" ]] && { echo "[]"; return 0; }

    # Use jq to group by file+category, then within each group merge findings
    # whose lines are within 5 of each other
    echo "$findings" | jq '
      # Sort by severity priority (critical first) then by line
      def sev_order: if . == "critical" then 0 elif . == "high" then 1
        elif . == "medium" then 2 else 3 end;

      sort_by([(.severity | sev_order), .line]) |

      # Group by file + category
      group_by([.file, .category]) |

      # Within each group, merge findings with lines within 5
      map(
        reduce .[] as $item ([];
          if length == 0 then [$item]
          elif (. | last | .line) and $item.line and
               (($item.line - (. | last | .line)) | fabs) <= 5
          then .  # Skip duplicate (nearby line, same file+category)
          else . + [$item]
          end
        )
      ) | flatten
    ' 2>/dev/null || echo "$findings"
}

# ─── Escalation trigger keywords ──────────────────────────────────────────
_COMPOUND_TRIGGERS_security="injection|auth|secret|credential|permission|bypass|xss|csrf|traversal|sanitiz"
_COMPOUND_TRIGGERS_error_handling="catch|swallow|silent|ignore.*error|missing.*error|unchecked|unhandled"
_COMPOUND_TRIGGERS_performance="O\\(n|loop.*loop|unbounded|pagination|cache|memory.*leak|quadratic"
_COMPOUND_TRIGGERS_edge_case="boundary|empty.*input|null.*check|zero.*length|unicode|concurrent|race"

# ─── compound_audit_escalate ──────────────────────────────────────────────
# Scans findings for trigger keywords, returns space-separated specialist list.
#
# Usage: compound_audit_escalate "$findings_json_array"
# Output: Space-separated specialist names (e.g., "security error_handling")
compound_audit_escalate() {
    local findings="$1"

    [[ -z "$findings" || "$findings" == "[]" ]] && return 0

    # Flatten all finding text for keyword scanning
    local all_text
    all_text=$(echo "$findings" | jq -r '.[] | .description + " " + .evidence + " " + .file' 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 0

    local specialists=""
    local spec
    for spec in security error_handling performance edge_case; do
        local varname="_COMPOUND_TRIGGERS_${spec}"
        local pattern="${!varname:-}"
        if [[ -n "$pattern" ]] && echo "$all_text" | grep >/dev/null -Ei "$pattern" 2>/dev/null; then
            specialists="${specialists:+${specialists} }${spec}"
        fi
    done

    echo "$specialists"
}

# ─── compound_audit_converged ─────────────────────────────────────────────
# Checks stop conditions for the cascade loop.
#
# Usage: compound_audit_converged "$new_findings" "$all_prev_findings" $cycle $max_cycles
# Output: Reason string if converged ("no_criticals", "dup_rate", "max_cycles"), empty if not
compound_audit_converged() {
    local new_findings="$1"
    local prev_findings="$2"
    local cycle="$3"
    local max_cycles="$4"

    # Hard cap: max cycles reached
    if [[ "$cycle" -ge "$max_cycles" ]]; then
        echo "max_cycles"
        return 0
    fi

    # No findings at all = converged
    local new_count
    new_count=$(echo "$new_findings" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$new_count" -eq 0 ]]; then
        echo "no_criticals"
        return 0
    fi

    # Check for critical/high in new findings
    local crit_high_count
    crit_high_count=$(echo "$new_findings" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")

    # If previous findings exist, check duplicate rate via structural match
    local prev_count
    prev_count=$(echo "$prev_findings" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$prev_count" -gt 0 && "$new_count" -gt 0 ]]; then
        # Count how many new findings structurally match previous ones
        local dup_count=0
        local i=0
        while [[ "$i" -lt "$new_count" ]]; do
            local nf nc nl
            nf=$(echo "$new_findings" | jq -r ".[$i].file // \"\"" 2>/dev/null)
            nc=$(echo "$new_findings" | jq -r ".[$i].category // \"\"" 2>/dev/null)
            nl=$(echo "$new_findings" | jq -r ".[$i].line // 0" 2>/dev/null)

            # Check if any previous finding matches file+category+nearby line
            local match
            match=$(echo "$prev_findings" | jq --arg f "$nf" --arg c "$nc" --argjson l "$nl" \
                '[.[] | select(.file == $f and .category == $c and ((.line // 0) - $l | fabs) <= 5)] | length' 2>/dev/null || echo "0")
            [[ "$match" -gt 0 ]] && dup_count=$((dup_count + 1))
            i=$((i + 1))
        done

        # If all findings are duplicates, converged
        if [[ "$dup_count" -eq "$new_count" ]]; then
            echo "dup_rate"
            return 0
        fi
    fi

    # No critical/high = converged
    if [[ "$crit_high_count" -eq 0 ]]; then
        echo "no_criticals"
        return 0
    fi

    # Not converged
    echo ""
    return 0
}

# ─── compound_audit_run_cycle ─────────────────────────────────────────────
# Runs multiple agents in parallel and collects their findings.
#
# Usage: compound_audit_run_cycle "logic integration completeness" "$diff" "$plan" "$prev_findings" $cycle
# Output: Merged JSON array of all findings
compound_audit_run_cycle() {
    local agents="$1"
    local diff="$2"
    local plan_summary="$3"
    local prev_findings="$4"
    local cycle="$5"

    local model="${COMPOUND_AUDIT_MODEL:-haiku}"
    local temp_dir
    temp_dir=$(mktemp -d) || return 0

    # Emit cycle start event
    type audit_emit >/dev/null 2>&1 && \
        audit_emit "compound.cycle_start" "cycle=$cycle" "agents=$agents" || true

    # Launch agents in parallel
    local pids=()
    local agent
    for agent in $agents; do
        local prompt
        prompt=$(compound_audit_build_prompt "$agent" "$diff" "$plan_summary" "$prev_findings")

        (
            local output
            output=$(echo "$prompt" | claude -p --model "$model" 2>/dev/null) || output='{"findings":[]}'
            echo "$output" > "$temp_dir/${agent}.json"
        ) &
        pids+=($!)
    done

    # Wait for all agents
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Merge findings from all agents
    local all_findings="[]"
    for agent in $agents; do
        local agent_file="$temp_dir/${agent}.json"
        if [[ -f "$agent_file" ]]; then
            local agent_findings
            agent_findings=$(compound_audit_parse_findings "$(cat "$agent_file")")

            # Emit individual findings as audit events
            local i=0
            local fc
            fc=$(echo "$agent_findings" | jq 'length' 2>/dev/null || echo "0")
            while [[ "$i" -lt "$fc" ]]; do
                local sev desc file line
                sev=$(echo "$agent_findings" | jq -r ".[$i].severity" 2>/dev/null)
                desc=$(echo "$agent_findings" | jq -r ".[$i].description" 2>/dev/null)
                file=$(echo "$agent_findings" | jq -r ".[$i].file" 2>/dev/null)
                line=$(echo "$agent_findings" | jq -r ".[$i].line" 2>/dev/null)
                type audit_emit >/dev/null 2>&1 && \
                    audit_emit "compound.finding" "cycle=$cycle" "agent=$agent" \
                        "severity=$sev" "file=$file" "line=$line" "description=$desc" || true
                i=$((i + 1))
            done

            # Merge into all_findings
            all_findings=$(echo "$all_findings" "$agent_findings" | jq -s '.[0] + .[1]' 2>/dev/null || echo "$all_findings")
        fi
    done

    # Cleanup
    rm -rf "$temp_dir" 2>/dev/null || true

    echo "$all_findings"
}
