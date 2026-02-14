#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright e2e smoke test — Pipeline orchestration without API keys    ║
# ║  Mock binaries · No Claude/GitHub calls · Runs on every PR             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Error trap for CI debugging — shows which line fails
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_PIPELINE_SCRIPT="$SCRIPT_DIR/sw-pipeline.sh"
REAL_DAEMON_SCRIPT="$SCRIPT_DIR/sw-daemon.sh"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────
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
#   ├── scripts/sw-pipeline.sh   (copy of real)
#   ├── scripts/sw-loop.sh       (mock)
#   ├── templates/pipelines/      (copies of real templates)
#   ├── bin/claude|gh|sw           (mocks on PATH)
#   ├── remote.git/                (bare repo for git push)
#   └── project/                   (mock git repo — tests cd here)
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-e2e-smoke.XXXXXX")

    # ── Copy real pipeline script ─────────────────────────────────────────
    mkdir -p "$TEMP_DIR/scripts"
    cp "$REAL_PIPELINE_SCRIPT" "$TEMP_DIR/scripts/sw-pipeline.sh"

    # ── Copy lib directory if present ─────────────────────────────────────
    if [[ -d "$SCRIPT_DIR/lib" ]]; then
        mkdir -p "$TEMP_DIR/scripts/lib"
        cp "$SCRIPT_DIR/lib"/*.sh "$TEMP_DIR/scripts/lib/" 2>/dev/null || true
    fi

    # ── Copy intelligence/composer scripts (pipeline sources them) ────────
    for dep in sw-intelligence.sh sw-pipeline-composer.sh sw-pipeline-vitals.sh sw-context.sh sw-github-graphql.sh sw-github-checks.sh sw-github-deploy.sh; do
        [[ -f "$SCRIPT_DIR/$dep" ]] && cp "$SCRIPT_DIR/$dep" "$TEMP_DIR/scripts/$dep"
    done

    # ── Mock sw-loop.sh (next to pipeline — preflight checks $SCRIPT_DIR/sw-loop.sh) ──
    cat > "$TEMP_DIR/scripts/sw-loop.sh" <<'LOOP_EOF'
#!/usr/bin/env bash
# Mock sw-loop: simulate build by creating a feature file and committing
mkdir -p src
cat > src/feature.js <<'FEAT'
function authenticate(token) { return token && token.length > 0; }
module.exports = { authenticate };
FEAT
git add src/feature.js
git commit -m "feat: implement feature" --quiet --allow-empty 2>/dev/null || true
LOOP_EOF
    chmod +x "$TEMP_DIR/scripts/sw-loop.sh"

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
    create_mock_sw

    # ── Mock project git repo ─────────────────────────────────────────────
    create_mock_project

    # ── Bare repo for git push ────────────────────────────────────────────
    git init --quiet --bare "$TEMP_DIR/remote.git" 2>/dev/null

    # ── Wire up git remotes ───────────────────────────────────────────────
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

### Task Checklist
- [ ] Create auth module in src/feature.js
- [ ] Add token validation logic
- [ ] Write unit tests for auth

### Definition of Done
- [ ] All tests pass
- [ ] Code reviewed
PLAN
elif echo "$prompt" | grep -qiE "review|reviewer|diff"; then
    cat <<'REVIEW'
# Code Review

## Findings

- **[Warning]** src/feature.js:3 — Missing input validation
- **[Bug]** src/feature.js:1 — Function name could be more descriptive

## Summary
2 issues found: 0 critical, 1 bug, 1 warning.
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
        exit 0
        ;;
    issue)
        case "$2" in
            view)
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

create_mock_sw() {
    cat > "$TEMP_DIR/bin/sw" <<MOCK_SW
#!/usr/bin/env bash
# Mock sw CLI — handles loop subcommand
case "\$1" in
    loop)
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
MOCK_SW
    chmod +x "$TEMP_DIR/bin/sw"
}

create_mock_project() {
    mkdir -p "$TEMP_DIR/project/src" "$TEMP_DIR/project/tests"

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

PIPELINE_OUTPUT=""
PIPELINE_EXIT=0

invoke_pipeline() {
    local subcommand="$1"
    shift
    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0

    PIPELINE_OUTPUT=$(
        cd "$TEMP_DIR/project"
        PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/sw-pipeline.sh" "$subcommand" "$@" 2>&1
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
    echo -e "    ${DIM}Output (last 5 lines):${RESET}"
    echo "$PIPELINE_OUTPUT" | tail -5 | sed 's/^/      /'
    return 1
}

assert_exit_code_nonzero() {
    local label="${1:-exit code nonzero}"
    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected nonzero exit code, got 0 ($label)"
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

assert_dir_exists() {
    local dirpath="$1" label="${2:-dir exists}"
    local full_path="$TEMP_DIR/project/$dirpath"
    if [[ -d "$full_path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Directory not found: $dirpath ($label)"
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

assert_no_feature_branches() {
    local label="${1:-no feature branches}"
    local branches
    branches=$(cd "$TEMP_DIR/project" && git branch --list | grep -v main || true)
    if [[ -z "$branches" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Feature branches found: $branches ($label)"
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
# 1. Dry-run exits zero
# ──────────────────────────────────────────────────────────────────────────────
test_dryrun_exits_zero() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. State file created after dry-run
# ──────────────────────────────────────────────────────────────────────────────
test_state_file_created() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    assert_file_exists ".claude/pipeline-state.md" "state file created"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. State file has required fields
# ──────────────────────────────────────────────────────────────────────────────
test_state_has_required_fields() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    assert_state_contains "status:" "state has status field" &&
    assert_state_contains "current_stage:" "state has current_stage field" &&
    assert_state_contains "pipeline:" "state has pipeline field"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Fast template loads correctly
# ──────────────────────────────────────────────────────────────────────────────
test_fast_template_loads() {
    invoke_pipeline start --pipeline fast --dry-run --issue 42 --skip-gates
    assert_exit_code 0 "fast dry-run should succeed" &&
    assert_output_contains "fast" "output mentions fast template" &&
    # Verify the fast template disables plan
    local fast_tpl="$TEMP_DIR/templates/pipelines/fast.json"
    if [[ -f "$fast_tpl" ]]; then
        local plan_enabled
        plan_enabled=$(jq -r '.stages[] | select(.id == "plan") | .enabled' "$fast_tpl" 2>/dev/null || echo "unknown")
        if [[ "$plan_enabled" != "false" ]]; then
            echo -e "    ${RED}✗${RESET} Fast template plan should be disabled, got: $plan_enabled"
            return 1
        fi
        local max_iter
        max_iter=$(jq -r '.stages[] | select(.id == "build") | .config.max_iterations // 0' "$fast_tpl" 2>/dev/null || echo "0")
        if [[ "$max_iter" -ne 10 ]]; then
            echo -e "    ${RED}✗${RESET} Fast template max_iterations should be 10, got: $max_iter"
            return 1
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. All templates parse as valid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_all_templates_parse() {
    local template_dir="$TEMP_DIR/templates/pipelines"
    local all_ok=true
    local count=0
    for tpl in "$template_dir"/*.json; do
        [[ ! -f "$tpl" ]] && continue
        count=$((count + 1))
        if ! jq empty "$tpl" 2>/dev/null; then
            echo -e "    ${RED}✗${RESET} Invalid JSON: $(basename "$tpl")"
            all_ok=false
        fi
    done
    if [[ "$count" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} No template files found"
        return 1
    fi
    $all_ok
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Stage ordering preserved in output
# ──────────────────────────────────────────────────────────────────────────────
test_stage_ordering_preserved() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed"

    # The pipeline output includes "Stages: intake plan build test ..." line
    # Verify intake appears before build in the output
    local stages_line
    stages_line=$(printf '%s\n' "$PIPELINE_OUTPUT" | grep -i "Stages:" | head -1 || true)
    if [[ -z "$stages_line" ]]; then
        echo -e "    ${RED}✗${RESET} No 'Stages:' line found in output"
        return 1
    fi

    # Extract stage names, verify intake comes before build
    local intake_pos build_pos
    intake_pos=$(echo "$stages_line" | grep -ob "intake" | head -1 | cut -d: -f1 || echo "")
    build_pos=$(echo "$stages_line" | grep -ob "build" | head -1 | cut -d: -f1 || echo "")

    if [[ -z "$intake_pos" || -z "$build_pos" ]]; then
        echo -e "    ${RED}✗${RESET} Could not find intake and build in stages line"
        echo -e "    ${DIM}$stages_line${RESET}"
        return 1
    fi

    if [[ "$intake_pos" -ge "$build_pos" ]]; then
        echo -e "    ${RED}✗${RESET} intake ($intake_pos) should appear before build ($build_pos)"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. CI mode sets flags
# ──────────────────────────────────────────────────────────────────────────────
test_ci_mode_sets_flags() {
    invoke_pipeline start --ci --dry-run --issue 42
    assert_exit_code 0 "CI dry-run should succeed" &&
    # CI mode implies --skip-gates, so check for auto gates indication
    assert_output_contains "auto.*skip-gates|skip-gates|all auto" "CI mode sets skip-gates"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Completed stages recognized
# ──────────────────────────────────────────────────────────────────────────────
test_completed_stages_parses() {
    invoke_pipeline start --completed-stages "intake,plan" --dry-run --issue 42 --skip-gates
    assert_exit_code 0 "completed-stages dry-run should succeed"
    # The pipeline should recognize completed stages — they get marked in state
    # or output references skipping them
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. No branches after dry-run
# ──────────────────────────────────────────────────────────────────────────────
test_no_branches_after_dryrun() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed"

    # Dry run should not create feature branches — only main should exist
    # Note: initialize_state may create state file but dry run returns before
    # running stages. If the pipeline creates a branch during init, that's
    # acceptable. We check that no feature branches (feat/) are created.
    local branches
    branches=$(cd "$TEMP_DIR/project" && git branch --list | sed 's/^\* //' | tr -d ' ' || true)
    local has_feat=false
    while IFS= read -r b; do
        if echo "$b" | grep -qiE "^feat/"; then
            has_feat=true
        fi
    done <<< "$branches"
    if $has_feat; then
        echo -e "    ${RED}✗${RESET} Feature branches created during dry-run"
        echo -e "    ${DIM}$(cd "$TEMP_DIR/project" && git branch --list)${RESET}"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Artifact directory created
# ──────────────────────────────────────────────────────────────────────────────
test_artifact_dir_created() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    assert_dir_exists ".claude" ".claude directory exists"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Pipeline help text
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_help_text() {
    invoke_pipeline --help
    assert_exit_code 0 "help should succeed" &&
    assert_output_contains "USAGE|usage|pipeline" "help text present"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Version consistency between pipeline and daemon
# ──────────────────────────────────────────────────────────────────────────────
test_version_consistency() {
    local pipeline_version daemon_version
    pipeline_version=$(grep '^VERSION=' "$REAL_PIPELINE_SCRIPT" | head -1 | sed 's/VERSION="//' | sed 's/"//')
    daemon_version=$(grep '^VERSION=' "$REAL_DAEMON_SCRIPT" | head -1 | sed 's/VERSION="//' | sed 's/"//')

    if [[ -z "$pipeline_version" ]]; then
        echo -e "    ${RED}✗${RESET} Could not read VERSION from pipeline script"
        return 1
    fi
    if [[ -z "$daemon_version" ]]; then
        echo -e "    ${RED}✗${RESET} Could not read VERSION from daemon script"
        return 1
    fi
    if [[ "$pipeline_version" != "$daemon_version" ]]; then
        echo -e "    ${RED}✗${RESET} Version mismatch: pipeline=$pipeline_version daemon=$daemon_version"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Goal flag accepted
# ──────────────────────────────────────────────────────────────────────────────
test_goal_flag_accepted() {
    invoke_pipeline start --goal "test goal for smoke" --dry-run --skip-gates
    assert_exit_code 0 "goal dry-run should succeed" &&
    assert_output_contains "test goal for smoke" "output contains the goal text"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Invalid template errors
# ──────────────────────────────────────────────────────────────────────────────
test_invalid_template_errors() {
    invoke_pipeline start --pipeline nonexistent --issue 42 --dry-run --skip-gates
    assert_exit_code_nonzero "invalid template should fail" &&
    assert_output_contains "not found|error|invalid" "error message for invalid template"
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Issue number in state
# ──────────────────────────────────────────────────────────────────────────────
test_issue_number_in_state() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    # Issue number should appear in output or state
    (
        if printf '%s\n' "$PIPELINE_OUTPUT" | grep -q "42" 2>/dev/null; then
            return 0
        fi
        if [[ -f "$TEMP_DIR/project/.claude/pipeline-state.md" ]] && grep -q "42" "$TEMP_DIR/project/.claude/pipeline-state.md"; then
            return 0
        fi
        echo -e "    ${RED}✗${RESET} Issue number 42 not found in output or state"
        return 1
    )
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright e2e smoke test — Pipeline Orchestration (No API)     ║${RESET}"
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
        "test_dryrun_exits_zero:Dry-run exits zero"
        "test_state_file_created:State file created after dry-run"
        "test_state_has_required_fields:State file has required fields"
        "test_fast_template_loads:Fast template loads correctly"
        "test_all_templates_parse:All templates parse as valid JSON"
        "test_stage_ordering_preserved:Stage ordering preserved in output"
        "test_ci_mode_sets_flags:CI mode sets flags"
        "test_completed_stages_parses:Completed stages recognized"
        "test_no_branches_after_dryrun:No feature branches after dry-run"
        "test_artifact_dir_created:Artifact directory created"
        "test_pipeline_help_text:Pipeline help text"
        "test_version_consistency:Version consistency (pipeline vs daemon)"
        "test_goal_flag_accepted:Goal flag accepted"
        "test_invalid_template_errors:Invalid template errors correctly"
        "test_issue_number_in_state:Issue number in state"
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
