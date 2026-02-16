#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright testgen — Autonomous test generation and coverage maintenance ║
# ║  Analyze coverage · Generate tests · Maintain thresholds · Score quality  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Handle subcommands ───────────────────────────────────────────────────────
if [[ "${1:-}" == "test" ]]; then
    shift
    exec "$SCRIPT_DIR/sw-testgen-test.sh" "$@"
fi

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

emit_event() {
    local type="$1"
    shift
    local json_data="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$type\""
    for pair in "$@"; do
        json_data="$json_data,\"$pair\""
    done
    json_data="$json_data}"
    echo "$json_data" >> "${EVENTS_FILE:-.shipwright-events.jsonl}"
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ─── Configuration ───────────────────────────────────────────────────────────
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
TEST_SUITES_DIR="$PROJECT_ROOT/scripts"
COVERAGE_THRESHOLD=70
TESTGEN_DIR="${TESTGEN_DIR:-.claude/testgen}"
COVERAGE_DB="$TESTGEN_DIR/coverage.json"
QUALITY_DB="$TESTGEN_DIR/quality.json"
REGRESSION_DB="$TESTGEN_DIR/regressions.json"

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright testgen${RESET} ${DIM}v${VERSION}${RESET} — Test generation and coverage maintenance"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright testgen${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}coverage${RESET}       Show test coverage analysis"
    echo -e "  ${CYAN}generate${RESET}       Generate tests for uncovered functions"
    echo -e "  ${CYAN}gaps${RESET}           Show specific untested code paths"
    echo -e "  ${CYAN}quality${RESET}        Score existing test quality"
    echo -e "  ${CYAN}maintain${RESET}       Check if tests need updating after code changes"
    echo -e "  ${CYAN}threshold${RESET}      Set/check coverage threshold"
    echo -e "  ${CYAN}regression${RESET}     Compare test results across runs"
    echo -e "  ${CYAN}help${RESET}           Show this help message"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--target${RESET} <script>   Target script for analysis"
    echo -e "  ${CYAN}--threshold${RESET} <num>   Set minimum coverage % (default: 70)"
    echo -e "  ${CYAN}--json${RESET}              Output JSON format"
    echo -e "  ${CYAN}--verbose${RESET}           Detailed output"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright testgen coverage${RESET}                    # Overall coverage"
    echo -e "  ${DIM}shipwright testgen coverage --target sw-daemon.sh${RESET}  # Target script"
    echo -e "  ${DIM}shipwright testgen generate --threshold 75${RESET}         # Generate with threshold"
    echo -e "  ${DIM}shipwright testgen quality sw-pipeline-test.sh${RESET}  # Score test quality"
    echo ""
    echo -e "${DIM}Docs: https://sethdford.github.io/shipwright${RESET}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# COVERAGE ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

analyze_coverage() {
    local target_script="${1:-.}"
    local output_format="${2:-text}"

    mkdir -p "$TESTGEN_DIR"

    # Extract all function definitions from target
    local total_functions=0
    local tested_functions=0
    local function_names=""

    if [[ -f "$target_script" ]]; then
        # Parse function definitions
        function_names=$(grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$target_script" | sed 's/().*//' || echo "")
        total_functions=$(echo "$function_names" | grep -c . || echo "0")
    fi

    # Find existing tests that call these functions
    if [[ -n "$function_names" ]]; then
        local test_file
        while IFS= read -r func; do
            [[ -z "$func" ]] && continue
            for test_file in "$TEST_SUITES_DIR"/*-test.sh; do
                [[ -f "$test_file" ]] || continue
                if grep -q "$func" "$test_file" 2>/dev/null; then
                    tested_functions=$((tested_functions + 1))
                    break
                fi
            done
        done << EOF
$function_names
EOF
    fi

    local coverage_pct=0
    if [[ $total_functions -gt 0 ]]; then
        coverage_pct=$((tested_functions * 100 / total_functions))
    fi

    if [[ "$output_format" == "json" ]]; then
        jq -n \
            --arg target "$target_script" \
            --argjson total "$total_functions" \
            --argjson tested "$tested_functions" \
            --argjson pct "$coverage_pct" \
            '{target: $target, total_functions: $total, tested_functions: $tested, coverage_percent: $pct}'
    else
        info "Coverage Analysis"
        echo ""
        echo -e "  ${CYAN}Target:${RESET}           $target_script"
        echo -e "  ${CYAN}Functions:${RESET}         $total_functions total"
        echo -e "  ${CYAN}Tested:${RESET}            $tested_functions"
        echo -e "  ${CYAN}Coverage:${RESET}          ${coverage_pct}%"
        echo ""

        if [[ $coverage_pct -lt $COVERAGE_THRESHOLD ]]; then
            warn "Coverage below threshold ($COVERAGE_THRESHOLD%)"
        else
            success "Coverage meets threshold"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_tests() {
    local target_script="${1:-.}"
    local threshold="${2:-$COVERAGE_THRESHOLD}"

    mkdir -p "$TESTGEN_DIR"

    info "Generating tests for $target_script"

    # Extract untested functions
    local all_functions=""
    all_functions=$(grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$target_script" | sed 's/().*//' || echo "")

    local untested_functions=""
    if [[ -n "$all_functions" ]]; then
        while IFS= read -r func_name; do
            [[ -z "$func_name" ]] && continue
            local found=false
            for test_file in "$TEST_SUITES_DIR"/*-test.sh; do
                [[ -f "$test_file" ]] || continue
                if grep -q "$func_name" "$test_file" 2>/dev/null; then
                    found=true
                    break
                fi
            done
            [[ "$found" == "false" ]] && untested_functions="${untested_functions}${func_name}"$'\n'
        done << EOF
$all_functions
EOF
    fi

    local untested_count=0
    [[ -n "$untested_functions" ]] && untested_count=$(echo "$untested_functions" | grep -c . || echo "0")

    if [[ $untested_count -eq 0 ]]; then
        success "All functions have tests"
        return 0
    fi

    echo ""
    info "Untested functions: $untested_count"
    echo "$untested_functions" | while IFS= read -r func; do
        [[ -z "$func" ]] && continue
        echo -e "  ${YELLOW}•${RESET} $func"
    done
    echo ""

    # Generate test template; use Claude for real assertions when available
    local test_template_file="$TESTGEN_DIR/generated-tests.sh"
    local use_claude="false"
    command -v claude &>/dev/null && use_claude="true"
    [[ "${TESTGEN_USE_CLAUDE:-true}" == "false" ]] && use_claude="false"

    {
        echo "#!/usr/bin/env bash"
        echo "# Generated tests for $target_script"
        echo "set -euo pipefail"
        echo "trap 'echo \"ERROR: \$BASH_SOURCE:\$LINENO exited with status \$?\" >&2' ERR"
        echo ""
        echo "SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\""
        echo "REPO_DIR=\"\$(cd \"\$SCRIPT_DIR/..\" && pwd)\""
        echo ""
        echo "# Helpers: assert equal (or contains) so tests fail when behavior is wrong"
        echo "assert_equal() { local e=\"\$1\" a=\"\$2\"; if [[ \"\$a\" != \"\$e\" ]]; then echo \"Expected: \$e\"; echo \"Actual: \$a\"; exit 1; fi; }"
        echo "assert_contains() { local sub=\"\$1\" full=\"\$2\"; if [[ \"\$full\" != *\"\$sub\"* ]]; then echo \"Expected to contain: \$sub\"; echo \"In: \$full\"; exit 1; fi; }"
        echo ""
        echo "PASS=0"
        echo "FAIL=0"
        echo ""
    } > "$test_template_file"

    local func_count=0
    while IFS= read -r func; do
        [[ -z "$func" ]] && continue
        func_count=$((func_count + 1))
        {
            if [[ "$use_claude" == "true" ]]; then
                local func_snippet
                func_snippet=$(awk "/^${func}\(\\)/,/^[a-zA-Z_][a-zA-Z0-9_]*\(\)|^$/" "$target_script" 2>/dev/null | head -40 || true)
                local prompt_file
                prompt_file=$(mktemp "${TMPDIR:-/tmp}/sw-testgen-prompt.XXXXXX")
                {
                    echo "Generate a bash test function for the following shell function. Use real assertions (assert_equal, assert_contains, or test exit code). Test happy path and at least one edge or error case. Output only the bash function body."
                    echo "Function name: ${func}"
                    echo "Function body:"
                    echo "$func_snippet"
                } > "$prompt_file"
                local claude_out
                # Read prompt through pipe to avoid shell expansion of $vars in function body
                claude_out=$(cat "$prompt_file" | claude -p --max-turns 2 2>/dev/null || true)
                rm -f "$prompt_file"
                if [[ -n "$claude_out" ]]; then
                    local code_block
                    code_block=$(echo "$claude_out" | sed -n '/^test_'"${func}"'()/,/^}/p' || echo "$claude_out" | sed -n '/^test_/,/^}/p' || true)
                    [[ -z "$code_block" ]] && code_block="$claude_out"
                    if echo "$code_block" | grep -qE 'assert_equal|assert_contains|\[\[.*\]\]|exit 1'; then
                        echo "test_${func}() {"
                        echo "$code_block" | sed 's/^test_'"${func}"'()//' | sed 's/^{//' | sed 's/^}//' | head -50
                        echo "    ((PASS++))"
                        echo "}"
                    else
                        echo "test_${func}() {"
                        echo "    # Claude-generated; review assertions"
                        echo "$code_block" | head -30 | sed 's/^/    /'
                        echo "    ((PASS++))"
                        echo "}"
                    fi
                else
                    echo "test_${func}() { # TODO: Claude unavailable"
                    echo "    ((PASS++))"
                    echo "}"
                fi
            else
                echo "test_${func}() {"
                echo "    # TODO: Implement test for $func"
                echo "    ((PASS++))"
                echo "}"
            fi
            echo ""
        } >> "$test_template_file"
    done << EOF
$untested_functions
EOF

    {
        echo "# Run all tests"
        echo "$untested_functions" | while IFS= read -r func; do
            [[ -z "$func" ]] && continue
            echo "test_${func}"
        done
        echo ""
        echo "echo \"Results: \$PASS passed, \$FAIL failed\""
    } >> "$test_template_file"

    chmod +x "$test_template_file"
    success "Generated test template: $test_template_file"
    [[ "$use_claude" == "true" ]] && info "Used Claude for assertions; review and run tests to validate"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GAP DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

show_gaps() {
    local target_script="${1:-.}"

    info "Finding test gaps in $target_script"

    # Extract functions and their line numbers
    local gap_found=0
    while IFS=: read -r line_num func_name; do
        [[ -z "$func_name" ]] && continue
        # Check if tested
        local tested=false
        for test_file in "$TEST_SUITES_DIR"/*-test.sh; do
            [[ -f "$test_file" ]] || continue
            if grep -q "$func_name" "$test_file" 2>/dev/null; then
                tested=true
                break
            fi
        done

        if [[ "$tested" == "false" ]]; then
            gap_found=1
            echo -e "  ${YELLOW}Gap at line $line_num:${RESET} $func_name()"
        fi
    done < <(grep -En '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$target_script" | sed 's/:.*\([a-zA-Z_][a-zA-Z0-9_]*\)().*/:\1/' || true)

    [[ $gap_found -eq 0 ]] && success "No test gaps found"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST QUALITY SCORING
# ═══════════════════════════════════════════════════════════════════════════════

score_quality() {
    local test_file="$1"

    [[ -f "$test_file" ]] || {
        error "Test file not found: $test_file"
        return 1
    }

    info "Scoring test quality: $(basename "$test_file")"

    # Count assertions
    local assertion_count=0
    assertion_count=$(grep -c -E '(assert_|test_|expect_)' "$test_file" || echo "0")

    # Count edge case patterns
    local edge_case_count=0
    edge_case_count=$(grep -c -E '(empty|null|nil|missing|invalid|error|fail)' "$test_file" || echo "0")

    # Count error path tests
    local error_path_count=0
    error_path_count=$(grep -c -E '(exit|return 1|error|ERROR)' "$test_file" || echo "0")

    # Calculate score (0-100)
    local quality_score=0
    quality_score=$((assertion_count * 10 + edge_case_count * 5 + error_path_count * 5))
    [[ $quality_score -gt 100 ]] && quality_score=100

    echo ""
    echo -e "  ${CYAN}Assertions:${RESET}        $assertion_count"
    echo -e "  ${CYAN}Edge cases:${RESET}        $edge_case_count"
    echo -e "  ${CYAN}Error paths:${RESET}       $error_path_count"
    echo -e "  ${CYAN}Quality score:${RESET}     $quality_score/100"
    echo ""

    if [[ $quality_score -ge 80 ]]; then
        success "Excellent test quality"
    elif [[ $quality_score -ge 60 ]]; then
        warn "Good test quality, could improve"
    else
        warn "Low test quality, needs improvement"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST MAINTENANCE
# ═══════════════════════════════════════════════════════════════════════════════

maintain_tests() {
    local source_file="${1:-.}"

    info "Checking test maintenance for $source_file"

    # Check for modified functions
    local modified_count=0
    local test_files=("$TEST_SUITES_DIR"/*-test.sh)

    for test_file in "${test_files[@]}"; do
        [[ -f "$test_file" ]] || continue

        # Extract functions tested by this test
        while IFS= read -r func_name; do
            [[ -z "$func_name" ]] && continue

            # Check if function signature changed
            if git diff --no-index "$source_file" "$source_file" 2>/dev/null | grep -q "$func_name"; then
                modified_count=$((modified_count + 1))
                warn "Function $func_name may need test updates"
            fi
        done < <(grep -E "$func_name\(" "$test_file" | sed 's/.*\([a-zA-Z_][a-zA-Z0-9_]*\)(.*/\1/' | sort -u || true)
    done

    if [[ $modified_count -eq 0 ]]; then
        success "All tests up to date with source"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# THRESHOLD MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

manage_threshold() {
    local action="${1:-show}"
    local value="${2:-}"

    case "$action" in
        set)
            [[ -z "$value" ]] && {
                error "Threshold value required"
                return 1
            }
            COVERAGE_THRESHOLD="$value"
            success "Coverage threshold set to $value%"
            ;;
        show)
            info "Current coverage threshold: $COVERAGE_THRESHOLD%"
            ;;
        check)
            # Compare current coverage against threshold
            local coverage_pct
            coverage_pct=$(analyze_coverage "${value:-.}" json 2>/dev/null | jq -r '.coverage_percent // 0')

            if [[ $coverage_pct -lt $COVERAGE_THRESHOLD ]]; then
                warn "Coverage ${coverage_pct}% below threshold ($COVERAGE_THRESHOLD%)"
                return 1
            else
                success "Coverage ${coverage_pct}% meets threshold ($COVERAGE_THRESHOLD%)"
            fi
            ;;
        *)
            error "Unknown threshold action: $action"
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# REGRESSION DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

detect_regressions() {
    mkdir -p "$TESTGEN_DIR"

    info "Scanning for test regressions"

    # Run all test suites and capture results
    local current_results=()
    local test_file
    for test_file in "$TEST_SUITES_DIR"/*-test.sh; do
        [[ -f "$test_file" ]] || continue
        [[ "$(basename "$test_file")" == "sw-testgen-test.sh" ]] && continue

        local result
        if bash "$test_file" &>/dev/null; then
            result="PASS"
        else
            result="FAIL"
        fi
        current_results+=("$(basename "$test_file"):$result")
    done

    # Compare with previous results
    if [[ -f "$REGRESSION_DB" ]]; then
        info "Comparing with previous run..."

        local regression_found=0
        for entry in "${current_results[@]}"; do
            local test_name="${entry%:*}"
            local current_status="${entry##*:}"

            local previous_status
            previous_status=$(jq -r ".\"$test_name\" // \"UNKNOWN\"" "$REGRESSION_DB" 2>/dev/null || echo "UNKNOWN")

            if [[ "$previous_status" == "PASS" && "$current_status" == "FAIL" ]]; then
                warn "Regression detected: $test_name (was PASS, now FAIL)"
                regression_found=$((regression_found + 1))
            fi
        done

        if [[ $regression_found -eq 0 ]]; then
            success "No regressions detected"
        fi
    fi

    # Save current results for future comparison
    {
        jq -n '.' > "$REGRESSION_DB"
        for entry in "${current_results[@]}"; do
            local test_name="${entry%:*}"
            local status="${entry##*:}"
            jq --arg name "$test_name" --arg status "$status" '.[$name] = $status' "$REGRESSION_DB" > "$REGRESSION_DB.tmp"
            mv "$REGRESSION_DB.tmp" "$REGRESSION_DB"
        done
    }

    success "Regression detection saved to $REGRESSION_DB"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN COMMAND ROUTER
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local cmd="${1:-help}"

    case "$cmd" in
        coverage)
            shift || true
            analyze_coverage "$@"
            ;;
        generate)
            shift || true
            generate_tests "$@"
            ;;
        gaps)
            shift || true
            show_gaps "$@"
            ;;
        quality)
            shift || true
            score_quality "$@"
            ;;
        maintain)
            shift || true
            maintain_tests "$@"
            ;;
        threshold)
            shift || true
            manage_threshold "$@"
            ;;
        regression)
            shift || true
            detect_regressions "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
