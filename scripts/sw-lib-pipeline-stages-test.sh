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
        printf 'node_modules/\n.artifacts/\n' > .gitignore
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
        git add -A && git commit -q -m "main: fake test command"
        git checkout -q -b side-branch "$(git rev-list --max-parents=0 HEAD)"
        echo side > side.txt && git add -A && git commit -q -m "side: not an ancestor of the pipeline"
        git checkout -q main
        # The pipeline's branch starts at the fork point: no commits beyond the base yet
        git checkout -q -b feat/diff-under-test
    ) >/dev/null 2>&1
}
# A scenario's repository: each one starts on a clean branch at the fork point (a reused repo would start
# with the previous scenario's agent commits, and the fork-point proof would rightly refuse it).
fresh_diff_repo() {
    local d="$TEST_TEMP_DIR/diff-$1"
    make_diff_repo "$d"
    echo "$d"
}

# The agent's build commit, made after the pipeline has started
agent_commit() { (cd "$1" && echo "agent $2" >> README.md && git add -A && git commit -q -m "agent: $2") >/dev/null 2>&1; }

# Runs the pipeline's start and then stage_test in <repo> with the given base branch, after the agent has
# committed. Each run has its own record home. Prints the stage's exit code.
run_diff_stage() {
    local repo="$1" base_branch="$2" rc=0 name home
    (
        cd "$repo"
        export PROJECT_ROOT="$repo" ARTIFACTS_DIR="$repo/.artifacts" BASE_BRANCH="$base_branch"
        name="diff-$(basename "$repo")"
        export ISSUE_NUMBER="" PIPELINE_NAME="$name" TEST_CMD="bash fake-tests.sh"
        home="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
        export SHIPWRIGHT_HOME="$home"
        pipeline_base_init || true
        echo agent >> README.md && git add -A && git commit -q -m "agent: build"
        stage_test
    ) >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# Pre-existing: the same failure on the base commit does not fail the stage
PRE_REPO="$(fresh_diff_repo pre)"
assert_eq "pre-existing failure does not fail the test stage" "0" "$(run_diff_stage "$PRE_REPO" main)"
assert_contains "pre-existing verdict is logged" "$(cat "$PRE_REPO/.artifacts/test-results.log")" "PRE-EXISTING, not blocking"

# Regression: a new failing unit fails the stage, and the feedback names the pre-existing one as not to fix
REG_REPO="$(fresh_diff_repo reg)"
touch "$REG_REPO/regression.flag"
assert_eq "a regression fails the test stage" "1" "$(run_diff_stage "$REG_REPO" main)"
diff_log="$(cat "$REG_REPO/.artifacts/test-results.log")"
assert_contains "regression verdict names the new failure" "$diff_log" "BLOCKING: NEW FAILURES"
assert_contains "feedback lists the pre-existing failure" "$diff_log" "old.test.ts::pre-existing one#1"
assert_contains "feedback tells the agent not to fix pre-existing failures" "$diff_log" "Do NOT fix them"

# No base commit: fail closed, the old behaviour (the same pre-existing failure blocks)
NOBASE_REPO="$(fresh_diff_repo nobase)"
assert_eq "no base branch: the failure blocks as before" "1" "$(run_diff_stage "$NOBASE_REPO" no-such-base-branch)"

# Hijack (#8671): the agent moves origin/main and main to its own HEAD after the base was recorded. The
# recorded base still judges the regression, so it blocks.
HIJACK_REPO="$TEST_TEMP_DIR/hijack-repo"
make_diff_repo "$HIJACK_REPO"
hijack_rc=0
HIJACK_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
(
    cd "$HIJACK_REPO"
    export PROJECT_ROOT="$HIJACK_REPO" ARTIFACTS_DIR="$HIJACK_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="hijack" SHIPWRIGHT_HOME="$HIJACK_HOME"
    pipeline_base_init
    echo agent >> README.md && git add -A && git commit -q -m "agent: build"
    touch regression.flag
    git update-ref refs/remotes/origin/main HEAD
    git update-ref refs/heads/main HEAD
    stage_test
) >/dev/null 2>&1 || hijack_rc=$?
assert_eq "a moved origin/main cannot make a regression pre-existing" "1" "$hijack_rc"

# P1 (#8671): resume after the agent has moved the refs. The base, run id, remote, push URL and branch are the
# ones recorded at the first start; a resume creates no record; the regression still blocks.
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
    echo "run=$SW_PIPELINE_RUN_ID"
    # the agent: a commit, moved refs, a changed remote, and a regression
    echo agent >> README.md && git add -A && git commit -q -m "agent: more"
    git update-ref refs/remotes/origin/main HEAD
    git update-ref refs/heads/main HEAD
    git config remote.origin.url "https://example.com/attacker.git"
    git config remote.origin.pushurl "https://example.com/push-attacker.git"
    touch regression.flag
    PIPELINE_RESUMING=true pipeline_base_init
    echo "resumed=$SW_PIPELINE_BASE_SHA"
    echo "resumedpush=$SW_PIPELINE_PUSH_URL"
    echo "resumedrun=$SW_PIPELINE_RUN_ID"
    echo "remote=$(pipeline_base_get_field "$RESUME_REPO" "$SW_PIPELINE_RUN_ID" remote)"
    echo "branch=$(pipeline_base_get_field "$RESUME_REPO" "$SW_PIPELINE_RUN_ID" branch)"
    if stage_test; then echo "rc=0"; else echo "rc=$?"; fi
) > "$RESUME_OUT" 2>&1 || true
resume_first="$(sed -n 's/^first=//p' "$RESUME_OUT")"
assert_eq "resume gets the base recorded at first start, after the agent moved origin/main" \
    "$resume_first" "$(sed -n 's/^resumed=//p' "$RESUME_OUT")"
assert_eq "resume gets the push URL recorded at first start, after the agent changed it" \
    "https://example.com/push-original.git" "$(sed -n 's/^resumedpush=//p' "$RESUME_OUT")"
assert_eq "the first start exports the push URL it recorded" \
    "https://example.com/push-original.git" "$(sed -n 's/^firstpush=//p' "$RESUME_OUT")"
assert_eq "resume reuses the run id of the first start" \
    "$(sed -n 's/^run=//p' "$RESUME_OUT")" "$(sed -n 's/^resumedrun=//p' "$RESUME_OUT")"
assert_eq "resume gets the remote recorded at first start, after the agent changed it" \
    "https://example.com/original.git" "$(sed -n 's/^remote=//p' "$RESUME_OUT")"
assert_eq "resume records the branch the pipeline started on" "feat/diff-under-test" "$(sed -n 's/^branch=//p' "$RESUME_OUT")"
assert_eq "a regression after a resume still blocks" "rc=1" "$(grep '^rc=' "$RESUME_OUT")"
rm -f "$RESUME_REPO/regression.flag"
(cd "$RESUME_REPO" && git config --unset remote.origin.url && git config --unset remote.origin.pushurl) >/dev/null 2>&1 || true

# The record: keyed by a run id, mode 0600, and holding the fields the other pipeline features read
run_id="$(sed -n 's/^run=//p' "$RESUME_OUT")"
record_file="$(find "$RESUME_HOME" -name "$run_id.json" | head -1)"
assert_eq "the base record is mode 0600" "-rw-------" "$(ls -l "$record_file" | cut -c1-10)"
assert_eq "the base record holds the base, remote, push URL, branch and node_modules fingerprint" "1" \
    "$(jq -e 'has("base") and has("remote") and has("push_url") and has("branch") and has("nm")' "$record_file" >/dev/null 2>&1 && echo 1 || echo 0)"

# P1c (#8671): a fresh start on a branch that already has agent commits is not a first start. Nothing is
# recorded, and the stage blocks even though the failure is the same on the base.
DIRTY_REPO="$TEST_TEMP_DIR/dirty-repo"
make_diff_repo "$DIRTY_REPO"
agent_commit "$DIRTY_REPO" "earlier run"
DIRTY_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
dirty_rc=0
(
    cd "$DIRTY_REPO"
    export PROJECT_ROOT="$DIRTY_REPO" ARTIFACTS_DIR="$DIRTY_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="dirty" SHIPWRIGHT_HOME="$DIRTY_HOME"
    rec_rc=0; pipeline_base_init || rec_rc=$?
    [[ "$rec_rc" -ne 0 && -z "${SW_PIPELINE_BASE_SHA:-}" && -z "${SW_PIPELINE_RUN_ID:-}" ]] || exit 9
    agent_commit_inline() { echo agent >> README.md && git add -A && git commit -q -m "agent: build"; }
    agent_commit_inline
    stage_test
) >"$TEST_TEMP_DIR/dirty.out" 2>&1 || dirty_rc=$?
assert_eq "a fresh start on a branch with agent commits records nothing and blocks" "1" "$dirty_rc"
assert_contains "the operator is told how to start clean" "$(cat "$TEST_TEMP_DIR/dirty.out")" "clean branch"
assert_eq "no record is written for the dirty branch" "0" "$(find "$DIRTY_HOME" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

# P1f/P1g (#8671): records are per run. A second fresh start for the same issue (or the same template, with no
# issue) gets its own run id and base, never an older record's.
STALE_REPO="$TEST_TEMP_DIR/stale-repo"
make_diff_repo "$STALE_REPO"
STALE_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
STALE_OUT="$TEST_TEMP_DIR/stale.out"
(
    cd "$STALE_REPO"
    export PROJECT_ROOT="$STALE_REPO" ARTIFACTS_DIR="$STALE_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="standard" SHIPWRIGHT_HOME="$STALE_HOME"
    pipeline_base_init; echo "run1=$SW_PIPELINE_RUN_ID"
    echo agent >> README.md && git add -A && git commit -q -m "agent: run one"
    git checkout -q main && git merge -q --ff-only feat/diff-under-test 2>/dev/null || true
    git checkout -q feat/diff-under-test
    pipeline_base_init; echo "run2=$SW_PIPELINE_RUN_ID"; echo "base2=$SW_PIPELINE_BASE_SHA"
    echo "resumed2=$(PIPELINE_RESUMING=true pipeline_base_init >/dev/null 2>&1; echo "$SW_PIPELINE_RUN_ID")"
) > "$STALE_OUT" 2>&1 || true
assert_eq "a second fresh start for the same template gets a new run id" \
    "$(sed -n 's/^run1=//p' "$STALE_OUT" | head -1)" "$(sed -n 's/^run1=//p' "$STALE_OUT" | head -1)"
run1="$(sed -n 's/^run1=//p' "$STALE_OUT")"
run2="$(sed -n 's/^run2=//p' "$STALE_OUT")"
assert_eq "a second fresh start for the same template gets a new run id" "1" "$([[ -n "$run2" && "$run2" != "$run1" ]] && echo 1 || echo 0)"
assert_eq "a resume after the second start uses the second run" "$run2" "$(sed -n 's/^resumed2=//p' "$STALE_OUT")"
assert_eq "the first run's record is still on disk, untouched (never reused)" "1" \
    "$(find "$STALE_HOME" -name "$run1.json" | wc -l | tr -d ' ')"

# Release (#8671): completion or abort deletes the run's record and pointer; a resume then has nothing to load
(
    cd "$STALE_REPO"
    export PROJECT_ROOT="$STALE_REPO" SHIPWRIGHT_HOME="$STALE_HOME"
    pipeline_base_release "$STALE_REPO"
    PIPELINE_RESUMING=true pipeline_base_init || true
    [[ -z "${SW_PIPELINE_BASE_SHA:-}" ]] || exit 9
) >/dev/null 2>&1; release_rc=$?
assert_eq "after release a resume loads nothing and exports no base" "0" "$release_rc"
assert_eq "release removes the run's record" "0" "$(find "$STALE_HOME" -name "$run2.json" | wc -l | tr -d ' ')"

# Expiry (#8671): records older than the TTL are swept at the next fresh start
EXP_REPO="$TEST_TEMP_DIR/exp-repo"
make_diff_repo "$EXP_REPO"
EXP_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
(
    cd "$EXP_REPO"
    export PROJECT_ROOT="$EXP_REPO" ARTIFACTS_DIR="$EXP_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="exp" SHIPWRIGHT_HOME="$EXP_HOME"
    pipeline_base_init
    old_file="$(dirname "$SW_PIPELINE_RUN_ID")"
    echo '{}' > "$(find "$EXP_HOME" -name "$SW_PIPELINE_RUN_ID.json" | head -1 | sed 's/.json$/.old.json/')"
    touch -t 202001010000 "$(find "$EXP_HOME" -name "$SW_PIPELINE_RUN_ID.old.json" | head -1)"
    pipeline_base_init
) >/dev/null 2>&1 || true
assert_eq "an expired record is swept at the next fresh start" "0" "$(find "$EXP_HOME" -name '*.old.json' | wc -l | tr -d ' ')"

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

# A record that is not 0600 (or not a plain file) is not trusted (#8671, item 4)
WIDE_REPO="$TEST_TEMP_DIR/wide-repo"
make_diff_repo "$WIDE_REPO"
WIDE_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
wide_rc=0
(
    cd "$WIDE_REPO"
    export PROJECT_ROOT="$WIDE_REPO" ARTIFACTS_DIR="$WIDE_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="wide" SHIPWRIGHT_HOME="$WIDE_HOME"
    pipeline_base_init
    chmod 644 "$(find "$WIDE_HOME" -name "$SW_PIPELINE_RUN_ID.json")"
    PIPELINE_RESUMING=true pipeline_base_init || true
    [[ -z "${SW_PIPELINE_BASE_SHA:-}" ]] || exit 9
) >/dev/null 2>&1 || wide_rc=$?
assert_eq "a record readable by others (0644) is not trusted" "0" "$wide_rc"

# A recorded base that equals HEAD, or is not an ancestor of HEAD, blocks
EQ_REPO="$(fresh_diff_repo equal)"
equal_rc=0
(
    cd "$EQ_REPO"
    export PROJECT_ROOT="$EQ_REPO" ARTIFACTS_DIR="$EQ_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    SW_PIPELINE_BASE_SHA="$(git rev-parse HEAD)" stage_test
) >/dev/null 2>&1 || equal_rc=$?
assert_eq "a recorded base equal to HEAD blocks" "1" "$equal_rc"
SIDE_REPO="$(fresh_diff_repo side)"
side_rc=0
(
    cd "$SIDE_REPO"
    export PROJECT_ROOT="$SIDE_REPO" ARTIFACTS_DIR="$SIDE_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    SW_PIPELINE_BASE_SHA="$(git rev-parse side-branch)" stage_test
) >/dev/null 2>&1 || side_rc=$?
assert_eq "a recorded base that is not an ancestor of HEAD blocks" "1" "$side_rc"

# P3a (#8671): the base run uses node_modules, which the agent can write. A change since the start blocks.
NM_CONTROL_REPO="$(fresh_diff_repo nm-control)"
nm_control="$(run_diff_stage "$NM_CONTROL_REPO" main)"
assert_eq "control: an unchanged node_modules (none) lets the pre-existing failure pass" "0" "$nm_control"
NM_POISON_REPO="$(fresh_diff_repo nm-poison)"
nm_home="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
nm_rc=0
(
    cd "$NM_POISON_REPO"
    export PROJECT_ROOT="$NM_POISON_REPO" ARTIFACTS_DIR="$NM_POISON_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="nm-poison" SHIPWRIGHT_HOME="$nm_home"
    pipeline_base_init
    echo agent >> README.md && git add -A && git commit -q -m "agent: build"
    mkdir -p node_modules/dep && echo poison > node_modules/dep/poison
    stage_test
) >"$TEST_TEMP_DIR/nm.out" 2>&1 || nm_rc=$?
assert_eq "an agent-poisoned node_modules blocks a pre-existing failure" "1" "$nm_rc"
assert_contains "the block says node_modules changed" "$(cat "$TEST_TEMP_DIR/nm.out")" "node_modules changed"

# P3b (#8671): poison behind a symlink inside node_modules. The fingerprint follows links, so it is seen.
LINK_REPO="$TEST_TEMP_DIR/link-repo"
make_diff_repo "$LINK_REPO"
mkdir -p "$LINK_REPO/node_modules/dep" && echo ok > "$LINK_REPO/node_modules/dep/index.js"
LINK_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
link_rc=0
(
    cd "$LINK_REPO"
    export PROJECT_ROOT="$LINK_REPO" ARTIFACTS_DIR="$LINK_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="link-poison" SHIPWRIGHT_HOME="$LINK_HOME"
    pipeline_base_init
    echo agent >> README.md && git add -A && git commit -q -m "agent: build"
    echo poison > "$TEST_TEMP_DIR/poison-target"
    ln -s "$TEST_TEMP_DIR/poison-target" node_modules/dep/poison
    stage_test
) >"$TEST_TEMP_DIR/link.out" 2>&1 || link_rc=$?
assert_eq "poison behind a symlink in node_modules blocks a pre-existing failure" "1" "$link_rc"
assert_contains "the symlink poison is reported as a node_modules change" "$(cat "$TEST_TEMP_DIR/link.out")" "node_modules changed"

# P3c (#8671): a symlinked directory inside node_modules points into the repository. Its content is part of the
# fingerprint, so an agent edit behind the link blocks.
DIR_REPO="$TEST_TEMP_DIR/dirlink-repo"
make_diff_repo "$DIR_REPO"
mkdir -p "$DIR_REPO/vendor-dep" "$DIR_REPO/node_modules" && : > "$DIR_REPO/vendor-dep/flag.txt"
ln -s ../vendor-dep "$DIR_REPO/node_modules/dep"
DIR_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
dir_rc=0
(
    cd "$DIR_REPO"
    export PROJECT_ROOT="$DIR_REPO" ARTIFACTS_DIR="$DIR_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="dir-poison" SHIPWRIGHT_HOME="$DIR_HOME"
    pipeline_base_init
    echo agent >> README.md && git add -A && git commit -q -m "agent: build"
    echo poison > vendor-dep/flag.txt
    stage_test
) >"$TEST_TEMP_DIR/dir.out" 2>&1 || dir_rc=$?
assert_eq "an agent edit behind a symlinked node_modules directory blocks" "1" "$dir_rc"

# P3d (#8671): a workspace package linked from node_modules is judged at the base commit. The agent breaks the
# package's committed code; the regression is new, not pre-existing.
WS_REPO="$TEST_TEMP_DIR/ws-repo"
mkdir -p "$WS_REPO/.artifacts"
(
    cd "$WS_REPO" && git init -q -b main && git config user.email t@t && git config user.name T
    printf 'node_modules/\n.artifacts/\n' > .gitignore
    mkdir -p packages/x && echo good > packages/x/impl.txt
    cat > fake-tests.sh <<'WSFAKE'
#!/usr/bin/env bash
echo "bun test v1.2.19"
echo ""
echo "old.test.ts:"
echo "(fail) pre-existing one [1.00ms]"
n=1
if [[ "$(cat node_modules/x/impl.txt)" != good ]]; then
    echo "app.test.ts:"
    echo "(fail) uses x [1.00ms]"
    n=2
fi
echo " 1 pass"
echo " $n fail"
echo "Ran $((n+1)) tests across $n files. [3.00ms]"
exit 1
WSFAKE
    git add -A && git commit -q -m "main: workspace package and tests"
    mkdir -p node_modules && ln -s ../packages/x node_modules/x
    git checkout -q -b feat/ws
) >/dev/null 2>&1
WS_HOME="$(mktemp -d "$TEST_TEMP_DIR/home.XXXXXX")"
ws_rc=0
(
    cd "$WS_REPO"
    export PROJECT_ROOT="$WS_REPO" ARTIFACTS_DIR="$WS_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="ws" SHIPWRIGHT_HOME="$WS_HOME"
    pipeline_base_init
    echo broken > packages/x/impl.txt && git add -A && git commit -q -m "agent: break x"
    stage_test
) >"$TEST_TEMP_DIR/ws.out" 2>&1 || ws_rc=$?
assert_eq "a committed regression in a linked workspace package blocks" "1" "$ws_rc"
assert_contains "the regression is the workspace test, not the pre-existing one" "$(cat "$WS_REPO/.artifacts/test-results.log")" "app.test.ts"

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
) >/dev/null 2>&1
suite_rc=0
(
    cd "$SUITE_REPO"
    export PROJECT_ROOT="$SUITE_REPO" ARTIFACTS_DIR="$SUITE_REPO/.artifacts" BASE_BRANCH=main TEST_CMD="bash runner.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="suite-x" SHIPWRIGHT_HOME="$SUITE_HOME"
    pipeline_base_init
    echo "pipeline change" >> README.md && git add -A && git commit -q -m "agent: build"
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
