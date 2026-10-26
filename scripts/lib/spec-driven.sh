#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_SPEC_DRIVEN_LOADED:-}" ]] && return 0
_SPEC_DRIVEN_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright spec-driven — Specification-Driven Development System       ║
# ║  Issue text → structured JSON spec → agent builds from spec             ║
# ║  Diff spec vs implementation at review stage for misalignment detection ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="4.0.0"

# ─── Output Helpers ──────────────────────────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi

# ─── Configuration ───────────────────────────────────────────────────────────

SPEC_DIR="${SPEC_DIR:-.claude/specs}"
SPEC_SCHEMA="${SPEC_SCHEMA:-}"  # Path to specification.json schema (auto-detected)

# ─── Schema Location ────────────────────────────────────────────────────────



# ─── Spec Generation ────────────────────────────────────────────────────────
# Generate a structured spec from issue text or goal description.
# This produces a template that Claude (or the pipeline) fills in.

spec_generate() {
    local title="${1:-}"
    local body="${2:-}"
    local issue_number="${3:-}"
    local output_file="${4:-}"
    local language="${5:-}"

    if [[ -z "$title" ]]; then
        error "spec_generate requires a title"
        return 1
    fi

    mkdir -p "$SPEC_DIR"

    # Generate spec filename from title if not provided
    if [[ -z "$output_file" ]]; then
        local slug
        slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 60)
        output_file="${SPEC_DIR}/${slug}.json"
    fi

    # Estimate complexity from body length and keywords
    local complexity="moderate"
    local body_len=${#body}
    if [[ "$body_len" -lt 100 ]]; then
        complexity="simple"
    elif [[ "$body_len" -lt 300 ]]; then
        complexity="moderate"
    elif [[ "$body_len" -lt 800 ]]; then
        complexity="complex"
    else
        complexity="very_complex"
    fi

    # Extract potential goals from body (lines starting with - or *)
    local goals_json="[]"
    if [[ -n "$body" ]]; then
        local extracted_goals
        extracted_goals=$(echo "$body" | grep -E '^\s*[-*]' | sed 's/^[ \t]*[-*][ \t]*//' | head -10 || true)
        if [[ -n "$extracted_goals" ]]; then
            goals_json="["
            local first=true
            while IFS= read -r goal; do
                [[ -z "$goal" ]] && continue
                # Escape quotes for JSON
                goal=$(echo "$goal" | sed 's/"/\\"/g')
                if $first; then
                    goals_json="${goals_json}\"${goal}\""
                    first=false
                else
                    goals_json="${goals_json},\"${goal}\""
                fi
            done <<< "$extracted_goals"
            goals_json="${goals_json}]"
        fi
    fi

    # If no goals extracted, use title as the goal
    if [[ "$goals_json" == "[]" ]]; then
        local escaped_title
        escaped_title=$(echo "$title" | sed 's/"/\\"/g')
        goals_json="[\"${escaped_title}\"]"
    fi

    # Build source block
    local source_json="{\"type\":\"manual\"}"
    if [[ -n "$issue_number" ]]; then
        source_json="{\"type\":\"github_issue\",\"issue_number\":${issue_number}}"
    fi

    # Write spec (use local fallback if mktemp unavailable in sandbox)
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "${output_file}.raw")
    cat > "$tmp_file" <<SPECEOF
{
  "version": "1.0",
  "title": $(printf '%s' "$title" | jq -Rs .),
  "source": ${source_json},
  "goals": ${goals_json},
  "constraints": [],
  "acceptance_criteria": [
    {
      "criterion": "All existing tests continue to pass",
      "testable": true,
      "verification_method": "unit_test"
    }
  ],
  "edge_cases": [],
  "security_requirements": [],
  "performance_requirements": {},
  "affected_files": [],
  "dependencies": [],
  "metadata": {
    "created_at": "$(now_iso)",
    "complexity": "${complexity}",
    "language": "${language:-unknown}"
  }
}
SPECEOF

    # Validate and pretty-print with jq
    if command -v jq >/dev/null 2>&1; then
        if jq '.' "$tmp_file" > "${output_file}.pp" 2>/dev/null; then
            mv "${output_file}.pp" "$output_file"
        else
            error "Generated spec is invalid JSON"
            mv "$tmp_file" "$output_file"
        fi
    else
        mv "$tmp_file" "$output_file"
    fi
    rm -f "$tmp_file" "${output_file}.pp" "${output_file}.raw" 2>/dev/null || true

    # Validate generated spec has required non-empty arrays
    if command -v jq >/dev/null 2>&1 && [[ -f "$output_file" ]]; then
        local g_count ac_count
        g_count=$(jq '.goals | if type == "array" then length else 0 end' "$output_file" 2>/dev/null || echo "0")
        ac_count=$(jq '.acceptance_criteria | if type == "array" then length else 0 end' "$output_file" 2>/dev/null || echo "0")
        if [[ "$g_count" -eq 0 ]]; then
            error "Generated spec missing non-empty 'goals' array: ${output_file}"
            return 1
        fi
        if [[ "$ac_count" -eq 0 ]]; then
            error "Generated spec missing non-empty 'acceptance_criteria' array: ${output_file}"
            return 1
        fi
    fi

    success "Spec generated: ${output_file}" >&2

    if type emit_event >/dev/null 2>&1; then
        emit_event "spec_generated" \
            "file=${output_file}" \
            "complexity=${complexity}" \
            "issue=${issue_number:-none}"
    fi

    echo "$output_file"
    return 0
}

# ─── Spec Validation ────────────────────────────────────────────────────────
# Validate a spec file against the JSON schema (lightweight jq-based check).

spec_validate() {
    local spec_file="${1:-}"

    if [[ ! -f "$spec_file" ]]; then
        error "Spec file not found: ${spec_file}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not available — skipping spec validation"
        return 0
    fi

    # Check required fields
    local errors=""

    local version
    version=$(jq -r '.version // empty' "$spec_file" 2>/dev/null)
    if [[ "$version" != "1.0" ]]; then
        errors="${errors}Missing or invalid version (expected '1.0')\n"
    fi

    local title
    title=$(jq -r '.title // empty' "$spec_file" 2>/dev/null)
    if [[ -z "$title" ]]; then
        errors="${errors}Missing required field: title\n"
    fi

    local goals_count
    goals_count=$(jq '.goals | length' "$spec_file" 2>/dev/null || echo "0")
    if [[ "$goals_count" -eq 0 ]]; then
        errors="${errors}Missing required field: goals (must have at least 1)\n"
    fi

    local criteria_count
    criteria_count=$(jq '.acceptance_criteria | length' "$spec_file" 2>/dev/null || echo "0")
    if [[ "$criteria_count" -eq 0 ]]; then
        errors="${errors}Missing required field: acceptance_criteria (must have at least 1)\n"
    fi

    # Check acceptance_criteria structure
    local invalid_criteria
    invalid_criteria=$(jq '[.acceptance_criteria[]? | select(.criterion == null or .testable == null)] | length' "$spec_file" 2>/dev/null || echo "0")
    if [[ "$invalid_criteria" -gt 0 ]]; then
        errors="${errors}${invalid_criteria} acceptance criteria missing 'criterion' or 'testable' field\n"
    fi

    if [[ -n "$errors" ]]; then
        error "Spec validation failed for ${spec_file}:"
        echo -e "$errors" | while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  - $line"
        done
        return 1
    fi

    success "Spec valid: ${spec_file}"
    return 0
}

# ─── Spec Load / Save ───────────────────────────────────────────────────────

spec_save() {
    local spec_file="${1:-}"
    local spec_json="${2:-}"

    if [[ -z "$spec_file" || -z "$spec_json" ]]; then
        error "spec_save requires file path and JSON content"
        return 1
    fi

    mkdir -p "$(dirname "$spec_file")"

    # Atomic write via temp file
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "${spec_file}.tmp")
    echo "$spec_json" | jq '.' > "$tmp_file" 2>/dev/null || {
        error "Invalid JSON for spec save"
        rm -f "$tmp_file"
        return 1
    }
    mv "$tmp_file" "$spec_file"

    # Update metadata timestamp
    local updated
    updated=$(jq --arg ts "$(now_iso)" '.metadata.updated_at = $ts' "$spec_file" 2>/dev/null)
    if [[ -n "$updated" ]]; then
        echo "$updated" > "$spec_file"
    fi

    if type emit_event >/dev/null 2>&1; then
        emit_event "spec_updated" "file=${spec_file}"
    fi

    return 0
}

# ─── Spec Diff ───────────────────────────────────────────────────────────────
# Compare spec against implementation. Returns JSON report of misalignments.
# This is used at the review stage to catch "spec says X, code does Y".

spec_diff() {
    local spec_file="${1:-}"
    local project_dir="${2:-.}"

    if [[ ! -f "$spec_file" ]]; then
        error "Spec file not found: ${spec_file}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not available — skipping spec diff"
        return 0
    fi

    local report_file="${SPEC_DIR}/compliance-report.json"
    mkdir -p "$SPEC_DIR"

    # Extract spec data
    local title goals_count criteria_count edge_count security_count
    title=$(jq -r '.title' "$spec_file" 2>/dev/null)
    goals_count=$(jq '.goals | length' "$spec_file" 2>/dev/null || echo "0")
    criteria_count=$(jq '.acceptance_criteria | length' "$spec_file" 2>/dev/null || echo "0")
    edge_count=$(jq '.edge_cases | length' "$spec_file" 2>/dev/null || echo "0")
    security_count=$(jq '.security_requirements | length' "$spec_file" 2>/dev/null || echo "0")

    # Check which affected files were actually modified
    local affected_files
    affected_files=$(jq -r '.affected_files[]?' "$spec_file" 2>/dev/null || true)
    local files_modified=0
    local files_missing=0
    local missing_files=""

    if [[ -n "$affected_files" ]]; then
        while IFS= read -r af; do
            [[ -z "$af" ]] && continue
            if git -C "$project_dir" diff --name-only HEAD 2>/dev/null | grep >/dev/null "$af"; then
                files_modified=$((files_modified + 1))
            elif [[ -f "${project_dir}/${af}" ]]; then
                # File exists but wasn't modified
                files_missing=$((files_missing + 1))
                if [[ -n "$missing_files" ]]; then
                    missing_files="${missing_files},\"${af}\""
                else
                    missing_files="\"${af}\""
                fi
            fi
        done <<< "$affected_files"
    fi

    # Check testable acceptance criteria have corresponding tests
    local testable_criteria untested_criteria
    testable_criteria=$(jq '[.acceptance_criteria[]? | select(.testable == true)] | length' "$spec_file" 2>/dev/null || echo "0")
    untested_criteria=0  # Would need test discovery to check this properly

    # Build compliance report
    cat > "$report_file" <<EOF
{
  "spec_file": "${spec_file}",
  "checked_at": "$(now_iso)",
  "title": $(printf '%s' "$title" | jq -Rs .),
  "coverage": {
    "goals_defined": ${goals_count},
    "acceptance_criteria": ${criteria_count},
    "testable_criteria": ${testable_criteria},
    "edge_cases_defined": ${edge_count},
    "security_requirements": ${security_count}
  },
  "file_coverage": {
    "expected_files": $(jq '.affected_files | length' "$spec_file" 2>/dev/null || echo "0"),
    "files_modified": ${files_modified},
    "files_not_modified": ${files_missing},
    "unmodified_files": [${missing_files}]
  },
  "warnings": [],
  "verdict": "$(if [[ "$files_missing" -gt 0 ]]; then echo "review_needed"; else echo "compliant"; fi)"
}
EOF

    local verdict
    verdict=$(jq -r '.verdict' "$report_file" 2>/dev/null || echo "unknown")

    if [[ "$verdict" == "compliant" ]]; then
        success "Spec compliance: ${title} — all checks passed"
    else
        warn "Spec compliance: ${title} — review needed (${files_missing} expected files not modified)"
    fi

    if type emit_event >/dev/null 2>&1; then
        emit_event "spec_compliance_checked" \
            "spec=${spec_file}" \
            "verdict=${verdict}" \
            "criteria=${criteria_count}"
    fi

    echo "$report_file"
    return 0
}

# ─── Spec List ───────────────────────────────────────────────────────────────

# ─── Spec for Pipeline Prompt ────────────────────────────────────────────────
# Format spec as markdown for injection into agent prompts.

spec_to_prompt() {
    local spec_file="${1:-}"

    if [[ ! -f "$spec_file" ]]; then
        return 1
    fi

    local title goals constraints criteria edge_cases security

    title=$(jq -r '.title' "$spec_file" 2>/dev/null)
    echo "## Specification: ${title}"
    echo ""

    echo "### Goals"
    jq -r '.goals[]?' "$spec_file" 2>/dev/null | while IFS= read -r g; do
        echo "- ${g}"
    done
    echo ""

    local constraints_count
    constraints_count=$(jq '.constraints | length' "$spec_file" 2>/dev/null || echo "0")
    if [[ "$constraints_count" -gt 0 ]]; then
        echo "### Constraints"
        jq -r '.constraints[]?' "$spec_file" 2>/dev/null | while IFS= read -r c; do
            echo "- ${c}"
        done
        echo ""
    fi

    echo "### Acceptance Criteria"
    jq -r '.acceptance_criteria[]? | "- [\(if .testable then "testable" else "manual" end)] \(.criterion)"' "$spec_file" 2>/dev/null
    echo ""

    local edge_count
    edge_count=$(jq '.edge_cases | length' "$spec_file" 2>/dev/null || echo "0")
    if [[ "$edge_count" -gt 0 ]]; then
        echo "### Edge Cases"
        jq -r '.edge_cases[]? | "- **\(.scenario)**: \(.expected_behavior)"' "$spec_file" 2>/dev/null
        echo ""
    fi

    local sec_count
    sec_count=$(jq '.security_requirements | length' "$spec_file" 2>/dev/null || echo "0")
    if [[ "$sec_count" -gt 0 ]]; then
        echo "### Security Requirements"
        jq -r '.security_requirements[]?' "$spec_file" 2>/dev/null | while IFS= read -r s; do
            echo "- ${s}"
        done
        echo ""
    fi
}
