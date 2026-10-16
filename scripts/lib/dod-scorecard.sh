#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  dod-scorecard.sh — Machine-Verifiable Definition of Done Scorecard       ║
# ║                                                                             ║
# ║  Computes automated checks for PR quality:                                ║
# ║  - PR size limits (configurable, default 500 lines)                       ║
# ║  - Test count delta (new tests added)                                     ║
# ║  - Never-ship rule violations (pattern checks)                            ║
# ║  - Planned file coverage (from scope-report.json)                         ║
# ║  - Acceptance criteria (test evidence verification)                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_DOD_SCORECARD_LOADED:-}" ]] && return 0
_DOD_SCORECARD_LOADED=1

# Defaults (safe under set -u)
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
QUALITY_PROFILE="${QUALITY_PROFILE:-.claude/quality-profile.json}"

# ─── Helper: Safe JSON read ───────────────────────────────────────────────────
# Usage: json_get "$json_string" ".path.to.key" "default_value"
json_get() {
    local json="$1"
    local key="$2"
    local default="${3:-}"
    jq -r "$key // \"$default\"" <<< "$json" 2>/dev/null || echo "$default"
}

# ─── Helper: Array length (bash 3.2 compatible) ────────────────────────────────
# Usage: array_len "item1" "item2" "item3"
# Returns count of non-empty arguments
array_count_items() {
    local count=0
    for item in "$@"; do
        [[ -n "$item" ]] && count=$((count + 1))
    done
    echo "$count"
}

# ─── Check: PR Size ──────────────────────────────────────────────────────────
# Returns JSON: {"status": "pass|fail", "value": lines, "limit": limit}
check_pr_size_score() {
    local base_branch="$1"
    local limit="${2:-500}"

    local total_lines=0

    # Try git diff stat first
    if git rev-parse "$base_branch" >/dev/null 2>&1; then
        local diff_stat
        diff_stat=$(git diff --stat "$base_branch...HEAD" 2>/dev/null | tail -1 || true)
        if [[ -n "$diff_stat" ]]; then
            # Format: "N files changed, X insertions(+), Y deletions(-)"
            # Extract insertions count
            total_lines=$(echo "$diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        fi
    fi

    local status="pass"
    [[ $total_lines -gt $limit ]] && status="fail"

    jq -n \
        --arg status "$status" \
        --argjson value "$total_lines" \
        --argjson limit "$limit" \
        '{status: $status, value: $value, limit: $limit}'
}

# ─── Check: Test Count Delta ──────────────────────────────────────────────────
# Counts test function patterns (describe, it, test, func_test) in changed files
# Returns JSON: {"status": "pass|fail", "value": new_tests, "baseline": 0}
check_test_count_delta() {
    local base_branch="$1"
    local baseline="${2:-0}"

    local new_test_count=0
    # Must be initialised: when $base_branch does not resolve, the assignment
    # below is skipped entirely and the `-n` test further down would abort the
    # caller with "unbound variable" under `set -u`.
    local changed_test_files=""

    # Get test files that changed
    if git rev-parse "$base_branch" >/dev/null 2>&1; then
        changed_test_files=$(git diff --name-only "$base_branch...HEAD" 2>/dev/null | grep -E '_test\.sh$|\.test\.js$|\.test\.ts$|_spec\.js$' || true)
    fi

    # Count test patterns in changed files
    if [[ -n "$changed_test_files" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" || ! -f "$file" ]] && continue
            # Count test/describe/it/test patterns
            local count
            count=$(grep -cE '^\s*(describe|it|test|assert_pass|assert_fail)\s*\(' "$file" 2>/dev/null || echo "0")
            new_test_count=$((new_test_count + count))
        done <<< "$changed_test_files"
    fi

    local status="pass"
    [[ $new_test_count -eq 0 && $baseline -eq 0 ]] && status="pass"
    # Note: we don't fail on zero new tests — some PRs legitimately add no tests

    jq -n \
        --arg status "$status" \
        --argjson value "$new_test_count" \
        --argjson baseline "$baseline" \
        '{status: $status, value: $value, baseline: $baseline}'
}

# ─── Check: Never-Ship Violations ────────────────────────────────────────────
# Scans diff for patterns listed in quality profile's never_ship rules
# Returns JSON: {"status": "pass|fail", "violations": [{"rule": "...", "lines": [...]}]}
check_never_ship_violations() {
    local base_branch="$1"
    local quality_profile="${2:-.claude/quality-profile.json}"

    local violations="[]"
    local status="pass"

    # Load never_ship rules from profile
    if [[ -f "$quality_profile" ]]; then
        local never_ship_rules
        never_ship_rules=$(jq -r '.quality.never_ship[]? // empty' "$quality_profile" 2>/dev/null)

        if [[ -n "$never_ship_rules" ]]; then
            local diff_content
            if git rev-parse "$base_branch" >/dev/null 2>&1; then
                diff_content=$(git diff "$base_branch...HEAD" 2>/dev/null || true)
            fi

            if [[ -n "$diff_content" ]]; then
                local temp_violations="[]"
                while IFS= read -r rule; do
                    [[ -z "$rule" ]] && continue
                    # Check if rule pattern appears in diff (case-insensitive)
                    if echo "$diff_content" | grep >/dev/null -i "$rule"; then
                        # Collect lines matching the rule
                        local matching_lines
                        matching_lines=$(echo "$diff_content" | grep -in "$rule" | head -3 || true)

                        # Build violation entry
                        temp_violations=$(jq -n \
                            --arg rule "$rule" \
                            --arg lines "$matching_lines" \
                            --argjson prev "$temp_violations" \
                            '$prev + [{"rule": $rule, "lines": ($lines | split("\n") | map(select(length > 0)))}]')

                        status="fail"
                    fi
                done <<< "$never_ship_rules"
                violations="$temp_violations"
            fi
        fi
    fi

    jq -n \
        --arg status "$status" \
        --argjson violations "$violations" \
        '{status: $status, violations: $violations}'
}

# ─── Check: Planned Files Coverage ───────────────────────────────────────────
# Compares files in scope-report.json against actual changes
# Returns JSON: {"status": "pass|fail", "planned": N, "touched": N, "unplanned": N}
check_planned_files_coverage() {
    local scope_report="${1:-$ARTIFACTS_DIR/scope-report.json}"

    local planned=0 touched=0 unplanned=0 status="pass"

    if [[ -f "$scope_report" ]]; then
        planned=$(jq -r '.planned_files | length' "$scope_report" 2>/dev/null || echo "0")
        touched=$(jq -r '.planned_files | map(select(.touched == true)) | length' "$scope_report" 2>/dev/null || echo "0")
        unplanned=$(jq -r '.unplanned_files | length' "$scope_report" 2>/dev/null || echo "0")

        # Check quality profile for whether unplanned files block
        local unplanned_blocks="false"
        if [[ -f "$QUALITY_PROFILE" ]]; then
            unplanned_blocks=$(jq -r '.scope.unplanned_files_block // false' "$QUALITY_PROFILE" 2>/dev/null)
        fi

        # Status: fail if unplanned files exist and they're configured to block
        if [[ $unplanned -gt 0 && "$unplanned_blocks" == "true" ]]; then
            status="fail"
        fi
    fi

    jq -n \
        --arg status "$status" \
        --argjson planned "$planned" \
        --argjson touched "$touched" \
        --argjson unplanned "$unplanned" \
        '{status: $status, planned: $planned, touched: $touched, unplanned: $unplanned}'
}

# ─── Check: Acceptance Criteria ──────────────────────────────────────────────
# Reads acceptance-criteria.json and searches test output for evidence
# Returns JSON: [{"id": "ac-1", "status": "pass|fail", "evidence": "..."}]
check_acceptance_criteria() {
    local acceptance_file="${1:-$ARTIFACTS_DIR/acceptance-criteria.json}"
    local test_output="${2:-$ARTIFACTS_DIR/test-results.log}"

    local criteria="[]"

    if [[ -f "$acceptance_file" ]]; then
        local test_log=""
        [[ -f "$test_output" ]] && test_log=$(cat "$test_output")

        # Extract criteria from acceptance file
        local count=0
        while IFS= read -r criterion; do
            [[ -z "$criterion" ]] && continue
            count=$((count + 1))

            local id="ac-$count"
            local status="pass"
            local evidence=""

            # Extract search keywords from criterion
            # Acceptance criteria typically contain keywords to search for in test output
            local keywords
            keywords=$(echo "$criterion" | grep -oE '\b(GET|POST|PUT|DELETE|assert|should|expect|test)\b' | head -3 || true)

            if [[ -n "$test_log" && -n "$keywords" ]]; then
                # Check if any keyword appears in test output
                local found_count=0
                while IFS= read -r keyword; do
                    [[ -z "$keyword" ]] && continue
                    if echo "$test_log" | grep >/dev/null -i "$keyword"; then
                        found_count=$((found_count + 1))
                    fi
                done <<< "$keywords"

                if [[ $found_count -gt 0 ]]; then
                    evidence="Evidence found: keyword(s) present in test output"
                else
                    status="fail"
                    evidence="No evidence found in test output for criterion"
                fi
            elif [[ -z "$test_log" ]]; then
                evidence="No test output available for verification"
            fi

            # Build criterion entry
            criteria=$(jq -n \
                --arg id "$id" \
                --arg status "$status" \
                --arg evidence "$evidence" \
                --arg criterion "$criterion" \
                --argjson prev "$criteria" \
                '$prev + [{"id": $id, "status": $status, "evidence": $evidence, "criterion": $criterion}]')
        done < <(jq -r '.acceptance_criteria[]? // empty' "$acceptance_file" 2>/dev/null | while read -r line; do echo "$line"; done)
    fi

    echo "$criteria"
}

# ─── Compute: Overall DoD Scorecard ──────────────────────────────────────────
# Runs all checks and produces dod-scorecard.json
# Usage: compute_dod_scorecard "$base_branch" "$artifacts_dir" "$quality_profile"
compute_dod_scorecard() {
    local base_branch="${1:-main}"
    local artifacts_dir="${2:-.claude/pipeline-artifacts}"
    local quality_profile="${3:-.claude/quality-profile.json}"

    # Ensure artifacts directory exists
    mkdir -p "$artifacts_dir"

    # Run all checks
    local pr_size_check acceptance_criteria_list
    local never_ship_check planned_files_check test_delta_check

    pr_size_check=$(check_pr_size_score "$base_branch" "$(jq -r '.quality.max_pr_lines // 500' "$quality_profile" 2>/dev/null || echo 500)")
    test_delta_check=$(check_test_count_delta "$base_branch" "0")
    never_ship_check=$(check_never_ship_violations "$base_branch" "$quality_profile")
    planned_files_check=$(check_planned_files_coverage "$artifacts_dir/scope-report.json")
    acceptance_criteria_list=$(check_acceptance_criteria "$artifacts_dir/acceptance-criteria.json" "$artifacts_dir/test-results.log")

    # Determine overall status and blocking failures
    local overall_status="pass"
    local blocking_failures="[]"

    # Extract status from checks
    local pr_size_status test_status never_status planned_status
    pr_size_status=$(echo "$pr_size_check" | jq -r '.status')
    test_status=$(echo "$test_delta_check" | jq -r '.status')
    never_status=$(echo "$never_ship_check" | jq -r '.status')
    planned_status=$(echo "$planned_files_check" | jq -r '.status')

    [[ "$pr_size_status" == "fail" ]] && overall_status="fail"
    [[ "$never_status" == "fail" ]] && overall_status="fail"

    # Check acceptance criteria for failures
    local ac_failures=0
    ac_failures=$(echo "$acceptance_criteria_list" | jq '[.[] | select(.status == "fail")] | length' 2>/dev/null || echo "0")
    [[ $ac_failures -gt 0 ]] && overall_status="fail"

    # Build blocking_failures array
    if [[ "$pr_size_status" == "fail" ]]; then
        blocking_failures=$(jq -n --argjson prev "$blocking_failures" '$prev + ["pr_size"]')
    fi
    if [[ "$never_status" == "fail" ]]; then
        blocking_failures=$(jq -n --argjson prev "$blocking_failures" '$prev + ["never_ship"]')
    fi
    if [[ $ac_failures -gt 0 ]]; then
        blocking_failures=$(jq -n --argjson prev "$blocking_failures" '$prev + ["acceptance_criteria"]')
    fi

    # Build complete scorecard JSON
    local scorecard_json
    scorecard_json=$(jq -n \
        --argjson pr_size "$pr_size_check" \
        --argjson test_count_delta "$test_delta_check" \
        --argjson never_ship_violations "$never_ship_check" \
        --argjson planned_files_coverage "$planned_files_check" \
        --argjson acceptance_criteria "$acceptance_criteria_list" \
        --arg overall "$overall_status" \
        --argjson blocking_failures "$blocking_failures" \
        --arg computed_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        '{
            scorecard: {
                pr_size: $pr_size,
                test_count_delta: $test_count_delta,
                never_ship_violations: $never_ship_violations,
                planned_files_coverage: $planned_files_coverage,
                acceptance_criteria: $acceptance_criteria
            },
            overall: $overall,
            blocking_failures: $blocking_failures,
            computed_at: $computed_at
        }')

    # Write to file
    echo "$scorecard_json" > "$artifacts_dir/dod-scorecard.json"
    echo "$scorecard_json"
}

# ─── Format: Scorecard for Display ────────────────────────────────────────────
# Returns human-readable markdown format of the scorecard
format_scorecard() {
    local scorecard_json="$1"

    local output="# Definition of Done Scorecard\n\n"

    # PR Size check
    local pr_size_status pr_size_value pr_size_limit
    pr_size_status=$(echo "$scorecard_json" | jq -r '.scorecard.pr_size.status')
    pr_size_value=$(echo "$scorecard_json" | jq -r '.scorecard.pr_size.value')
    pr_size_limit=$(echo "$scorecard_json" | jq -r '.scorecard.pr_size.limit')

    local pr_size_emoji="✓"
    [[ "$pr_size_status" == "fail" ]] && pr_size_emoji="✗"
    local pr_size_status_upper
    pr_size_status_upper=$(echo "$pr_size_status" | tr a-z A-Z)
    output+="## PR Size\n$pr_size_emoji $pr_size_status_upper: ${pr_size_value} lines (max: ${pr_size_limit})\n\n"

    # Test Count Delta
    local test_status test_value test_baseline
    test_status=$(echo "$scorecard_json" | jq -r '.scorecard.test_count_delta.status')
    test_value=$(echo "$scorecard_json" | jq -r '.scorecard.test_count_delta.value')
    test_baseline=$(echo "$scorecard_json" | jq -r '.scorecard.test_count_delta.baseline')

    local test_emoji="✓"
    [[ "$test_status" == "fail" ]] && test_emoji="✗"
    local test_status_upper
    test_status_upper=$(echo "$test_status" | tr a-z A-Z)
    output+="## Test Coverage\n$test_emoji $test_status_upper: ${test_value} new tests (baseline: ${test_baseline})\n\n"

    # Never-Ship Violations
    local never_status never_violations_count
    never_status=$(echo "$scorecard_json" | jq -r '.scorecard.never_ship_violations.status')
    never_violations_count=$(echo "$scorecard_json" | jq -r '.scorecard.never_ship_violations.violations | length')

    local never_emoji="✓"
    [[ "$never_status" == "fail" ]] && never_emoji="✗"
    local never_status_upper
    never_status_upper=$(echo "$never_status" | tr a-z A-Z)
    output+="## Never-Ship Rules\n$never_emoji $never_status_upper: ${never_violations_count} violation(s)\n"

    if [[ $never_violations_count -gt 0 ]]; then
        output+="$(echo "$scorecard_json" | jq -r '.scorecard.never_ship_violations.violations[] | "  - \(.rule)"' | head -5)\n\n"
    else
        output+="\n"
    fi

    # Planned Files Coverage
    local planned_status planned_count touched_count unplanned_count
    planned_status=$(echo "$scorecard_json" | jq -r '.scorecard.planned_files_coverage.status')
    planned_count=$(echo "$scorecard_json" | jq -r '.scorecard.planned_files_coverage.planned')
    touched_count=$(echo "$scorecard_json" | jq -r '.scorecard.planned_files_coverage.touched')
    unplanned_count=$(echo "$scorecard_json" | jq -r '.scorecard.planned_files_coverage.unplanned')

    local planned_emoji="✓"
    [[ "$planned_status" == "fail" ]] && planned_emoji="✗"
    local planned_status_upper
    planned_status_upper=$(echo "$planned_status" | tr a-z A-Z)
    output+="## Scope Coverage\n$planned_emoji $planned_status_upper: ${touched_count}/${planned_count} planned files touched, ${unplanned_count} unplanned\n\n"

    # Acceptance Criteria
    local ac_count ac_passed ac_failed
    ac_count=$(echo "$scorecard_json" | jq '.scorecard.acceptance_criteria | length')
    ac_passed=$(echo "$scorecard_json" | jq '[.scorecard.acceptance_criteria[] | select(.status == "pass")] | length')
    ac_failed=$((ac_count - ac_passed))

    output+="## Acceptance Criteria\n✓ ${ac_passed}/${ac_count} passed"
    if [[ $ac_failed -gt 0 ]]; then
        output+=" (${ac_failed} failed)\n"
    else
        output+="\n"
    fi
    output+="\n"

    # Overall status
    local overall_status overall_emoji
    overall_status=$(echo "$scorecard_json" | jq -r '.overall')
    [[ "$overall_status" == "pass" ]] && overall_emoji="✓" || overall_emoji="✗"
    local overall_status_upper
    overall_status_upper=$(echo "$overall_status" | tr a-z A-Z)

    output+="## Overall Result\n${overall_emoji} **${overall_status_upper}**\n"

    echo -e "$output"
}

# ─── Gate: Scorecard Pass/Fail ───────────────────────────────────────────────
# Returns 0 if overall == pass, 1 if overall == fail
scorecard_passed() {
    local scorecard_json="$1"
    local overall_status
    overall_status=$(echo "$scorecard_json" | jq -r '.overall // "fail"')

    if [[ "$overall_status" == "pass" ]]; then
        return 0
    else
        return 1
    fi
}

# ─── Blocking Failures Extractor ────────────────────────────────────────────
# Returns list of blocking failure categories
get_blocking_failures() {
    local scorecard_json="$1"
    echo "$scorecard_json" | jq -r '.blocking_failures[]? // empty'
}
