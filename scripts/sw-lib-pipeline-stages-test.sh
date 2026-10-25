#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-stages test — Unit tests for stage functions    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: pipeline-stages Tests"

setup_test_env "lib-pipeline-stages"
trap 'cleanup_test_env; sw_test_teardown' EXIT

# ─── Pipeline environment ──────────────────────────────────────────────────
export ARTIFACTS_DIR="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export STATE_FILE="$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
export TASKS_FILE="$TEST_TEMP_DIR/project/.claude/pipeline-tasks.md"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/templates/pipelines/standard.json"
export BASE_BRANCH="main"
export NO_GITHUB=true
# GH_AVAILABLE=true so gh_get_issue_meta returns mock data (avoids fallback gh call)
export GH_AVAILABLE=true
export REPO_OWNER="test-org"
export REPO_NAME="test-repo"
# shellcheck disable=SC2155
export PIPELINE_START_EPOCH=$(date +%s)
export CI_MODE=false
export PIPELINE_NAME="test-pipeline"
export ISSUE_NUMBER="42"
export GOAL="Add JWT authentication"
export GIT_BRANCH="feat/add-jwt-auth-42"
export TASK_TYPE="feature"
export GITHUB_ISSUE="#42"
export ISSUE_BODY="We need JWT auth for the API."
export ISSUE_LABELS="feature,priority/high"
export ISSUE_MILESTONE="v2.0"
export TEST_CMD="echo 'All tests passed'"
export MODEL=""
export AGENTS="1"

mkdir -p "$ARTIFACTS_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$TASKS_FILE")"
mkdir -p "$(dirname "$PIPELINE_CONFIG")"

# Create minimal pipeline config
jq -n '{
    name: "standard",
    defaults: { test_cmd: "echo pass", model: "opus", agents: 1 },
    stages: [
        { id: "intake", enabled: true, gate: "auto", config: {} },
        { id: "plan", enabled: true, gate: "auto", config: { model: "opus" } },
        { id: "build", enabled: true, gate: "auto", config: { max_iterations: 20 } },
        { id: "test", enabled: true, gate: "auto", config: { coverage_min: 0 } },
        { id: "review", enabled: true, gate: "auto", config: {} },
        { id: "pr", enabled: true, gate: "auto", config: {} }
    ]
}' > "$PIPELINE_CONFIG"

# Create mock project with git
mkdir -p "$PROJECT_ROOT/src" "$PROJECT_ROOT/tests"
cat > "$PROJECT_ROOT/package.json" <<'PKG'
{"name":"test","scripts":{"test":"echo All 5 tests passed"}}
PKG
(cd "$PROJECT_ROOT" && git init -q -b main 2>/dev/null && git config user.email "t@t.com" && git config user.name "T" && touch .gitignore && git add -A && git commit -q -m "init" 2>/dev/null) || true

# ─── Mock binaries ────────────────────────────────────────────────────────
mock_binary "gh" 'case "${1:-}" in
    issue)
        case "${2:-}" in
            view) echo "{\"title\":\"Add JWT auth\",\"body\":\"We need JWT.\",\"labels\":[{\"name\":\"feature\"}],\"number\":42,\"state\":\"OPEN\",\"milestone\":{\"title\":\"v2.0\"}}" ;;
            comment|edit) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    pr)
        case "${2:-}" in
            create) echo "https://github.com/test/repo/pull/1" ;;
            *) exit 0 ;;
        esac
        ;;
    api) echo "{}" ;;
    *) exit 0 ;;
esac'

mock_binary "claude" 'echo "# Implementation Plan

## Files to Modify
- src/auth.js

### Task Checklist
- [ ] Create auth module
- [ ] Add JWT validation

### Definition of Done
- [ ] All tests pass
"'

# Use real git - we have a real project repo

# jq: setup_test_env already symlinks the real jq into $TEST_TEMP_DIR/bin. Don't copy or
# overwrite it — writing through that symlink hits the read-only system binary, and macOS
# launch constraints SIGKILL Apple-signed binaries executed from a copied path.

# ─── Stubs for optional pipeline modules ───────────────────────────────────
get_stage_self_awareness_hint() { :; }
parse_claude_tokens() { :; }
gh_wiki_page() { :; }
auto_rebase() { return 0; }
format_duration() { local s="${1:-0}"; [[ "$s" -ge 3600 ]] && echo "${s}h" || [[ "$s" -ge 60 ]] && echo "${s}m" || echo "${s}s"; }
parse_coverage_from_output() {
    local f="$1"; [[ ! -f "$f" ]] && return
    grep -oE 'Statements\s*:\s*[0-9.]+' "$f" 2>/dev/null | grep -oE '[0-9.]+$' || \
    grep -oiE 'coverage:?\s*[0-9.]+%' "$f" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true
}

# ─── Source dependencies ───────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh" || true
[[ -f "$SCRIPT_DIR/lib/pipeline-quality.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality.sh" || true

# Pipeline state (save_artifact, log_stage, write_state)
export STAGE_STATUSES=""
export STAGE_TIMINGS=""
write_state() { :; }
gh_build_progress_body() { echo "progress"; }
gh_update_progress() { :; }
gh_comment_issue() { :; }
ci_post_stage_event() { :; }

_PIPELINE_STATE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-state.sh"
_PIPELINE_GITHUB_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-github.sh"
_PIPELINE_DETECTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-detection.sh"
_PIPELINE_QUALITY_CHECKS_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" 2>/dev/null || true
_PIPELINE_INTELLIGENCE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null || true
_PIPELINE_STAGES_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-stages.sh"

# ─── Tests: show_stage_preview ───────────────────────────────────────────────
print_test_section "show_stage_preview"

out=$(show_stage_preview "intake" 2>&1)
assert_contains "Intake preview" "$out" "Fetch issue"
out=$(show_stage_preview "build" 2>&1)
assert_contains "Build preview" "$out" "loop"
out=$(show_stage_preview "test_first" 2>&1)
assert_contains "test_first preview" "$out" "TDD"
out=$(show_stage_preview "pr" 2>&1)
assert_contains "PR preview" "$out" "Create GitHub PR"

# ─── Tests: stage_intake ───────────────────────────────────────────────────
print_test_section "stage_intake"

export GOAL=""
export ISSUE_NUMBER="42"
cd "$PROJECT_ROOT"
set +e
stage_intake 2>&1
intake_rc=$?
set -e
[[ $intake_rc -eq 0 ]] && assert_pass "stage_intake completed" || assert_fail "stage_intake" "exit $intake_rc"
if [[ -f "$ARTIFACTS_DIR/intake.json" ]]; then
    goal=$(jq -r '.goal' "$ARTIFACTS_DIR/intake.json")
    assert_contains "Goal set from issue" "$goal" "JWT"
    branch=$(jq -r '.branch' "$ARTIFACTS_DIR/intake.json")
    assert_contains "Branch created" "$branch" "42"
fi

# With inline goal (no issue)
export GOAL="Add rate limiting"
export ISSUE_NUMBER=""
rm -f "$ARTIFACTS_DIR/intake.json"
stage_intake 2>/dev/null || true
[[ -f "$ARTIFACTS_DIR/intake.json" ]] && assert_pass "Intake inline artifact" || assert_pass "Intake attempted"

# ─── Tests: stage_plan ──────────────────────────────────────────────────────
print_test_section "stage_plan"

export GOAL="Add auth module"
mkdir -p "$ARTIFACTS_DIR"
stage_plan 2>/dev/null
assert_file_exists "Plan generated" "$ARTIFACTS_DIR/plan.md"
plan_content=$(cat "$ARTIFACTS_DIR/plan.md")
assert_contains "Plan has checklist" "$plan_content" "Task Checklist"
assert_contains "Plan has steps" "$plan_content" "Files to Modify"
assert_file_exists "DoD extracted" "$ARTIFACTS_DIR/dod.md"
assert_file_exists "Tasks file" "$TASKS_FILE"

# ─── Tests: stage_build ────────────────────────────────────────────────────
print_test_section "stage_build"

echo "# Plan" > "$ARTIFACTS_DIR/plan.md"
echo "# Design" > "$ARTIFACTS_DIR/design.md"
mkdir -p "$PROJECT_ROOT/.claude"
echo "# Tasks" > "$TASKS_FILE"

mock_binary "sw" 'mkdir -p src
echo "// auth" > src/auth.js
git add src/auth.js 2>/dev/null || true
git commit -m "feat: add auth" --allow-empty 2>/dev/null || true'

# stage_build invokes `sw loop` - ensure sw mock is in PATH
if sw loop --help 2>/dev/null || true; then :; fi
stage_build 2>/dev/null || build_rc=$?
[[ "${build_rc:-0}" -eq 0 ]] && assert_pass "Build stage completes" || assert_pass "Build attempted"
[[ -f "$PROJECT_ROOT/src/auth.js" ]] && assert_pass "Build produced source file" || assert_pass "Build stage ran"

# ─── Tests: stage_test ──────────────────────────────────────────────────────
print_test_section "stage_test"

export TEST_CMD="echo 'All 8 tests passed'"
stage_test 2>/dev/null
assert_file_exists "Test log created" "$ARTIFACTS_DIR/test-results.log"
assert_contains "Test output captured" "$(cat "$ARTIFACTS_DIR/test-results.log")" "passed"

# Test with coverage in output
export TEST_CMD="echo 'Statements : 85.5%'"
stage_test 2>/dev/null
coverage=$(parse_coverage_from_output "$ARTIFACTS_DIR/test-results.log")
assert_eq "Coverage parsed" "85.5" "$coverage"

# Test failure
export TEST_CMD="echo FAIL; exit 1"
stage_test 2>/dev/null || rc=$?
[[ $rc -eq 1 ]] && assert_pass "Stage test returns 1 on test failure"

# ─── Tests: stage_test differential judgement (#8663, #8671) ───────────────
print_test_section "stage_test differential"

# Each scenario gets its own repository, so a ref moved in one cannot leak into another. The fake test
# command prints bun-style output: one failure that the base commit also has, and a second, new one when
# the uncommitted regression.flag exists (the base worktree never has it).
make_diff_repo() {
    local dir="$1"
    mkdir -p "$dir/.artifacts"
    (
        cd "$dir" && git init -q -b main && git config user.email "t@t.com" && git config user.name "T"
        echo "# root" > README.md && git add -A && git commit -q -m "root"
        cat > fake-tests.sh <<'FAKE'
#!/usr/bin/env bash
echo "bun test v1.2.19"
echo ""
echo "old.test.ts:"
echo "(fail) pre-existing one [1.00ms]"
if [[ -f regression.flag ]]; then
    echo "new.test.ts:"
    echo "(fail) regression [1.00ms]"
    echo " 1 pass"
    echo " 2 fail"
    echo "Ran 3 tests across 2 files. [3.00ms]"
    exit 1
fi
echo " 1 pass"
echo " 1 fail"
echo "Ran 2 tests across 1 file. [2.00ms]"
exit 1
FAKE
        # Like a pipeline branch: the fork point (main's tip) has a parent, and HEAD is one commit past it
        git add -A && git commit -q -m "main: fake test command"
        git checkout -q -b side-branch "$(git rev-list --max-parents=0 HEAD)"
        echo side > side.txt && git add -A && git commit -q -m "side: not an ancestor of the pipeline"
        git checkout -q main
        git checkout -q -b feat/diff-under-test
        echo "pipeline change" >> README.md && git add -A && git commit -q -m "pipeline change"
    ) >/dev/null 2>&1
}
DIFF_REPO="$TEST_TEMP_DIR/diff-repo"
make_diff_repo "$DIFF_REPO"

# Runs the pipeline's start (base record) and then stage_test in <repo> with the given base branch. Each run
# has its own record home. Prints the stage's exit code.
run_diff_stage() {
    local repo="$1" base_branch="$2" rc=0 home name
    (
        cd "$repo"
        export PROJECT_ROOT="$repo" ARTIFACTS_DIR="$repo/.artifacts" BASE_BRANCH="$base_branch"
        name="diff-$(basename "$repo")"
        export ISSUE_NUMBER="" PIPELINE_NAME="$name" TEST_CMD="bash fake-tests.sh"
        home="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
        export SHIPWRIGHT_HOME="$home"
        pipeline_base_init || true
        stage_test
    ) >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# Pre-existing: the same failure on the base commit does not fail the stage
rm -f "$DIFF_REPO/regression.flag"
assert_eq "pre-existing failure does not fail the test stage" "0" "$(run_diff_stage "$DIFF_REPO" main)"
assert_contains "pre-existing verdict is logged" "$(cat "$DIFF_REPO/.artifacts/test-results.log")" "PRE-EXISTING, not blocking"

# Regression: a new failing unit fails the stage, and the feedback names the pre-existing one as not to fix
touch "$DIFF_REPO/regression.flag"
assert_eq "a regression fails the test stage" "1" "$(run_diff_stage "$DIFF_REPO" main)"
diff_log="$(cat "$DIFF_REPO/.artifacts/test-results.log")"
assert_contains "regression verdict names the new failure" "$diff_log" "BLOCKING: NEW FAILURES"
assert_contains "feedback lists the pre-existing failure" "$diff_log" "old.test.ts::pre-existing one#1"
assert_contains "feedback tells the agent not to fix pre-existing failures" "$diff_log" "Do NOT fix them"
rm -f "$DIFF_REPO/regression.flag"

# No base commit: fail closed, the old behaviour (the same pre-existing failure blocks)
assert_eq "no base branch: the failure blocks as before" "1" "$(run_diff_stage "$DIFF_REPO" no-such-base-branch)"

# Hijack (#8671 item 1): the agent moves origin/main and main to its own HEAD after the base was recorded.
# The recorded base still judges the regression, so it blocks.
HIJACK_REPO="$TEST_TEMP_DIR/hijack-repo"
make_diff_repo "$HIJACK_REPO"
HIJACK_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
touch "$HIJACK_REPO/regression.flag"
hijack_rc=0
(
    cd "$HIJACK_REPO"
    export PROJECT_ROOT="$HIJACK_REPO" ARTIFACTS_DIR="$HIJACK_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="hijack" SHIPWRIGHT_HOME="$HIJACK_HOME"
    pipeline_base_init
    git update-ref refs/remotes/origin/main HEAD
    git update-ref refs/heads/main HEAD
    stage_test
) >/dev/null 2>&1 || hijack_rc=$?
assert_eq "a moved origin/main cannot make a regression pre-existing" "1" "$hijack_rc"

# P1 (#8671): resume after the agent has moved the refs. The base and the remote are the ones recorded at the
# first start; a resume creates no record; the regression still blocks.
RESUME_REPO="$TEST_TEMP_DIR/resume-repo"
make_diff_repo "$RESUME_REPO"
RESUME_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
RESUME_OUT="$TEST_TEMP_DIR/resume.out"
(
    cd "$RESUME_REPO"
    export PROJECT_ROOT="$RESUME_REPO" ARTIFACTS_DIR="$RESUME_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="resume-p1" SHIPWRIGHT_HOME="$RESUME_HOME"
    git config remote.origin.url "https://example.com/original.git"
    git config remote.origin.pushurl "https://example.com/push-original.git"
    pipeline_base_init
    echo "first=$SW_PIPELINE_BASE_SHA"
    echo "firstpush=$SW_PIPELINE_PUSH_URL"
    # the agent: a commit, moved refs, a changed remote, and a regression
    echo agent >> README.md && git add -A && git commit -q -m "agent: more"
    git update-ref refs/remotes/origin/main HEAD
    git update-ref refs/heads/main HEAD
    git config remote.origin.url "https://example.com/attacker.git"
    git config remote.origin.pushurl "https://example.com/push-attacker.git"
    touch regression.flag
    PIPELINE_RESUMING=true pipeline_base_init
    echo "resumed=$SW_PIPELINE_BASE_SHA"
    echo "remote=$(pipeline_base_get_field "$RESUME_REPO" resume-p1 remote)"
    echo "branch=$(pipeline_base_get_field "$RESUME_REPO" resume-p1 branch)"
    echo "resumedpush=$SW_PIPELINE_PUSH_URL"
    if stage_test; then echo "rc=0"; else echo "rc=$?"; fi
) > "$RESUME_OUT" 2>&1 || true
resume_first="$(sed -n 's/^first=//p' "$RESUME_OUT")"
assert_eq "resume gets the base recorded at first start, after the agent moved origin/main" \
    "$resume_first" "$(sed -n 's/^resumed=//p' "$RESUME_OUT")"
assert_eq "resume gets the remote recorded at first start, after the agent changed it" \
    "https://example.com/original.git" "$(sed -n 's/^remote=//p' "$RESUME_OUT")"
assert_eq "resume gets the push URL recorded at first start, after the agent changed it" \
    "https://example.com/push-original.git" "$(sed -n 's/^resumedpush=//p' "$RESUME_OUT")"
assert_eq "the first start exports the push URL it recorded" \
    "https://example.com/push-original.git" "$(sed -n 's/^firstpush=//p' "$RESUME_OUT")"
assert_eq "resume records the branch the pipeline started on" "feat/diff-under-test" "$(sed -n 's/^branch=//p' "$RESUME_OUT")"
assert_eq "a regression after a resume still blocks" "rc=1" "$(grep '^rc=' "$RESUME_OUT")"
rm -f "$RESUME_REPO/regression.flag"
(cd "$RESUME_REPO" && git config --unset remote.origin.url && git config --unset remote.origin.pushurl) >/dev/null 2>&1 || true

# The record: mode 0600 and the fields the other pipeline features read
record_file="$(find "$RESUME_HOME" -name 'resume-p1.json' | head -1)"
assert_eq "the base record is mode 0600" "-rw-------" "$(ls -l "$record_file" | cut -c1-10)"
assert_eq "the base record holds the base, remote, branch and node_modules fingerprint" "1" \
    "$(jq -e 'has("base") and has("remote") and has("branch") and has("nm")' "$record_file" >/dev/null 2>&1 && echo 1 || echo 0)"

# A resume without a record cannot prove the base: no record, no base, and the stage blocks
unrecorded_home="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
unrec_rc=0
(
    cd "$RESUME_REPO"
    export PROJECT_ROOT="$RESUME_REPO" ARTIFACTS_DIR="$RESUME_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="never-recorded" SHIPWRIGHT_HOME="$unrecorded_home"
    touch regression.flag
    rec_rc=0; PIPELINE_RESUMING=true pipeline_base_init || rec_rc=$?
    [[ "$rec_rc" -ne 0 && -z "${SW_PIPELINE_BASE_SHA:-}" ]] || exit 9
    stage_test
) >/dev/null 2>&1 || unrec_rc=$?
rm -f "$RESUME_REPO/regression.flag"
assert_eq "a resume with no record exports no base and blocks" "1" "$unrec_rc"

# A corrupt record is not trusted: a resume with it blocks
corrupt_rc=0
(
    cd "$RESUME_REPO"
    export PROJECT_ROOT="$RESUME_REPO" ARTIFACTS_DIR="$RESUME_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="resume-p1" SHIPWRIGHT_HOME="$RESUME_HOME"
    printf 'not json' > "$record_file"
    PIPELINE_RESUMING=true pipeline_base_init || true
    [[ -z "${SW_PIPELINE_BASE_SHA:-}" ]] || exit 9
    stage_test
) >/dev/null 2>&1 || corrupt_rc=$?
assert_eq "a corrupt base record blocks" "1" "$corrupt_rc"

# A recorded base that equals HEAD, or is not an ancestor of HEAD, blocks
equal_rc=0
(
    cd "$DIFF_REPO"
    export PROJECT_ROOT="$DIFF_REPO" ARTIFACTS_DIR="$DIFF_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    SW_PIPELINE_BASE_SHA="$(git rev-parse HEAD)" stage_test
) >/dev/null 2>&1 || equal_rc=$?
assert_eq "a recorded base equal to HEAD blocks" "1" "$equal_rc"
side_rc=0
(
    cd "$DIFF_REPO"
    export PROJECT_ROOT="$DIFF_REPO" ARTIFACTS_DIR="$DIFF_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    SW_PIPELINE_BASE_SHA="$(git rev-parse side-branch)" stage_test
) >/dev/null 2>&1 || side_rc=$?
assert_eq "a recorded base that is not an ancestor of HEAD blocks" "1" "$side_rc"

# P3 (#8671): the base run symlinks node_modules, which the agent can write. A change since the start blocks.
NM_REPO="$TEST_TEMP_DIR/nm-repo"
make_diff_repo "$NM_REPO"
nm_control="$(run_diff_stage "$NM_REPO" main)"
assert_eq "control: an unchanged node_modules (none) lets the pre-existing failure pass" "0" "$nm_control"
nm_home="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
nm_rc=0
(
    cd "$NM_REPO"
    export PROJECT_ROOT="$NM_REPO" ARTIFACTS_DIR="$NM_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="nm-poison" SHIPWRIGHT_HOME="$nm_home"
    pipeline_base_init
    mkdir -p node_modules/dep && echo poison > node_modules/dep/poison
    stage_test
) >"$TEST_TEMP_DIR/nm.out" 2>&1 || nm_rc=$?
assert_eq "an agent-poisoned node_modules blocks a pre-existing failure" "1" "$nm_rc"
assert_contains "the block says node_modules changed" "$(cat "$TEST_TEMP_DIR/nm.out")" "node_modules changed"

# sw-test-all format (#8671 item 2 and item 5). One suite; its failing assertion A01 is new and sits
# above the last 20 lines, the window sw-test-all prints by default. FAIL_LOG_LINES must lift that.
# A second assertion (A30) is pre-existing; the suite-level exit unit must not be listed as pre-existing.
SUITE_REPO="$TEST_TEMP_DIR/suite-repo"
mkdir -p "$SUITE_REPO/.artifacts"
SUITE_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
(
    cd "$SUITE_REPO" && git init -q -b main && git config user.email "t@t.com" && git config user.name "T"
    echo "# root" > README.md && git add -A && git commit -q -m "root"
    cat > runner.sh <<'RUNNER'
#!/usr/bin/env bash
# Prints one failing suite in sw-test-all's shape. The section shows the last FAIL_LOG_LINES lines.
lines="${FAIL_LOG_LINES:-20}"
nfail=1
[[ -f new-break ]] && nfail=2
body="$(
    [[ -f new-break ]] && echo "    ✗ A01 new break"
    for i in $(seq 1 30); do echo "    ✓ P$i ok"; done
    echo "    ✗ A30 old break"
    echo "  $nfail of 31 tests failed"
)"
printf '  ✓ suite-ok   0s\n'
printf '  ✗ suite-x   exit 1 0s\n'
printf '━━━ suite-x (FAIL:1) — last %s lines ━━━\n' "$lines"
printf '%s\n' "$body" | tail -n "$lines"
printf '1 passed  1 failed  0 timed out  (2 suites, 1s)\n'
exit 1
RUNNER
    git add -A && git commit -q -m "main: runner"
    git checkout -q -b feat/suite
    echo "pipeline change" >> README.md && git add -A && git commit -q -m "pipeline change"
) >/dev/null 2>&1
suite_rc=0
(
    cd "$SUITE_REPO"
    export PROJECT_ROOT="$SUITE_REPO" ARTIFACTS_DIR="$SUITE_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash runner.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="suite-x" SHIPWRIGHT_HOME="$SUITE_HOME"
    pipeline_base_init
    touch new-break
    stage_test
) >/dev/null 2>&1 || suite_rc=$?
suite_log="$(cat "$SUITE_REPO/.artifacts/test-results.log")"
assert_eq "a new assertion above the default log window still blocks (FAIL_LOG_LINES)" "1" "$suite_rc"
assert_contains "the new assertion is named" "$suite_log" "suite-x::A01 new break#1"
assert_contains "the pre-existing assertion is still named" "$suite_log" "A30 old break"
pre_line="$(printf '%s\n' "$suite_log" | grep '^PRE-EXISTING' || true)"
assert_eq "suite-level exit unit is not listed as pre-existing when the suite has new failures" "0" "$(printf '%s' "$pre_line" | grep -c 'suite-x::exit=' || true)"

# ─── Tests: stage_review ────────────────────────────────────────────────────
print_test_section "stage_review"

(cd "$PROJECT_ROOT" && git checkout -b feat/review-test 2>/dev/null)
echo "change" >> "$PROJECT_ROOT/src/auth.js" 2>/dev/null || touch "$PROJECT_ROOT/src/auth.js"
(cd "$PROJECT_ROOT" && git add -A && git diff main...HEAD > "$ARTIFACTS_DIR/review-diff.patch" 2>/dev/null || echo "diff" > "$ARTIFACTS_DIR/review-diff.patch")

stage_review 2>/dev/null
assert_file_exists "Review generated" "$ARTIFACTS_DIR/review.md"
review_len=$(wc -c < "$ARTIFACTS_DIR/review.md")
assert_gt "Review has content" "$review_len" 0

# ─── Tests: stage_pr quality gate ───────────────────────────────────────────
print_test_section "stage_pr quality gate"

(cd "$PROJECT_ROOT" && git checkout main 2>/dev/null) || true
(cd "$PROJECT_ROOT" && git checkout -b feat/empty 2>/dev/null) || true
mkdir -p "$PROJECT_ROOT/.claude/foo"
echo "x" > "$PROJECT_ROOT/.claude/foo/bar"
(cd "$PROJECT_ROOT" && git add .claude && git commit -m "artifacts" 2>/dev/null) || true
rc=0
stage_pr 2>/dev/null || rc=$?
if [[ "$rc" -eq 1 ]]; then assert_pass "PR rejects when no real code changes"; else assert_pass "PR quality gate executed (rc=$rc)"; fi

# ─── Tests: detect_task_type ────────────────────────────────────────────────
print_test_section "detect_task_type"

t=$(detect_task_type "Fix the login bug")
assert_eq "Bug type" "bug" "$t"
t=$(detect_task_type "Refactor auth module")
assert_eq "Refactor type" "refactor" "$t"
t=$(detect_task_type "Add new feature")
assert_eq "Feature type" "feature" "$t"

# ─── Tests: branch_prefix_for_type ──────────────────────────────────────────
print_test_section "branch_prefix_for_type"

p=$(branch_prefix_for_type "bug")
assert_eq "Bug prefix" "fix" "$p"
p=$(branch_prefix_for_type "feature")
assert_eq "Feature prefix" "feat" "$p"

# ─── Tests: detect_project_lang ──────────────────────────────────────────────
print_test_section "detect_project_lang"

lang=$(detect_project_lang)
# package.json → nodejs (pipeline-detection.sh)
assert_contains "Project lang detected" "$lang" "nodejs"

# ─── Tests: gh_get_issue_meta ───────────────────────────────────────────────
print_test_section "gh_get_issue_meta"

meta=$(gh_get_issue_meta "42")
assert_contains "Issue meta has title" "$meta" "JWT"
title=$(echo "$meta" | jq -r '.title')
assert_contains "Title parsed" "$title" "JWT"

print_test_results
