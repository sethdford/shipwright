#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline test — E2E validation invoking the REAL pipeline          ║
# ║  Every test runs cct-pipeline.sh as a subprocess · No logic reimpl.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_PIPELINE_SCRIPT="$SCRIPT_DIR/cct-pipeline.sh"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT SETUP
# Creates the complete temp structure that the real pipeline needs:
#   $TEMP_DIR/
#   ├── scripts/cct-pipeline.sh   (copy of real)
#   ├── scripts/cct-loop.sh       (mock)
#   ├── templates/pipelines/      (default template + per-test overrides)
#   ├── bin/claude|gh|cct          (mocks on PATH)
#   ├── remote.git/                (bare repo for git push)
#   └── project/                   (mock git repo — tests cd here)
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-pipeline-test.XXXXXX")

    # ── Copy real pipeline script ─────────────────────────────────────────
    mkdir -p "$TEMP_DIR/scripts"
    cp "$REAL_PIPELINE_SCRIPT" "$TEMP_DIR/scripts/cct-pipeline.sh"

    # ── Mock cct-loop.sh (next to pipeline — preflight checks $SCRIPT_DIR/cct-loop.sh) ──
    cat > "$TEMP_DIR/scripts/cct-loop.sh" <<'LOOP_EOF'
#!/usr/bin/env bash
# Mock cct-loop: simulate build by creating a feature file and committing
mkdir -p src
cat > src/feature.js <<'FEAT'
function authenticate(token) { return token && token.length > 0; }
module.exports = { authenticate };
FEAT
git add src/feature.js
git commit -m "feat: implement feature" --quiet --allow-empty 2>/dev/null || true
LOOP_EOF
    chmod +x "$TEMP_DIR/scripts/cct-loop.sh"

    # ── Copy pipeline templates ───────────────────────────────────────────
    mkdir -p "$TEMP_DIR/templates/pipelines"
    if [[ -d "$REPO_DIR/templates/pipelines" ]]; then
        cp "$REPO_DIR/templates/pipelines"/*.json "$TEMP_DIR/templates/pipelines/" 2>/dev/null || true
    fi
    # Ensure at least a standard template exists
    if [[ ! -f "$TEMP_DIR/templates/pipelines/standard.json" ]]; then
        write_standard_template
    fi

    # ── Mock binaries ─────────────────────────────────────────────────────
    mkdir -p "$TEMP_DIR/bin"
    create_mock_claude
    create_mock_gh
    create_mock_cct

    # ── Mock project git repo ─────────────────────────────────────────────
    create_mock_project

    # ── Bare repo for git push ────────────────────────────────────────────
    git init --quiet --bare "$TEMP_DIR/remote.git" 2>/dev/null

    # ── Wire up git remotes ───────────────────────────────────────────────
    # Push URL → local bare repo (so git push works)
    # Fetch URL → fake GitHub URL (so gh_init() detects REPO_OWNER/REPO_NAME)
    (
        cd "$TEMP_DIR/project"
        git remote add origin "$TEMP_DIR/remote.git"
        git push -u origin main --quiet 2>/dev/null
        git remote set-url origin "https://github.com/test-org/test-repo.git"
        git config remote.origin.pushurl "$TEMP_DIR/remote.git"
    )
}

write_standard_template() {
    cat > "$TEMP_DIR/templates/pipelines/standard.json" <<'TMPL'
{
  "name": "standard",
  "description": "Standard pipeline for tests",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "stages": [
    { "id": "intake",   "enabled": true,  "gate": "auto", "config": {} },
    { "id": "plan",     "enabled": true,  "gate": "auto", "config": { "model": "opus" } },
    { "id": "build",    "enabled": true,  "gate": "auto", "config": { "max_iterations": 20 } },
    { "id": "test",     "enabled": true,  "gate": "auto", "config": { "coverage_min": 0 } },
    { "id": "review",   "enabled": true,  "gate": "auto", "config": {} },
    { "id": "pr",       "enabled": true,  "gate": "auto", "config": { "wait_ci": false } },
    { "id": "deploy",   "enabled": false, "gate": "auto", "config": {} },
    { "id": "validate", "enabled": false, "gate": "auto", "config": {} }
  ]
}
TMPL
}

# Generate a pipeline config with only specified stages enabled
# Usage: pipeline_config_with_stages "intake,plan,build"
pipeline_config_with_stages() {
    local enabled_csv="$1"
    local all_stages=("intake" "plan" "build" "test" "review" "pr" "deploy" "validate")
    local json='{ "name": "test-custom", "description": "Custom test pipeline",'
    json+=' "defaults": { "test_cmd": "echo all-tests-passed", "model": "opus", "agents": 1 },'
    json+=' "stages": ['
    local first=true
    for s in "${all_stages[@]}"; do
        local enabled="false"
        if echo ",$enabled_csv," | grep -q ",$s,"; then
            enabled="true"
        fi
        $first || json+=","
        first=false
        json+=" {\"id\":\"$s\",\"enabled\":$enabled,\"gate\":\"auto\",\"config\":{}}"
    done
    json+=' ] }'
    echo "$json"
}

create_mock_claude() {
    cat > "$TEMP_DIR/bin/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
# Mock claude CLI — detects plan vs review from prompt content
prompt=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --print|--output-format) shift ;;
        --model|--max-turns)     shift 2 ;;
        -p)                      shift 2 ;;
        *)                       prompt="$1"; shift ;;
    esac
done

if echo "$prompt" | grep -qiE "implementation plan|task checklist|create a.*plan"; then
    cat <<'PLAN'
# Implementation Plan

## Files to Modify
- src/feature.js — New auth module
- tests/feature.test.js — Tests for auth

## Implementation Steps
1. Create authentication module
2. Add token validation
3. Write unit tests

### Task Checklist
- [ ] Create auth module in src/feature.js
- [ ] Add token validation logic
- [ ] Write unit tests for auth
- [ ] Add error handling for invalid tokens
- [ ] Update API documentation

### Testing Approach
Run the test suite to verify auth works end to end.

### Definition of Done
- [ ] All tests pass
- [ ] Code reviewed
- [ ] No security vulnerabilities
PLAN
elif echo "$prompt" | grep -qiE "review|reviewer|diff"; then
    cat <<'REVIEW'
# Code Review

## Findings

- **[Warning]** src/feature.js:3 — Missing input validation for empty strings
- **[Bug]** src/feature.js:1 — Function name could be more descriptive
- **[Suggestion]** src/feature.js:2 — Consider using strict equality check

## Summary
3 issues found: 0 critical, 1 bug, 1 warning, 1 suggestion.
Code is generally acceptable with minor improvements recommended.
REVIEW
else
    echo "Mock claude: unrecognized prompt context"
fi
CLAUDE_EOF
    chmod +x "$TEMP_DIR/bin/claude"
}

create_mock_gh() {
    cat > "$TEMP_DIR/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
# Mock gh CLI — routes by subcommand
case "$1" in
    auth)
        # gh auth status → success
        exit 0
        ;;
    issue)
        case "$2" in
            view)
                # gh issue view N --json ...
                issue_num="$3"
                cat <<ISSUE_JSON
{
  "title": "Add JWT authentication to API",
  "body": "We need JWT auth for the /users endpoint.\\n\\nAcceptance criteria:\\n- Token validation\\n- 401 on invalid token",
  "labels": [{"name": "feature"}, {"name": "priority/high"}],
  "milestone": {"title": "v2.0"},
  "assignees": [],
  "comments": [],
  "number": ${issue_num:-42},
  "state": "OPEN"
}
ISSUE_JSON
                ;;
            comment|edit)
                # gh issue comment/edit → silent success
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    pr)
        case "$2" in
            create)
                echo "https://github.com/test-org/test-repo/pull/1"
                ;;
            checks)
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    api)
        # gh api → return JSON with comment id for progress tracking
        if echo "$*" | grep -q "comments"; then
            echo '{"id": 12345}'
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GH_EOF
    chmod +x "$TEMP_DIR/bin/gh"
}

create_mock_cct() {
    # The pipeline calls `cct loop "${loop_args[@]}"` in stage_build
    cat > "$TEMP_DIR/bin/cct" <<MOCK_CCT
#!/usr/bin/env bash
# Mock cct CLI — handles loop subcommand
case "\$1" in
    loop)
        # Simulate build: create feature file and commit
        mkdir -p src
        cat > src/feature.js <<'FEAT'
function authenticate(token) { return token && token.length > 0; }
module.exports = { authenticate };
FEAT
        git add src/feature.js
        git commit -m "feat: implement feature" --quiet --allow-empty 2>/dev/null || true
        ;;
    *)
        exit 0
        ;;
esac
MOCK_CCT
    chmod +x "$TEMP_DIR/bin/cct"
}

create_mock_project() {
    mkdir -p "$TEMP_DIR/project/src" "$TEMP_DIR/project/tests"

    # package.json (so detect_test_cmd returns "npm test")
    cat > "$TEMP_DIR/project/package.json" <<'PKG'
{
  "name": "test-project",
  "version": "1.0.0",
  "scripts": { "test": "echo 'All 5 tests passed'" },
  "dependencies": {}
}
PKG

    cat > "$TEMP_DIR/project/src/index.js" <<'SRC'
const express = require('express');
const app = express();
app.get('/health', (req, res) => res.json({ status: 'ok' }));
module.exports = app;
SRC

    cat > "$TEMP_DIR/project/tests/index.test.js" <<'TST'
describe('health', () => {
  it('should return ok', () => { expect(true).toBe(true); });
});
TST

    (
        cd "$TEMP_DIR/project"
        git init --quiet -b main
        git config user.email "test@test.com"
        git config user.name "Test User"
        git add -A
        git commit -m "Initial commit" --quiet
    )
}

# Reset project state between tests (keeps the base env, resets git + artifacts)
reset_test() {
    (
        cd "$TEMP_DIR/project"
        # Remove pipeline artifacts
        rm -rf .claude 2>/dev/null || true
        # Reset to main branch, remove feature branches
        git checkout main --quiet 2>/dev/null || true
        local branches
        branches=$(git branch --list | grep -v '^\* *main$' | grep -v '^ *main$' || true)
        if [[ -n "$branches" ]]; then
            echo "$branches" | xargs git branch -D --quiet 2>/dev/null || true
        fi
        # Remove any build artifacts
        rm -f src/feature.js 2>/dev/null || true
        git checkout -- . 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true
    )
    # Reset the remote bare repo
    rm -rf "$TEMP_DIR/remote.git"
    git init --quiet --bare "$TEMP_DIR/remote.git" 2>/dev/null
    (
        cd "$TEMP_DIR/project"
        git config remote.origin.pushurl "$TEMP_DIR/remote.git"
        git push -u origin main --quiet 2>/dev/null || true
    )
    # Remove self-healing markers
    rm -f "$TEMP_DIR/self-heal-marker" 2>/dev/null || true
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE INVOCATION HELPER
# Every test calls this to invoke the REAL pipeline as a subprocess.
# ═══════════════════════════════════════════════════════════════════════════════

# Run the real pipeline and capture output + exit code.
# Usage: run_pipeline <subcommand> [args...]
# Sets: PIPELINE_OUTPUT, PIPELINE_EXIT
PIPELINE_OUTPUT=""
PIPELINE_EXIT=0

invoke_pipeline() {
    local subcommand="$1"
    shift
    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0

    # Invoke the REAL pipeline script as a subprocess
    PIPELINE_OUTPUT=$(
        cd "$TEMP_DIR/project"
        PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/cct-pipeline.sh" "$subcommand" "$@" 2>&1
    ) || PIPELINE_EXIT=$?
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS — verify pipeline outputs without reimplementing logic
# ═══════════════════════════════════════════════════════════════════════════════

assert_exit_code() {
    local expected="$1" label="${2:-exit code}"
    if [[ "$PIPELINE_EXIT" -eq "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit code $expected, got $PIPELINE_EXIT ($label)"
    return 1
}

assert_output_contains() {
    local pattern="$1" label="${2:-output match}"
    if printf '%s\n' "$PIPELINE_OUTPUT" | grep -qiE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $pattern ($label)"
    echo -e "    ${DIM}Output (last 5 lines):${RESET}"
    echo "$PIPELINE_OUTPUT" | tail -5 | sed 's/^/      /'
    return 1
}

assert_output_not_contains() {
    local pattern="$1" label="${2:-output exclusion}"
    if ! printf '%s\n' "$PIPELINE_OUTPUT" | grep -qiE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $pattern ($label)"
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    local full_path="$TEMP_DIR/project/$filepath"
    if [[ -f "$full_path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_file_not_exists() {
    local filepath="$1" label="${2:-file absent}"
    local full_path="$TEMP_DIR/project/$filepath"
    if [[ ! -f "$full_path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File should not exist: $filepath ($label)"
    return 1
}

assert_file_contains() {
    local filepath="$1" pattern="$2" label="${3:-file content}"
    local full_path="$TEMP_DIR/project/$filepath"
    if [[ ! -f "$full_path" ]]; then
        echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
        return 1
    fi
    if grep -qiE "$pattern" "$full_path"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File $filepath missing pattern: $pattern ($label)"
    return 1
}

assert_branch_exists() {
    local pattern="$1" label="${2:-branch exists}"
    local branches
    branches=$(cd "$TEMP_DIR/project" && git branch --list 2>/dev/null)
    if printf '%s\n' "$branches" | grep -qE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} No branch matching: $pattern ($label)"
    echo -e "    ${DIM}Branches: $(echo "$branches" | tr '\n' ' ')${RESET}"
    return 1
}

assert_state_contains() {
    local pattern="$1" label="${2:-state check}"
    assert_file_contains ".claude/pipeline-state.md" "$pattern" "$label"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

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
# TESTS — Each invokes the REAL pipeline. NO logic reimplementation.
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Preflight passes with all mocks in place
# ──────────────────────────────────────────────────────────────────────────────
test_preflight_passes() {
    invoke_pipeline start --goal "Test preflight" --skip-gates --dry-run
    assert_exit_code 0 "dry-run should succeed" &&
    assert_output_contains "Pre-flight passed" "preflight check"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Preflight fails when cct-loop.sh is missing
# ──────────────────────────────────────────────────────────────────────────────
test_preflight_fails_missing_loop() {
    # Temporarily remove cct-loop.sh
    mv "$TEMP_DIR/scripts/cct-loop.sh" "$TEMP_DIR/scripts/cct-loop.sh.bak"

    invoke_pipeline start --goal "Test missing loop" --skip-gates --dry-run

    # Restore
    mv "$TEMP_DIR/scripts/cct-loop.sh.bak" "$TEMP_DIR/scripts/cct-loop.sh"

    assert_exit_code 1 "should fail preflight" &&
    assert_output_contains "cct-loop" "should mention cct-loop"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Start requires --goal or --issue
# ──────────────────────────────────────────────────────────────────────────────
test_start_requires_goal_or_issue() {
    invoke_pipeline start --skip-gates
    assert_exit_code 1 "should fail without goal/issue" &&
    assert_output_contains "Must provide" "error message"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Intake with inline --goal creates branch + artifacts
# ──────────────────────────────────────────────────────────────────────────────
test_intake_inline() {
    # Use intake-only template so pipeline stops after intake
    pipeline_config_with_stages "intake" > "$TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add JWT auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact" &&
    assert_file_contains ".claude/pipeline-artifacts/intake.json" "JWT" "goal in intake" &&
    assert_branch_exists "feat/.*jwt" "feature branch created" &&
    assert_state_contains "intake.*complete" "intake marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Intake with --issue fetches from mock gh
# ──────────────────────────────────────────────────────────────────────────────
test_intake_issue() {
    pipeline_config_with_stages "intake" > "$TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --issue 42 --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact" &&
    assert_file_contains ".claude/pipeline-artifacts/intake.json" "42" "issue number in intake" &&
    assert_branch_exists "42" "branch includes issue number" &&
    assert_output_contains "Issue #42" "output shows issue number"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Plan stage generates plan.md, dod.md, and pipeline-tasks.md
# ──────────────────────────────────────────────────────────────────────────────
test_plan_generates_artifacts() {
    pipeline_config_with_stages "intake,plan" > "$TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth module" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan generated" &&
    assert_file_contains ".claude/pipeline-artifacts/plan.md" "Task Checklist" "plan has checklist" &&
    assert_file_exists ".claude/pipeline-artifacts/dod.md" "definition of done extracted" &&
    assert_file_exists ".claude/pipeline-tasks.md" "task tracking file" &&
    assert_file_contains ".claude/pipeline-tasks.md" "\\- \\[" "tasks have checkboxes" &&
    assert_file_exists ".claude/tasks.md" "Claude Code task list" &&
    assert_file_contains ".claude/tasks.md" "Checklist" "CC task list has checklist section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Build stage invokes cct loop and produces commits
# ──────────────────────────────────────────────────────────────────────────────
test_build_invokes_cct() {
    pipeline_config_with_stages "intake,plan,build" > "$TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists "src/feature.js" "build created feature file" &&
    assert_state_contains "build.*complete" "build marked complete"

    # Verify a commit exists with "feat:" prefix (from mock cct loop)
    local commits
    commits=$(cd "$TEMP_DIR/project" && git log --oneline 2>/dev/null)
    if ! printf '%s\n' "$commits" | grep -q "feat:" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} No 'feat:' commit found"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Test stage captures results to log file
# ──────────────────────────────────────────────────────────────────────────────
test_test_captures_results() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo 'All 8 tests passed'"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/test-results.log" "test log" &&
    assert_file_contains ".claude/pipeline-artifacts/test-results.log" "passed" "test output captured" &&
    assert_state_contains "test.*complete" "test marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Review stage generates review.md with severity markers
# ──────────────────────────────────────────────────────────────────────────────
test_review_generates_report() {
    pipeline_config_with_stages "intake,plan,build,test,review" > "$TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/review.md" "review generated" &&
    assert_file_contains ".claude/pipeline-artifacts/review.md" "Warning|Bug|Suggestion" "review has severity markers" &&
    assert_state_contains "review.*complete" "review marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. PR stage creates PR URL artifact
# ──────────────────────────────────────────────────────────────────────────────
test_pr_creates_url() {
    pipeline_config_with_stages "intake,plan,build,test,review,pr" > "$TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/pr-url.txt" "PR URL saved" &&
    assert_file_contains ".claude/pipeline-artifacts/pr-url.txt" "github.com" "PR URL is a GitHub link" &&
    assert_state_contains "pr.*complete" "pr marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Full E2E pipeline — all 6 enabled stages complete
# ──────────────────────────────────────────────────────────────────────────────
test_full_pipeline_e2e() {
    # Restore real standard template with all gates set to auto
    write_standard_template

    invoke_pipeline start --goal "Add JWT authentication" --skip-gates --test-cmd "echo 'All tests passed'"

    assert_exit_code 0 "full pipeline should complete" &&
    assert_output_contains "Pipeline complete" "completion message" &&
    assert_state_contains "status: complete" "final status" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan artifact" &&
    assert_file_exists ".claude/pipeline-artifacts/test-results.log" "test log" &&
    assert_file_exists ".claude/pipeline-artifacts/review.md" "review artifact" &&
    assert_file_exists ".claude/pipeline-artifacts/pr-url.txt" "PR URL"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Resume continues from partial state
# ──────────────────────────────────────────────────────────────────────────────
test_resume() {
    # Step 1: Run intake-only pipeline to create real state + branch
    pipeline_config_with_stages "intake" > "$TEMP_DIR/templates/pipelines/standard.json"
    invoke_pipeline start --goal "Resume test feature" --skip-gates --test-cmd "echo passed"

    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Setup failed: intake didn't complete"
        return 1
    fi

    # Step 2: Read back the branch name from state
    local branch_name
    branch_name=$(sed -n 's/^branch: *"*\([^"]*\)"*/\1/p' "$TEMP_DIR/project/.claude/pipeline-state.md" | head -1)

    # Step 3: Modify state to look like an interrupted pipeline with intake done
    # and update the template to include plan stage
    pipeline_config_with_stages "intake,plan" > "$TEMP_DIR/templates/pipelines/standard.json"

    # Rewrite status from "complete" to "interrupted" so resume will continue
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' 's/^status: complete$/status: interrupted/' "$TEMP_DIR/project/.claude/pipeline-state.md"
    else
        sed -i 's/^status: complete$/status: interrupted/' "$TEMP_DIR/project/.claude/pipeline-state.md"
    fi

    # Step 4: Resume — should skip intake, run plan
    invoke_pipeline resume

    assert_exit_code 0 "resume should complete" &&
    assert_output_contains "Resum" "resume message" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan generated after resume" &&
    assert_state_contains "plan.*complete" "plan completed after resume"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Abort marks pipeline as aborted
# ──────────────────────────────────────────────────────────────────────────────
test_abort() {
    # Create a state file that looks like a running pipeline
    mkdir -p "$TEMP_DIR/project/.claude/pipeline-artifacts"
    cat > "$TEMP_DIR/project/.claude/pipeline-state.md" <<'STATE'
---
pipeline: standard
goal: "Abort test feature"
status: running
issue: ""
branch: "feat/abort-test"
current_stage: build
started_at: 2024-01-01T00:00:00Z
updated_at: 2024-01-01T00:00:00Z
elapsed: 30s
stages:
  intake: complete
  plan: complete
---

## Log
### intake (12:00:00)
Goal: Abort test feature
STATE

    invoke_pipeline abort

    assert_exit_code 0 "abort should succeed" &&
    assert_state_contains "status: aborted" "state shows aborted" &&
    assert_output_contains "aborted" "abort message"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Dry run shows config but creates no stage artifacts
# ──────────────────────────────────────────────────────────────────────────────
test_dry_run() {
    write_standard_template

    invoke_pipeline start --goal "Dry run test" --skip-gates --dry-run

    assert_exit_code 0 "dry-run should succeed" &&
    assert_output_contains "Dry run" "dry-run message" &&
    assert_output_contains "Pipeline.*standard" "shows pipeline name" &&
    assert_file_not_exists ".claude/pipeline-artifacts/intake.json" "no intake artifact" &&
    assert_file_not_exists ".claude/pipeline-artifacts/plan.md" "no plan artifact"

    # Verify no feature branches were created
    local branches
    branches=$(cd "$TEMP_DIR/project" && git branch --list | grep -v main || true)
    if [[ -n "$branches" ]]; then
        echo -e "    ${RED}✗${RESET} Feature branches created during dry-run: $branches"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Self-healing build→test retry loop
# ──────────────────────────────────────────────────────────────────────────────
test_self_healing() {
    # Use a template with build + test enabled (triggers self-healing loop)
    pipeline_config_with_stages "intake,plan,build,test" > "$TEMP_DIR/templates/pipelines/standard.json"

    # Test script that fails first, then passes (using marker file).
    # Must be a separate script file — `eval "...exit 1..."` would kill the pipeline.
    local marker="$TEMP_DIR/self-heal-marker"
    cat > "$TEMP_DIR/bin/fail-then-pass-test" <<HEAL_EOF
#!/usr/bin/env bash
if [ -f "$marker" ]; then
    echo "All tests passed"
    exit 0
else
    touch "$marker"
    echo "FAIL: expected 401 got 403"
    exit 1
fi
HEAL_EOF
    chmod +x "$TEMP_DIR/bin/fail-then-pass-test"

    invoke_pipeline start --goal "Fix auth bug" --skip-gates --test-cmd "$TEMP_DIR/bin/fail-then-pass-test" --self-heal 2

    assert_exit_code 0 "self-healing should eventually succeed" &&
    assert_output_contains "Self-[Hh]ealing" "shows self-healing message" &&
    assert_state_contains "test.*complete" "test eventually passes"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright pipeline test — E2E Validation (Real Subprocess)     ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the real pipeline script exists
    if [[ ! -f "$REAL_PIPELINE_SCRIPT" ]]; then
        echo -e "${RED}✗ Pipeline script not found: $REAL_PIPELINE_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available (required by pipeline)
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up mock environment...${RESET}"
    setup_env
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_preflight_passes:Preflight passes with all mocks"
        "test_preflight_fails_missing_loop:Preflight fails when cct-loop.sh missing"
        "test_start_requires_goal_or_issue:Start requires --goal or --issue"
        "test_intake_inline:Intake with --goal creates branch + artifacts"
        "test_intake_issue:Intake with --issue fetches from GitHub"
        "test_plan_generates_artifacts:Plan generates plan.md, dod.md, tasks"
        "test_build_invokes_cct:Build invokes cct loop and commits"
        "test_test_captures_results:Test stage captures results to log"
        "test_review_generates_report:Review generates report with severities"
        "test_pr_creates_url:PR stage creates PR URL artifact"
        "test_full_pipeline_e2e:Full E2E pipeline (6 stages)"
        "test_resume:Resume continues from partial state"
        "test_abort:Abort marks pipeline as aborted"
        "test_dry_run:Dry run shows config, no artifacts"
        "test_self_healing:Self-healing build→test retry loop"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
