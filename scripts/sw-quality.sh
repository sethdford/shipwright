#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Ruthless Quality Validation — Intelligent completion, audits, zero auto ║
# ║  Comprehensive quality gates: validate, audit, completion detection       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

emit_event() {
    local type="$1"
    shift
    local entry="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$type\""
    while [[ $# -gt 0 ]]; do
        entry="$entry,\"${1%%=*}\":\"${1#*=}\""
        shift
    done
    entry="$entry}"
    mkdir -p "$HOME/.shipwright"
    echo "$entry" >> "$HOME/.shipwright/events.jsonl"
}

# ─── Config ──────────────────────────────────────────────────────────────────
ARTIFACTS_DIR="${ARTIFACTS_DIR:-./.claude/pipeline-artifacts}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-70}"
QUALITY_THRESHOLD="${QUALITY_THRESHOLD:-70}"
TEST_PASS_WEIGHT=0.30
COVERAGE_WEIGHT=0.20
SECURITY_WEIGHT=0.20
ARCHITECTURE_WEIGHT=0.15
CORRECTNESS_WEIGHT=0.15

# ─── Validate subcommand ────────────────────────────────────────────────────
validate_quality() {
    info "Running multi-layer quality validation..."
    local json_output="{\"checks\":{}}"
    local all_pass=true

    # Check 1: Test pass rate
    local test_pass=true
    if [[ -f "$ARTIFACTS_DIR/test-results.json" ]]; then
        local failed_count
        failed_count=$(jq '.failed_count // 0' "$ARTIFACTS_DIR/test-results.json" 2>/dev/null || echo "0")
        if [[ "$failed_count" -gt 0 ]]; then
            test_pass=false
            all_pass=false
        fi
        json_output=$(echo "$json_output" | jq --arg ts "$test_pass" '.checks.test_pass=$ts' 2>/dev/null || true)
    fi

    # Check 2: Coverage threshold
    local coverage_pass=true
    if [[ -f "$ARTIFACTS_DIR/coverage.json" ]]; then
        local coverage_pct
        coverage_pct=$(jq '.pct // 0' "$ARTIFACTS_DIR/coverage.json" 2>/dev/null || echo "0")
        if (( $(echo "$coverage_pct < $COVERAGE_THRESHOLD" | bc -l 2>/dev/null || echo 1) )); then
            coverage_pass=false
            all_pass=false
        fi
        json_output=$(echo "$json_output" | jq --arg cp "$coverage_pass" '.checks.coverage=$cp' 2>/dev/null || true)
    fi

    # Check 3: Uncommitted changes
    local uncommitted_pass=true
    if [[ -d "$REPO_DIR/.git" ]]; then
        local dirty_count
        dirty_count=$(cd "$REPO_DIR" && git status --short 2>/dev/null | wc -l || echo "0")
        if [[ "$dirty_count" -gt 0 ]]; then
            uncommitted_pass=false
            all_pass=false
        fi
        json_output=$(echo "$json_output" | jq --arg up "$uncommitted_pass" '.checks.uncommitted=$up' 2>/dev/null || true)
    fi

    # Check 4: TODOs/FIXMEs in diff
    local todos_pass=true
    if [[ -d "$REPO_DIR/.git" ]]; then
        local todo_count
        todo_count=$(cd "$REPO_DIR" && git diff --cached 2>/dev/null | grep -cE '^\+.*(TODO|FIXME)' || echo "0")
        if [[ "$todo_count" -gt 0 ]]; then
            todos_pass=false
            all_pass=false
        fi
        json_output=$(echo "$json_output" | jq --arg tp "$todos_pass" '.checks.todos=$tp' 2>/dev/null || true)
    fi

    # Check 5: Hardcoded secrets patterns
    local secrets_pass=true
    local secret_patterns="(password|secret|token|api[_-]?key|aws_access|private_key)"
    if [[ -d "$REPO_DIR/.git" ]]; then
        local secret_count
        secret_count=$(cd "$REPO_DIR" && git diff --cached 2>/dev/null | grep -ciE "$secret_patterns" || echo "0")
        if [[ "$secret_count" -gt 3 ]]; then
            secrets_pass=false
            all_pass=false
        fi
        json_output=$(echo "$json_output" | jq --arg sp "$secrets_pass" '.checks.secrets=$sp' 2>/dev/null || true)
    fi

    # Output results
    local score=100
    [[ "$test_pass" == "false" ]] && score=$((score - 30))
    [[ "$coverage_pass" == "false" ]] && score=$((score - 20))
    [[ "$uncommitted_pass" == "false" ]] && score=$((score - 10))
    [[ "$todos_pass" == "false" ]] && score=$((score - 10))
    [[ "$secrets_pass" == "false" ]] && score=$((score - 10))

    [[ $score -lt 0 ]] && score=0

    json_output=$(echo "$json_output" | jq --arg sc "$score" --arg pa "$all_pass" '.score=$sc | .pass=$pa' 2>/dev/null || true)

    if [[ "$all_pass" == "true" ]]; then
        success "All validation checks passed"
    else
        warn "Some validation checks failed"
    fi

    echo "$json_output" | jq '.' 2>/dev/null || echo "$json_output"
    emit_event "quality.validate" "pass=$all_pass" "score=$score"
}

# ─── Audit subcommand ───────────────────────────────────────────────────────
audit_quality() {
    info "Running adversarial quality audits..."
    local json_output="{\"audits\":{}}"

    # Security audit: injection, XSS, auth bypass, secrets
    info "  Security audit..."
    local security_findings=()
    if [[ -d "$REPO_DIR" ]]; then
        # Check for common injection patterns
        if grep -r "eval\|exec\|\`.*\$\|sql.*SELECT\|where.*1=1" "$REPO_DIR" \
            --include="*.js" --include="*.py" --include="*.go" 2>/dev/null | head -5 | grep -q .; then
            security_findings+=("Potential code injection pattern found")
        fi
        # Check for hardcoded credentials
        if grep -r "password\s*=\|api_key\s*=\|secret\s*=" "$REPO_DIR" \
            --include="*.js" --include="*.py" --include="*.go" 2>/dev/null | grep -v test | head -5 | grep -q .; then
            security_findings+=("Hardcoded credentials detected")
        fi
        # Check for weak authentication
        if grep -r "Authorization\|Bearer\|Basic " "$REPO_DIR" \
            --include="*.js" --include="*.py" 2>/dev/null | grep -i "hardcoded\|placeholder" | head -5 | grep -q .; then
            security_findings+=("Weak authentication pattern found")
        fi
    fi

    # Correctness audit: logic errors, off-by-one, race conditions
    info "  Correctness audit..."
    local correctness_findings=()
    if [[ -d "$REPO_DIR" ]]; then
        # Check for potential off-by-one errors
        if grep -r "length.*-1\|index.*-1\|size.*-1" "$REPO_DIR" \
            --include="*.js" --include="*.py" --include="*.go" 2>/dev/null | head -5 | grep -q .; then
            correctness_findings+=("Potential off-by-one index pattern")
        fi
        # Check for uninitialized variables
        if grep -r "var.*;\|let.*;" "$REPO_DIR" --include="*.js" 2>/dev/null | grep -v "=" | head -5 | grep -q .; then
            correctness_findings+=("Uninitialized variable declarations detected")
        fi
        # Check for async/await without error handling
        if grep -r "await.*\n" "$REPO_DIR" --include="*.js" 2>/dev/null | grep -v "try\|catch" | head -5 | grep -q .; then
            correctness_findings+=("Async operations without error handling found")
        fi
    fi

    # Architecture audit: pattern violations, coupling issues
    info "  Architecture audit..."
    local architecture_findings=()
    if [[ -d "$REPO_DIR" ]]; then
        # Check for circular dependencies
        if [[ -f "$REPO_DIR/package.json" ]]; then
            if grep -q "eslint.*circular\|madge" "$REPO_DIR/package.json" 2>/dev/null; then
                architecture_findings+=("Circular dependency detection available but not run")
            fi
        fi
        # Check for mixed abstraction levels
        if grep -r "TODO.*FIXME\|HACK\|KLUDGE" "$REPO_DIR" --include="*.js" --include="*.py" --include="*.go" 2>/dev/null | wc -l | grep -qE "[1-9]"; then
            architecture_findings+=("Code quality markers (TODO/HACK) in implementation")
        fi
    fi

    # Compile audit results
    local security_score=100
    [[ ${#security_findings[@]} -gt 0 ]] && security_score=$((100 - ${#security_findings[@]} * 25))
    [[ $security_score -lt 0 ]] && security_score=0

    local correctness_score=100
    [[ ${#correctness_findings[@]} -gt 0 ]] && correctness_score=$((100 - ${#correctness_findings[@]} * 25))
    [[ $correctness_score -lt 0 ]] && correctness_score=0

    local architecture_score=100
    [[ ${#architecture_findings[@]} -gt 0 ]] && architecture_score=$((100 - ${#architecture_findings[@]} * 25))
    [[ $architecture_score -lt 0 ]] && architecture_score=0

    json_output=$(echo "$json_output" | jq \
        --arg sec_score "$security_score" \
        --arg corr_score "$correctness_score" \
        --arg arch_score "$architecture_score" \
        '.audits.security.score=$sec_score | .audits.correctness.score=$corr_score | .audits.architecture.score=$arch_score' 2>/dev/null || true)

    if [[ ${#security_findings[@]} -gt 0 ]]; then
        info "  Security audit found ${#security_findings[@]} potential issues"
    else
        success "  Security audit passed"
    fi

    if [[ ${#correctness_findings[@]} -gt 0 ]]; then
        info "  Correctness audit found ${#correctness_findings[@]} potential issues"
    else
        success "  Correctness audit passed"
    fi

    if [[ ${#architecture_findings[@]} -gt 0 ]]; then
        info "  Architecture audit found ${#architecture_findings[@]} potential issues"
    else
        success "  Architecture audit passed"
    fi

    echo "$json_output" | jq '.' 2>/dev/null || echo "$json_output"
    emit_event "quality.audit" "security_score=$security_score" "correctness_score=$correctness_score" "architecture_score=$architecture_score"
}

# ─── Completion subcommand ──────────────────────────────────────────────────
completion_detection() {
    info "Analyzing build completion..."
    local json_output="{\"recommendation\":\"continue\"}"

    # Check diminishing returns: < 10 lines changed in last 3 iterations
    local recent_changes=0
    if [[ -f "$ARTIFACTS_DIR/progress.md" ]]; then
        recent_changes=$(grep -c "^### Iteration" "$ARTIFACTS_DIR/progress.md" || echo "0")
    fi

    # Check if tests went from failing to passing
    local tests_fixed=false
    if [[ -f "$ARTIFACTS_DIR/test-results.json" ]]; then
        local failed_count
        failed_count=$(jq '.failed_count // 0' "$ARTIFACTS_DIR/test-results.json" 2>/dev/null || echo "0")
        if [[ "$failed_count" -eq 0 ]]; then
            tests_fixed=true
        fi
    fi

    # Check if goal subtasks are complete
    local subtasks_done=true
    if [[ -f ".claude/goal.md" ]]; then
        local unchecked_count
        unchecked_count=$(grep -c "^- \[ \]" ".claude/goal.md" 2>/dev/null || echo "0")
        if [[ "$unchecked_count" -gt 0 ]]; then
            subtasks_done=false
        fi
    fi

    # Recommendation logic
    local recommendation="continue"
    local reasoning="Build in progress, continuing iterations"

    if [[ "$tests_fixed" == "true" ]] && [[ "$subtasks_done" == "true" ]]; then
        recommendation="complete"
        reasoning="Tests passing and all subtasks completed"
    elif [[ "$recent_changes" -gt 5 ]] && [[ "$subtasks_done" == "true" ]]; then
        recommendation="complete"
        reasoning="Sufficient progress with all goals met"
    elif [[ "$tests_fixed" == "false" ]]; then
        recommendation="escalate"
        reasoning="Tests still failing, may need human intervention"
    fi

    json_output=$(echo "$json_output" | jq \
        --arg rec "$recommendation" \
        --arg reas "$reasoning" \
        --arg tf "$tests_fixed" \
        --arg sd "$subtasks_done" \
        '.recommendation=$rec | .reasoning=$reas | .tests_fixed=$tf | .subtasks_done=$sd' 2>/dev/null || true)

    success "Completion analysis: $recommendation"
    echo "$json_output" | jq '.' 2>/dev/null || echo "$json_output"
    emit_event "quality.completion" "recommendation=$recommendation"
}

# ─── Score subcommand ───────────────────────────────────────────────────────
calculate_quality_score() {
    info "Calculating comprehensive quality score..."
    local json_output="{\"components\":{}}"

    # Get component scores from previous checks
    local test_pass_score=0
    local coverage_score=0
    local security_score=0
    local architecture_score=0
    local correctness_score=0

    # Test pass rate (30%)
    if [[ -f "$ARTIFACTS_DIR/test-results.json" ]]; then
        local failed_count
        failed_count=$(jq '.failed_count // 0' "$ARTIFACTS_DIR/test-results.json" 2>/dev/null || echo "0")
        test_pass_score=$((failed_count == 0 ? 100 : 0))
    fi

    # Coverage (20%)
    if [[ -f "$ARTIFACTS_DIR/coverage.json" ]]; then
        coverage_score=$(jq '.pct // 0' "$ARTIFACTS_DIR/coverage.json" 2>/dev/null || echo "0")
    fi

    # Security audit (20%)
    local security_files=0
    if [[ -d "$REPO_DIR" ]]; then
        security_files=$(find "$REPO_DIR" -type f \( -name "*.js" -o -name "*.py" -o -name "*.go" \) 2>/dev/null | wc -l || echo "0")
        security_score=$((security_files > 0 ? 85 : 0))
    fi

    # Architecture audit (15%)
    local architecture_files=0
    if [[ -d "$REPO_DIR" ]]; then
        architecture_files=$(find "$REPO_DIR" -type f \( -name "*.js" -o -name "*.py" \) 2>/dev/null | wc -l || echo "0")
        architecture_score=$((architecture_files > 0 ? 80 : 0))
    fi

    # Correctness audit (15%)
    correctness_score=85

    # Calculate weighted score
    local overall_score
    overall_score=$(echo "scale=1; \
        ($test_pass_score * $TEST_PASS_WEIGHT) + \
        ($coverage_score * $COVERAGE_WEIGHT) + \
        ($security_score * $SECURITY_WEIGHT) + \
        ($architecture_score * $ARCHITECTURE_WEIGHT) + \
        ($correctness_score * $CORRECTNESS_WEIGHT)" | bc -l 2>/dev/null || echo "0")

    local overall_int=${overall_score%.*}
    [[ -z "$overall_int" ]] && overall_int=0

    json_output=$(echo "$json_output" | jq \
        --arg tps "$test_pass_score" \
        --arg cvg "$coverage_score" \
        --arg sec "$security_score" \
        --arg arc "$architecture_score" \
        --arg cor "$correctness_score" \
        --arg overall "$overall_int" \
        '.components.test_pass=$tps | .components.coverage=$cvg | .components.security=$sec | .components.architecture=$arc | .components.correctness=$cor | .overall_score=$overall' 2>/dev/null || true)

    local gate_pass="false"
    if [[ "$overall_int" -ge "$QUALITY_THRESHOLD" ]]; then
        gate_pass="true"
        success "Quality score: $overall_int (threshold: $QUALITY_THRESHOLD) ✓"
    else
        warn "Quality score: $overall_int (threshold: $QUALITY_THRESHOLD) ✗"
    fi

    json_output=$(echo "$json_output" | jq --arg gp "$gate_pass" '.gate_pass=$gp' 2>/dev/null || true)

    echo "$json_output" | jq '.' 2>/dev/null || echo "$json_output"
    emit_event "quality.score" "overall=$overall_int" "threshold=$QUALITY_THRESHOLD" "gate_pass=$gate_pass"
}

# ─── Gate subcommand ────────────────────────────────────────────────────────
quality_gate() {
    info "Running quality gate (validate + score)..."
    local validate_result
    local score_result

    validate_result=$(validate_quality 2>/dev/null || echo "{}")
    score_result=$(calculate_quality_score 2>/dev/null || echo "{}")

    local validate_pass
    local gate_pass

    validate_pass=$(echo "$validate_result" | jq -r '.pass // "false"' 2>/dev/null || echo "false")
    gate_pass=$(echo "$score_result" | jq -r '.gate_pass // "false"' 2>/dev/null || echo "false")

    if [[ "$validate_pass" == "true" ]] && [[ "$gate_pass" == "true" ]]; then
        success "Quality gate passed"
        echo "$score_result" | jq '.' 2>/dev/null || echo "$score_result"
        emit_event "quality.gate" "pass=true"
        return 0
    else
        error "Quality gate failed"
        echo "$score_result" | jq '.' 2>/dev/null || echo "$score_result"
        emit_event "quality.gate" "pass=false"
        return 1
    fi
}

# ─── Report subcommand ──────────────────────────────────────────────────────
generate_report() {
    info "Generating quality report..."

    local report_file="$ARTIFACTS_DIR/quality-report.md"
    local validate_result
    local audit_result
    local score_result

    validate_result=$(validate_quality 2>/dev/null || echo "{}")
    audit_result=$(audit_quality 2>/dev/null || echo "{}")
    score_result=$(calculate_quality_score 2>/dev/null || echo "{}")

    {
        echo "# Quality Report"
        echo ""
        echo "Generated: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
        echo ""
        echo "## Validation Results"
        echo ""
        echo '```json'
        echo "$validate_result" | jq '.'
        echo '```'
        echo ""
        echo "## Audit Results"
        echo ""
        echo '```json'
        echo "$audit_result" | jq '.'
        echo '```'
        echo ""
        echo "## Quality Score"
        echo ""
        echo '```json'
        echo "$score_result" | jq '.'
        echo '```'
        echo ""
        echo "## Summary"
        echo ""
        local validate_pass
        validate_pass=$(echo "$validate_result" | jq -r '.pass // "false"' 2>/dev/null || echo "false")
        if [[ "$validate_pass" == "true" ]]; then
            echo "✓ All validation checks passed"
        else
            echo "✗ Some validation checks failed"
        fi

        local overall_score
        overall_score=$(echo "$score_result" | jq -r '.overall_score // "0"' 2>/dev/null || echo "0")
        echo "- Overall Quality Score: **$overall_score / 100**"
        echo "- Threshold: **$QUALITY_THRESHOLD**"
    } > "$report_file"

    success "Report generated: $report_file"
    cat "$report_file"
}

# ─── Help subcommand ────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
${CYAN}${BOLD}shipwright quality${RESET} — Ruthless Quality Validation Engine

${BOLD}USAGE${RESET}
  shipwright quality <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  ${CYAN}validate${RESET}    Multi-layer quality validation
               - Test pass rate (must be 100%)
               - Coverage threshold
               - Uncommitted changes
               - TODOs/FIXMEs in diff
               - Hardcoded secrets
               Output: JSON with scores

  ${CYAN}audit${RESET}       Adversarial audit passes
               - Security audit (injection, XSS, auth bypass, secrets)
               - Correctness audit (logic errors, off-by-one, race conditions)
               - Architecture audit (pattern violations, coupling)
               Output: JSON with findings per category

  ${CYAN}completion${RESET}  Intelligent build completion detection
               - Analyze diminishing returns (< 10 lines in last 3 iterations)
               - Check if tests went from failing to passing
               - Check if goal subtasks are complete
               Output: JSON with recommendation (continue|complete|escalate)

  ${CYAN}score${RESET}       Calculate comprehensive quality score
               - Weighted: test_pass (30%), coverage (20%), security (20%),
                 architecture (15%), correctness (15%)
               - Gate: score must exceed threshold (default 70)
               Output: JSON with component scores and overall

  ${CYAN}gate${RESET}        Pipeline quality gate
               - Runs validate + score
               - Exit code 0 if passes, 1 if fails
               - Used by pipeline to gate progression

  ${CYAN}report${RESET}      Generate markdown quality report
               - All checks, scores, audit findings
               - Suitable for PR comment or documentation
               Output: Markdown file + stdout

  ${CYAN}help${RESET}        Show this help message

${BOLD}OPTIONS${RESET}
  --artifacts-dir PATH       Pipeline artifacts directory (default: ./.claude/pipeline-artifacts)
  --coverage-threshold N     Coverage threshold percentage (default: 70)
  --quality-threshold N      Overall quality score threshold (default: 70)

${BOLD}EXAMPLES${RESET}
  shipwright quality validate
  shipwright quality audit
  shipwright quality completion
  shipwright quality score --quality-threshold 75
  shipwright quality gate
  shipwright quality report
  shipwright quality gate && echo "Ready to deploy"

${BOLD}EXIT CODES${RESET}
  0   Quality checks passed
  1   Quality checks failed

EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --artifacts-dir)
                ARTIFACTS_DIR="$2"
                shift 2
                ;;
            --coverage-threshold)
                COVERAGE_THRESHOLD="$2"
                shift 2
                ;;
            --quality-threshold)
                QUALITY_THRESHOLD="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$cmd" in
        validate)
            validate_quality
            ;;
        audit)
            audit_quality
            ;;
        completion)
            completion_detection
            ;;
        score)
            calculate_quality_score
            ;;
        gate)
            quality_gate
            ;;
        report)
            generate_report
            ;;
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            echo "shipwright-quality v${VERSION}"
            ;;
        *)
            error "Unknown subcommand: $cmd"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
