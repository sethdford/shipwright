#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  test-optimizer — Test execution optimization: parallel, affected-first,  ║
# ║                   fast-fail, with historical data and learning           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Functions:
#   testopt_init                  Initialize test discovery and history loading
#   testopt_select_affected       Select tests affected by changed files
#   testopt_prioritize            Order tests by likelihood to fail
#   testopt_run_with_fast_fail    Execute with stop-on-first-fail
#   testopt_run_parallel          Execute independent tests in parallel
#   testopt_record_history        Record results for learning
#   testopt_report                Print optimization stats
#
# Usage:
#   source scripts/lib/test-optimizer.sh
#   testopt_init <project_root>
#   testopt_record_history "test_file" "pass/fail" "duration" "changed_files"
#   testopt_report
#
set -euo pipefail

# Module guard
[[ -n "${_TEST_OPTIMIZER_LOADED:-}" ]] && return 0; _TEST_OPTIMIZER_LOADED=1

# ─── Defaults ──────────────────────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# State: discovered test files, historical data, changed files
declare -a DISCOVERED_TESTS=()
declare -a AFFECTED_TESTS=()
declare -a TEST_HISTORY=()
declare -a CHANGED_FILES=()

TESTOPT_HISTORY_FILE="${HOME}/.shipwright/optimization/test-history.jsonl"
TESTOPT_PROJECT_ROOT=""
TESTOPT_STATS_TESTS_RUN=0
TESTOPT_STATS_TESTS_SKIPPED=0
TESTOPT_STATS_TIME_SAVED=0
TESTOPT_STATS_FAIL_EARLY="false"

# Ensure helpers
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ─── Test Discovery ────────────────────────────────────────────────────────

# Discover all test files in a project
# testopt_discover_tests <project_root>
testopt_discover_tests() {
    local project_root="${1:-.}"
    [[ ! -d "$project_root" ]] && { error "Project root not found: $project_root"; return 1; }

    DISCOVERED_TESTS=()

    # Pattern 1: *-test.sh
    while IFS= read -r test_file; do
        [[ -f "$test_file" ]] && DISCOVERED_TESTS+=("$test_file")
    done < <(find "$project_root" -name "*-test.sh" -type f 2>/dev/null || true)

    # Pattern 2: *_test.sh
    while IFS= read -r test_file; do
        [[ -f "$test_file" ]] && DISCOVERED_TESTS+=("$test_file")
    done < <(find "$project_root" -name "*_test.sh" -type f 2>/dev/null || true)

    # Pattern 3: test_*.sh
    while IFS= read -r test_file; do
        [[ -f "$test_file" ]] && DISCOVERED_TESTS+=("$test_file")
    done < <(find "$project_root" -name "test_*.sh" -type f 2>/dev/null || true)

    # Deduplicate
    local IFS=$'\n'
    DISCOVERED_TESTS=($(sort -u <<<"${DISCOVERED_TESTS[*]}" 2>/dev/null || true))
}

# ─── History Loading ──────────────────────────────────────────────────────

# Load historical test data
testopt_load_history() {
    TEST_HISTORY=()
    if [[ ! -f "$TESTOPT_HISTORY_FILE" ]]; then
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        TEST_HISTORY+=("$line")
    done < "$TESTOPT_HISTORY_FILE"
}

# Query history for a test file: returns duration, or 0 if not found
testopt_get_historical_duration() {
    local test_file="$1"
    for entry in "${TEST_HISTORY[@]:-}"; do
        local file
        file=$(echo "$entry" | jq -r '.test_file // empty' 2>/dev/null || true)
        if [[ "$file" == "$test_file" ]]; then
            echo "$entry" | jq -r '.duration_s // 0' 2>/dev/null || echo 0
            return 0
        fi
    done
    echo 0
}

# Query history for fail rate (0.0-1.0)
testopt_get_fail_rate() {
    local test_file="$1"
    local pass_count=0
    local fail_count=0

    for entry in "${TEST_HISTORY[@]:-}"; do
        local file result
        file=$(echo "$entry" | jq -r '.test_file // empty' 2>/dev/null || true)
        result=$(echo "$entry" | jq -r '.result // empty' 2>/dev/null || true)
        if [[ "$file" == "$test_file" ]]; then
            if [[ "$result" == "pass" ]]; then
                pass_count=$((pass_count + 1))
            elif [[ "$result" == "fail" ]]; then
                fail_count=$((fail_count + 1))
            fi
        fi
    done

    local total=$((pass_count + fail_count))
    if [[ "$total" -eq 0 ]]; then
        echo "0.0"
    else
        # Return fail_count/total as float (bash approximation)
        echo "$fail_count" | awk -v total="$total" '{ printf "%.2f", $1 / total }'
    fi
}

# ─── Affected Test Selection ───────────────────────────────────────────────

# Detect which files changed between revisions
# testopt_get_changed_files [<from_ref> <to_ref>]
testopt_get_changed_files() {
    local from_ref="${1:-HEAD~1}"
    local to_ref="${2:-HEAD}"

    CHANGED_FILES=()

    # Try git diff first
    if command -v git >/dev/null 2>&1; then
        while IFS= read -r file; do
            [[ -n "$file" ]] && CHANGED_FILES+=("$file")
        done < <(git diff --name-only "$from_ref" "$to_ref" 2>/dev/null || true)
    fi
}

# Map changed files to affected test files
# Returns: test files that import/source changed files or are in same directory
testopt_select_affected() {
    # Arguments win; with none, use CHANGED_FILES from testopt_get_changed_files (the usual call).
    local -a changed_files=()
    if [[ $# -gt 0 ]]; then
        changed_files=("$@")
    elif [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
        changed_files=("${CHANGED_FILES[@]}")
    fi
    AFFECTED_TESTS=()

    if [[ ${#changed_files[@]} -eq 0 ]]; then
        # No changes detected, return all tests
        AFFECTED_TESTS=("${DISCOVERED_TESTS[@]}")
        return 0
    fi

    # Extract directories from changed files
    declare -a changed_dirs=()
    for file in "${changed_files[@]}"; do
        local dir
        dir=$(dirname "$file")
        changed_dirs+=("$dir")
    done

    # For each discovered test, check if it's affected
    for test_file in "${DISCOVERED_TESTS[@]}"; do
        local test_dir
        test_dir=$(dirname "$test_file")

        local is_affected=0

        # Check 1: Test in same directory as changed file
        for dir in "${changed_dirs[@]}"; do
            if [[ "$test_dir" == "$dir" ]]; then
                is_affected=1
                break
            fi
        done

        # Check 2: Test sources/imports changed file
        if [[ "$is_affected" -eq 0 ]]; then
            for changed_file in "${changed_files[@]}"; do
                # The test names the changed file (source, import or require): a fixed-string match on
                # its basename. No "|| true" here: it made every test count as affected.
                local changed_base
                changed_base=$(basename "$changed_file")
                if grep -qF -- "$changed_base" "$test_file" 2>/dev/null; then
                    is_affected=1
                    break
                fi
            done
        fi

        if [[ "$is_affected" -eq 1 ]]; then
            AFFECTED_TESTS+=("$test_file")
        fi
    done

    # Fallback: if no affected tests found, use all tests
    if [[ ${#AFFECTED_TESTS[@]} -eq 0 ]]; then
        AFFECTED_TESTS=("${DISCOVERED_TESTS[@]}")
    fi
}

# ─── Test Prioritization ──────────────────────────────────────────────────

# Prioritize tests by: fail rate, historical duration, then name
# Returns: space-separated test list (stdout)
testopt_prioritize() {
    local -a tests_to_sort=("$@")

    if [[ ${#tests_to_sort[@]} -eq 0 ]]; then
        tests_to_sort=("${AFFECTED_TESTS[@]}")
    fi

    # Build temp file with scoring
    local tmp_score_file
    tmp_score_file=$(mktemp)
    trap "rm -f '$tmp_score_file'" RETURN

    for test_file in "${tests_to_sort[@]}"; do
        local fail_rate duration
        fail_rate=$(testopt_get_fail_rate "$test_file")
        duration=$(testopt_get_historical_duration "$test_file")

        # Score: fail_rate (0-100) * 100 + duration (so high-fail tests run first, then fast ones)
        local fail_score
        fail_score=$(echo "$fail_rate" | awk '{ printf "%.0f", $1 * 100 }')
        local score=$((fail_score * 100 - duration))

        echo "$score $test_file" >> "$tmp_score_file"
    done

    # Sort by score descending, output just test files
    sort -rn "$tmp_score_file" 2>/dev/null | awk '{ print $2 }' || echo "${tests_to_sort[@]}"
}

# ─── Test Execution ────────────────────────────────────────────────────────

# Run tests with fast-fail: stop on first failure
# testopt_run_with_fast_fail [--continue-on-fail] <test1> [test2] ...
# Returns: 0 on all pass, 1 on first fail
testopt_run_with_fast_fail() {
    local continue_on_fail=false
    [[ "$1" == "--continue-on-fail" ]] && { continue_on_fail=true; shift; }

    local -a tests=("$@")
    [[ ${#tests[@]} -eq 0 ]] && tests=("${AFFECTED_TESTS[@]}")

    local failed_test=""
    local all_passed=true
    local tmp_results
    tmp_results=$(mktemp)
    trap "rm -f '$tmp_results'" RETURN

    info "Running ${#tests[@]} test(s) with fast-fail..."

    for test_file in "${tests[@]}"; do
        [[ ! -f "$test_file" ]] && continue

        local start_ts exit_code=0
        start_ts=$(date +%s)

        # Run the test
        bash "$test_file" > /dev/null 2>&1 || exit_code=$?

        local duration=$(($(date +%s) - start_ts))

        if [[ "$exit_code" -ne 0 ]]; then
            all_passed=false
            failed_test="$test_file"
            local result="fail"
            TESTOPT_STATS_FAIL_EARLY=true
            TESTOPT_STATS_TESTS_RUN=$((TESTOPT_STATS_TESTS_RUN + 1))

            # Record this failure
            {
                echo "{"
                echo "  \"test_file\": \"$test_file\","
                echo "  \"result\": \"$result\","
                echo "  \"duration_s\": $duration,"
                echo "  \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
                echo "}"
            } >> "$tmp_results"

            error "Test failed: $test_file (${duration}s)"
            emit_event "testopt.fail_fast" "test=$test_file" "duration=$duration"

            if [[ "$continue_on_fail" == false ]]; then
                break
            fi
        else
            TESTOPT_STATS_TESTS_RUN=$((TESTOPT_STATS_TESTS_RUN + 1))
            {
                echo "{"
                echo "  \"test_file\": \"$test_file\","
                echo "  \"result\": \"pass\","
                echo "  \"duration_s\": $duration,"
                echo "  \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
                echo "}"
            } >> "$tmp_results" 2>/dev/null || true
            success "Test passed: $test_file (${duration}s)"
        fi
    done

    # Return failed test name in stdout for caller to process
    [[ -n "$failed_test" ]] && echo "$failed_test"

    [[ "$all_passed" == "true" ]] && return 0 || return 1
}

# Run tests in parallel (grouped by directory)
# testopt_run_parallel [--max-workers=N] <test1> [test2] ...
# Returns: 0 on all pass, 1 on any fail
testopt_run_parallel() {
    local max_workers=4
    [[ "$1" == --max-workers=* ]] && { max_workers="${1#--max-workers=}"; shift; }

    local -a tests=("$@")
    [[ ${#tests[@]} -eq 0 ]] && tests=("${AFFECTED_TESTS[@]}")

    info "Running ${#tests[@]} test(s) in parallel (max ${max_workers} workers)..."

    # Group tests by directory for better cache locality
    declare -a test_groups=()
    declare -a current_group=()
    local current_dir=""

    for test_file in "${tests[@]}"; do
        local test_dir
        test_dir=$(dirname "$test_file")
        if [[ "$test_dir" != "$current_dir" ]] && [[ ${#current_group[@]} -gt 0 ]]; then
            test_groups+=("${current_group[*]}")
            current_group=()
        fi
        current_dir="$test_dir"
        current_group+=("$test_file")
    done
    [[ ${#current_group[@]} -gt 0 ]] && test_groups+=("${current_group[*]}")

    # Run groups in parallel
    local tmp_results
    tmp_results=$(mktemp)
    trap "rm -f '$tmp_results'" RETURN

    local all_passed=true
    local job_count=0

    for group in "${test_groups[@]:-}"; do
        # Wait for a worker slot
        while [[ $(jobs -r | wc -l) -ge "$max_workers" ]]; do
            sleep 0.1  # Intentional 100ms spin-wait for worker slot — too small for backoff
        done

        # Run this group in background
        {
            for test_file in $group; do
                [[ ! -f "$test_file" ]] && continue
                local start_ts exit_code=0
                start_ts=$(date +%s)
                bash "$test_file" > /dev/null 2>&1 || exit_code=$?
                local duration=$(($(date +%s) - start_ts))

                if [[ "$exit_code" -ne 0 ]]; then
                    all_passed=false
                    echo "$test_file FAIL $duration" >> "$tmp_results"
                else
                    echo "$test_file PASS $duration" >> "$tmp_results"
                fi
            done
        } &

        job_count=$((job_count + 1))
    done

    # Wait for all background jobs
    wait
    TESTOPT_STATS_TESTS_RUN=$((TESTOPT_STATS_TESTS_RUN + ${#tests[@]}))

    # Report results
    if [[ -f "$tmp_results" ]]; then
        while IFS= read -r line; do
            local test_file status duration
            test_file=$(echo "$line" | awk '{ print $1 }')
            status=$(echo "$line" | awk '{ print $2 }')
            duration=$(echo "$line" | awk '{ print $3 }')

            if [[ "$status" == "PASS" ]]; then
                success "Test passed: $test_file (${duration}s)"
            else
                error "Test failed: $test_file (${duration}s)"
            fi
        done < "$tmp_results"
    fi

    [[ "$all_passed" == true ]] && return 0 || return 1
}

# ─── History Recording ─────────────────────────────────────────────────────

# Record a test execution result for future prioritization
# testopt_record_history <test_file> <result> <duration> [changed_files...]
testopt_record_history() {
    local test_file="$1"
    local result="${2:-unknown}"  # pass or fail
    local duration="${3:-0}"
    shift 3 || true
    local changed_files=("$@")

    [[ -z "$test_file" ]] && return 1

    # Ensure history directory exists
    mkdir -p "$(dirname "$TESTOPT_HISTORY_FILE")"

    # Atomic write: temp file + move
    local tmp_history
    tmp_history=$(mktemp)
    trap "rm -f '$tmp_history'" RETURN

    # Build JSON entry (single line JSONL format)
    local changed_files_json="[]"
    if [[ ${#changed_files[@]} -gt 0 ]]; then
        changed_files_json="[$(printf '"%s",' "${changed_files[@]}" | sed 's/,$//')]"
    fi

    local json_line
    if command -v jq >/dev/null 2>&1; then
        json_line=$(jq -c -n \
            --arg test_file "$test_file" \
            --arg result "$result" \
            --argjson duration "$duration" \
            --argjson changed_files "$changed_files_json" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{test_file: $test_file, result: $result, duration_s: $duration, changed_files: $changed_files, ts: $ts}' 2>/dev/null)
    else
        json_line="{\"test_file\": \"$test_file\", \"result\": \"$result\", \"duration_s\": $duration, \"changed_files\": [], \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    fi

    echo "$json_line" >> "$tmp_history"

    # Append to history (use >> to append, not overwrite)
    cat "$tmp_history" >> "$TESTOPT_HISTORY_FILE" 2>/dev/null || true

    emit_event "testopt.recorded" "test=$test_file" "result=$result" "duration=$duration"
}

# ─── Initialization ────────────────────────────────────────────────────────

# Initialize test optimizer for a pipeline run
# testopt_init <project_root>
testopt_init() {
    local project_root="${1:-.}"
    TESTOPT_PROJECT_ROOT="$project_root"

    info "Initializing test optimizer..."

    # Discover tests
    testopt_discover_tests "$project_root"
    [[ ${#DISCOVERED_TESTS[@]} -eq 0 ]] && { warn "No test files discovered"; return 0; }
    info "Discovered ${#DISCOVERED_TESTS[@]} test file(s)"

    # Load historical data
    testopt_load_history
    [[ ${#TEST_HISTORY[@]} -eq 0 ]] && { info "No historical test data found"; } || { info "Loaded ${#TEST_HISTORY[@]} historical record(s)"; }

    # Get changed files (assume standard git workflow)
    testopt_get_changed_files "HEAD~1" "HEAD" 2>/dev/null || testopt_get_changed_files

    if [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
        info "Detected ${#CHANGED_FILES[@]} changed file(s)"
        testopt_select_affected
        info "Selected ${#AFFECTED_TESTS[@]} affected test(s)"
    else
        AFFECTED_TESTS=("${DISCOVERED_TESTS[@]}")
    fi
}

# ─── Reporting ────────────────────────────────────────────────────────────

# Print test optimization statistics
testopt_report() {
    local test_saved=0
    [[ "$TESTOPT_STATS_FAIL_EARLY" == true ]] && test_saved=$((${#DISCOVERED_TESTS[@]} - TESTOPT_STATS_TESTS_RUN))

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Execution Optimization Report"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Discovered tests:     ${#DISCOVERED_TESTS[@]}"
    echo "  Affected tests:       ${#AFFECTED_TESTS[@]}"
    echo "  Tests run:            $TESTOPT_STATS_TESTS_RUN"
    echo "  Tests skipped:        $TESTOPT_STATS_TESTS_SKIPPED"
    [[ "$TESTOPT_STATS_FAIL_EARLY" == true ]] && echo "  Fast-fail:            Yes (stopped at first failure, saved $test_saved tests)"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
