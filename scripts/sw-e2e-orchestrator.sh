#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright e2e orchestrator — Test suite registry & execution            ║
# ║  Smoke tests, integration tests, regression management, parallel exec    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="2.2.0"

# ─── Script directory resolution ────────────────────────────────────────────
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

# ─── State directories ──────────────────────────────────────────────────────
E2E_DIR="${HOME}/.shipwright/e2e"
SUITE_REGISTRY="$E2E_DIR/suite-registry.json"
FLAKY_CACHE="$E2E_DIR/flaky-cache.json"
RESULTS_LOG="$E2E_DIR/results.jsonl"
LATEST_REPORT="$E2E_DIR/latest-report.json"

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

# E2E-specific: log suite result to RESULTS_LOG (different from canonical emit_event)
_log_suite_result() {
    local event_type="$1"
    shift
    local data=""
    for pair in "$@"; do
        [[ -n "$data" ]] && data="$data "
        data="$data$pair"
    done
    local timestamp
    timestamp=$(date -u +%s)
    echo "{\"timestamp\":$timestamp,\"type\":\"$event_type\",$data}" >> "$RESULTS_LOG"
}

ensure_state_dir() {
    mkdir -p "$E2E_DIR"
}

# ─── Initialize suite registry ──────────────────────────────────────────────
init_registry() {
    ensure_state_dir
    if [[ ! -f "$SUITE_REGISTRY" ]]; then
        cat > "$SUITE_REGISTRY" <<'EOF'
{
  "suites": [
    {
      "id": "smoke",
      "name": "Smoke Tests",
      "category": "smoke",
      "description": "Quick validation (<30s): CLI routing, help text, basic commands",
      "script": "sw-e2e-smoke-test.sh",
      "features": ["cli-routing", "help-text", "basic-commands"],
      "timeout_seconds": 30,
      "enabled": true
    },
    {
      "id": "integration",
      "name": "Integration Tests",
      "category": "integration",
      "description": "Cross-component tests: pipeline→daemon, memory→pipeline, tracker→daemon",
      "script": "sw-e2e-integration-test.sh",
      "features": ["pipeline", "daemon", "memory", "tracker"],
      "timeout_seconds": 600,
      "enabled": true
    },
    {
      "id": "regression",
      "name": "Regression Suite",
      "category": "regression",
      "description": "Full regression suite: all known failures, edge cases",
      "script": "sw-daemon-test.sh",
      "features": ["daemon", "metrics", "health"],
      "timeout_seconds": 300,
      "enabled": true
    }
  ],
  "flaky_tests": [],
  "quarantine": [],
  "last_updated": 0
}
EOF
        success "Initialized suite registry at $SUITE_REGISTRY"
    fi
}

# ─── Load and validate registry ─────────────────────────────────────────────
load_registry() {
    ensure_state_dir
    if [[ ! -f "$SUITE_REGISTRY" ]]; then
        init_registry
    fi
    cat "$SUITE_REGISTRY"
}

# ─── Register a new test suite ──────────────────────────────────────────────
cmd_register() {
    local suite_id="$1"
    local suite_name="${2:-$suite_id}"
    local category="${3:-custom}"
    local features_str="${4:-}"

    ensure_state_dir

    if [[ ! -f "$SUITE_REGISTRY" ]]; then
        init_registry
    fi

    # Parse existing registry
    local registry=$(load_registry)
    local new_suite

    # Create feature array
    local features="[]"
    if [[ -n "$features_str" ]]; then
        features=$(echo "$features_str" | jq -R 'split(",") | map(select(length > 0))')
    fi

    # Build new suite entry
    new_suite=$(jq -n \
        --arg id "$suite_id" \
        --arg name "$suite_name" \
        --arg cat "$category" \
        --argjson feats "$features" \
        '{
            id: $id,
            name: $name,
            category: $cat,
            description: "",
            script: "sw-\($id)-test.sh",
            features: $feats,
            timeout_seconds: 300,
            enabled: true
        }')

    # Check if suite already exists
    if echo "$registry" | jq -e ".suites[] | select(.id == \"$suite_id\")" > /dev/null 2>&1; then
        error "Suite '$suite_id' already registered"
        return 1
    fi

    # Add to registry
    registry=$(echo "$registry" | jq ".suites += [$new_suite] | .last_updated = $(date +%s)")

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    echo "$registry" | jq '.' > "$tmp_file"
    mv "$tmp_file" "$SUITE_REGISTRY"

    success "Registered suite: $suite_id"
}

# ─── Quarantine a flaky test ───────────────────────────────────────────────
cmd_quarantine() {
    local test_name="$1"
    local reason="${2:-Intermittent failures}"
    local action="${3:-quarantine}"  # quarantine or unquarantine

    ensure_state_dir

    if [[ ! -f "$SUITE_REGISTRY" ]]; then
        init_registry
    fi

    local registry=$(load_registry)

    if [[ "$action" == "quarantine" ]]; then
        # Add to quarantine list if not already present
        if ! echo "$registry" | jq -e ".quarantine[] | select(. == \"$test_name\")" > /dev/null 2>&1; then
            registry=$(echo "$registry" | jq ".quarantine += [\"$test_name\"] | .last_updated = $(date +%s)")
            local tmp_file
            tmp_file=$(mktemp)
            echo "$registry" | jq '.' > "$tmp_file"
            mv "$tmp_file" "$SUITE_REGISTRY"
            success "Quarantined: $test_name — $reason"
        else
            warn "$test_name already quarantined"
        fi
    else
        # Remove from quarantine
        registry=$(echo "$registry" | jq ".quarantine |= map(select(. != \"$test_name\")) | .last_updated = $(date +%s)")
        local tmp_file
        tmp_file=$(mktemp)
        echo "$registry" | jq '.' > "$tmp_file"
        mv "$tmp_file" "$SUITE_REGISTRY"
        success "Unquarantined: $test_name"
    fi
}

# ─── Run a single test suite ────────────────────────────────────────────────
run_suite() {
    local suite_id="$1"
    local registry=$(load_registry)

    # Find suite
    local suite=$(echo "$registry" | jq ".suites[] | select(.id == \"$suite_id\")")

    if [[ -z "$suite" ]]; then
        error "Suite not found: $suite_id"
        return 1
    fi

    local suite_name=$(echo "$suite" | jq -r '.name')
    local script=$(echo "$suite" | jq -r '.script')
    local timeout=$(echo "$suite" | jq -r '.timeout_seconds')
    local features=$(echo "$suite" | jq -r '.features | join(", ")')

    local test_script="$SCRIPT_DIR/$script"

    if [[ ! -f "$test_script" ]]; then
        error "Test script not found: $test_script"
        return 1
    fi

    info "Running: $suite_name ($features)"
    local start_time=$(date +%s)

    # Run with timeout
    local exit_code=0
    timeout "$timeout" bash "$test_script" || exit_code=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Log result
    _log_suite_result "suite_complete" \
        "\"suite_id\":\"$suite_id\"" \
        "\"suite_name\":\"$suite_name\"" \
        "\"exit_code\":$exit_code" \
        "\"duration_seconds\":$duration"

    return $exit_code
}

# ─── Run suites in parallel ─────────────────────────────────────────────────
run_parallel() {
    local category="${1:-}"
    local max_parallel=${2:-3}

    ensure_state_dir
    > "$RESULTS_LOG"  # Clear results log

    local registry=$(load_registry)

    # Filter suites by category and enabled status
    local suites
    if [[ -n "$category" ]]; then
        suites=$(echo "$registry" | jq -r ".suites[] | select(.category == \"$category\" and .enabled) | .id")
    else
        suites=$(echo "$registry" | jq -r ".suites[] | select(.enabled) | .id")
    fi

    local suite_array=()
    while IFS= read -r suite; do
        [[ -n "$suite" ]] && suite_array+=("$suite")
    done <<< "$suites"

    if [[ ${#suite_array[@]} -eq 0 ]]; then
        warn "No suites to run"
        return 0
    fi

    info "Running ${#suite_array[@]} test suite(s) in parallel (max $max_parallel workers)"

    local pids=()
    local running=0
    local idx=0
    local failed_suites=()

    # Spawn initial batch
    for (( i = 0; i < max_parallel && i < ${#suite_array[@]}; i++ )); do
        run_suite "${suite_array[$i]}" &
        pids+=($!)
        ((running++))
        ((idx++))
    done

    # Process remaining suites as workers finish
    while [[ $running -gt 0 ]]; do
        for i in "${!pids[@]}"; do
            if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                # Process finished
                wait "${pids[$i]}" || failed_suites+=("${suite_array[$((i + max_parallel - running))]}")

                # Spawn next if available
                if [[ $idx -lt ${#suite_array[@]} ]]; then
                    run_suite "${suite_array[$idx]}" &
                    pids[$i]=$!
                    ((idx++))
                else
                    unset 'pids[$i]'
                fi
                ((running--))
            fi
        done
        sleep 0.1
    done

    # Wait for all to finish
    local exit_code=0
    for pid in "${pids[@]}"; do
        wait "$pid" || exit_code=1
    done

    return $exit_code
}

# ─── Generate test report ──────────────────────────────────────────────────
cmd_report() {
    ensure_state_dir

    if [[ ! -f "$RESULTS_LOG" ]]; then
        warn "No test results found"
        return 0
    fi

    info "Generating test report..."

    local pass=0
    local fail=0
    local timeout=0
    local skip=0

    while IFS= read -r line; do
        local exit_code=$(echo "$line" | jq -r '.exit_code // 0')
        if [[ $exit_code -eq 0 ]]; then
            ((pass++))
        elif [[ $exit_code -eq 124 ]]; then
            ((timeout++))
        else
            ((fail++))
        fi
    done < "$RESULTS_LOG"

    local total=$((pass + fail + timeout + skip))

    # Create report
    local report=$(jq -n \
        --arg ts "$(date -Iseconds)" \
        --arg version "$VERSION" \
        --argjson p "$pass" \
        --argjson f "$fail" \
        --argjson t "$timeout" \
        --argjson s "$skip" \
        --argjson total "$total" \
        '{
            timestamp: $ts,
            version: $version,
            summary: {
                total: $total,
                passed: $p,
                failed: $f,
                timeout: $t,
                skipped: $s,
                pass_rate: ($p / $total * 100 | round | tostring + "%")
            },
            details: input
        }' < <(jq -s '.' "$RESULTS_LOG"))

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    echo "$report" | jq '.' > "$tmp_file"
    mv "$tmp_file" "$LATEST_REPORT"

    # Display
    echo ""
    echo -e "${CYAN}${BOLD}━━━ Test Report ━━━${RESET}"
    echo "$report" | jq '.summary'
    echo ""

    if [[ $fail -gt 0 ]]; then
        error "Tests failed: $fail/$total"
        return 1
    else
        success "All tests passed: $total/$total"
        return 0
    fi
}

# ─── Show flaky test analysis ───────────────────────────────────────────────
cmd_flaky() {
    ensure_state_dir

    if [[ ! -f "$RESULTS_LOG" ]]; then
        warn "No test history found"
        return 0
    fi

    info "Analyzing flaky tests..."

    # Group by test name, count passes/fails
    local flaky_analysis=$(jq -s 'group_by(.suite_id) | map({
        test: .[0].suite_id,
        runs: length,
        passes: (map(select(.exit_code == 0)) | length),
        failures: (map(select(.exit_code != 0)) | length)
    }) | map(select(.failures > 0 and .passes > 0))' "$RESULTS_LOG" 2>/dev/null || echo '[]')

    echo ""
    echo -e "${CYAN}${BOLD}━━━ Flaky Tests ━━━${RESET}"
    echo "$flaky_analysis" | jq '.'

    if [[ $(echo "$flaky_analysis" | jq 'length') -gt 0 ]]; then
        warn "Found intermittent failures — consider quarantine"
    else
        success "No flaky tests detected"
    fi
}

# ─── Main command routing ───────────────────────────────────────────────────
show_help() {
    cat <<EOF
${CYAN}${BOLD}shipwright e2e${RESET} — End-to-end test orchestrator

${BOLD}USAGE${RESET}
  shipwright e2e <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}run${RESET} [category]        Run all test suites (or filtered by category)
  ${CYAN}smoke${RESET}                Run quick smoke test suite
  ${CYAN}integration${RESET}          Run integration test suite
  ${CYAN}regression${RESET}           Run full regression test suite
  ${CYAN}register${RESET} <id> [...]  Register a new test suite
  ${CYAN}quarantine${RESET} <name>   Quarantine a flaky test
  ${CYAN}unquarantine${RESET} <name> Unquarantine a test
  ${CYAN}report${RESET}              Generate test result report
  ${CYAN}flaky${RESET}               Show flaky test analysis
  ${CYAN}help${RESET}                Show this help message

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright e2e run${RESET}                    # Run all suites
  ${DIM}shipwright e2e run smoke${RESET}               # Run only smoke tests
  ${DIM}shipwright e2e smoke${RESET}                   # Quick validation
  ${DIM}shipwright e2e register custom-test Custom${RESET}
  ${DIM}shipwright e2e quarantine flaky_test${RESET}
  ${DIM}shipwright e2e report${RESET}                  # Show latest results
  ${DIM}shipwright e2e flaky${RESET}                   # Analyze intermittent failures

${BOLD}ENVIRONMENT${RESET}
  State directory: $E2E_DIR
  Registry: $SUITE_REGISTRY
  Results log: $RESULTS_LOG
  Report: $LATEST_REPORT

${DIM}Version: $VERSION${RESET}
EOF
}

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    ensure_state_dir

    case "$cmd" in
        run)
            init_registry
            run_parallel "$@"
            cmd_report
            ;;
        smoke)
            init_registry
            run_suite "smoke"
            ;;
        integration)
            init_registry
            run_suite "integration"
            ;;
        regression)
            init_registry
            run_suite "regression"
            ;;
        register)
            init_registry
            cmd_register "$@"
            ;;
        quarantine)
            quarantine_test="${1:-}"
            if [[ -z "$quarantine_test" ]]; then
                error "Usage: e2e quarantine <test-name>"
                return 1
            fi
            cmd_quarantine "$quarantine_test" "$2" "quarantine"
            ;;
        unquarantine)
            test_name="${1:-}"
            if [[ -z "$test_name" ]]; then
                error "Usage: e2e unquarantine <test-name>"
                return 1
            fi
            cmd_quarantine "$test_name" "" "unquarantine"
            ;;
        report)
            cmd_report
            ;;
        flaky)
            cmd_flaky
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            return 1
            ;;
    esac
}

# Source guard: allow sourcing this script
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
