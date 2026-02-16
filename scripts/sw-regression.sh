#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright regression — Regression Detection Pipeline                    ║
# ║  Captures metrics · Detects regressions · Tracks baselines · Reports      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Regression Storage ────────────────────────────────────────────────────
BASELINES_DIR="${HOME}/.shipwright/baselines"
LATEST_BASELINE="${BASELINES_DIR}/latest.json"
THRESHOLDS_FILE="${HOME}/.shipwright/regression-thresholds.json"

ensure_baseline_dir() {
    mkdir -p "$BASELINES_DIR"
    if [[ ! -f "$THRESHOLDS_FILE" ]]; then
        cat > "$THRESHOLDS_FILE" <<'THRESHOLDS'
{
  "test_count_decrease": true,
  "pass_rate_drop": 5.0,
  "line_count_increase": 20.0,
  "syntax_errors": true,
  "function_count_decrease": true
}
THRESHOLDS
    fi
}

# ─── Metric Collection ─────────────────────────────────────────────────────

# Collect current test count and pass rate from all test suites
collect_test_metrics() {
    local test_count=0
    local pass_count=0
    local fail_count=0

    # Check for test output files and parse them
    if [[ -f "$REPO_DIR/.claude/pipeline-artifacts/test-results.json" ]]; then
        pass_count=$(jq -r '.summary.passed // 0' "$REPO_DIR/.claude/pipeline-artifacts/test-results.json" 2>/dev/null || echo "0")
        fail_count=$(jq -r '.summary.failed // 0' "$REPO_DIR/.claude/pipeline-artifacts/test-results.json" 2>/dev/null || echo "0")
        test_count=$((pass_count + fail_count))
    fi

    # Fallback: run tests and capture output
    if [[ "$test_count" -eq 0 ]]; then
        if [[ -f "$REPO_DIR/scripts/sw-pipeline-test.sh" ]]; then
            local test_output
            test_output=$("$REPO_DIR/scripts/sw-pipeline-test.sh" 2>&1 || true)
            pass_count=$(echo "$test_output" | grep -c "^✓ " || true)
            fail_count=$(echo "$test_output" | grep -c "^✗ " || true)
            test_count=$((pass_count + fail_count))
        fi
    fi

    local pass_rate=0
    if [[ "$test_count" -gt 0 ]]; then
        pass_rate=$(awk "BEGIN { printf \"%.1f\", ($pass_count / $test_count) * 100 }")
    fi

    echo "$test_count"
    echo "$pass_count"
    echo "$fail_count"
    echo "$pass_rate"
}

# Collect script metrics: count, total lines, function count
collect_script_metrics() {
    local script_count=0
    local total_lines=0
    local function_count=0
    local syntax_errors=0

    # Count .sh files
    script_count=$(find "$REPO_DIR/scripts" -maxdepth 1 -name "*.sh" -type f 2>/dev/null | wc -l)

    # Count total lines in all scripts
    total_lines=$(find "$REPO_DIR/scripts" -maxdepth 1 -name "*.sh" -type f 2>/dev/null -exec wc -l {} + | awk '{sum+=$1} END {print sum}')

    # Count functions (grep for function definitions)
    function_count=$(find "$REPO_DIR/scripts" -maxdepth 1 -name "*.sh" -type f 2>/dev/null -exec grep -h "^[a-z_][a-z0-9_]*() {" {} + 2>/dev/null | wc -l)

    # Check for syntax errors
    while IFS= read -r script; do
        if ! bash -n "$script" 2>/dev/null; then
            ((syntax_errors++))
        fi
    done < <(find "$REPO_DIR/scripts" -maxdepth 1 -name "*.sh" -type f 2>/dev/null)

    echo "$script_count"
    echo "$total_lines"
    echo "$function_count"
    echo "$syntax_errors"
}

# Collect all current metrics into a baseline object
collect_all_metrics() {
    local test_data
    test_data=$(collect_test_metrics)
    local test_count=$(echo "$test_data" | sed -n '1p')
    local pass_count=$(echo "$test_data" | sed -n '2p')
    local fail_count=$(echo "$test_data" | sed -n '3p')
    local pass_rate=$(echo "$test_data" | sed -n '4p')

    local script_data
    script_data=$(collect_script_metrics)
    local script_count=$(echo "$script_data" | sed -n '1p')
    local total_lines=$(echo "$script_data" | sed -n '2p')
    local function_count=$(echo "$script_data" | sed -n '3p')
    local syntax_errors=$(echo "$script_data" | sed -n '4p')

    cat <<METRICS
{
  "timestamp": "$(now_iso)",
  "epoch": $(now_epoch),
  "test_count": $test_count,
  "pass_count": $pass_count,
  "fail_count": $fail_count,
  "pass_rate": $pass_rate,
  "script_count": $script_count,
  "total_lines": $total_lines,
  "function_count": $function_count,
  "syntax_errors": $syntax_errors
}
METRICS
}

# ─── Baseline Commands ────────────────────────────────────────────────────

cmd_baseline() {
    local save_flag="${1:-}"

    ensure_baseline_dir

    info "Collecting current metrics..."
    local metrics
    metrics=$(collect_all_metrics)

    local timestamp
    timestamp=$(echo "$metrics" | jq -r '.timestamp')
    local epoch
    epoch=$(echo "$metrics" | jq -r '.epoch')

    # Create timestamped baseline file
    local baseline_file
    baseline_file="${BASELINES_DIR}/baseline-$(echo "$timestamp" | sed 's/[:T-]//g' | sed 's/Z$//').json"

    local tmp_file
    tmp_file=$(mktemp "${baseline_file}.tmp.XXXXXX")

    echo "$metrics" > "$tmp_file"
    mv "$tmp_file" "$baseline_file"

    # Update latest symlink
    rm -f "$LATEST_BASELINE"
    ln -s "$(basename "$baseline_file")" "$LATEST_BASELINE"

    emit_event "regression.baseline" \
        "timestamp=${timestamp}" \
        "test_count=$(echo "$metrics" | jq -r '.test_count')" \
        "pass_rate=$(echo "$metrics" | jq -r '.pass_rate')" \
        "script_count=$(echo "$metrics" | jq -r '.script_count')" \
        "total_lines=$(echo "$metrics" | jq -r '.total_lines')"

    success "Baseline saved: $baseline_file"

    if [[ "$save_flag" == "--save" ]]; then
        success "Baseline committed as reference point"
    fi

    # Print summary
    echo ""
    echo -e "${CYAN}${BOLD}Metrics${RESET}"
    echo "  Test Count: $(echo "$metrics" | jq -r '.test_count')"
    echo "  Pass Rate:  $(echo "$metrics" | jq -r '.pass_rate')%"
    echo "  Scripts:    $(echo "$metrics" | jq -r '.script_count')"
    echo "  Lines:      $(echo "$metrics" | jq -r '.total_lines')"
    echo "  Functions:  $(echo "$metrics" | jq -r '.function_count')"
    echo "  Syntax Err: $(echo "$metrics" | jq -r '.syntax_errors')"
}

# ─── Regression Check ─────────────────────────────────────────────────────

# Compare current metrics against baseline with configured thresholds
cmd_check() {
    ensure_baseline_dir

    if [[ ! -f "$LATEST_BASELINE" ]]; then
        error "No baseline found. Run 'shipwright regression baseline' first."
        exit 1
    fi

    info "Comparing current metrics against baseline..."

    # Resolve symlink to actual file
    local baseline_file
    baseline_file="$BASELINES_DIR/$(basename "$(readlink "$LATEST_BASELINE")")"

    if [[ ! -f "$baseline_file" ]]; then
        error "Baseline file not found: $baseline_file"
        exit 1
    fi

    local baseline
    baseline=$(cat "$baseline_file")

    local current
    current=$(collect_all_metrics)

    local thresholds
    thresholds=$(cat "$THRESHOLDS_FILE")

    local regressions=0
    local improvements=0

    # Helper to compare metrics
    compare_metric() {
        local name="$1"
        local baseline_val="$2"
        local current_val="$3"
        local threshold_key="$4"
        local threshold_val="$5"
        local direction="${6:-decrease}"  # decrease or increase

        local baseline_val_num="${baseline_val//[^0-9.-]/}"
        local current_val_num="${current_val//[^0-9.-]/}"

        if [[ -z "$baseline_val_num" ]] || [[ -z "$current_val_num" ]]; then
            return
        fi

        local diff
        local pct_diff=0
        if [[ "$baseline_val_num" != "0" ]]; then
            pct_diff=$(awk "BEGIN { printf \"%.1f\", (($current_val_num - $baseline_val_num) / $baseline_val_num) * 100 }")
        fi

        if [[ "$direction" == "decrease" ]]; then
            # Metric should not decrease
            if (( $(echo "$current_val_num < $baseline_val_num" | bc -l 2>/dev/null || echo "0") )); then
                echo -e "${RED}✗ $name: $baseline_val_num → $current_val_num (${pct_diff}%)${RESET}"
                ((regressions++))
                return 1
            fi
        elif [[ "$direction" == "increase" ]]; then
            # Metric should not increase beyond threshold
            if (( $(echo "$pct_diff > $threshold_val" | bc -l 2>/dev/null || echo "0") )); then
                echo -e "${RED}✗ $name: $baseline_val_num → $current_val_num (+${pct_diff}%)${RESET}"
                ((regressions++))
                return 1
            fi
        fi

        # Improvement
        if [[ "$direction" == "decrease" ]] && (( $(echo "$current_val_num > $baseline_val_num" | bc -l 2>/dev/null || echo "0") )); then
            echo -e "${GREEN}✓ $name: $baseline_val_num → $current_val_num (improved)${RESET}"
            ((improvements++))
        elif [[ "$direction" == "increase" ]] && (( $(echo "$current_val_num < $baseline_val_num" | bc -l 2>/dev/null || echo "0") )); then
            echo -e "${GREEN}✓ $name: $baseline_val_num → $current_val_num (improved)${RESET}"
            ((improvements++))
        fi
    }

    echo ""
    info "Regression Analysis"
    echo ""

    # Test count
    local base_test_count
    base_test_count=$(echo "$baseline" | jq -r '.test_count // 0')
    local curr_test_count
    curr_test_count=$(echo "$current" | jq -r '.test_count // 0')
    compare_metric "Test Count" "$base_test_count" "$curr_test_count" "test_count_decrease" "0" "decrease"

    # Pass rate
    local base_pass_rate
    base_pass_rate=$(echo "$baseline" | jq -r '.pass_rate // 0')
    local curr_pass_rate
    curr_pass_rate=$(echo "$current" | jq -r '.pass_rate // 0')
    local pass_rate_threshold
    pass_rate_threshold=$(echo "$thresholds" | jq -r '.pass_rate_drop // 5.0')
    local pass_rate_diff
    pass_rate_diff=$(awk "BEGIN { printf \"%.1f\", ($base_pass_rate - $curr_pass_rate) }")
    if (( $(echo "$pass_rate_diff > $pass_rate_threshold" | bc -l 2>/dev/null || echo "0") )); then
        echo -e "${RED}✗ Pass Rate: $base_pass_rate% → $curr_pass_rate% (drop: ${pass_rate_diff}%)${RESET}"
        ((regressions++))
    elif (( $(echo "$curr_pass_rate > $base_pass_rate" | bc -l 2>/dev/null || echo "0") )); then
        echo -e "${GREEN}✓ Pass Rate: $base_pass_rate% → $curr_pass_rate%${RESET}"
        ((improvements++))
    else
        echo -e "${DIM}= Pass Rate: $base_pass_rate% → $curr_pass_rate%${RESET}"
    fi

    # Line count (should not increase beyond threshold)
    local base_lines
    base_lines=$(echo "$baseline" | jq -r '.total_lines // 0')
    local curr_lines
    curr_lines=$(echo "$current" | jq -r '.total_lines // 0')
    local line_threshold
    line_threshold=$(echo "$thresholds" | jq -r '.line_count_increase // 20.0')
    compare_metric "Total Lines" "$base_lines" "$curr_lines" "line_count_increase" "$line_threshold" "increase"

    # Script count
    local base_script_count
    base_script_count=$(echo "$baseline" | jq -r '.script_count // 0')
    local curr_script_count
    curr_script_count=$(echo "$current" | jq -r '.script_count // 0')
    compare_metric "Script Count" "$base_script_count" "$curr_script_count" "" "" "decrease"

    # Function count
    local base_func_count
    base_func_count=$(echo "$baseline" | jq -r '.function_count // 0')
    local curr_func_count
    curr_func_count=$(echo "$current" | jq -r '.function_count // 0')
    compare_metric "Function Count" "$base_func_count" "$curr_func_count" "" "" "decrease"

    # Syntax errors
    local base_syntax_errors
    base_syntax_errors=$(echo "$baseline" | jq -r '.syntax_errors // 0')
    local curr_syntax_errors
    curr_syntax_errors=$(echo "$current" | jq -r '.syntax_errors // 0')
    if [[ "$curr_syntax_errors" -gt "$base_syntax_errors" ]]; then
        echo -e "${RED}✗ Syntax Errors: $base_syntax_errors → $curr_syntax_errors${RESET}"
        ((regressions++))
    elif [[ "$curr_syntax_errors" -lt "$base_syntax_errors" ]]; then
        echo -e "${GREEN}✓ Syntax Errors: $base_syntax_errors → $curr_syntax_errors${RESET}"
        ((improvements++))
    else
        echo -e "${DIM}= Syntax Errors: $base_syntax_errors → $curr_syntax_errors${RESET}"
    fi

    echo ""
    if [[ "$regressions" -eq 0 ]]; then
        success "No regressions detected"
        emit_event "regression.check" "status=pass" "regressions=0" "improvements=$improvements"
        return 0
    else
        error "$regressions regression(s) detected, $improvements improvement(s)"
        emit_event "regression.check" "status=fail" "regressions=$regressions" "improvements=$improvements"
        return 1
    fi
}

# ─── Report Generation ────────────────────────────────────────────────────

cmd_report() {
    local format="${1:-text}"

    ensure_baseline_dir

    if [[ ! -f "$LATEST_BASELINE" ]]; then
        error "No baseline found. Run 'shipwright regression baseline' first."
        exit 1
    fi

    local baseline_file
    baseline_file="$BASELINES_DIR/$(basename "$(readlink "$LATEST_BASELINE")")"

    if [[ ! -f "$baseline_file" ]]; then
        error "Baseline file not found: $baseline_file"
        exit 1
    fi

    local baseline
    baseline=$(cat "$baseline_file")

    local current
    current=$(collect_all_metrics)

    case "$format" in
        json)
            jq -n \
                --argjson baseline "$baseline" \
                --argjson current "$current" \
                '{baseline: $baseline, current: $current}'
            ;;
        markdown|md)
            local baseline_ts
            baseline_ts=$(echo "$baseline" | jq -r '.timestamp')
            local current_ts
            current_ts=$(echo "$current" | jq -r '.timestamp')

            cat <<REPORT
# Regression Report

Generated: $(date)

## Baseline Information

- Timestamp: $baseline_ts
- Test Count: $(echo "$baseline" | jq -r '.test_count')
- Pass Rate: $(echo "$baseline" | jq -r '.pass_rate')%
- Scripts: $(echo "$baseline" | jq -r '.script_count')
- Total Lines: $(echo "$baseline" | jq -r '.total_lines')
- Functions: $(echo "$baseline" | jq -r '.function_count')
- Syntax Errors: $(echo "$baseline" | jq -r '.syntax_errors')

## Current Metrics

- Timestamp: $current_ts
- Test Count: $(echo "$current" | jq -r '.test_count')
- Pass Rate: $(echo "$current" | jq -r '.pass_rate')%
- Scripts: $(echo "$current" | jq -r '.script_count')
- Total Lines: $(echo "$current" | jq -r '.total_lines')
- Functions: $(echo "$current" | jq -r '.function_count')
- Syntax Errors: $(echo "$current" | jq -r '.syntax_errors')

## Deltas

| Metric | Baseline | Current | Change |
|--------|----------|---------|--------|
| Test Count | $(echo "$baseline" | jq -r '.test_count') | $(echo "$current" | jq -r '.test_count') | $(awk "BEGIN {printf \"%+d\", $(echo "$current" | jq -r '.test_count') - $(echo "$baseline" | jq -r '.test_count')}") |
| Pass Rate | $(echo "$baseline" | jq -r '.pass_rate')% | $(echo "$current" | jq -r '.pass_rate')% | $(awk "BEGIN {printf \"%+.1f%%\", $(echo "$current" | jq -r '.pass_rate') - $(echo "$baseline" | jq -r '.pass_rate')}") |
| Total Lines | $(echo "$baseline" | jq -r '.total_lines') | $(echo "$current" | jq -r '.total_lines') | $(awk "BEGIN {printf \"%+d\", $(echo "$current" | jq -r '.total_lines') - $(echo "$baseline" | jq -r '.total_lines')}") |
| Scripts | $(echo "$baseline" | jq -r '.script_count') | $(echo "$current" | jq -r '.script_count') | $(awk "BEGIN {printf \"%+d\", $(echo "$current" | jq -r '.script_count') - $(echo "$baseline" | jq -r '.script_count')}") |
| Functions | $(echo "$baseline" | jq -r '.function_count') | $(echo "$current" | jq -r '.function_count') | $(awk "BEGIN {printf \"%+d\", $(echo "$current" | jq -r '.function_count') - $(echo "$baseline" | jq -r '.function_count')}") |
| Syntax Errors | $(echo "$baseline" | jq -r '.syntax_errors') | $(echo "$current" | jq -r '.syntax_errors') | $(awk "BEGIN {printf \"%+d\", $(echo "$current" | jq -r '.syntax_errors') - $(echo "$baseline" | jq -r '.syntax_errors')}") |

REPORT
            ;;
        *)
            # Default: text format
            info "Regression Report"
            echo ""
            echo -e "${BOLD}Baseline${RESET}"
            echo "  Timestamp:     $(echo "$baseline" | jq -r '.timestamp')"
            echo "  Test Count:    $(echo "$baseline" | jq -r '.test_count')"
            echo "  Pass Rate:     $(echo "$baseline" | jq -r '.pass_rate')%"
            echo "  Scripts:       $(echo "$baseline" | jq -r '.script_count')"
            echo "  Total Lines:   $(echo "$baseline" | jq -r '.total_lines')"
            echo "  Functions:     $(echo "$baseline" | jq -r '.function_count')"
            echo "  Syntax Errors: $(echo "$baseline" | jq -r '.syntax_errors')"
            echo ""
            echo -e "${BOLD}Current${RESET}"
            echo "  Timestamp:     $(echo "$current" | jq -r '.timestamp')"
            echo "  Test Count:    $(echo "$current" | jq -r '.test_count')"
            echo "  Pass Rate:     $(echo "$current" | jq -r '.pass_rate')%"
            echo "  Scripts:       $(echo "$current" | jq -r '.script_count')"
            echo "  Total Lines:   $(echo "$current" | jq -r '.total_lines')"
            echo "  Functions:     $(echo "$current" | jq -r '.function_count')"
            echo "  Syntax Errors: $(echo "$current" | jq -r '.syntax_errors')"
            ;;
    esac
}

# ─── History Command ─────────────────────────────────────────────────────

cmd_history() {
    ensure_baseline_dir

    if [[ ! -d "$BASELINES_DIR" ]] || [[ -z "$(ls -A "$BASELINES_DIR" 2>/dev/null || true)" ]]; then
        warn "No baselines found. Run 'shipwright regression baseline' to create one."
        exit 0
    fi

    info "Baseline History (last 10)"
    echo ""

    local count=0
    while IFS= read -r baseline_file; do
        ((count++))
        if [[ "$count" -gt 10 ]]; then
            break
        fi

        local timestamp
        timestamp=$(jq -r '.timestamp' "$baseline_file" 2>/dev/null || echo "unknown")
        local test_count
        test_count=$(jq -r '.test_count // 0' "$baseline_file" 2>/dev/null || echo "0")
        local pass_rate
        pass_rate=$(jq -r '.pass_rate // 0' "$baseline_file" 2>/dev/null || echo "0")
        local lines
        lines=$(jq -r '.total_lines // 0' "$baseline_file" 2>/dev/null || echo "0")

        local marker=" "
        if [[ "$(basename "$baseline_file")" == "$(basename "$(readlink "$LATEST_BASELINE" 2>/dev/null || echo "")")" ]]; then
            marker="${GREEN}*${RESET}"
        fi

        printf "%s %-30s Tests: %3d  Pass: %5.1f%%  Lines: %6d\n" \
            "$marker" "$timestamp" "$test_count" "$pass_rate" "$lines"
    done < <(find "$BASELINES_DIR" -name "baseline-*.json" -type f | sort -rn | head -10)

    echo ""
    echo -e "${DIM}${CYAN}*${RESET}${DIM} = Latest baseline${RESET}"
}

# ─── Help Command ────────────────────────────────────────────────────────

cmd_help() {
    cat <<HELP
${CYAN}${BOLD}shipwright regression${RESET}  — Detect regressions after merge

${BOLD}USAGE${RESET}
  shipwright regression <command> [options]

${BOLD}COMMANDS${RESET}
  baseline [--save]     Capture current metrics as baseline
  check                 Compare current state against saved baseline (exit 1 if regressions)
  report [--json|--md]  Generate detailed regression report
  history               Show baseline history (last 10)
  help                  Show this help

${BOLD}METRICS TRACKED${RESET}
  • Test count (must not decrease)
  • Test suite pass rate (must not drop >5% by default)
  • Total script line count (must not increase >20% by default)
  • Script count (must not decrease)
  • Function count (must not decrease)
  • Bash syntax errors (must not increase)

${BOLD}BASELINE STORAGE${RESET}
  Baselines stored in: ~/.shipwright/baselines/
  Latest symlink:      ~/.shipwright/baselines/latest.json
  Thresholds:          ~/.shipwright/regression-thresholds.json

${BOLD}EXAMPLES${RESET}
  ${DIM}# Capture baseline after successful merge${RESET}
  shipwright regression baseline --save

  ${DIM}# Check for regressions before deploying${RESET}
  shipwright regression check

  ${DIM}# Generate a detailed report${RESET}
  shipwright regression report --markdown

  ${DIM}# View historical baselines${RESET}
  shipwright regression history

${BOLD}EXIT CODES${RESET}
  0  No regressions detected
  1  Regressions found or error

HELP
}

# ─── Main Router ────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        baseline)
            cmd_baseline "$@"
            ;;
        check)
            cmd_check "$@"
            ;;
        report)
            # Handle --json and --markdown flags
            local format="text"
            for arg in "$@"; do
                case "$arg" in
                    --json)
                        format="json"
                        ;;
                    --markdown|--md)
                        format="markdown"
                        ;;
                esac
            done
            cmd_report "$format"
            ;;
        history)
            cmd_history "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# Guard against being sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
