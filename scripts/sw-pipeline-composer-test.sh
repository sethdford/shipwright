#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline composer — Test Suite                              ║
# ║  Validates composition, insertion, downgrade, estimation, validation    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ───────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ───────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-composer-test.XXXXXX")
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/project/.claude/pipeline-artifacts"
    mkdir -p "$TEMP_DIR/templates/pipelines"

    # Copy script under test
    cp "$SCRIPT_DIR/sw-pipeline-composer.sh" "$TEMP_DIR/scripts/"

    # Create mock standard template (fallback)
    cat > "$TEMP_DIR/templates/pipelines/standard.json" <<'TMPL'
{
  "name": "standard",
  "description": "Standard pipeline",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "plan", "enabled": true, "gate": "approve", "config": { "model": "opus" } },
    { "id": "build", "enabled": true, "gate": "auto", "config": { "max_iterations": 20 } },
    { "id": "test", "enabled": true, "gate": "auto", "config": { "coverage_min": 80 } },
    { "id": "review", "enabled": true, "gate": "approve", "config": {} },
    { "id": "pr", "enabled": true, "gate": "approve", "config": {} }
  ]
}
TMPL

    # Create mock sw-intelligence.sh that provides deterministic responses
    cat > "$TEMP_DIR/scripts/sw-intelligence.sh" <<'INTEL'
#!/usr/bin/env bash
# Mock intelligence engine for testing

intelligence_compose_pipeline() {
    local analysis="${1:-}"
    local repo_ctx="${2:-}"
    local budget="${3:-}"

    # Check if analysis requests a security-focused pipeline
    local has_security=""
    has_security=$(echo "$analysis" | jq -r '.risk_flags // [] | map(select(. == "security")) | length' 2>/dev/null) || true

    if [[ "$has_security" == "1" ]]; then
        cat <<'EOF'
{
  "name": "composed-security",
  "description": "Security-focused pipeline",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "plan", "enabled": true, "gate": "auto", "config": { "model": "opus" } },
    { "id": "build", "enabled": true, "gate": "auto", "config": { "max_iterations": 25 } },
    { "id": "security_audit", "enabled": true, "gate": "auto", "config": {} },
    { "id": "test", "enabled": true, "gate": "auto", "config": { "coverage_min": 90 } },
    { "id": "review", "enabled": true, "gate": "approve", "config": {} },
    { "id": "pr", "enabled": true, "gate": "approve", "config": {} }
  ]
}
EOF
    else
        cat <<'EOF'
{
  "name": "composed",
  "description": "AI-composed pipeline",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "plan", "enabled": true, "gate": "auto", "config": { "model": "opus" } },
    { "id": "build", "enabled": true, "gate": "auto", "config": { "max_iterations": 20 } },
    { "id": "test", "enabled": true, "gate": "auto", "config": { "coverage_min": 80 } },
    { "id": "review", "enabled": true, "gate": "auto", "config": {} },
    { "id": "pr", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    fi
}

intelligence_estimate_iterations() {
    local analysis="${1:-}"
    local complexity=""
    complexity=$(echo "$analysis" | jq -r '.complexity // "medium"' 2>/dev/null) || true
    case "$complexity" in
        trivial)  echo 5 ;;
        low)      echo 10 ;;
        medium)   echo 15 ;;
        high)     echo 25 ;;
        critical) echo 40 ;;
        *)        echo 20 ;;
    esac
}
INTEL
    chmod +x "$TEMP_DIR/scripts/sw-intelligence.sh"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE COMPOSITION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Composed pipeline has valid stage ordering
# ──────────────────────────────────────────────────────────────────────────────
test_compose_valid_ordering() {
    local analysis='{"complexity":"medium","risk_flags":[]}'
    local output
    output=$(
        cd "$TEMP_DIR/project"
        HOME="$TEMP_DIR/home" \
        SCRIPT_DIR="$TEMP_DIR/scripts" \
        bash -c '
            SCRIPT_DIR="'"$TEMP_DIR/scripts"'"
            REPO_DIR="'"$TEMP_DIR"'"
            source "$SCRIPT_DIR/sw-pipeline-composer.sh"
            composer_create_pipeline '"'"''"$analysis"''"'"' "" ""
        ' 2>/dev/null
    )

    if [[ -z "$output" ]]; then
        echo -e "    ${RED}✗${RESET} No output file returned"
        return 1
    fi

    # Read the composed pipeline and validate ordering
    local pipeline_file="$TEMP_DIR/project/${output}"
    if [[ ! -f "$pipeline_file" ]]; then
        # output might be full path
        pipeline_file="$output"
    fi
    # Try relative to project dir
    if [[ ! -f "$pipeline_file" ]]; then
        pipeline_file="$TEMP_DIR/project/.claude/pipeline-artifacts/composed-pipeline.json"
    fi

    if [[ ! -f "$pipeline_file" ]]; then
        echo -e "    ${RED}✗${RESET} Composed pipeline file not found"
        return 1
    fi

    # Validate via the script's own validator
    local valid=0
    (
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_validate_pipeline "$pipeline_file"
    ) 2>/dev/null || valid=$?

    if [[ "$valid" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Composed pipeline failed validation"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. High-risk issue gets extra security stages
# ──────────────────────────────────────────────────────────────────────────────
test_compose_security_stages() {
    local analysis='{"complexity":"high","risk_flags":["security"]}'

    (
        cd "$TEMP_DIR/project"
        HOME="$TEMP_DIR/home" \
        SCRIPT_DIR="$TEMP_DIR/scripts" \
        REPO_DIR="$TEMP_DIR" \
        bash -c '
            SCRIPT_DIR="'"$TEMP_DIR/scripts"'"
            REPO_DIR="'"$TEMP_DIR"'"
            source "$SCRIPT_DIR/sw-pipeline-composer.sh"
            composer_create_pipeline '"'"''"$analysis"''"'"' "" ""
        ' 2>/dev/null
    )

    local pipeline_file="$TEMP_DIR/project/.claude/pipeline-artifacts/composed-pipeline.json"
    if [[ ! -f "$pipeline_file" ]]; then
        echo -e "    ${RED}✗${RESET} Composed pipeline file not found"
        return 1
    fi

    # Check for security_audit stage
    local has_security
    has_security=$(jq '[.stages[].id] | map(select(. == "security_audit")) | length' "$pipeline_file")

    if [[ "$has_security" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Security audit stage not present in high-risk pipeline"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Budget constraint triggers model downgrades
# ──────────────────────────────────────────────────────────────────────────────
test_downgrade_models() {
    local pipeline
    pipeline=$(cat "$TEMP_DIR/templates/pipelines/standard.json")

    local result
    result=$(
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        HOME="$TEMP_DIR/home"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_downgrade_models "$pipeline" "test" 2>/dev/null
    )

    # Stages from "test" onwards should have model=sonnet in config
    local test_model review_model pr_model
    test_model=$(echo "$result" | jq -r '.stages[] | select(.id == "test") | .config.model // "none"')
    review_model=$(echo "$result" | jq -r '.stages[] | select(.id == "review") | .config.model // "none"')
    pr_model=$(echo "$result" | jq -r '.stages[] | select(.id == "pr") | .config.model // "none"')

    if [[ "$test_model" != "sonnet" ]]; then
        echo -e "    ${RED}✗${RESET} test stage model not downgraded: $test_model"
        return 1
    fi
    if [[ "$review_model" != "sonnet" ]]; then
        echo -e "    ${RED}✗${RESET} review stage model not downgraded: $review_model"
        return 1
    fi
    if [[ "$pr_model" != "sonnet" ]]; then
        echo -e "    ${RED}✗${RESET} pr stage model not downgraded: $pr_model"
        return 1
    fi

    # Plan stage (before "test") should NOT be downgraded
    local plan_model
    plan_model=$(echo "$result" | jq -r '.stages[] | select(.id == "plan") | .config.model // "none"')
    if [[ "$plan_model" == "sonnet" ]]; then
        echo -e "    ${RED}✗${RESET} plan stage was incorrectly downgraded"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Fallback to static template when intelligence unavailable
# ──────────────────────────────────────────────────────────────────────────────
test_fallback_to_template() {
    # Remove mock intelligence so fallback kicks in
    local saved="$TEMP_DIR/scripts/sw-intelligence.sh.bak"
    mv "$TEMP_DIR/scripts/sw-intelligence.sh" "$saved"

    local output
    output=$(
        cd "$TEMP_DIR/project"
        HOME="$TEMP_DIR/home" \
        bash -c '
            SCRIPT_DIR="'"$TEMP_DIR/scripts"'"
            REPO_DIR="'"$TEMP_DIR"'"
            source "$SCRIPT_DIR/sw-pipeline-composer.sh"
            composer_create_pipeline "" "" ""
        ' 2>/dev/null
    )

    # Restore
    mv "$saved" "$TEMP_DIR/scripts/sw-intelligence.sh"

    local pipeline_file="$TEMP_DIR/project/.claude/pipeline-artifacts/composed-pipeline.json"
    if [[ ! -f "$pipeline_file" ]]; then
        echo -e "    ${RED}✗${RESET} Fallback pipeline file not created"
        return 1
    fi

    # Should match the standard template name
    local name
    name=$(jq -r '.name' "$pipeline_file")
    if [[ "$name" != "standard" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 'standard' template, got: $name"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Conditional stage insertion at correct position
# ──────────────────────────────────────────────────────────────────────────────
test_insert_stage_position() {
    local pipeline
    pipeline=$(cat "$TEMP_DIR/templates/pipelines/standard.json")

    local new_stage='{"id":"security_scan","enabled":true,"gate":"auto","config":{}}'

    local result
    result=$(
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        HOME="$TEMP_DIR/home"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_insert_conditional_stage "$pipeline" "build" "$new_stage" 2>/dev/null
    )

    # Find position of security_scan — should be right after build
    local build_idx scan_idx
    build_idx=$(echo "$result" | jq '[.stages[].id] | to_entries | map(select(.value == "build")) | .[0].key')
    scan_idx=$(echo "$result" | jq '[.stages[].id] | to_entries | map(select(.value == "security_scan")) | .[0].key')

    if [[ "$scan_idx" == "null" ]]; then
        echo -e "    ${RED}✗${RESET} security_scan stage not found after insertion"
        return 1
    fi

    local expected=$((build_idx + 1))
    if [[ "$scan_idx" -ne "$expected" ]]; then
        echo -e "    ${RED}✗${RESET} security_scan at index $scan_idx, expected $expected"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Validation rejects invalid pipeline (missing required stages ordering)
# ──────────────────────────────────────────────────────────────────────────────
test_validate_rejects_invalid() {
    # Pipeline with test before build (invalid ordering)
    local bad_pipeline='{
        "stages": [
            { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
            { "id": "test", "enabled": true, "gate": "auto", "config": {} },
            { "id": "build", "enabled": true, "gate": "auto", "config": {} },
            { "id": "pr", "enabled": true, "gate": "auto", "config": {} }
        ]
    }'

    local exit_code=0
    (
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_validate_pipeline "$bad_pipeline"
    ) 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Validator accepted pipeline with test before build"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Validation rejects pipeline with missing stage ids
# ──────────────────────────────────────────────────────────────────────────────
test_validate_rejects_missing_ids() {
    local bad_pipeline='{
        "stages": [
            { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
            { "enabled": true, "gate": "auto", "config": {} }
        ]
    }'

    local exit_code=0
    (
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_validate_pipeline "$bad_pipeline"
    ) 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Validator accepted pipeline with missing stage id"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Validation accepts valid pipeline
# ──────────────────────────────────────────────────────────────────────────────
test_validate_accepts_valid() {
    local good_pipeline
    good_pipeline=$(cat "$TEMP_DIR/templates/pipelines/standard.json")

    local exit_code=0
    (
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_validate_pipeline "$good_pipeline"
    ) 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Validator rejected valid pipeline"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Iteration estimation returns reasonable numbers
# ──────────────────────────────────────────────────────────────────────────────
test_estimate_iterations_reasonable() {
    local analysis_low='{"complexity":"low"}'
    local analysis_high='{"complexity":"high"}'
    local analysis_none='{}'

    local est_low est_high est_none
    est_low=$(
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_estimate_iterations "$analysis_low" "" 2>/dev/null
    )
    est_high=$(
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_estimate_iterations "$analysis_high" "" 2>/dev/null
    )
    est_none=$(
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_estimate_iterations "$analysis_none" "" 2>/dev/null
    )

    # All should be in 1-50 range
    for est in "$est_low" "$est_high" "$est_none"; do
        if [[ ! "$est" =~ ^[0-9]+$ ]] || [[ "$est" -lt 1 ]] || [[ "$est" -gt 50 ]]; then
            echo -e "    ${RED}✗${RESET} Estimate out of range: $est"
            return 1
        fi
    done

    # High should be greater than low
    if [[ "$est_high" -le "$est_low" ]]; then
        echo -e "    ${RED}✗${RESET} High estimate ($est_high) should exceed low ($est_low)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Insert into nonexistent stage fails
# ──────────────────────────────────────────────────────────────────────────────
test_insert_nonexistent_stage_fails() {
    local pipeline
    pipeline=$(cat "$TEMP_DIR/templates/pipelines/standard.json")
    local new_stage='{"id":"extra","enabled":true,"gate":"auto","config":{}}'

    local exit_code=0
    (
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        HOME="$TEMP_DIR/home"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_insert_conditional_stage "$pipeline" "nonexistent" "$new_stage"
    ) 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Insert into nonexistent stage should fail"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Downgrade with nonexistent stage fails
# ──────────────────────────────────────────────────────────────────────────────
test_downgrade_nonexistent_stage_fails() {
    local pipeline
    pipeline=$(cat "$TEMP_DIR/templates/pipelines/standard.json")

    local exit_code=0
    (
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        HOME="$TEMP_DIR/home"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_downgrade_models "$pipeline" "nonexistent"
    ) 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Downgrade with nonexistent stage should fail"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Validation rejects missing stages array
# ──────────────────────────────────────────────────────────────────────────────
test_validate_rejects_no_stages() {
    local bad='{"name":"broken"}'

    local exit_code=0
    (
        SCRIPT_DIR="$TEMP_DIR/scripts"
        REPO_DIR="$TEMP_DIR"
        source "$TEMP_DIR/scripts/sw-pipeline-composer.sh"
        composer_validate_pipeline "$bad"
    ) 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Validator accepted pipeline without stages"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright pipeline composer — Test Suite        ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for composer tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Composition tests
echo -e "${PURPLE}${BOLD}Pipeline Composition${RESET}"
run_test "Composed pipeline has valid stage ordering" test_compose_valid_ordering
run_test "High-risk issue gets security stages" test_compose_security_stages
run_test "Fallback to static template when no intelligence" test_fallback_to_template
echo ""

# Stage insertion tests
echo -e "${PURPLE}${BOLD}Conditional Stage Insertion${RESET}"
run_test "Stage inserted at correct position after build" test_insert_stage_position
run_test "Insert into nonexistent stage fails" test_insert_nonexistent_stage_fails
echo ""

# Model downgrade tests
echo -e "${PURPLE}${BOLD}Model Downgrade${RESET}"
run_test "Budget constraint triggers model downgrades" test_downgrade_models
run_test "Downgrade with nonexistent stage fails" test_downgrade_nonexistent_stage_fails
echo ""

# Validation tests
echo -e "${PURPLE}${BOLD}Pipeline Validation${RESET}"
run_test "Validation accepts valid pipeline" test_validate_accepts_valid
run_test "Validation rejects invalid ordering (test before build)" test_validate_rejects_invalid
run_test "Validation rejects missing stage ids" test_validate_rejects_missing_ids
run_test "Validation rejects missing stages array" test_validate_rejects_no_stages
echo ""

# Iteration estimation tests
echo -e "${PURPLE}${BOLD}Iteration Estimation${RESET}"
run_test "Iteration estimates are reasonable (1-50 range)" test_estimate_iterations_reasonable
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
