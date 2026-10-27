#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   scope-enforcement.sh — Planned vs actual file tracking, PR size gate
#   Implements Component 4 of the Pipeline Quality Revolution
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

[[ -n "${_SCOPE_ENFORCEMENT_LOADED:-}" ]] && return 0
_SCOPE_ENFORCEMENT_LOADED=1

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${SCRIPT_DIR}/lib/helpers.sh"

VERSION="4.0.0"

# ─── Extract planned files from plan.md "Files to Modify" section ─────────
# Handles multiple markdown formats: bullet lists, numbered lists, tables, code blocks
# Usage: extract_planned_files "$plan_file"
# Output: newline-separated list of file paths
extract_planned_files() {
    local plan_file="$1"

    if [[ ! -f "$plan_file" ]]; then
        echo ""
        return 0
    fi

    local in_files_section=false
    local files=""

    while IFS= read -r line; do
        # Detect "Files to Modify" section header (case-insensitive)
        local line_lower
        line_lower=$(echo "$line" | tr 'A-Z' 'a-z')
        if echo "$line_lower" | grep -E '^[[:space:]]*#+[[:space:]]*(files[[:space:]]+to[[:space:]]+(modify|change))' >/dev/null; then
            in_files_section=true
            continue
        fi

        # Exit section if we hit another ## header
        if [[ "$in_files_section" == "true" ]] && [[ "$line" =~ ^##[^#] ]]; then
            in_files_section=false
            continue
        fi

        # Only process lines while we're in the Files section
        if [[ "$in_files_section" == "false" ]]; then
            continue
        fi

        # Skip empty lines and headers within the section
        if [[ -z "$(echo "$line" | sed 's/^[[:space:]]*$//')" ]]; then
            continue
        fi

        # Extract paths from bullet lists: "- path/to/file.ts"
        if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+([^[:space:]#].+)$ ]]; then
            local item="${BASH_REMATCH[1]}"
            # Clean up markdown formatting
            item=$(echo "$item" | sed 's/`//g' | sed 's/\*\*//g' | sed 's/\[//g' | sed 's/\]//g' | xargs)
            if [[ -n "$item" && ! "$item" =~ ^# ]]; then
                files="${files}${item}"$'\n'
            fi
            continue
        fi

        # Extract paths from numbered lists: "1. path/to/file.ts" or "1) path/to/file.ts"
        if echo "$line" | grep -E '^[[:space:]]*[0-9]+[.)] ' >/dev/null; then
            local item
            item=$(echo "$line" | sed 's/^[[:space:]]*[0-9]*[.)] //' | xargs)
            item=$(echo "$item" | sed 's/`//g' | sed 's/\*\*//g' | sed 's/\[//g' | sed 's/\]//g')
            if [[ -n "$item" && ! "$item" =~ ^# ]]; then
                files="${files}${item}"$'\n'
            fi
            continue
        fi

        # Extract paths from markdown tables (pipe-delimited)
        if echo "$line" | grep -E '^[[:space:]]*\|' >/dev/null; then
            # Skip separator rows (all dashes)
            if echo "$line" | grep -E '^\|[-: |]+\|' >/dev/null; then
                continue
            fi
            # Skip header rows (contains "File", "Path", "Purpose", etc.)
            if echo "$line" | grep -i -E '(File|Path|Purpose)' >/dev/null; then
                continue
            fi
            # Extract cells from the line
            local cells
            cells=$(echo "$line" | sed 's/^[[:space:]]*|//' | sed 's/|[[:space:]]*$//')
            # Process first cell (usually the file path)
            local first_cell
            first_cell=$(echo "$cells" | cut -d'|' -f1 | xargs)
            first_cell=$(echo "$first_cell" | sed 's/`//g' | sed 's/\*\*//g' | sed 's/\[//g' | sed 's/\]//g')
            if [[ -n "$first_cell" && "$first_cell" =~ / ]]; then
                files="${files}${first_cell}"$'\n'
            fi
            continue
        fi

        # Extract paths from code blocks (triple backticks with optional language)
        if [[ "$line" =~ ^\`\`\`([a-zA-Z0-9_-]*)?$ ]]; then
            continue
        fi

        if [[ "$line" =~ ^\`\`\`$ ]]; then
            continue
        fi

        # If line looks like a file path (contains /, starts with src/, lib/, etc.)
        local trimmed
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^[[:space:]]*[0-9]*[.)] //' | xargs)
        if [[ "$trimmed" =~ / ]] && [[ -n "$trimmed" ]] && [[ ! "$trimmed" =~ ^[#*] ]]; then
            files="${files}${trimmed}"$'\n'
        fi
    done < "$plan_file"

    # Remove duplicates and blank lines
    echo "$files" | grep -v '^$' | sort -u || true
}

# ─── Get list of actually changed files from git diff ─────────────────────
# Usage: get_changed_files "$base_branch"
# Output: newline-separated list of file paths
get_changed_files() {
    local base_branch="${1:-origin/main}"

    # Get files changed compared to base branch
    # Filter out .claude/ files to focus on real code changes
    git diff --name-only "$base_branch"...HEAD 2>/dev/null | grep -v '^\.claude/' || true
}

# ─── Get PR stats (insertions, deletions, files changed) ──────────────────
# Usage: get_pr_stats "$base_branch"
# Output: JSON with insertions, deletions, files_changed
get_pr_stats() {
    local base_branch="${1:-origin/main}"

    local insertions=0
    local deletions=0
    local files_changed=0

    # Get stat output
    local stat_output
    stat_output=$(git diff --stat "$base_branch"...HEAD 2>/dev/null || true)

    if [[ -n "$stat_output" ]]; then
        # Extract counts from the summary line (last line of --stat output)
        # Format: " N files changed, M insertions(+), K deletions(-)"
        local summary
        summary=$(echo "$stat_output" | tail -1)

        # Extract files changed
        if [[ "$summary" =~ ([0-9]+)[[:space:]]+files?[[:space:]]+changed ]]; then
            files_changed="${BASH_REMATCH[1]}"
        fi

        # Extract insertions
        if [[ "$summary" =~ ([0-9]+)[[:space:]]+insertions?\(\+ ]]; then
            insertions="${BASH_REMATCH[1]}"
        fi

        # Extract deletions
        if [[ "$summary" =~ ([0-9]+)[[:space:]]+deletions?\(\- ]]; then
            deletions="${BASH_REMATCH[1]}"
        fi
    fi

    # Return as JSON
    echo "{\"insertions\":$insertions,\"deletions\":$deletions,\"files_changed\":$files_changed}"
}

# ─── Compare planned vs actual files, generate scope report ───────────────
# Usage: generate_scope_report "$plan_file" "$base_branch" "$artifacts_dir"
# Output: scope-report.json in artifacts_dir
generate_scope_report() {
    local plan_file="$1"
    local base_branch="${2:-origin/main}"
    local artifacts_dir="${3:-.}"

    # Extract planned files
    local planned_files
    planned_files=$(extract_planned_files "$plan_file")

    # Get actual changed files
    local actual_files
    actual_files=$(get_changed_files "$base_branch")

    # Get PR stats
    local pr_stats
    pr_stats=$(get_pr_stats "$base_branch")

    # Build arrays for comparison
    local planned_array=()
    local actual_array=()

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        planned_array+=("$file")
    done <<< "$planned_files"

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        actual_array+=("$file")
    done <<< "$actual_files"

    # Calculate overlaps
    local planned_and_touched=()
    local planned_but_untouched=()
    local unplanned_files=()

    # Files that were both planned AND touched
    for pfile in "${planned_array[@]}"; do
        local found=false
        for afile in "${actual_array[@]}"; do
            if [[ "$pfile" == "$afile" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == "true" ]]; then
            planned_and_touched+=("$pfile")
        else
            planned_but_untouched+=("$pfile")
        fi
    done

    # Files that were touched but NOT planned
    for afile in "${actual_array[@]}"; do
        local found=false
        for pfile in "${planned_array[@]}"; do
            if [[ "$afile" == "$pfile" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            unplanned_files+=("$afile")
        fi
    done

    # Calculate scope creep score (unplanned / total, or 0 if no files changed)
    local scope_creep_score=0
    local total_files=$((${#planned_array[@]} + ${#unplanned_files[@]}))
    if [[ "$total_files" -gt 0 ]]; then
        scope_creep_score=$(echo "scale=2; ${#unplanned_files[@]} / $total_files" | bc 2>/dev/null || echo "0")
    fi

    # Build JSON report
    local report="{
  \"planned_files\": ["
    local first=true
    for file in "${planned_array[@]}"; do
        if [[ "$first" == "false" ]]; then
            report="${report},"
        fi
        report="${report}\"$(echo "$file" | sed 's/"/\\"/g')\""
        first=false
    done
    report="${report}],
  \"actual_files\": ["
    first=true
    for file in "${actual_array[@]}"; do
        if [[ "$first" == "false" ]]; then
            report="${report},"
        fi
        report="${report}\"$(echo "$file" | sed 's/"/\\"/g')\""
        first=false
    done
    report="${report}],
  \"planned_and_touched\": ["
    first=true
    for file in "${planned_and_touched[@]}"; do
        if [[ "$first" == "false" ]]; then
            report="${report},"
        fi
        report="${report}\"$(echo "$file" | sed 's/"/\\"/g')\""
        first=false
    done
    report="${report}],
  \"planned_but_untouched\": ["
    first=true
    for file in "${planned_but_untouched[@]}"; do
        if [[ "$first" == "false" ]]; then
            report="${report},"
        fi
        report="${report}\"$(echo "$file" | sed 's/"/\\"/g')\""
        first=false
    done
    report="${report}],
  \"unplanned_files\": ["
    first=true
    for file in "${unplanned_files[@]}"; do
        if [[ "$first" == "false" ]]; then
            report="${report},"
        fi
        report="${report}\"$(echo "$file" | sed 's/"/\\"/g')\""
        first=false
    done
    report="${report}],
  \"pr_stats\": $pr_stats,
  \"scope_creep_score\": $scope_creep_score
}"

    # Write report to artifacts directory
    mkdir -p "$artifacts_dir"
    echo "$report" > "$artifacts_dir/scope-report.json"
    return 0
}

# ─── Format scope report for injection into review prompt ─────────────────
# Usage: format_scope_report_for_prompt "$artifacts_dir"
format_scope_report_for_prompt() {
    local artifacts_dir="${1:-.}"
    local report_file="$artifacts_dir/scope-report.json"

    if [[ ! -f "$report_file" ]]; then
        echo "No scope report available."
        return 0
    fi

    local output="## Scope Analysis

"

    # Extract and format planned vs actual
    local planned_count
    planned_count=$(jq '.planned_files | length' "$report_file" 2>/dev/null || echo "0")
    local actual_count
    actual_count=$(jq '.actual_files | length' "$report_file" 2>/dev/null || echo "0")

    output="${output}**Planned files:** ${planned_count} | **Actual files changed:** ${actual_count}

"

    # List planned files
    output="${output}### Planned Files
"
    local planned_list
    planned_list=$(jq -r '.planned_files[]' "$report_file" 2>/dev/null || true)
    if [[ -n "$planned_list" ]]; then
        while IFS= read -r file; do
            output="${output}  - \`${file}\`
"
        done <<< "$planned_list"
    else
        output="${output}  (none specified)
"
    fi

    # List files planned but not touched
    local untouched_count
    untouched_count=$(jq '.planned_but_untouched | length' "$report_file" 2>/dev/null || echo "0")
    if [[ "$untouched_count" -gt 0 ]]; then
        output="${output}
### Planned But Untouched
"
        local untouched_list
        untouched_list=$(jq -r '.planned_but_untouched[]' "$report_file" 2>/dev/null || true)
        while IFS= read -r file; do
            output="${output}  - \`${file}\` (planned but not modified)
"
        done <<< "$untouched_list"
    fi

    # List unplanned files (scope creep)
    local unplanned_count
    unplanned_count=$(jq '.unplanned_files | length' "$report_file" 2>/dev/null || echo "0")
    if [[ "$unplanned_count" -gt 0 ]]; then
        output="${output}
### Unplanned Files (Scope Creep)
"
        local unplanned_list
        unplanned_list=$(jq -r '.unplanned_files[]' "$report_file" 2>/dev/null || true)
        while IFS= read -r file; do
            output="${output}  - \`${file}\` (not in plan — justify or flag as creep)
"
        done <<< "$unplanned_list"
    fi

    # PR stats
    output="${output}
### PR Statistics
"
    local insertions deletions files_changed
    insertions=$(jq '.pr_stats.insertions' "$report_file" 2>/dev/null || echo "0")
    deletions=$(jq '.pr_stats.deletions' "$report_file" 2>/dev/null || echo "0")
    files_changed=$(jq '.pr_stats.files_changed' "$report_file" 2>/dev/null || echo "0")

    output="${output}  - **Files changed:** ${files_changed}
  - **Insertions:** +${insertions}
  - **Deletions:** -${deletions}
  - **Net change:** +$((insertions - deletions)) lines
"

    # Scope creep score
    local creep_score
    creep_score=$(jq '.scope_creep_score' "$report_file" 2>/dev/null || echo "0")
    output="${output}
**Scope creep score:** ${creep_score} (unplanned files as % of total)
"

    echo -n "$output"
}

# ─── Check PR size against limit ─────────────────────────────────────────
# Returns 0 if under limit, 1 if over
# Usage: check_pr_size "$base_branch" "$max_lines"
check_pr_size() {
    local base_branch="${1:-origin/main}"
    local max_lines="${2:-500}"

    # Get total line changes
    local stat_output
    stat_output=$(git diff --stat "$base_branch"...HEAD 2>/dev/null || true)

    if [[ -z "$stat_output" ]]; then
        return 0
    fi

    # Extract total from last line
    local total_lines=0
    local summary
    summary=$(echo "$stat_output" | tail -1)

    # Sum insertions and deletions
    local insertions=0
    local deletions=0

    if [[ "$summary" =~ ([0-9]+)[[:space:]]+insertions?\(\+ ]]; then
        insertions="${BASH_REMATCH[1]}"
    fi

    if [[ "$summary" =~ ([0-9]+)[[:space:]]+deletions?\(\- ]]; then
        deletions="${BASH_REMATCH[1]}"
    fi

    total_lines=$((insertions + deletions))

    if [[ "$total_lines" -gt "$max_lines" ]]; then
        return 1
    fi

    return 0
}
