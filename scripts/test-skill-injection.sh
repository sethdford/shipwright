#!/usr/bin/env bash
# test-skill-injection.sh — Verify Dynamic Skill Injection System
# Tests: skill registry, issue type classification, retry context, two-stage review
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_PATH="$PATH"
PASS=0
FAIL=0
ERRORS=""

# ─── Helpers ──────────────────────────────────────────────────────────────────

pass() { PASS=$((PASS + 1)); printf "  ✓ %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  ✗ $1"; printf "  \033[31m✗ %s\033[0m\n" "$1"; }

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if echo "$haystack" | grep >/dev/null "$needle" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (expected to contain '$needle')"
    fi
}

assert_not_empty() {
    local val="$1" msg="$2"
    if [[ -n "$val" ]]; then
        pass "$msg"
    else
        fail "$msg (was empty)"
    fi
}

assert_file_exists() {
    local path="$1" msg="$2"
    if [[ -f "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (file not found: $path)"
    fi
}

assert_exit_zero() {
    local msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$msg"
    else
        fail "$msg (exit code: $?)"
    fi
}

assert_exit_nonzero() {
    local msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$msg (expected non-zero exit, got 0)"
    else
        pass "$msg"
    fi
}

assert_true() {
    local expr="$1" msg="$2"
    if eval "$expr" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (expression was false)"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if echo "$haystack" | grep >/dev/null "$needle" 2>/dev/null; then
        fail "$msg (should NOT contain '$needle')"
    else
        pass "$msg"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 1: Skill Registry
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 1: Skill Registry ═══"

source "$SCRIPT_DIR/lib/skill-registry.sh"

# --- skill_get_prompts: plan stage ---
echo ""
echo "  ── Plan stage mappings ──"

plan_frontend=$(skill_get_prompts "frontend" "plan")
assert_contains "$plan_frontend" "brainstorming.md" "frontend/plan includes brainstorming"
assert_contains "$plan_frontend" "frontend-design.md" "frontend/plan includes frontend-design"
assert_contains "$plan_frontend" "product-thinking.md" "frontend/plan includes product-thinking"

plan_api=$(skill_get_prompts "api" "plan")
assert_contains "$plan_api" "brainstorming.md" "api/plan includes brainstorming"
assert_contains "$plan_api" "api-design.md" "api/plan includes api-design"

plan_database=$(skill_get_prompts "database" "plan")
assert_contains "$plan_database" "brainstorming.md" "database/plan includes brainstorming"
assert_contains "$plan_database" "data-pipeline.md" "database/plan includes data-pipeline"

plan_security=$(skill_get_prompts "security" "plan")
assert_contains "$plan_security" "brainstorming.md" "security/plan includes brainstorming"
assert_contains "$plan_security" "security-audit.md" "security/plan includes security-audit"

plan_performance=$(skill_get_prompts "performance" "plan")
assert_contains "$plan_performance" "brainstorming.md" "performance/plan includes brainstorming"
assert_contains "$plan_performance" "performance.md" "performance/plan includes performance"

plan_testing=$(skill_get_prompts "testing" "plan")
assert_contains "$plan_testing" "testing-strategy.md" "testing/plan includes testing-strategy"

plan_docs=$(skill_get_prompts "documentation" "plan")
assert_contains "$plan_docs" "documentation.md" "documentation/plan includes documentation"

plan_backend=$(skill_get_prompts "backend" "plan")
assert_contains "$plan_backend" "brainstorming.md" "backend/plan includes brainstorming"

plan_refactor=$(skill_get_prompts "refactor" "plan")
assert_contains "$plan_refactor" "brainstorming.md" "refactor/plan includes brainstorming"

plan_infra=$(skill_get_prompts "infrastructure" "plan")
assert_contains "$plan_infra" "brainstorming.md" "infrastructure/plan includes brainstorming"

# --- skill_get_prompts: build stage ---
echo ""
echo "  ── Build stage mappings ──"

build_frontend=$(skill_get_prompts "frontend" "build")
assert_contains "$build_frontend" "frontend-design.md" "frontend/build includes frontend-design"

build_api=$(skill_get_prompts "api" "build")
assert_contains "$build_api" "api-design.md" "api/build includes api-design"

build_security=$(skill_get_prompts "security" "build")
assert_contains "$build_security" "security-audit.md" "security/build includes security-audit"

build_backend=$(skill_get_prompts "backend" "build")
assert_eq "$build_backend" "" "backend/build returns no skills (empty)"

build_refactor=$(skill_get_prompts "refactor" "build")
assert_eq "$build_refactor" "" "refactor/build returns no skills (empty)"

# --- skill_get_prompts: review stage ---
echo ""
echo "  ── Review stage mappings ──"

review_frontend=$(skill_get_prompts "frontend" "review")
assert_contains "$review_frontend" "two-stage-review.md" "frontend/review includes two-stage-review"

review_api=$(skill_get_prompts "api" "review")
assert_contains "$review_api" "two-stage-review.md" "api/review includes two-stage-review"
assert_contains "$review_api" "security-audit.md" "api/review includes security-audit"

review_security=$(skill_get_prompts "security" "review")
assert_contains "$review_security" "two-stage-review.md" "security/review includes two-stage-review"
assert_contains "$review_security" "security-audit.md" "security/review includes security-audit"

review_docs=$(skill_get_prompts "documentation" "review")
assert_eq "$review_docs" "" "documentation/review returns no skills (empty)"

# --- skill_get_prompts: unknown stage ---
echo ""
echo "  ── Edge cases ──"

unknown_stage=$(skill_get_prompts "frontend" "nonexistent_stage")
assert_eq "$unknown_stage" "" "unknown stage returns empty"

unknown_type=$(skill_get_prompts "aliens" "plan")
assert_contains "$unknown_type" "brainstorming.md" "unknown type defaults to brainstorming in plan"

# --- skill_load_prompts ---
echo ""
echo "  ── skill_load_prompts ──"

loaded_frontend=$(skill_load_prompts "frontend" "plan")
assert_contains "$loaded_frontend" "Socratic Design Refinement" "frontend/plan loads brainstorming content"
assert_contains "$loaded_frontend" "Accessibility" "frontend/plan loads frontend-design content"
assert_contains "$loaded_frontend" "User Stories" "frontend/plan loads product-thinking content"

loaded_backend_build=$(skill_load_prompts "backend" "build")
assert_eq "$loaded_backend_build" "" "backend/build loads no content (empty)"

loaded_api_review=$(skill_load_prompts "api" "review")
assert_contains "$loaded_api_review" "Two-Stage Code Review" "api/review loads two-stage-review content"
assert_contains "$loaded_api_review" "OWASP" "api/review loads security-audit content"

# --- skill_has_two_stage_review ---
echo ""
echo "  ── skill_has_two_stage_review ──"

assert_exit_zero "frontend has two-stage review" skill_has_two_stage_review "frontend"
assert_exit_zero "api has two-stage review" skill_has_two_stage_review "api"
assert_exit_zero "backend has two-stage review" skill_has_two_stage_review "backend"
assert_exit_zero "security has two-stage review" skill_has_two_stage_review "security"
assert_exit_nonzero "documentation has NO two-stage review" skill_has_two_stage_review "documentation"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 2: Issue Type Classification (Fallback Heuristic)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 2: Issue Type Classification ═══"

# We need to source sw-intelligence.sh to get _intelligence_fallback_analyze.
# It requires some functions/vars — stub them out.
emit_event() { :; }
warn() { :; }
info() { :; }
error() { :; }
now_epoch() { date +%s; }
compute_md5() { echo "test"; }
export INTELLIGENCE_ENABLED="false"  # force fallback path
export -f emit_event warn info error now_epoch compute_md5

# Source intelligence (it checks for functions, so stub what's needed)
_intelligence_enabled() { return 1; }
_intelligence_cache_get() { return 1; }
_intelligence_cache_set() { :; }
intelligence_github_enrich() { echo "$1"; }
export -f _intelligence_enabled _intelligence_cache_get _intelligence_cache_set intelligence_github_enrich

source "$SCRIPT_DIR/sw-intelligence.sh" 2>/dev/null || true

echo ""
echo "  ── Label-based issue_type detection ──"

# Test the fallback analyzer directly
result_frontend=$(_intelligence_fallback_analyze "Fix CSS layout" "The sidebar is broken on mobile" "ui, bug")
type_frontend=$(echo "$result_frontend" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_frontend" "frontend" "labels 'ui, bug' → frontend"

result_api=$(_intelligence_fallback_analyze "Add REST endpoint" "New /api/users endpoint" "api, feature")
type_api=$(echo "$result_api" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_api" "api" "labels 'api, feature' → api"

result_db=$(_intelligence_fallback_analyze "Add migration" "Need new schema" "db, migration")
type_db=$(echo "$result_db" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_db" "database" "labels 'db, migration' → database"

result_sec=$(_intelligence_fallback_analyze "Fix auth bypass" "XSS vulnerability" "security")
type_sec=$(echo "$result_sec" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_sec" "security" "labels 'security' → security"

result_perf=$(_intelligence_fallback_analyze "Slow query" "latency is 5s" "perf, backend")
type_perf=$(echo "$result_perf" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_perf" "performance" "labels 'perf, backend' → performance"

result_test=$(_intelligence_fallback_analyze "Add tests" "Improve coverage" "test, quality")
type_test=$(echo "$result_test" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_test" "testing" "labels 'test, quality' → testing"

result_docs=$(_intelligence_fallback_analyze "Update README" "Outdated docs" "docs")
type_docs=$(echo "$result_docs" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_docs" "documentation" "labels 'docs' → documentation"

result_infra=$(_intelligence_fallback_analyze "Fix CI" "Pipeline broken" "ci, infra")
type_infra=$(echo "$result_infra" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_infra" "infrastructure" "labels 'ci, infra' → infrastructure"

result_refactor=$(_intelligence_fallback_analyze "Refactor auth" "Clean up module" "refactor")
type_refactor=$(echo "$result_refactor" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_refactor" "refactor" "labels 'refactor' → refactor"

result_default=$(_intelligence_fallback_analyze "Some task" "Do the thing" "enhancement")
type_default=$(echo "$result_default" | jq -r '.issue_type' 2>/dev/null)
assert_eq "$type_default" "backend" "labels 'enhancement' → backend (default)"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 3: Skill Files Integrity
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 3: Skill File Integrity ═══"

EXPECTED_SKILLS=(
    brainstorming
    systematic-debugging
    two-stage-review
    frontend-design
    api-design
    data-pipeline
    security-audit
    performance
    testing-strategy
    product-thinking
    documentation
)

for skill in "${EXPECTED_SKILLS[@]}"; do
    path="$SCRIPT_DIR/skills/${skill}.md"
    assert_file_exists "$path" "skill file exists: ${skill}.md"
done

# Verify content signatures (each file should have specific content)
echo ""
echo "  ── Content verification ──"

assert_contains "$(cat "$SCRIPT_DIR/skills/brainstorming.md")" "Socratic" "brainstorming.md mentions Socratic"
assert_contains "$(cat "$SCRIPT_DIR/skills/systematic-debugging.md")" "Root Cause" "systematic-debugging.md mentions Root Cause"
assert_contains "$(cat "$SCRIPT_DIR/skills/two-stage-review.md")" "Pass 1" "two-stage-review.md has Pass 1"
assert_contains "$(cat "$SCRIPT_DIR/skills/two-stage-review.md")" "Pass 2" "two-stage-review.md has Pass 2"
assert_contains "$(cat "$SCRIPT_DIR/skills/frontend-design.md")" "Accessibility" "frontend-design.md mentions Accessibility"
assert_contains "$(cat "$SCRIPT_DIR/skills/api-design.md")" "RESTful" "api-design.md mentions RESTful"
assert_contains "$(cat "$SCRIPT_DIR/skills/data-pipeline.md")" "Migration" "data-pipeline.md mentions Migration"
assert_contains "$(cat "$SCRIPT_DIR/skills/security-audit.md")" "OWASP" "security-audit.md mentions OWASP"
assert_contains "$(cat "$SCRIPT_DIR/skills/performance.md")" "Profiling" "performance.md mentions Profiling"
assert_contains "$(cat "$SCRIPT_DIR/skills/testing-strategy.md")" "Test Pyramid" "testing-strategy.md mentions Test Pyramid"
assert_contains "$(cat "$SCRIPT_DIR/skills/product-thinking.md")" "User Stories" "product-thinking.md mentions User Stories"
assert_contains "$(cat "$SCRIPT_DIR/skills/documentation.md")" "Skip Heavy Stages" "documentation.md mentions Skip Heavy Stages"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 4: Retry Context Mechanics
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 4: Retry Context Mechanics ═══"

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf $TMPDIR_TEST" EXIT

# Test: retry context file format
echo ""
echo "  ── Retry context file creation ──"

# Simulate what sw-pipeline.sh writes
_retry_ctx_file="${TMPDIR_TEST}/.retry-context-build.md"
error_class="logic"
attempt=1
max_retries=2
_log_file="${TMPDIR_TEST}/build-log.txt"
echo "Error: Cannot find module './foo'" > "$_log_file"
echo "TypeError: undefined is not a function" >> "$_log_file"

ARTIFACTS_DIR="$TMPDIR_TEST"
# Create some fake artifacts
echo "# Plan" > "${ARTIFACTS_DIR}/plan.md"
for i in $(seq 1 15); do echo "- Task $i" >> "${ARTIFACTS_DIR}/plan.md"; done

{
    echo "## Previous Attempt Failed"
    echo ""
    echo "**Error classification:** ${error_class}"
    echo "**Attempt:** ${attempt} of $((max_retries + 1))"
    echo ""
    echo "### Error Output (last 30 lines)"
    echo '```'
    tail -30 "$_log_file" 2>/dev/null || echo "(no log available)"
    echo '```'
    echo ""
    local_existing_artifacts=""
    for _af in plan.md design.md test-results.log; do
        if [[ -s "${ARTIFACTS_DIR}/${_af}" ]]; then
            _af_lines=$(wc -l < "${ARTIFACTS_DIR}/${_af}" 2>/dev/null | xargs)
            local_existing_artifacts="${local_existing_artifacts}  - ${_af} (${_af_lines} lines)\n"
        fi
    done
    if [[ -n "$local_existing_artifacts" ]]; then
        echo "### Existing Artifacts (PRESERVE these)"
        echo -e "$local_existing_artifacts"
    fi
    echo "### Investigation Required"
    echo "1. Read the error output above carefully"
} > "$_retry_ctx_file" 2>/dev/null || true

assert_file_exists "$_retry_ctx_file" "retry context file created"
assert_contains "$(cat "$_retry_ctx_file")" "Previous Attempt Failed" "retry context has header"
assert_contains "$(cat "$_retry_ctx_file")" "logic" "retry context has error class"
assert_contains "$(cat "$_retry_ctx_file")" "Cannot find module" "retry context captures error output"
assert_contains "$(cat "$_retry_ctx_file")" "plan.md" "retry context lists existing artifacts"
assert_contains "$(cat "$_retry_ctx_file")" "Investigation Required" "retry context has investigation section"

# Test: plan artifact skip logic
echo ""
echo "  ── Plan artifact skip logic ──"

plan_artifact="${TMPDIR_TEST}/plan.md"
existing_lines=$(wc -l < "$plan_artifact" 2>/dev/null | xargs)
existing_lines="${existing_lines:-0}"
if [[ "$existing_lines" -gt 10 ]]; then
    plan_skip="yes"
else
    plan_skip="no"
fi
assert_eq "$plan_skip" "yes" "plan with ${existing_lines} lines skips retry (>10)"

# Test with short plan
echo "# Short plan" > "${TMPDIR_TEST}/short-plan.md"
short_lines=$(wc -l < "${TMPDIR_TEST}/short-plan.md" 2>/dev/null | xargs)
if [[ "$short_lines" -gt 10 ]]; then
    short_skip="yes"
else
    short_skip="no"
fi
assert_eq "$short_skip" "no" "plan with ${short_lines} lines does NOT skip retry (<=10)"

# Test: retry context consumption
echo ""
echo "  ── Retry context consumption ──"

echo "Debug info here" > "${TMPDIR_TEST}/.retry-context-plan.md"
_retry_ctx="${TMPDIR_TEST}/.retry-context-plan.md"
if [[ -s "$_retry_ctx" ]]; then
    _retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
    rm -f "$_retry_ctx"
fi
assert_eq "$_retry_hints" "Debug info here" "retry context consumed correctly"
if [[ ! -f "$_retry_ctx" ]]; then
    pass "retry context file deleted after consumption"
else
    fail "retry context file should be deleted after consumption"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 5: Integration — End-to-End Skill Flow
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 5: Integration — End-to-End Skill Flow ═══"

echo ""
echo "  ── Frontend issue → full skill chain ──"

# Simulate: frontend issue classified, skills loaded for each stage
export INTELLIGENCE_ISSUE_TYPE="frontend"

plan_skills=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "plan")
assert_contains "$plan_skills" "Socratic" "frontend plan gets brainstorming"
assert_contains "$plan_skills" "Accessibility" "frontend plan gets frontend-design"
assert_contains "$plan_skills" "User Stories" "frontend plan gets product-thinking"

build_skills=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "build")
assert_contains "$build_skills" "Responsive Design" "frontend build gets frontend-design"

review_skills=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "review")
assert_contains "$review_skills" "Two-Stage" "frontend review gets two-stage-review"

echo ""
echo "  ── API issue → security in review ──"

export INTELLIGENCE_ISSUE_TYPE="api"
api_review=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "review")
assert_contains "$api_review" "Two-Stage" "api review gets two-stage-review"
assert_contains "$api_review" "OWASP" "api review gets security-audit"

echo ""
echo "  ── Documentation issue → lightweight ──"

export INTELLIGENCE_ISSUE_TYPE="documentation"
doc_plan=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "plan")
assert_contains "$doc_plan" "Skip Heavy Stages" "documentation plan gets lightweight guidance"

doc_review=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "review")
assert_eq "$doc_review" "" "documentation review gets NO review skills"

assert_exit_nonzero "documentation has no two-stage review" skill_has_two_stage_review "documentation"

echo ""
echo "  ── Security issue → double security ──"

export INTELLIGENCE_ISSUE_TYPE="security"
sec_plan=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "plan")
assert_contains "$sec_plan" "OWASP" "security plan gets security-audit"

sec_build=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "build")
assert_contains "$sec_build" "OWASP" "security build gets security-audit"

sec_review=$(skill_load_prompts "$INTELLIGENCE_ISSUE_TYPE" "review")
assert_contains "$sec_review" "OWASP" "security review gets security-audit"
assert_contains "$sec_review" "Two-Stage" "security review also gets two-stage-review"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 6: New Skill Files (PDLC Expansion)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 6: New PDLC Skill Files ═══"

NEW_SKILLS=(
    architecture-design
    adversarial-quality
    pr-quality
    deploy-safety
    validation-thoroughness
    observability
)

for skill in "${NEW_SKILLS[@]}"; do
    path="$SCRIPT_DIR/skills/${skill}.md"
    assert_file_exists "$path" "new skill file exists: ${skill}.md"
done

echo ""
echo "  ── Content verification ──"

assert_contains "$(cat "$SCRIPT_DIR/skills/architecture-design.md")" "Component Decomposition" "architecture-design.md has component decomposition"
assert_contains "$(cat "$SCRIPT_DIR/skills/architecture-design.md")" "Interface Contracts" "architecture-design.md has interface contracts"
assert_contains "$(cat "$SCRIPT_DIR/skills/adversarial-quality.md")" "Failure Mode" "adversarial-quality.md has failure mode analysis"
assert_contains "$(cat "$SCRIPT_DIR/skills/adversarial-quality.md")" "Negative Testing" "adversarial-quality.md has negative testing"
assert_contains "$(cat "$SCRIPT_DIR/skills/pr-quality.md")" "Commit Hygiene" "pr-quality.md has commit hygiene"
assert_contains "$(cat "$SCRIPT_DIR/skills/pr-quality.md")" "Reviewer Empathy" "pr-quality.md has reviewer empathy"
assert_contains "$(cat "$SCRIPT_DIR/skills/deploy-safety.md")" "Rollback" "deploy-safety.md has rollback strategy"
assert_contains "$(cat "$SCRIPT_DIR/skills/deploy-safety.md")" "Blue-Green" "deploy-safety.md has blue-green strategy"
assert_contains "$(cat "$SCRIPT_DIR/skills/validation-thoroughness.md")" "Smoke Test" "validation-thoroughness.md has smoke test design"
assert_contains "$(cat "$SCRIPT_DIR/skills/validation-thoroughness.md")" "Health Check Layers" "validation-thoroughness.md has health check layers"
assert_contains "$(cat "$SCRIPT_DIR/skills/observability.md")" "Anomaly Detection" "observability.md has anomaly detection"
assert_contains "$(cat "$SCRIPT_DIR/skills/observability.md")" "Auto-Rollback Triggers" "observability.md has auto-rollback triggers"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 7: New Stage Mappings in Registry
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 7: New Stage Mappings ═══"

echo ""
echo "  ── Design stage ──"

design_frontend=$(skill_get_prompts "frontend" "design")
assert_contains "$design_frontend" "architecture-design.md" "frontend/design includes architecture-design"
assert_contains "$design_frontend" "frontend-design.md" "frontend/design includes frontend-design"

design_api=$(skill_get_prompts "api" "design")
assert_contains "$design_api" "architecture-design.md" "api/design includes architecture-design"
assert_contains "$design_api" "api-design.md" "api/design includes api-design"

design_security=$(skill_get_prompts "security" "design")
assert_contains "$design_security" "security-audit.md" "security/design includes security-audit"

design_docs=$(skill_get_prompts "documentation" "design")
assert_eq "$design_docs" "" "documentation/design returns empty"

design_backend=$(skill_get_prompts "backend" "design")
assert_contains "$design_backend" "architecture-design.md" "backend/design includes architecture-design"

echo ""
echo "  ── Compound quality stage ──"

cq_frontend=$(skill_get_prompts "frontend" "compound_quality")
assert_contains "$cq_frontend" "adversarial-quality.md" "frontend/compound_quality includes adversarial-quality"
assert_contains "$cq_frontend" "testing-strategy.md" "frontend/compound_quality includes testing-strategy"

cq_api=$(skill_get_prompts "api" "compound_quality")
assert_contains "$cq_api" "adversarial-quality.md" "api/compound_quality includes adversarial-quality"
assert_contains "$cq_api" "security-audit.md" "api/compound_quality includes security-audit"

cq_docs=$(skill_get_prompts "documentation" "compound_quality")
assert_eq "$cq_docs" "" "documentation/compound_quality returns empty"

echo ""
echo "  ── PR stage ──"

pr_any=$(skill_get_prompts "backend" "pr")
assert_contains "$pr_any" "pr-quality.md" "backend/pr includes pr-quality"

pr_docs=$(skill_get_prompts "documentation" "pr")
assert_contains "$pr_docs" "pr-quality.md" "documentation/pr includes pr-quality"

echo ""
echo "  ── Deploy stage ──"

deploy_api=$(skill_get_prompts "api" "deploy")
assert_contains "$deploy_api" "deploy-safety.md" "api/deploy includes deploy-safety"
assert_contains "$deploy_api" "security-audit.md" "api/deploy includes security-audit"

deploy_db=$(skill_get_prompts "database" "deploy")
assert_contains "$deploy_db" "deploy-safety.md" "database/deploy includes deploy-safety"
assert_contains "$deploy_db" "data-pipeline.md" "database/deploy includes data-pipeline"

deploy_docs=$(skill_get_prompts "documentation" "deploy")
assert_eq "$deploy_docs" "" "documentation/deploy returns empty"

echo ""
echo "  ── Validate stage ──"

validate_api=$(skill_get_prompts "api" "validate")
assert_contains "$validate_api" "validation-thoroughness.md" "api/validate includes validation-thoroughness"
assert_contains "$validate_api" "security-audit.md" "api/validate includes security-audit"

validate_docs=$(skill_get_prompts "documentation" "validate")
assert_eq "$validate_docs" "" "documentation/validate returns empty"

echo ""
echo "  ── Monitor stage ──"

monitor_perf=$(skill_get_prompts "performance" "monitor")
assert_contains "$monitor_perf" "observability.md" "performance/monitor includes observability"
assert_contains "$monitor_perf" "performance.md" "performance/monitor includes performance (double!)"

monitor_docs=$(skill_get_prompts "documentation" "monitor")
assert_eq "$monitor_docs" "" "documentation/monitor returns empty"

monitor_api=$(skill_get_prompts "api" "monitor")
assert_contains "$monitor_api" "observability.md" "api/monitor includes observability"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 8: Full PDLC Integration — Every Stage Covered
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 8: Full PDLC Integration ═══"

echo ""
echo "  ── API issue → all 9 stages ──"
export INTELLIGENCE_ISSUE_TYPE="api"

api_plan=$(skill_load_prompts "api" "plan")
assert_not_empty "$api_plan" "api/plan has skills"

api_design=$(skill_load_prompts "api" "design")
assert_contains "$api_design" "Architecture" "api/design has architecture guidance"
assert_contains "$api_design" "RESTful" "api/design has API patterns"

api_build=$(skill_load_prompts "api" "build")
assert_not_empty "$api_build" "api/build has skills"

api_review=$(skill_load_prompts "api" "review")
assert_not_empty "$api_review" "api/review has skills"

api_cq=$(skill_load_prompts "api" "compound_quality")
assert_contains "$api_cq" "Failure Mode" "api/compound_quality has adversarial thinking"

api_pr=$(skill_load_prompts "api" "pr")
assert_contains "$api_pr" "Commit Hygiene" "api/pr has PR quality"

api_deploy=$(skill_load_prompts "api" "deploy")
assert_contains "$api_deploy" "Rollback" "api/deploy has deploy safety"

api_validate=$(skill_load_prompts "api" "validate")
assert_contains "$api_validate" "Smoke Test" "api/validate has validation"

api_monitor=$(skill_load_prompts "api" "monitor")
assert_contains "$api_monitor" "Anomaly" "api/monitor has observability"

echo ""
echo "  ── Documentation issue → lightweight everywhere ──"
export INTELLIGENCE_ISSUE_TYPE="documentation"

ALL_STAGES=(plan design build review compound_quality pr deploy validate monitor)
doc_nonempty=0
doc_empty=0
for stage in "${ALL_STAGES[@]}"; do
    content=$(skill_load_prompts "documentation" "$stage")
    if [[ -n "$content" ]]; then
        doc_nonempty=$((doc_nonempty + 1))
    else
        doc_empty=$((doc_empty + 1))
    fi
done
# Documentation should have skills in plan, build, pr only (3 non-empty)
assert_eq "$doc_nonempty" "3" "documentation has exactly 3 stages with skills (plan, build, pr)"
assert_eq "$doc_empty" "6" "documentation skips 6 stages (design, review, compound_quality, deploy, validate, monitor)"

echo ""
echo "  ── Total skill file count ──"
total_skills=$(ls "$SCRIPT_DIR/skills/"*.md 2>/dev/null | wc -l | xargs)
assert_eq "$total_skills" "17" "17 total skill files (11 original + 6 new)"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 9: Adaptive Skill Selection (Level 2)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 9: Adaptive Skill Selection ═══"

# Test: skill_detect_from_body — accessibility keywords
echo ""
echo "  ── Body analysis: accessibility ──"

body_accessibility="Fix WCAG compliance issues. The interface needs better keyboard navigation and ARIA labels for screen readers."
detected_a11y=$(skill_detect_from_body "$body_accessibility" "plan")
assert_contains "$detected_a11y" "frontend-design.md" "accessibility keywords detected"

# Test: skill_detect_from_body — API keywords
echo ""
echo "  ── Body analysis: API/endpoint ──"

body_api="Design new REST endpoint for user management. Need GraphQL mutation support."
detected_api=$(skill_detect_from_body "$body_api" "plan")
assert_contains "$detected_api" "api-design.md" "API keywords detected"

# Test: skill_detect_from_body — security keywords
echo ""
echo "  ── Body analysis: security ──"

body_security="Fix XSS vulnerability in user input. Implement OWASP Top 10 mitigations."
detected_sec=$(skill_detect_from_body "$body_security" "plan")
assert_contains "$detected_sec" "security-audit.md" "security keywords detected"

# Test: skill_detect_from_body — performance keywords
echo ""
echo "  ── Body analysis: performance ──"

body_perf="Query is too slow. P95 latency is 5 seconds. Need to optimize and add caching."
detected_perf=$(skill_detect_from_body "$body_perf" "plan")
assert_contains "$detected_perf" "performance.md" "performance keywords detected"

# Test: skill_detect_from_body — migration keywords
echo ""
echo "  ── Body analysis: database migration ──"

body_migration="Database schema refactor needed. Add new column and create migration."
detected_db=$(skill_detect_from_body "$body_migration" "plan")
assert_contains "$detected_db" "data-pipeline.md" "migration keywords detected"

# Test: skill_detect_from_body — empty body returns empty
echo ""
echo "  ── Body analysis: edge cases ──"

detected_empty=$(skill_detect_from_body "" "plan")
assert_eq "$detected_empty" "" "empty body returns empty (no extra skills)"

# Test: skill_detect_from_body — multiple patterns in one body
body_multi="Improve accessibility (ARIA labels) and add API endpoint (REST). Also need security audit for OWASP compliance."
detected_multi=$(skill_detect_from_body "$body_multi" "plan")
assert_contains "$detected_multi" "frontend-design.md" "multiple patterns: accessibility detected"
assert_contains "$detected_multi" "api-design.md" "multiple patterns: API detected"
assert_contains "$detected_multi" "security-audit.md" "multiple patterns: security detected"

# Test: skill_weight_by_complexity — simple issues (1-3) reduce to first skill
echo ""
echo "  ── Complexity weighting: simple (1-3) ──"

skills_sample="$(printf '%s\n%s\n%s' "$SCRIPT_DIR/skills/brainstorming.md" "$SCRIPT_DIR/skills/frontend-design.md" "$SCRIPT_DIR/skills/product-thinking.md")"
weighted_simple=$(skill_weight_by_complexity "1" "$skills_sample")
simple_count=$(echo "$weighted_simple" | grep -c "^.*\.md$" 2>/dev/null || echo "0")
assert_eq "$simple_count" "1" "complexity 1 keeps only 1 skill (essential)"

weighted_simple_3=$(skill_weight_by_complexity "3" "$skills_sample")
simple_3_count=$(echo "$weighted_simple_3" | grep -c "^.*\.md$" 2>/dev/null || echo "0")
assert_eq "$simple_3_count" "1" "complexity 3 keeps only 1 skill (essential)"

# Test: skill_weight_by_complexity — standard issues (4-7) keep all skills
echo ""
echo "  ── Complexity weighting: standard (4-7) ──"

weighted_std=$(skill_weight_by_complexity "5" "$skills_sample")
std_count=$(echo "$weighted_std" | grep -c "^.*\.md$" 2>/dev/null || echo "0")
assert_eq "$std_count" "3" "complexity 5 keeps all 3 skills (standard)"

weighted_std_7=$(skill_weight_by_complexity "7" "$skills_sample")
std_7_count=$(echo "$weighted_std_7" | grep -c "^.*\.md$" 2>/dev/null || echo "0")
assert_eq "$std_7_count" "3" "complexity 7 keeps all 3 skills (standard)"

# Test: skill_weight_by_complexity — complex issues (8-10) add cross-cutting concerns
echo ""
echo "  ── Complexity weighting: complex (8-10) ──"

weighted_complex=$(skill_weight_by_complexity "9" "$skills_sample")
# Should have original 3 + security-audit (if not present) + performance (if not present)
assert_contains "$weighted_complex" "brainstorming.md" "complexity 9: includes original skills"
assert_contains "$weighted_complex" "security-audit.md" "complexity 9: adds security-audit"
assert_contains "$weighted_complex" "performance.md" "complexity 9: adds performance"

# Test: skill_select_adaptive — combines all signals
echo ""
echo "  ── Adaptive selection: full integration ──"

export INTELLIGENCE_ISSUE_TYPE="api"
body_for_adaptive="Add new REST API endpoint. Need to ensure WCAG accessibility. Consider OWASP security."
complexity_level=6
adaptive_result=$(skill_select_adaptive "api" "plan" "$body_for_adaptive" "$complexity_level")
assert_contains "$adaptive_result" "brainstorming.md" "adaptive: base skills included"
assert_contains "$adaptive_result" "api-design.md" "adaptive: issue-type skill included"
assert_contains "$adaptive_result" "frontend-design.md" "adaptive: body analysis detects accessibility"
assert_contains "$adaptive_result" "security-audit.md" "adaptive: body analysis detects security"

# Test: deduplication in adaptive selection
echo ""
echo "  ── Adaptive selection: deduplication ──"

# If api-design is in base skills and body mentions API, should only appear once
adaptive_dup=$(skill_select_adaptive "api" "design" "Improve REST API design with GraphQL support" "5")
api_count=$(echo "$adaptive_dup" | grep -c "api-design.md" 2>/dev/null || echo "0")
assert_eq "$api_count" "1" "adaptive: duplicate skills deduplicated"

# Test: graceful degradation when adaptive unavailable
echo ""
echo "  ── Fallback behavior ──"

# This tests that pipeline-stages.sh correctly falls back to skill_load_prompts if skill_select_adaptive unavailable
# We simulate by checking that skill_load_prompts still works standalone
fallback_result=$(skill_load_prompts "frontend" "plan")
assert_contains "$fallback_result" "Accessibility" "fallback: skill_load_prompts still functional"

echo ""
echo "  ── Adaptive with zero complexity ──"

# Edge case: complexity 0 should be normalized to 1
weighted_zero=$(skill_weight_by_complexity "0" "$skills_sample")
zero_count=$(echo "$weighted_zero" | grep -c "^.*\.md$" 2>/dev/null || echo "0")
assert_eq "$zero_count" "1" "complexity 0 normalized to 1 (essential only)"

# Edge case: complexity > 10 should be capped
weighted_high=$(skill_weight_by_complexity "99" "$skills_sample")
assert_contains "$weighted_high" "security-audit.md" "complexity 99 capped to 10 (adds cross-cutting)"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 10: Skill Memory & Learning
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 10: Skill Memory & Learning ═══"

# Load skill memory module first (once)
source "$SCRIPT_DIR/lib/skill-memory.sh"

# --- Test 1: Recording a success outcome creates/updates JSON ---
echo ""
echo "  ── Recording outcomes ──"

# Use temporary file for testing (don't pollute real memory)
_TEST_MEMORY_FILE=$(mktemp)
export SKILL_MEMORY_FILE="$_TEST_MEMORY_FILE"

skill_memory_record "backend" "plan" "brainstorming,frontend-design" "success" "1" >/dev/null 2>&1 || true
assert_file_exists "$SKILL_MEMORY_FILE" "Memory file created on first write"

result=$(jq '.records | length' "$SKILL_MEMORY_FILE" 2>/dev/null || echo "0")
assert_eq "$result" "1" "First record written to memory"

# --- Test 2: Recording a failure outcome ---
skill_memory_record "frontend" "build" "frontend-design" "failure" "1" >/dev/null 2>&1 || true
result=$(jq '.records | length' "$SKILL_MEMORY_FILE" 2>/dev/null || echo "0")
assert_eq "$result" "2" "Second record (failure) appended"

# Clean up from test 1-2 before test 3
rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"
# Re-initialize after cleanup
_skill_memory_ensure_file

# --- Test 3: Success rate calculation (2 success, 1 failure = 67%, rounded to 66) ---
skill_memory_record "api" "review" "two-stage-review,security-audit" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "api" "review" "two-stage-review,security-audit" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "api" "review" "two-stage-review,security-audit" "failure" "1" >/dev/null 2>&1 || true

rate=$(skill_memory_get_success_rate "api" "review" "two-stage-review" 2>/dev/null || echo "0")
assert_eq "$rate" "66" "Success rate: 2 success + 1 failure = 66%"

# --- Test 4: Recommendations return skills sorted by success rate ---
skill_memory_record "backend" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "backend" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "backend" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true

skill_memory_record "backend" "plan" "architecture-design" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "backend" "plan" "architecture-design" "failure" "1" >/dev/null 2>&1 || true

recommendations=$(skill_memory_get_recommendations "backend" "plan" 2>/dev/null || echo "")
# brainstorming should rank higher (100% success vs 50%)
if [[ "$recommendations" == *"brainstorming"* ]]; then
    pass "Recommendations returned for backend/plan"
else
    fail "Recommendations should not be empty for backend/plan"
fi

# Clean up from test 1-4
rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"

# --- Test 5: Empty memory returns empty recommendations ---
_TEST_MEMORY_FILE=$(mktemp)
export SKILL_MEMORY_FILE="$_TEST_MEMORY_FILE"
recommendations=$(skill_memory_get_recommendations "frontend" "test" 2>/dev/null || echo "")
assert_eq "$recommendations" "" "Empty memory returns empty recommendations"
rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"

# --- Test 6: Memory file created lazily ---
_TEST_MEMORY_FILE=$(mktemp)
rm -f "$_TEST_MEMORY_FILE"
export SKILL_MEMORY_FILE="$_TEST_MEMORY_FILE"
[[ ! -f "$SKILL_MEMORY_FILE" ]] && pass "Temp file doesn't exist initially"

skill_memory_record "testing" "plan" "testing-strategy" "success" "1" >/dev/null 2>&1 || true
assert_file_exists "$SKILL_MEMORY_FILE" "Memory file created lazily on first record"
rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"

# --- Test 7: Graceful handling when jq is unavailable ---
export PATH="/nonexistent:$PATH"
if ! command -v jq &>/dev/null; then
    _TEST_MEMORY_FILE=$(mktemp)
    export SKILL_MEMORY_FILE="$_TEST_MEMORY_FILE"
    skill_memory_record "database" "design" "data-pipeline" "success" "1" >/dev/null 2>&1 || true
    fail_code=$?
    if [[ $fail_code -ne 0 ]]; then
        pass "Graceful failure when jq unavailable"
    else
        fail "Should return error when jq unavailable"
    fi
    rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"
else
    pass "jq is available (can't fully test unavailable case)"
fi
export PATH="$ORIGINAL_PATH"

# --- Test 8: Max records limit (pruning) ---
_TEST_MEMORY_FILE=$(mktemp)
export SKILL_MEMORY_FILE="$_TEST_MEMORY_FILE"
for i in {1..250}; do
    skill_memory_record "refactor" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true
done
record_count=$(jq '.records | length' "$SKILL_MEMORY_FILE" 2>/dev/null || echo "0")
if [[ "$record_count" -le 200 ]]; then
    pass "Records pruned to max 200 (got $record_count)"
else
    fail "Records not pruned (expected ≤200, got $record_count)"
fi
rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"

# --- Test 9: Skill stats function ---
_TEST_MEMORY_FILE=$(mktemp)
export SKILL_MEMORY_FILE="$_TEST_MEMORY_FILE"
skill_memory_record "performance" "compound_quality" "adversarial-quality,performance" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "performance" "compound_quality" "adversarial-quality,performance" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "performance" "compound_quality" "adversarial-quality,performance" "failure" "1" >/dev/null 2>&1 || true

stats=$(skill_memory_stats "performance" "compound_quality" "adversarial-quality" 2>/dev/null || echo "")
success_count=$(echo "$stats" | jq '.success_count' 2>/dev/null || echo "0")
failure_count=$(echo "$stats" | jq '.failure_count' 2>/dev/null || echo "0")

assert_eq "$success_count" "2" "Stats: 2 successes for adversarial-quality"
assert_eq "$failure_count" "1" "Stats: 1 failure for adversarial-quality"
rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"

# --- Test 10: Export and import functionality ---
_TEST_MEMORY_FILE=$(mktemp)
_TEST_IMPORT_FILE=$(mktemp)
export SKILL_MEMORY_FILE="$_TEST_MEMORY_FILE"

skill_memory_record "documentation" "pr" "pr-quality" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "documentation" "pr" "pr-quality" "success" "1" >/dev/null 2>&1 || true

skill_memory_export > "$_TEST_IMPORT_FILE" 2>/dev/null || true
import_records=$(jq '.records | length' "$_TEST_IMPORT_FILE" 2>/dev/null || echo "0")
assert_eq "$import_records" "2" "Export has correct record count"

rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock" "$_TEST_IMPORT_FILE"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 11: Skill Catalog Builder
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 11: Skill Catalog Builder ═══"
echo ""

# Test: catalog includes curated skills
echo "  ── Curated skills in catalog ──"
_catalog=$(skill_build_catalog 2>/dev/null || true)
assert_contains "$_catalog" "brainstorming" "catalog includes brainstorming"
assert_contains "$_catalog" "frontend-design" "catalog includes frontend-design"
assert_contains "$_catalog" "security-audit" "catalog includes security-audit"

# Test: catalog includes one-line descriptions
assert_contains "$_catalog" "Socratic" "brainstorming has description"

# Test: catalog includes generated skills when they exist
_gen_dir="${SKILLS_DIR}/generated"
mkdir -p "$_gen_dir"
printf '%s\n%s\n' "## Test Generated Skill" "Test content for generated skill." > "$_gen_dir/test-gen-skill.md"
_catalog=$(skill_build_catalog 2>/dev/null || true)
assert_contains "$_catalog" "test-gen-skill" "catalog includes generated skill"
assert_contains "$_catalog" "[generated]" "generated skill is tagged"
rm -f "$_gen_dir/test-gen-skill.md"

# Test: catalog includes memory context when available
skill_memory_clear 2>/dev/null || true
skill_memory_record "frontend" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true
skill_memory_record "frontend" "plan" "brainstorming" "success" "1" >/dev/null 2>&1 || true
_catalog=$(skill_build_catalog "frontend" "plan" 2>/dev/null || true)
assert_contains "$_catalog" "success" "catalog includes memory context"
skill_memory_clear 2>/dev/null || true

echo ""
echo "  ── LLM skill analysis (mock) ──"

# We can't test real LLM calls in unit tests, so test the JSON parsing/artifact writing
# Mock: simulate skill_analyze_issue writing skill-plan.json
_test_artifacts=$(mktemp -d)

_mock_plan='{"issue_type":"frontend","confidence":0.92,"secondary_domains":["accessibility"],"complexity_assessment":{"score":6,"reasoning":"moderate"},"skill_plan":{"plan":["brainstorming","frontend-design"],"build":["frontend-design"],"review":["two-stage-review"]},"skill_rationale":{"frontend-design":"ARIA progressbar needed","brainstorming":"Task decomposition required"},"generated_skills":[],"review_focus":["accessibility"],"risk_areas":["ETA accuracy"]}'
echo "$_mock_plan" > "$_test_artifacts/skill-plan.json"

# Verify skill-plan.json is valid JSON
assert_true "jq '.' '$_test_artifacts/skill-plan.json' >/dev/null 2>&1" "skill-plan.json is valid JSON"

# Verify we can extract skills for a stage
_plan_skills=$(jq -r '.skill_plan.plan[]' "$_test_artifacts/skill-plan.json" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
assert_eq "$_plan_skills" "brainstorming,frontend-design" "plan stage skills extracted correctly"

# Verify rationale extraction
_rationale=$(jq -r '.skill_rationale["frontend-design"]' "$_test_artifacts/skill-plan.json" 2>/dev/null)
assert_contains "$_rationale" "ARIA" "rationale extracted correctly"

rm -rf "$_test_artifacts"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 12: Plan-Based Skill Loading
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 12: Plan-Based Skill Loading ═══"
echo ""

_test_artifacts=$(mktemp -d)

# Write a mock skill-plan.json
cat > "$_test_artifacts/skill-plan.json" << 'PLAN_EOF'
{
  "issue_type": "frontend",
  "skill_plan": {
    "plan": ["brainstorming", "frontend-design"],
    "build": ["frontend-design"],
    "review": ["two-stage-review"],
    "deploy": []
  },
  "skill_rationale": {
    "brainstorming": "Task decomposition for progress bar feature",
    "frontend-design": "ARIA progressbar role and responsive CSS needed",
    "two-stage-review": "Spec compliance check against plan.md"
  },
  "generated_skills": []
}
PLAN_EOF

echo "  ── Loading skills from plan ──"

# Test: load plan stage skills
plan_content=$(ARTIFACTS_DIR="$_test_artifacts" skill_load_from_plan "plan" 2>/dev/null || true)
assert_contains "$plan_content" "brainstorming" "plan stage loads brainstorming skill"
assert_contains "$plan_content" "frontend-design" "plan stage loads frontend-design skill content"
assert_contains "$plan_content" "ARIA progressbar" "plan stage includes rationale"
assert_contains "$plan_content" "Task decomposition" "plan stage includes brainstorming rationale"

# Test: load build stage skills
build_content=$(ARTIFACTS_DIR="$_test_artifacts" skill_load_from_plan "build" 2>/dev/null || true)
assert_contains "$build_content" "frontend-design" "build stage loads frontend-design"
assert_not_contains "$build_content" "brainstorming" "build stage does NOT load brainstorming"

# Test: empty stage returns empty
deploy_content=$(ARTIFACTS_DIR="$_test_artifacts" skill_load_from_plan "deploy" 2>/dev/null || true)
assert_eq "" "$(echo "$deploy_content" | tr -d '[:space:]')" "empty stage returns empty"

# Test: missing skill-plan.json falls back to skill_select_adaptive
_no_plan_dir=$(mktemp -d)
fallback_content=$(ARTIFACTS_DIR="$_no_plan_dir" INTELLIGENCE_ISSUE_TYPE="frontend" skill_load_from_plan "plan" 2>/dev/null || true)
assert_contains "$fallback_content" "brainstorming\|frontend\|Socratic" "fallback to adaptive when no plan"
rm -rf "$_no_plan_dir"

# Test: refinements are appended
mkdir -p "$SKILLS_DIR/generated/_refinements"
echo "REFINEMENT: Always check stat-bar CSS pattern reuse." > "$SKILLS_DIR/generated/_refinements/frontend-design.patch.md"
plan_content=$(ARTIFACTS_DIR="$_test_artifacts" skill_load_from_plan "plan" 2>/dev/null || true)
assert_contains "$plan_content" "REFINEMENT" "refinement patch appended to skill"
rm -f "$SKILLS_DIR/generated/_refinements/frontend-design.patch.md"

rm -rf "$_test_artifacts"


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 13: Outcome Learning Loop
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 13: Outcome Learning Loop ═══"
echo ""

_test_artifacts=$(mktemp -d)

# Write a mock skill-plan.json
cat > "$_test_artifacts/skill-plan.json" << 'PLAN_EOF'
{
  "issue_type": "frontend",
  "skill_plan": {
    "plan": ["brainstorming", "frontend-design"],
    "build": ["frontend-design"],
    "review": ["two-stage-review"]
  },
  "skill_rationale": {
    "frontend-design": "ARIA progressbar needed"
  },
  "generated_skills": []
}
PLAN_EOF

echo "  ── Outcome JSON parsing ──"

# Test: parse a mock outcome response
_mock_outcome='{"skill_effectiveness":{"frontend-design":{"verdict":"effective","evidence":"ARIA section in plan","learning":"stat-bar reuse hint followed"}},"refinements":[{"skill":"frontend-design","addition":"For dashboard features, mention existing CSS patterns"}],"generated_skill_verdict":{}}'
echo "$_mock_outcome" > "$_test_artifacts/skill-outcome.json"

# Verify outcome JSON is valid
assert_true "jq '.' '$_test_artifacts/skill-outcome.json' >/dev/null 2>&1" "outcome JSON is valid"

# Verify verdict extraction
_verdict=$(jq -r '.skill_effectiveness["frontend-design"].verdict' "$_test_artifacts/skill-outcome.json" 2>/dev/null)
assert_eq "effective" "$_verdict" "verdict extracted correctly"

# Verify refinement extraction
_refinement_skill=$(jq -r '.refinements[0].skill' "$_test_artifacts/skill-outcome.json" 2>/dev/null)
assert_eq "frontend-design" "$_refinement_skill" "refinement skill extracted"

echo ""
echo "  ── Refinement file writing ──"

# Test: skill_apply_refinements writes patch files
_ref_dir="${SKILLS_DIR}/generated/_refinements"
mkdir -p "$_ref_dir"
skill_apply_refinements "$_test_artifacts/skill-outcome.json" 2>/dev/null || true
assert_true "[[ -f '$_ref_dir/frontend-design.patch.md' ]]" "refinement patch file created"
_ref_content=$(cat "$_ref_dir/frontend-design.patch.md" 2>/dev/null || true)
assert_contains "$_ref_content" "dashboard" "refinement content written"
rm -f "$_ref_dir/frontend-design.patch.md"

echo ""
echo "  ── Generated skill lifecycle ──"

# Test: prune verdict deletes generated skill
mkdir -p "${SKILLS_DIR}/generated"
echo "## Temp Skill" > "${SKILLS_DIR}/generated/temp-skill.md"
_prune_outcome='{"skill_effectiveness":{},"refinements":[],"generated_skill_verdict":{"temp-skill":"prune"}}'
echo "$_prune_outcome" > "$_test_artifacts/skill-outcome.json"
skill_apply_lifecycle_verdicts "$_test_artifacts/skill-outcome.json" 2>/dev/null || true
assert_true "[[ ! -f '${SKILLS_DIR}/generated/temp-skill.md' ]]" "pruned skill deleted"

rm -rf "$_test_artifacts"


# ═══════════════════════════════════════════════════════════════════════════════
# Suite 14: Full AI Integration
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Suite 14: Full AI Integration ═══"
echo ""

echo "  ── End-to-end skill flow ──"

# Test: catalog → plan → load → outcome cycle
_e2e_dir=$(mktemp -d)

# 1. Build catalog (should include all 17 curated skills)
_catalog=$(skill_build_catalog 2>/dev/null || true)
_catalog_lines=$(echo "$_catalog" | grep -c '^-' 2>/dev/null || echo "0")
assert_true "[[ $_catalog_lines -ge 17 ]]" "catalog has at least 17 skills (got $_catalog_lines)"

# 2. Write a skill plan (simulating what skill_analyze_issue would produce)
cat > "$_e2e_dir/skill-plan.json" << 'E2E_PLAN'
{
  "issue_type": "api",
  "confidence": 0.88,
  "skill_plan": {
    "plan": ["brainstorming", "api-design"],
    "build": ["api-design"],
    "review": ["two-stage-review", "security-audit"]
  },
  "skill_rationale": {
    "api-design": "REST endpoint versioning needed",
    "brainstorming": "Multiple valid API approaches",
    "two-stage-review": "Spec compliance for API contract",
    "security-audit": "Auth endpoint requires security review"
  },
  "generated_skills": []
}
E2E_PLAN

# 3. Load from plan for each stage
ARTIFACTS_DIR="$_e2e_dir" _plan_out=$(skill_load_from_plan "plan" 2>/dev/null || true)
ARTIFACTS_DIR="$_e2e_dir" _build_out=$(skill_load_from_plan "build" 2>/dev/null || true)
ARTIFACTS_DIR="$_e2e_dir" _review_out=$(skill_load_from_plan "review" 2>/dev/null || true)

assert_contains "$_plan_out" "api-design" "plan loads api-design skill"
assert_contains "$_plan_out" "REST endpoint" "plan includes rationale"
assert_contains "$_build_out" "api-design" "build loads api-design"
assert_not_contains "$_build_out" "brainstorming" "build doesn't load plan-only skills"
assert_contains "$_review_out" "two-stage-review" "review loads two-stage-review"
assert_contains "$_review_out" "security-audit" "review loads security-audit"

# 4. Test fallback chain (no plan → adaptive → static)
_no_plan_dir=$(mktemp -d)
_fallback_out=$(ARTIFACTS_DIR="$_no_plan_dir" INTELLIGENCE_ISSUE_TYPE="frontend" skill_load_from_plan "plan" 2>/dev/null || true)
assert_contains "$_fallback_out" "brainstorming\|frontend\|Socratic" "fallback produces output when no plan exists"

# 5. Verify generated skill directory structure
assert_true "[[ -d '$SKILLS_DIR/generated' ]]" "generated skills directory exists"
assert_true "[[ -d '$SKILLS_DIR/generated/_refinements' ]]" "refinements directory exists"

rm -rf "$_e2e_dir" "$_no_plan_dir"


# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
    printf "\033[32m  ALL %d TESTS PASSED ✓\033[0m\n" "$TOTAL"
else
    printf "\033[31m  %d/%d PASSED, %d FAILED\033[0m\n" "$PASS" "$TOTAL" "$FAIL"
    echo ""
    echo "  Failures:"
    echo -e "$ERRORS"
fi
echo "═══════════════════════════════════════════"
echo ""

exit "$FAIL"
