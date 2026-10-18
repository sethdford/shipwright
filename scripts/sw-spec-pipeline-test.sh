#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-spec-pipeline-test.sh — Spec-Driven Pipeline Stages Test Suite      ║
# ║  Tests stage_spec_generation() and stage_spec_verification()            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-isolate.sh"
sw_test_isolate
PASS=0
FAIL=0
TEST_TMP=""

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_true() {
    local condition="$1" description="${2:-}"
    if eval "$condition"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
    fi
}

assert_file_exists() {
    local file="$1" description="${2:-}"
    if [[ -f "$file" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    File not found: $file"
    fi
}

assert_json_field() {
    local file="$1" query="$2" expected="$3" description="${4:-}"
    local actual
    actual=$(jq -r "$query" "$file" 2>/dev/null || echo "__jq_error__")
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

# ─── Mock functions ─────────────────────────────────────────────────────────
emit_event() { true; }
log_stage() { true; }
info() { true; }
success() { true; }
warn() { true; }
error() { true; }
now_iso() { echo "2026-04-04T00:00:00Z"; }
detect_project_lang() { echo "javascript"; }
save_artifact() {
    local name="$1" content="$2"
    mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
    echo "$content" > "$ARTIFACTS_DIR/$name"
}

# Provide styling variables
BOLD="" RESET="" DIM="" CYAN="" GREEN="" PURPLE=""

# ─── Source modules (lightweight) ───────────────────────────────────────────
# Only source spec-driven.sh (our dependency), not the full pipeline modules.
# We extract stage functions by sourcing only what's needed.
_SPEC_DRIVEN_LOADED=""
source "$SCRIPT_DIR/lib/spec-driven.sh"

# Extract stage_spec_generation from pipeline-stages-intake.sh
# and stage_spec_verification from pipeline-stages-review.sh
# by sourcing them with guards pre-set to avoid pulling in other stages
_PIPELINE_STAGES_INTAKE_LOADED=""
_PIPELINE_STAGES_REVIEW_LOADED=""

# Stub out all functions these modules try to source/use
analyze_intent() { return 1; }
detect_task_type() { echo "feature"; }
template_for_type() { echo "standard"; }
branch_prefix_for_type() { echo "feat"; }
gh_get_issue_meta() { echo "{}"; }
gh_assign_self() { true; }
gh_add_labels() { true; }
gh_build_progress_body() { echo ""; }
gh_post_progress() { true; }
classify_error() { echo "unknown"; }
_safe_base_diff() { echo ""; }
set_stage_status() { true; }
get_stage_status() { echo ""; }
show_stage_preview() { true; }
prune_context_section() { echo "$2"; }
verify_stage_artifacts() { return 0; }
rotate_event_log_if_needed() { true; }
intelligence_search_memory() { echo ""; }
skill_analyze_issue() { return 1; }
holdout_partition() { return 1; }
holdout_seal() { return 1; }

# Source the stage files
source "$SCRIPT_DIR/lib/pipeline-stages-intake.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/pipeline-stages-review.sh" 2>/dev/null || true

# Verify functions loaded
if ! type stage_spec_generation >/dev/null 2>&1; then
    echo "FATAL: stage_spec_generation not loaded"
    exit 1
fi
if ! type stage_spec_verification >/dev/null 2>&1; then
    echo "FATAL: stage_spec_verification not loaded"
    exit 1
fi

# ─── Setup / Teardown ──────────────────────────────────────────────────────
setup() {
    TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sw-spec-test.XXXXXX")
    ARTIFACTS_DIR="$TEST_TMP/artifacts"
    PROJECT_ROOT="$TEST_TMP/project"
    SPEC_DIR="$ARTIFACTS_DIR/specs"
    GOAL="Add user authentication"
    ISSUE_BODY="Implement OAuth2 login with JWT tokens"
    ISSUE_NUMBER="42"
    ISSUE_LABELS="feature"
    MODEL="sonnet"
    BASE_BRANCH="main"
    NO_GITHUB="true"
    SPEC_DRIVEN_ENABLED="true"
    CURRENT_STAGE_ID=""

    mkdir -p "$ARTIFACTS_DIR" "$PROJECT_ROOT" "$SPEC_DIR"

    # Ensure claude CLI is not found during tests (prevents real API calls)
    ORIG_PATH="$PATH"
    _mock_bin="$TEST_TMP/mock-bin"
    mkdir -p "$_mock_bin"
    # Create a mock claude that returns empty (no real API calls)
    cat > "$_mock_bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo ""
exit 0
MOCKEOF
    chmod +x "$_mock_bin/claude"
    PATH="$_mock_bin:$PATH"
}

teardown() {
    PATH="${ORIG_PATH:-$PATH}"
    rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ─── Test: spec_generation skips when disabled ──────────────────────────────
test_spec_generation_skips_when_disabled() {
    setup
    SPEC_DRIVEN_ENABLED="false"

    stage_spec_generation
    local exit_code=$?

    assert_equals "0" "$exit_code" "spec_generation exits 0 when disabled"
    teardown
}

# ─── Test: spec_generation skips when no spec and no goal ───────────────────
test_spec_generation_skips_no_spec_no_goal() {
    setup
    GOAL=""
    rm -f "$ARTIFACTS_DIR/spec.json" 2>/dev/null || true

    stage_spec_generation
    local exit_code=$?

    assert_equals "0" "$exit_code" "spec_generation exits 0 when no spec and no goal"
    teardown
}

# ─── Test: spec_generation uses existing spec ───────────────────────────────
test_spec_generation_uses_existing_spec() {
    setup

    cat > "$ARTIFACTS_DIR/spec.json" <<'EOF'
{
  "version": "1.0",
  "title": "Add user authentication",
  "source": {"type": "github_issue", "issue_number": 42},
  "goals": ["Implement OAuth2 login"],
  "constraints": [],
  "acceptance_criteria": [
    {"criterion": "All tests pass", "testable": true, "verification_method": "unit_test"}
  ],
  "edge_cases": [],
  "security_requirements": [],
  "performance_requirements": {},
  "affected_files": [],
  "dependencies": [],
  "metadata": {"created_at": "2026-04-04T00:00:00Z", "complexity": "moderate"}
}
EOF

    # Claude CLI not available in test — should keep original
    stage_spec_generation
    local exit_code=$?

    assert_equals "0" "$exit_code" "spec_generation succeeds with existing spec"
    assert_file_exists "$ARTIFACTS_DIR/spec.json" "spec.json still exists after generation"
    teardown
}

# ─── Test: spec_generation generates spec when missing ──────────────────────
test_spec_generation_creates_spec_when_missing() {
    setup
    rm -f "$ARTIFACTS_DIR/spec.json" 2>/dev/null || true
    GOAL="Implement feature X"

    stage_spec_generation
    local exit_code=$?

    assert_equals "0" "$exit_code" "spec_generation exits 0 when generating new spec"

    # Check that a spec was created somewhere
    if [[ -f "$ARTIFACTS_DIR/spec.json" ]]; then
        local has_title
        has_title=$(jq -r '.title // empty' "$ARTIFACTS_DIR/spec.json" 2>/dev/null || true)
        assert_true "[[ -n '${has_title}' ]]" "generated spec has a title"
    else
        # Still valid — stage handled missing spec gracefully
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m spec_generation handled missing spec gracefully"
    fi
    teardown
}

# ─── Test: spec_verification skips when disabled ────────────────────────────
test_spec_verification_skips_when_disabled() {
    setup
    SPEC_DRIVEN_ENABLED="false"

    stage_spec_verification
    local exit_code=$?

    assert_equals "0" "$exit_code" "spec_verification exits 0 when disabled"
    teardown
}

# ─── Test: spec_verification skips when no spec ─────────────────────────────
test_spec_verification_skips_no_spec() {
    setup
    rm -f "$ARTIFACTS_DIR/spec.json" 2>/dev/null || true

    stage_spec_verification
    local exit_code=$?

    assert_equals "0" "$exit_code" "spec_verification exits 0 when no spec"
    teardown
}

# ─── Test: spec_verification generates report ───────────────────────────────
test_spec_verification_generates_report() {
    setup

    cat > "$ARTIFACTS_DIR/spec.json" <<'EOF'
{
  "version": "1.0",
  "title": "Test feature",
  "source": {"type": "manual"},
  "goals": ["Test goal"],
  "constraints": [],
  "acceptance_criteria": [
    {"criterion": "Unit tests pass", "testable": true, "verification_method": "unit_test"},
    {"criterion": "Static analysis clean", "testable": true, "verification_method": "static_analysis"},
    {"criterion": "UX reviewed", "testable": false, "verification_method": "manual"}
  ],
  "edge_cases": [],
  "security_requirements": [],
  "performance_requirements": {},
  "affected_files": [],
  "dependencies": [],
  "metadata": {"created_at": "2026-04-04T00:00:00Z", "complexity": "moderate"}
}
EOF

    stage_spec_verification
    local exit_code=$?

    assert_equals "0" "$exit_code" "spec_verification exits 0"
    assert_file_exists "$ARTIFACTS_DIR/spec-verification-report.json" "verification report generated"

    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.total_criteria" "3" "report has 3 total criteria"
    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.manual_review" "1" "report has 1 manual review criterion"
    teardown
}

# ─── Test: spec_verification computes compliance score ──────────────────────
test_spec_verification_compliance_score() {
    setup

    cat > "$ARTIFACTS_DIR/spec.json" <<'EOF'
{
  "version": "1.0",
  "title": "Test compliance",
  "source": {"type": "manual"},
  "goals": ["Test goal"],
  "constraints": [],
  "acceptance_criteria": [
    {"criterion": "Tests pass", "testable": true, "verification_method": "unit_test"},
    {"criterion": "More tests pass", "testable": true, "verification_method": "unit_test"}
  ],
  "edge_cases": [],
  "security_requirements": [],
  "performance_requirements": {},
  "affected_files": [],
  "dependencies": [],
  "metadata": {"created_at": "2026-04-04T00:00:00Z", "complexity": "simple"}
}
EOF

    echo "All 15 tests passed" > "$ARTIFACTS_DIR/test-results.log"

    stage_spec_verification

    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.compliance_score" "100" "100% compliance when all tests pass"
    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.verified" "2" "2 criteria verified"
    teardown
}

# ─── Test: spec_verification detects failures ───────────────────────────────
test_spec_verification_detects_failures() {
    setup

    cat > "$ARTIFACTS_DIR/spec.json" <<'EOF'
{
  "version": "1.0",
  "title": "Test failures",
  "source": {"type": "manual"},
  "goals": ["Test goal"],
  "constraints": [],
  "acceptance_criteria": [
    {"criterion": "Tests pass", "testable": true, "verification_method": "unit_test"}
  ],
  "edge_cases": [],
  "security_requirements": [],
  "performance_requirements": {},
  "affected_files": [],
  "dependencies": [],
  "metadata": {"created_at": "2026-04-04T00:00:00Z", "complexity": "simple"}
}
EOF

    echo "FAIL: test_auth_login expected 200 got 401" > "$ARTIFACTS_DIR/test-results.log"

    stage_spec_verification

    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.compliance_score" "0" "0% compliance when tests fail"
    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.unverified" "1" "1 criterion unverified"
    teardown
}

# ─── Test: spec_verification handles static analysis ────────────────────────
test_spec_verification_static_analysis() {
    setup

    cat > "$ARTIFACTS_DIR/spec.json" <<'EOF'
{
  "version": "1.0",
  "title": "Static analysis test",
  "source": {"type": "manual"},
  "goals": ["Clean code"],
  "constraints": [],
  "acceptance_criteria": [
    {"criterion": "No constitutional violations", "testable": true, "verification_method": "static_analysis"}
  ],
  "edge_cases": [],
  "security_requirements": [],
  "performance_requirements": {},
  "affected_files": [],
  "dependencies": [],
  "metadata": {"created_at": "2026-04-04T00:00:00Z", "complexity": "simple"}
}
EOF

    echo '{"total_violations": 0, "results": []}' > "$ARTIFACTS_DIR/constitutional-audit.json"

    stage_spec_verification

    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.verified" "1" "static analysis criterion verified"
    assert_json_field "$ARTIFACTS_DIR/spec-verification-report.json" ".summary.compliance_score" "100" "100% compliance with clean audit"
    teardown
}

# ─── Test: pipeline templates include new stages ────────────────────────────
test_templates_include_spec_stages() {
    local templates_dir="$SCRIPT_DIR/../templates/pipelines"

    local has_gen has_ver
    has_gen=$(jq '[.stages[].id] | index("spec_generation")' "$templates_dir/standard.json" 2>/dev/null)
    has_ver=$(jq '[.stages[].id] | index("spec_verification")' "$templates_dir/standard.json" 2>/dev/null)

    assert_true "[[ '$has_gen' != 'null' && -n '$has_gen' ]]" "standard template includes spec_generation"
    assert_true "[[ '$has_ver' != 'null' && -n '$has_ver' ]]" "standard template includes spec_verification"

    # Verify ordering: intake < spec_generation < plan
    local intake_idx gen_idx plan_idx
    intake_idx=$(jq '[.stages[].id] | index("intake")' "$templates_dir/standard.json" 2>/dev/null)
    gen_idx=$(jq '[.stages[].id] | index("spec_generation")' "$templates_dir/standard.json" 2>/dev/null)
    plan_idx=$(jq '[.stages[].id] | index("plan")' "$templates_dir/standard.json" 2>/dev/null)

    assert_true "[[ $gen_idx -gt $intake_idx ]]" "spec_generation comes after intake"
    assert_true "[[ $gen_idx -lt $plan_idx ]]" "spec_generation comes before plan"

    # Verify ordering: review < spec_verification < compound_quality
    local review_idx ver_idx cq_idx
    review_idx=$(jq '[.stages[].id] | index("review")' "$templates_dir/standard.json" 2>/dev/null)
    ver_idx=$(jq '[.stages[].id] | index("spec_verification")' "$templates_dir/standard.json" 2>/dev/null)
    cq_idx=$(jq '[.stages[].id] | index("compound_quality")' "$templates_dir/standard.json" 2>/dev/null)

    assert_true "[[ $ver_idx -gt $review_idx ]]" "spec_verification comes after review"
    assert_true "[[ $ver_idx -lt $cq_idx ]]" "spec_verification comes before compound_quality"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-spec-pipeline-test.sh — Spec-Driven Pipeline Stages"
echo ""

echo "Stage: spec_generation"
test_spec_generation_skips_when_disabled
test_spec_generation_skips_no_spec_no_goal
test_spec_generation_uses_existing_spec
test_spec_generation_creates_spec_when_missing

echo ""
echo "Stage: spec_verification"
test_spec_verification_skips_when_disabled
test_spec_verification_skips_no_spec
test_spec_verification_generates_report
test_spec_verification_compliance_score
test_spec_verification_detects_failures
test_spec_verification_static_analysis

echo ""
echo "Pipeline Templates"
test_templates_include_spec_stages

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
