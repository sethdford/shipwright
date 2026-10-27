#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_CONSTITUTIONAL_LOADED:-}" ]] && return 0
_CONSTITUTIONAL_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright constitutional — Principle-Based Code Self-Critique          ║
# ║  Deterministic constitutional checks against defined code principles    ║
# ║  Checks files and diffs against security, quality, testing rules        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="4.0.0"

# ─── Output Helpers ──────────────────────────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Configuration ───────────────────────────────────────────────────────────

# Default constitution path (project override takes precedence)
CONSTITUTIONAL_DEFAULT_PATH="${CONSTITUTIONAL_DEFAULT_PATH:-config/code-constitution.json}"
CONSTITUTIONAL_PROJECT_OVERRIDE="${CONSTITUTIONAL_PROJECT_OVERRIDE:-.claude/code-constitution.json}"
CONSTITUTIONAL_REPORT_FILE="${CONSTITUTIONAL_REPORT_FILE:-.claude/pipeline-artifacts/constitution-report.json}"

# Loaded constitution cache (module-level)
_CONSTITUTIONAL_JSON=""
_CONSTITUTIONAL_SOURCE=""

# ─── constitutional_load ─────────────────────────────────────────────────────
# Load constitution from project override or default config.
# Sets _CONSTITUTIONAL_JSON with the parsed content.
# $1: optional explicit path to constitution file
# Returns: 0 on success, 1 on failure

constitutional_load() {
    local explicit_path="${1:-}"
    local constitution_path=""

    # Priority: explicit > project override > default
    if [[ -n "$explicit_path" && -f "$explicit_path" ]]; then
        constitution_path="$explicit_path"
    elif [[ -f "$CONSTITUTIONAL_PROJECT_OVERRIDE" ]]; then
        constitution_path="$CONSTITUTIONAL_PROJECT_OVERRIDE"
    elif [[ -f "$CONSTITUTIONAL_DEFAULT_PATH" ]]; then
        constitution_path="$CONSTITUTIONAL_DEFAULT_PATH"
    else
        # Try relative to SCRIPT_DIR (for when sourced from pipeline)
        local script_dir_path="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
        local repo_root
        repo_root=$(cd "$script_dir_path/.." 2>/dev/null && pwd)
        if [[ -f "$repo_root/$CONSTITUTIONAL_DEFAULT_PATH" ]]; then
            constitution_path="$repo_root/$CONSTITUTIONAL_DEFAULT_PATH"
        fi
    fi

    if [[ -z "$constitution_path" || ! -f "$constitution_path" ]]; then
        warn "No constitution file found"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq required for constitutional checks"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$constitution_path" 2>/dev/null; then
        error "Invalid JSON in constitution: $constitution_path"
        return 1
    fi

    _CONSTITUTIONAL_JSON=$(cat "$constitution_path")
    _CONSTITUTIONAL_SOURCE="$constitution_path"
    return 0
}

# ─── constitutional_get_principles ───────────────────────────────────────────
# Get all principles, optionally filtered by category or severity.
# $1: category filter (optional, e.g., "security")
# $2: severity filter (optional, e.g., "critical")
# Outputs: JSON array of matching principles

constitutional_get_principles() {
    local category="${1:-}"
    local severity="${2:-}"

    if [[ -z "$_CONSTITUTIONAL_JSON" ]]; then
        echo "[]"
        return 1
    fi

    local filter=".principles"

    if [[ -n "$category" ]]; then
        filter="${filter}.${category} // []"
    else
        # Flatten all categories into a single array
        filter="[${filter} | to_entries[] | .value[]]"
    fi

    local result
    result=$(echo "$_CONSTITUTIONAL_JSON" | jq "$filter" 2>/dev/null || echo "[]")

    if [[ -n "$severity" ]]; then
        result=$(echo "$result" | jq --arg sev "$severity" '[.[] | select(.severity == $sev)]' 2>/dev/null || echo "[]")
    fi

    echo "$result"
}

# ─── constitutional_check_file ───────────────────────────────────────────────
# Check a single file against all principles with automated checks.
# $1: file path to check
# $2: optional category filter
# Outputs: JSON array of violations
# Returns: 0 (always — violations in output, not exit code)

constitutional_check_file() {
    local file_path="${1:-}"
    local category="${2:-}"

    if [[ -z "$file_path" || ! -f "$file_path" ]]; then
        echo "[]"
        return 0
    fi

    if [[ -z "$_CONSTITUTIONAL_JSON" ]]; then
        constitutional_load || { echo "[]"; return 0; }
    fi

    local violations="[]"
    local principles
    principles=$(constitutional_get_principles "$category")

    local count
    count=$(echo "$principles" | jq 'length' 2>/dev/null || echo "0")

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local principle
        principle=$(echo "$principles" | jq ".[$i]" 2>/dev/null)

        local has_check
        has_check=$(echo "$principle" | jq -r 'has("check")' 2>/dev/null || echo "false")

        if [[ "$has_check" == "true" ]]; then
            local check_cmd
            check_cmd=$(echo "$principle" | jq -r '.check' 2>/dev/null)

            # Replace {file} placeholder with actual file path
            check_cmd="${check_cmd//\{file\}/$file_path}"

            local check_output=""
            # Safety: only allow grep-based checks to prevent code injection
            # from untrusted constitution override files (CRITIC-001)
            if echo "$check_cmd" | grep >/dev/null -E '^grep\b'; then
                check_output=$(bash -c "$check_cmd" 2>/dev/null) || true
            else
                # Non-grep check commands are logged and skipped
                if type emit_event >/dev/null 2>&1; then
                    emit_event "constitutional.unsafe_check_skipped" "cmd=$(echo "$check_cmd" | head -c 50)"
                fi
            fi

            if [[ -n "$check_output" ]]; then
                local id sev rule
                id=$(echo "$principle" | jq -r '.id' 2>/dev/null)
                sev=$(echo "$principle" | jq -r '.severity' 2>/dev/null)
                rule=$(echo "$principle" | jq -r '.rule' 2>/dev/null)

                # Parse each matching line
                while IFS= read -r match_line; do
                    [[ -z "$match_line" ]] && continue
                    local line_num=""
                    # Extract line number if present (grep -n format: "N:content")
                    if echo "$match_line" | grep >/dev/null -E '^[0-9]+:'; then
                        line_num=$(echo "$match_line" | cut -d: -f1)
                    fi

                    violations=$(echo "$violations" | jq \
                        --arg id "$id" \
                        --arg sev "$sev" \
                        --arg rule "$rule" \
                        --arg file "$file_path" \
                        --arg line "${line_num:-0}" \
                        --arg match "$match_line" \
                        '. + [{
                            "principle_id": $id,
                            "severity": $sev,
                            "rule": $rule,
                            "file": $file,
                            "line": ($line | tonumber),
                            "match": $match,
                            "type": "automated"
                        }]' 2>/dev/null || echo "$violations")
                done <<< "$check_output"
            fi
        fi

        i=$((i + 1))
    done

    echo "$violations"
}

# ─── constitutional_check_diff ───────────────────────────────────────────────
# Check only changed lines from a git diff against constitutional principles.
# $1: base branch or commit (default: main)
# $2: optional category filter
# Outputs: JSON array of violations in changed code only

constitutional_check_diff() {
    local base="${1:-main}"
    local category="${2:-}"

    if [[ -z "$_CONSTITUTIONAL_JSON" ]]; then
        constitutional_load || { echo "[]"; return 0; }
    fi

    # Get list of changed files (added/modified only)
    local changed_files
    changed_files=$(git diff --name-only --diff-filter=AM "$base" 2>/dev/null || true)

    if [[ -z "$changed_files" ]]; then
        echo "[]"
        return 0
    fi

    local all_violations="[]"

    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue

        # Get added line numbers for this file
        local added_lines
        added_lines=$(git diff "$base" -- "$file" 2>/dev/null | \
            grep -nE '^\+' | grep -v '^\+\+\+' | \
            sed 's/^\([0-9]*\):.*/\1/' || true)

        # Check the file
        local file_violations
        file_violations=$(constitutional_check_file "$file" "$category")

        local vcount
        vcount=$(echo "$file_violations" | jq 'length' 2>/dev/null || echo "0")

        # Filter to only violations on changed lines (if we have line info)
        if [[ -n "$added_lines" && "$vcount" -gt 0 ]]; then
            local vi=0
            while [[ "$vi" -lt "$vcount" ]]; do
                local v_line
                v_line=$(echo "$file_violations" | jq -r ".[$vi].line" 2>/dev/null || echo "0")
                # Include violation if line is 0 (no line info) or in changed lines
                if [[ "$v_line" == "0" ]] || echo "$added_lines" | grep >/dev/null -x "$v_line" 2>/dev/null; then
                    local violation
                    violation=$(echo "$file_violations" | jq ".[$vi]" 2>/dev/null)
                    all_violations=$(echo "$all_violations" | jq --argjson v "$violation" '. + [$v]' 2>/dev/null || echo "$all_violations")
                fi
                vi=$((vi + 1))
            done
        fi
    done <<< "$changed_files"

    echo "$all_violations"
}

# ─── constitutional_self_critique ────────────────────────────────────────────
# Generate a full self-critique report with violations and fix suggestions.
# $1: base branch or commit (default: main)
# $2: output file (default: CONSTITUTIONAL_REPORT_FILE)
# Returns: number of violations found

constitutional_self_critique() {
    local base="${1:-main}"
    local report_file="${2:-$CONSTITUTIONAL_REPORT_FILE}"

    if [[ -z "$_CONSTITUTIONAL_JSON" ]]; then
        constitutional_load || return 1
    fi

    # Ensure artifacts directory exists
    local report_dir
    report_dir=$(dirname "$report_file")
    mkdir -p "$report_dir" 2>/dev/null || true

    # Run diff-based checks
    local violations
    violations=$(constitutional_check_diff "$base")

    local total
    total=$(echo "$violations" | jq 'length' 2>/dev/null || echo "0")

    # Count by severity
    local critical high medium low
    critical=$(echo "$violations" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")
    high=$(echo "$violations" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")
    medium=$(echo "$violations" | jq '[.[] | select(.severity == "medium")] | length' 2>/dev/null || echo "0")
    low=$(echo "$violations" | jq '[.[] | select(.severity == "low")] | length' 2>/dev/null || echo "0")

    # Build report
    local report
    report=$(jq -n \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg src "${_CONSTITUTIONAL_SOURCE:-unknown}" \
        --arg base "$base" \
        --argjson violations "$violations" \
        --argjson total "$total" \
        --argjson critical "$critical" \
        --argjson high "$high" \
        --argjson medium "$medium" \
        --argjson low "$low" \
        '{
            "timestamp": $ts,
            "constitution_source": $src,
            "base_branch": $base,
            "summary": {
                "total_violations": $total,
                "by_severity": {
                    "critical": $critical,
                    "high": $high,
                    "medium": $medium,
                    "low": $low
                },
                "verdict": (if $critical > 0 then "fail" elif $high > 0 then "review_needed" else "pass" end)
            },
            "violations": $violations
        }' 2>/dev/null)

    # Write report atomically
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "${report_file}.tmp")
    echo "$report" > "$tmp_file"
    mv "$tmp_file" "$report_file" 2>/dev/null || cp "$tmp_file" "$report_file"
    rm -f "$tmp_file" 2>/dev/null || true

    # Log results
    if [[ "$total" -gt 0 ]]; then
        if [[ "$critical" -gt 0 ]]; then
            error "Constitutional review: $total violation(s) ($critical critical, $high high)"
        elif [[ "$high" -gt 0 ]]; then
            warn "Constitutional review: $total violation(s) ($high high, $medium medium)"
        else
            info "Constitutional review: $total violation(s) ($medium medium, $low low)"
        fi
    else
        success "Constitutional review: clean — no violations"
    fi

    # Emit event if available
    if type emit_event >/dev/null 2>&1; then
        emit_event "constitutional.review_complete" \
            "total=$total" \
            "critical=$critical" \
            "high=$high" \
            "verdict=$(echo "$report" | jq -r '.summary.verdict' 2>/dev/null || echo "unknown")"
    fi

    echo "$total"
}

# ─── constitutional_inject_prompt ────────────────────────────────────────────
# Format constitutional principles for injection into agent prompts.
# $1: optional category filter (e.g., "security")
# $2: optional severity minimum ("critical", "high", "medium", "low")
# Outputs: formatted text block for prompt injection

constitutional_inject_prompt() {
    local category="${1:-}"
    local min_severity="${2:-}"

    if [[ -z "$_CONSTITUTIONAL_JSON" ]]; then
        constitutional_load || return 0
    fi

    local principles
    principles=$(constitutional_get_principles "$category")

    # Filter by minimum severity if specified
    if [[ -n "$min_severity" ]]; then
        local sev_filter
        case "$min_severity" in
            critical) sev_filter='select(.severity == "critical")' ;;
            high)     sev_filter='select(.severity == "critical" or .severity == "high")' ;;
            medium)   sev_filter='select(.severity == "critical" or .severity == "high" or .severity == "medium")' ;;
            *)        sev_filter='.' ;;
        esac
        principles=$(echo "$principles" | jq "[.[] | $sev_filter]" 2>/dev/null || echo "$principles")
    fi

    local count
    count=$(echo "$principles" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo "## Code Constitution — Mandatory Principles"
    echo "You MUST follow these principles. Violations will be caught by automated review."
    echo ""

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local id sev rule
        id=$(echo "$principles" | jq -r ".[$i].id" 2>/dev/null)
        sev=$(echo "$principles" | jq -r ".[$i].severity" 2>/dev/null)
        rule=$(echo "$principles" | jq -r ".[$i].rule" 2>/dev/null)
        echo "- **[$sev]** $id: $rule"
        i=$((i + 1))
    done

    # Inject violation history if report exists
    if [[ -f "$CONSTITUTIONAL_REPORT_FILE" ]]; then
        local prev_total
        prev_total=$(jq -r '.summary.total_violations // 0' "$CONSTITUTIONAL_REPORT_FILE" 2>/dev/null || echo "0")
        if [[ "$prev_total" -gt 0 ]]; then
            echo ""
            echo "### Previous Violations (fix these first)"
            jq -r '.violations[]? | "- [\(.severity)] \(.principle_id): \(.rule) — \(.file):\(.line)"' \
                "$CONSTITUTIONAL_REPORT_FILE" 2>/dev/null | head -20
        fi
    fi
}

# ─── constitutional_format_violations ────────────────────────────────────────
# Format violations as human-readable text.
# $1: JSON violations array
# Outputs: formatted violation list

constitutional_format_violations() {
    local violations="${1:-[]}"

    local count
    count=$(echo "$violations" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        echo "No violations found."
        return 0
    fi

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local id sev rule file line
        id=$(echo "$violations" | jq -r ".[$i].principle_id" 2>/dev/null)
        sev=$(echo "$violations" | jq -r ".[$i].severity" 2>/dev/null)
        rule=$(echo "$violations" | jq -r ".[$i].rule" 2>/dev/null)
        file=$(echo "$violations" | jq -r ".[$i].file" 2>/dev/null)
        line=$(echo "$violations" | jq -r ".[$i].line" 2>/dev/null)
        echo "VIOLATION [$sev] $id: $rule — $file:$line"
        i=$((i + 1))
    done
}
