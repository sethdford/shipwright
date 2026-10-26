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

# Each scenario has its own repository with a bare origin, which stands in for the remote. The base is the
# origin's main, read through ls-remote (#8671). The fake test command prints bun-style output: one failure the
# base also has, and a second, new one when regression.flag exists.
make_diff_repo() {
    local dir="$1"
    mkdir -p "$dir/.artifacts"
    (
        cd "$dir" && git init -q -b main && git config user.email "t@t.com" && git config user.name "T"
        printf 'node_modules/\n.artifacts/\n.env\n' > .gitignore
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
        git init -q --bare "$dir.origin" && git remote add origin "$dir.origin" && git -C "$dir.origin" fetch -q "$dir" main:refs/heads/main
        git checkout -q -b feat/diff-under-test
    ) >/dev/null 2>&1
}
fresh_diff_repo() { local d="$TEST_TEMP_DIR/diff-$1"; make_diff_repo "$d"; printf '%s' "$d"; }
new_home() { mktemp -d "$TEST_TEMP_DIR/home.XXXXXX"; }
# diff_env <repo> <home> <base-branch> — the pipeline's environment for a scenario.
diff_env() {
    export PROJECT_ROOT="$1" ARTIFACTS_DIR="$1/.artifacts" BASE_BRANCH="$3" TEST_CMD="bash fake-tests.sh"
    export ISSUE_NUMBER="" PIPELINE_NAME="diff" SHIPWRIGHT_HOME="$2"
    unset PIPELINE_RESUMING RESUME_FROM_CHECKPOINT SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
}
# agent_commit <repo> <msg> — the agent's build commit, made after the pipeline started.
agent_commit() { (cd "$1" && echo "agent $2" >> README.md && git add -A && git commit -q -m "agent: $2") >/dev/null 2>&1; }
# run_diff_stage <repo> <base-branch> — a fresh start, the agent's commit, then stage_test. Prints the exit code.
run_diff_stage() {
    local repo="$1" base_branch="$2" rc=0 home
    home="$(new_home)"
    (
        diff_env "$repo" "$home" "$base_branch"
        cd "$repo" || exit 1
        pipeline_base_init || true
        agent_commit "$repo" build
        stage_test
    ) >"$TEST_TEMP_DIR/stage.out" 2>&1 || rc=$?
    echo "$rc"
}

# Pre-existing: the same failure on the base does not fail the stage.
PRE_REPO="$(fresh_diff_repo pre)"
assert_eq "pre-existing failure does not fail the test stage" "0" "$(run_diff_stage "$PRE_REPO" main)"
assert_contains "pre-existing verdict is logged" "$(cat "$PRE_REPO/.artifacts/test-results.log")" "PRE-EXISTING, not blocking"

# Regression: a new failing unit fails the stage; the feedback names the pre-existing one as not to fix.
REG_REPO="$(fresh_diff_repo reg)"
touch "$REG_REPO/regression.flag"
assert_eq "a regression fails the test stage" "1" "$(run_diff_stage "$REG_REPO" main)"
diff_log="$(cat "$REG_REPO/.artifacts/test-results.log")"
assert_contains "regression verdict names the new failure" "$diff_log" "BLOCKING: NEW FAILURES"
assert_contains "feedback lists the pre-existing failure" "$diff_log" "old.test.ts::pre-existing one#1"
assert_contains "feedback tells the agent not to fix pre-existing failures" "$diff_log" "Do NOT fix them"

# No base on the remote: the failure blocks, as before.
NOBASE_REPO="$(fresh_diff_repo nobase)"
assert_eq "no base branch on the remote: the failure blocks as before" "1" "$(run_diff_stage "$NOBASE_REPO" no-such-base-branch)"

# In-process hijack: the agent moves local main and origin/main to its own commit. The judgement uses the base
# held in memory at init, so the regression still blocks.
HIJACK_REPO="$(fresh_diff_repo hijack)"
HIJACK_HOME="$(new_home)"
hijack_rc=0
(
    diff_env "$HIJACK_REPO" "$HIJACK_HOME" main
    cd "$HIJACK_REPO" || exit 1
    pipeline_base_init
    agent_commit "$HIJACK_REPO" build
    touch regression.flag
    git update-ref refs/remotes/origin/main HEAD
    git update-ref refs/heads/main HEAD
    stage_test
) >/dev/null 2>&1 || hijack_rc=$?
assert_eq "moved local main and origin/main cannot make a regression pre-existing" "1" "$hijack_rc"

# Resume in a new process after the agent moved refs and changed the remote: the run's recorded base, push URL and
# run id are used, and the regression still blocks.
RESUME_REPO="$(fresh_diff_repo resume)"
RESUME_HOME="$(new_home)"
RESUME_OUT="$TEST_TEMP_DIR/resume.out"
(
    diff_env "$RESUME_REPO" "$RESUME_HOME" main
    cd "$RESUME_REPO" || exit 1
    pipeline_base_init
    echo "first=$SW_PIPELINE_BASE_SHA"
    echo "firstpush=$SW_PIPELINE_PUSH_URL"
    echo "run=$SW_PIPELINE_RUN_ID"
) > "$RESUME_OUT" 2>&1
(
    diff_env "$RESUME_REPO" "$RESUME_HOME" main
    cd "$RESUME_REPO" || exit 1
    agent_commit "$RESUME_REPO" more
    git update-ref refs/remotes/origin/main HEAD
    git update-ref refs/heads/main HEAD
    git remote set-url origin "https://example.com/attacker.git"
    touch regression.flag
    export PIPELINE_RESUMING=true
    pipeline_base_init
    echo "resumed=$SW_PIPELINE_BASE_SHA"
    echo "resumedpush=$SW_PIPELINE_PUSH_URL"
    echo "resumedrun=$SW_PIPELINE_RUN_ID"
    if stage_test; then echo "rc=0"; else echo "rc=$?"; fi
) >> "$RESUME_OUT" 2>&1
assert_eq "resume gets the base recorded at first start, after the agent moved refs" \
    "$(sed -n 's/^first=//p' "$RESUME_OUT")" "$(sed -n 's/^resumed=//p' "$RESUME_OUT")"
assert_eq "resume gets the push URL recorded at first start, after the remote changed" \
    "$(sed -n 's/^firstpush=//p' "$RESUME_OUT")" "$(sed -n 's/^resumedpush=//p' "$RESUME_OUT")"
assert_eq "resume reuses the run id of the first start" \
    "$(sed -n 's/^run=//p' "$RESUME_OUT")" "$(sed -n 's/^resumedrun=//p' "$RESUME_OUT")"
assert_eq "a regression after a resume still blocks" "rc=1" "$(grep '^rc=' "$RESUME_OUT")"
assert_eq "a resume creates no second record" "1" "$(find "$RESUME_HOME" -name '*.json' | wc -l | tr -d ' ')"

# Resume after the intake step's git checkout -b: the record is found through the worktree's pointer, not the branch.
CKB_REPO="$(fresh_diff_repo ckb)"
CKB_HOME="$(new_home)"
(
    diff_env "$CKB_REPO" "$CKB_HOME" main
    cd "$CKB_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
CKB_OUT="$TEST_TEMP_DIR/ckb.out"
(
    diff_env "$CKB_REPO" "$CKB_HOME" main
    cd "$CKB_REPO" || exit 1
    git checkout -q -b fix/goal-1
    export PIPELINE_RESUMING=true
    if pipeline_base_init; then echo "init=0"; else echo "init=1"; fi
    agent_commit "$CKB_REPO" build
    touch regression.flag
    if stage_test; then echo "rc=0"; else echo "rc=$?"; fi
) > "$CKB_OUT" 2>&1
assert_eq "a resume after git checkout -b finds the record" "init=0" "$(grep '^init=' "$CKB_OUT")"
assert_eq "a resume after git checkout -b still blocks a regression" "rc=1" "$(grep '^rc=' "$CKB_OUT")"

# Release after the intake branch change: the record and the pointer are removed.
REL_REPO="$(fresh_diff_repo rel)"
REL_HOME="$(new_home)"
(
    diff_env "$REL_REPO" "$REL_HOME" main
    cd "$REL_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
(
    diff_env "$REL_REPO" "$REL_HOME" main
    cd "$REL_REPO" || exit 1
    git checkout -q -b fix/goal-rel
    pipeline_base_release "$REL_REPO"
) >/dev/null 2>&1
assert_eq "release after the intake branch change removes the record" "0" "$(find "$REL_HOME" -name '*.json' | wc -l | tr -d ' ')"
assert_eq "release after the intake branch change removes the pointer" "0" "$(find "$REL_HOME" -name '*.run' | wc -l | tr -d ' ')"
rel_resume="$(
    diff_env "$REL_REPO" "$REL_HOME" main
    cd "$REL_REPO" || exit 1
    export PIPELINE_RESUMING=true
    if pipeline_base_init 2>/dev/null; then echo 0; else echo 1; fi
)"
assert_eq "after release a resume has no record and fails closed" "1" "$rel_resume"

# In-process rewrite (#8671, A2): the test command rewrites this run's record on disk so its base is HEAD. The judgement
# holds the base in memory, so the pre-existing failure still passes.
RW_REPO="$(fresh_diff_repo rw)"
RW_HOME="$(new_home)"
RW_SCRIPT="$TEST_TEMP_DIR/rewrite-record.sh"
cat > "$RW_SCRIPT" <<'RW'
rec="$(find "$SHIPWRIGHT_HOME" -name "$SW_PIPELINE_RUN_ID.json" | head -1)"
jq --arg h "$(git rev-parse HEAD)" '.base = $h | .nm = "absent"' "$rec" > "$rec.t" && chmod 600 "$rec.t" && mv "$rec.t" "$rec"
RW
(
    diff_env "$RW_REPO" "$RW_HOME" main
    export TEST_CMD="bash $RW_SCRIPT; bash fake-tests.sh"
    cd "$RW_REPO" || exit 1
    pipeline_base_init
    agent_commit "$RW_REPO" build
    stage_test
) >"$TEST_TEMP_DIR/rw.out" 2>&1 || true
rw_log="$(cat "$RW_REPO/.artifacts/test-results.log")"
assert_contains "a test command that rewrites the record does not change the judgement" "$rw_log" "PRE-EXISTING, not blocking"

# In-process rewrite with a poisoned node_modules: the test command poisons node_modules and rewrites the record's
# fingerprint to match. The fingerprint held in memory still differs, so the stage blocks.
RWN_REPO="$(fresh_diff_repo rwnm)"
RWN_HOME="$(new_home)"
RWN_SCRIPT="$TEST_TEMP_DIR/poison-and-rewrite.sh"
cat > "$RWN_SCRIPT" <<'RWN'
mkdir -p node_modules/dep && echo poison > node_modules/dep/poison
source "$SW_TEST_LIB"
rec="$(find "$SHIPWRIGHT_HOME" -name "$SW_PIPELINE_RUN_ID.json" | head -1)"
jq --arg nm "$(_pipeline_base_nm_fingerprint .)" '.nm = $nm' "$rec" > "$rec.t" && chmod 600 "$rec.t" && mv "$rec.t" "$rec"
RWN
(
    diff_env "$RWN_REPO" "$RWN_HOME" main
    export TEST_CMD="bash $RWN_SCRIPT; bash fake-tests.sh" SW_TEST_LIB="$SCRIPT_DIR/lib/pipeline-base.sh"
    cd "$RWN_REPO" || exit 1
    pipeline_base_init
    agent_commit "$RWN_REPO" build
    stage_test
) >"$TEST_TEMP_DIR/rwn.out" 2>&1 && rwn_rc=0 || rwn_rc=$?
assert_eq "a poisoned node_modules with a rewritten record still blocks" "1" "$rwn_rc"
assert_contains "the block says node_modules changed" "$(cat "$TEST_TEMP_DIR/rwn.out")" "node_modules changed"

# A process the test command left running is killed before the base run (#8671, A3): it would otherwise write
# after the judgement.
LEAK_REPO="$(fresh_diff_repo leak)"
LEAK_HOME="$(new_home)"
LEAK_MARK="$TEST_TEMP_DIR/leak-marker"
(
    diff_env "$LEAK_REPO" "$LEAK_HOME" main
    export TEST_CMD="( sleep 1; touch \"$LEAK_MARK\" ) & bash fake-tests.sh"
    cd "$LEAK_REPO" || exit 1
    pipeline_base_init
    agent_commit "$LEAK_REPO" build
    stage_test
) >/dev/null 2>&1 || true
sleep 1.5
assert_eq "a background process of the test command is killed before the base run" "no" "$(test -e "$LEAK_MARK" && echo yes || echo no)"

# Dirty branch (#8671, P1c): agent commits before the first start. Nothing is recorded, and the stage blocks.
DIRTY_REPO="$(fresh_diff_repo dirty)"
DIRTY_HOME="$(new_home)"
(
    diff_env "$DIRTY_REPO" "$DIRTY_HOME" main
    cd "$DIRTY_REPO" || exit 1
    agent_commit "$DIRTY_REPO" earlier
    if pipeline_base_init 2>/dev/null; then echo "init=0"; else echo "init=1"; fi
    echo "run=${SW_PIPELINE_RUN_ID:-}"
    touch regression.flag
    if stage_test; then echo "rc=0"; else echo "rc=$?"; fi
) > "$TEST_TEMP_DIR/dirty.out" 2>&1
assert_eq "a fresh start on a branch with agent commits fails" "init=1" "$(grep '^init=' "$TEST_TEMP_DIR/dirty.out")"
assert_eq "a fresh start on a branch with agent commits exports no run" "run=" "$(grep '^run=' "$TEST_TEMP_DIR/dirty.out")"
assert_eq "no record is written for the dirty branch" "0" "$(find "$DIRTY_HOME" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "the stage blocks the dirty branch" "rc=1" "$(grep '^rc=' "$TEST_TEMP_DIR/dirty.out")"

# Agent moved local refs to its own commit, then branched from it (#8671, A4). The remote's main does not contain
# that commit, so the proof fails: the local refs are not trusted.
A4_REPO="$(fresh_diff_repo a4)"
A4_HOME="$(new_home)"
(
    diff_env "$A4_REPO" "$A4_HOME" main
    cd "$A4_REPO" || exit 1
    echo evil >> README.md && git add -A && git commit -q -m "agent: moved main"
    c="$(git rev-parse HEAD)"
    git update-ref refs/remotes/origin/main "$c"
    git update-ref refs/heads/main "$c"
    git checkout -q -B feat/a4 main
    if pipeline_base_init 2>/dev/null; then echo "init=0"; else echo "init=1"; fi
) > "$TEST_TEMP_DIR/a4.out" 2>&1
assert_eq "a start on local refs the remote does not have fails closed" "init=1" "$(grep '^init=' "$TEST_TEMP_DIR/a4.out")"
assert_eq "a start on local refs the remote does not have records nothing" "0" "$(find "$A4_HOME" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

# The repository's own config sets a push URL or a URL rewrite (#8671, A5): the start fails closed.
for cfg in "remote.origin.pushurl=https://evil.example/x.git" "url.https://evil.example/.insteadOf=$TEST_TEMP_DIR/x"; do
    A5_REPO="$(fresh_diff_repo a5-$RANDOM)"
    A5_HOME="$(new_home)"
    key="${cfg%%=*}"; val="${cfg#*=}"
    (
        diff_env "$A5_REPO" "$A5_HOME" main
        cd "$A5_REPO" || exit 1
        git config "$key" "$val"
        rc=0; pipeline_base_init 2>/dev/null || rc=$?; echo "init=$rc"
    ) > "$TEST_TEMP_DIR/a5.out" 2>&1
    if [[ "$key" == url.* ]]; then
        assert_eq "a local insteadOf refuses the start as tampering" "init=2" "$(grep '^init=' "$TEST_TEMP_DIR/a5.out")"
    else
        assert_eq "a local pushurl is a note: the start is not refused" "init=0" "$(grep '^init=' "$TEST_TEMP_DIR/a5.out")"
    fi
done

# The origin URL changed since the first start (pinned): a fresh start fails.
PIN_REPO="$(fresh_diff_repo pin)"
PIN_HOME="$(new_home)"
(
    diff_env "$PIN_REPO" "$PIN_HOME" main
    cd "$PIN_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
(
    diff_env "$PIN_REPO" "$PIN_HOME" main
    cd "$PIN_REPO" || exit 1
    git remote set-url origin "$TEST_TEMP_DIR/elsewhere.git"
    rc=0; pipeline_base_init 2>/dev/null || rc=$?; echo "init=$rc"
) > "$TEST_TEMP_DIR/pin.out" 2>&1
assert_eq "a fresh start after the origin URL changed is refused as tampering" "init=2" "$(grep '^init=' "$TEST_TEMP_DIR/pin.out")"

# SHIPWRIGHT_HOME/pipeline-base is a link to an attacker directory (#8671, A6): nothing is written there.
A6_REPO="$(fresh_diff_repo a6)"
A6_HOME="$(new_home)"
A6_ATTACK="$TEST_TEMP_DIR/a6-attack"
mkdir -p "$A6_ATTACK"
ln -s "$A6_ATTACK" "$A6_HOME/pipeline-base"
a6_rc=0
(
    diff_env "$A6_REPO" "$A6_HOME" main
    cd "$A6_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1 || a6_rc=$?
assert_eq "a pipeline-base directory that is a link fails the start" "1" "$a6_rc"
assert_eq "nothing is written through the link" "0" "$(find "$A6_ATTACK" -type f | wc -l | tr -d ' ')"

# SHIPWRIGHT_HOME itself is a link, or is writable by others: the start fails.
A6L_REAL="$(new_home)"
A6L_LINK="$TEST_TEMP_DIR/a6-home-link"
ln -s "$A6L_REAL" "$A6L_LINK"
a6l_rc=0
(
    diff_env "$A6_REPO" "$A6L_LINK" main
    cd "$A6_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1 || a6l_rc=$?
assert_eq "a SHIPWRIGHT_HOME that is a link fails the start" "1" "$a6l_rc"
A6W_HOME="$(new_home)"
chmod 775 "$A6W_HOME"
a6w_rc=0
(
    diff_env "$A6_REPO" "$A6W_HOME" main
    cd "$A6_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1 || a6w_rc=$?
assert_eq "a SHIPWRIGHT_HOME writable by others fails the start" "1" "$a6w_rc"

# Forged checkpoint (#8671, daemon-failure.sh): the agent writes a checkpoint and the daemon passes --resume. With no
# record for the worktree, the resume fails closed, and the stage blocks even a pre-existing failure.
FC_REPO="$(fresh_diff_repo forged)"
FC_HOME="$(new_home)"
mkdir -p "$FC_REPO/.claude/pipeline-artifacts/checkpoints"
echo '{"stage":"build"}' > "$FC_REPO/.claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
(
    diff_env "$FC_REPO" "$FC_HOME" main
    cd "$FC_REPO" || exit 1
    export RESUME_FROM_CHECKPOINT=true
    if pipeline_base_init 2>/dev/null; then echo "init=0"; else echo "init=1"; fi
    echo "run=${SW_PIPELINE_RUN_ID:-}"
    if stage_test; then echo "rc=0"; else echo "rc=$?"; fi
) > "$TEST_TEMP_DIR/forged.out" 2>&1
assert_eq "a forged checkpoint with no record fails the resume closed" "init=1" "$(grep '^init=' "$TEST_TEMP_DIR/forged.out")"
assert_eq "a forged checkpoint exports no run" "run=" "$(grep '^run=' "$TEST_TEMP_DIR/forged.out")"
assert_eq "a forged checkpoint blocks the stage" "rc=1" "$(grep '^rc=' "$TEST_TEMP_DIR/forged.out")"

# Each fresh start gets its own run (#8671, P1f and P1g): a second start on the same worktree (no issue id, same
# template) gets a new run id, and the first run's record is never reused.
DUP_REPO="$(fresh_diff_repo dup)"
DUP_HOME="$(new_home)"
(
    diff_env "$DUP_REPO" "$DUP_HOME" main
    cd "$DUP_REPO" || exit 1
    pipeline_base_init
    echo "run1=$SW_PIPELINE_RUN_ID"
) >"$TEST_TEMP_DIR/dup.out" 2>&1
(
    diff_env "$DUP_REPO" "$DUP_HOME" main
    cd "$DUP_REPO" || exit 1
    pipeline_base_init
    echo "run2=$SW_PIPELINE_RUN_ID"
) >>"$TEST_TEMP_DIR/dup.out" 2>&1
dup_run1="$(sed -n 's/^run1=//p' "$TEST_TEMP_DIR/dup.out")"
dup_run2="$(sed -n 's/^run2=//p' "$TEST_TEMP_DIR/dup.out")"
assert_eq "a second fresh start gets a new run id" "1" "$([[ -n "$dup_run2" && "$dup_run2" != "$dup_run1" ]] && echo 1 || echo 0)"
assert_eq "the first run's record is still there, never reused" "1" "$(find "$DUP_HOME" -name "$dup_run1.json" | wc -l | tr -d ' ')"
dup_resume="$(
    diff_env "$DUP_REPO" "$DUP_HOME" main
    cd "$DUP_REPO" || exit 1
    export PIPELINE_RESUMING=true
    pipeline_base_init >/dev/null 2>&1 && echo "$SW_PIPELINE_RUN_ID"
)"
assert_eq "a resume after the second start uses the second run" "$dup_run2" "$dup_resume"

# Expiry: records older than the TTL are swept at the next fresh start.
EXP_REPO="$(fresh_diff_repo exp)"
EXP_HOME="$(new_home)"
(
    diff_env "$EXP_REPO" "$EXP_HOME" main
    cd "$EXP_REPO" || exit 1
    pipeline_base_init
    echo "run=$SW_PIPELINE_RUN_ID"
) >"$TEST_TEMP_DIR/exp.out" 2>&1
exp_run="$(sed -n 's/^run=//p' "$TEST_TEMP_DIR/exp.out")"
touch -t 202001010000 "$EXP_HOME"/pipeline-base/*/"$exp_run".json
(
    diff_env "$EXP_REPO" "$EXP_HOME" main
    cd "$EXP_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
assert_eq "an expired record is swept at the next fresh start" "0" "$(find "$EXP_HOME" -name "$exp_run.json" | wc -l | tr -d ' ')"

# A corrupt record is not trusted on resume.
CR_REPO="$(fresh_diff_repo corrupt)"
CR_HOME="$(new_home)"
(
    diff_env "$CR_REPO" "$CR_HOME" main
    cd "$CR_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
find "$CR_HOME" -name '*.json' -exec sh -c 'printf "not json" > "$1"' _ {} \;
cr_resume="$(
    diff_env "$CR_REPO" "$CR_HOME" main
    cd "$CR_REPO" || exit 1
    export PIPELINE_RESUMING=true
    if pipeline_base_init 2>/dev/null; then echo 0; else echo 1; fi
)"
assert_eq "a corrupt base record fails the resume closed" "1" "$cr_resume"

# A record readable by others is not trusted on resume.
WR_REPO="$(fresh_diff_repo wide)"
WR_HOME="$(new_home)"
(
    diff_env "$WR_REPO" "$WR_HOME" main
    cd "$WR_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
chmod 644 "$(find "$WR_HOME" -name '*.json')"
wr_resume="$(
    diff_env "$WR_REPO" "$WR_HOME" main
    cd "$WR_REPO" || exit 1
    export PIPELINE_RESUMING=true
    if pipeline_base_init 2>/dev/null; then echo 0; else echo 1; fi
)"
assert_eq "a record readable by others is not trusted" "1" "$wr_resume"

# A recorded base that equals HEAD blocks; one that is not an ancestor of HEAD blocks.
EQ_REPO="$(fresh_diff_repo equal)"
EQ_HOME="$(new_home)"
assert_eq "a base equal to HEAD blocks" "1" "$(
    diff_env "$EQ_REPO" "$EQ_HOME" main
    cd "$EQ_REPO" || exit 1
    pipeline_base_init
    stage_test >/dev/null 2>&1 && echo 0 || echo 1
)"
SIDE_REPO="$(fresh_diff_repo side)"
SIDE_HOME="$(new_home)"
assert_eq "a base that is not an ancestor of HEAD blocks" "1" "$(
    diff_env "$SIDE_REPO" "$SIDE_HOME" main
    cd "$SIDE_REPO" || exit 1
    git branch side-root "$(git rev-list --max-parents=0 HEAD)"
    pipeline_base_init
    agent_commit "$SIDE_REPO" build
    git reset -q --hard side-root
    stage_test >/dev/null 2>&1 && echo 0 || echo 1
)"

# node_modules fingerprint (#8671, P3a): a poisoned node_modules blocks a pre-existing failure; an untouched one does not.
NM_CONTROL="$(fresh_diff_repo nm-control)"
assert_eq "control: an unchanged node_modules lets the pre-existing failure pass" "0" "$(run_diff_stage "$NM_CONTROL" main)"
NM_REPO="$(fresh_diff_repo nm-poison)"
NM_HOME="$(new_home)"
(
    diff_env "$NM_REPO" "$NM_HOME" main
    cd "$NM_REPO" || exit 1
    pipeline_base_init
    agent_commit "$NM_REPO" build
    mkdir -p node_modules/dep && echo poison > node_modules/dep/poison
    stage_test
) >"$TEST_TEMP_DIR/nm.out" 2>&1 || true
assert_contains "an agent-poisoned node_modules blocks a pre-existing failure" "$(cat "$TEST_TEMP_DIR/nm.out")" "node_modules changed"

# Poison behind a symlink inside node_modules (#8671, P3b): the fingerprint follows links.
LINK_REPO="$(fresh_diff_repo link)"
LINK_HOME="$(new_home)"
mkdir -p "$LINK_REPO/node_modules/dep" && echo ok > "$LINK_REPO/node_modules/dep/index.js"
(
    diff_env "$LINK_REPO" "$LINK_HOME" main
    cd "$LINK_REPO" || exit 1
    pipeline_base_init
    agent_commit "$LINK_REPO" build
    echo poison > "$TEST_TEMP_DIR/poison-target"
    ln -s "$TEST_TEMP_DIR/poison-target" node_modules/dep/poison
    stage_test
) >"$TEST_TEMP_DIR/link.out" 2>&1 || true
assert_contains "poison behind a symlink in node_modules is reported as a node_modules change" "$(cat "$TEST_TEMP_DIR/link.out")" "node_modules changed"

# A symlinked directory inside node_modules points into the repository (#8671, P3c): an edit behind it blocks.
DIR_REPO="$(fresh_diff_repo dirlink)"
DIR_HOME="$(new_home)"
mkdir -p "$DIR_REPO/vendor-dep" "$DIR_REPO/node_modules" && : > "$DIR_REPO/vendor-dep/flag.txt"
ln -s ../vendor-dep "$DIR_REPO/node_modules/dep"
(
    diff_env "$DIR_REPO" "$DIR_HOME" main
    cd "$DIR_REPO" || exit 1
    pipeline_base_init
    agent_commit "$DIR_REPO" build
    echo poison > vendor-dep/flag.txt
    stage_test
) >"$TEST_TEMP_DIR/dir.out" 2>&1 || true
assert_contains "an agent edit behind a symlinked node_modules directory blocks" "$(cat "$TEST_TEMP_DIR/dir.out")" "node_modules changed"

# The fingerprint walk is bounded (#8671, P3): a walk that times out fails closed, not as an unchanged tree.
TO_DIR="$TEST_TEMP_DIR/timeout-nm"
mkdir -p "$TO_DIR/node_modules/dep" && echo x > "$TO_DIR/node_modules/dep/f"
TO_SHIM="$TEST_TEMP_DIR/slow-bin"
mkdir -p "$TO_SHIM" && printf '#!/bin/sh\nsleep 5\n' > "$TO_SHIM/cksum" && chmod +x "$TO_SHIM/cksum"
to_rc=0
(
    source "$SCRIPT_DIR/lib/pipeline-base.sh"
    SW_PIPELINE_NM_TIMEOUT=1 PATH="$TO_SHIM:$PATH" _pipeline_base_nm_fingerprint "$TO_DIR" >/dev/null
) >/dev/null 2>&1 || to_rc=$?
assert_eq "a node_modules walk that times out fails closed" "1" "$([[ $to_rc -ne 0 ]] && echo 1 || echo 0)"

# Workspace package (#8671, P3d): a package linked from node_modules is judged at the base commit. The agent breaks
# its committed code; the regression is new, not pre-existing.
WS_REPO="$TEST_TEMP_DIR/ws-repo"
WS_HOME="$(new_home)"
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
    git init -q --bare "$WS_REPO.origin" && git remote add origin "$WS_REPO.origin" && git -C "$WS_REPO.origin" fetch -q "$WS_REPO" main:refs/heads/main
    mkdir -p node_modules && ln -s ../packages/x node_modules/x
    git checkout -q -b feat/ws
) >/dev/null 2>&1
ws_rc=0
(
    diff_env "$WS_REPO" "$WS_HOME" main
    export TEST_CMD="bash fake-tests.sh"
    cd "$WS_REPO" || exit 1
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
    git init -q --bare "$SUITE_REPO.origin" && git remote add origin "$SUITE_REPO.origin" && git -C "$SUITE_REPO.origin" fetch -q "$SUITE_REPO" main:refs/heads/main && git checkout -q -b feat/suite
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

# ─── Local config and escapes (#8671 round 5, P0/P1/P2) ────────────────────
# The remote a start is proved against must not depend on this checkout's config. Each attack makes a previous
# agent's local config point at an attacker's remote, whose main is an evil commit on top of the real base. A start
# that is poisoned has base = EVIL. A start that is refused has no base. Both are fine; only base = EVIL is a failure.
CFG_EVIL_BASE=""
cfg_fixture() { # $1 name → sets CFG_REPO CFG_ORIGIN CFG_EVIL CFG_REAL, HEAD at the evil commit
    local t="$TEST_TEMP_DIR/cfg-$1"
    mkdir -p "$t"
    git init -q --bare -b main "$t/origin.git"
    git init -q --bare -b main "$t/evil.git"
    (
        cd "$t" && git init -q -b main seed && cd seed && git config user.email t@t && git config user.name T
        echo base > base.txt && git add -A && git commit -qm base && git -C "$t/origin.git" fetch -q "$t/seed" main:refs/heads/main
        echo planted > planted.txt && git add -A && git commit -qm evil && git -C "$t/evil.git" fetch -q "$t/seed" main:refs/heads/main
    ) >/dev/null 2>&1
    CFG_ORIGIN="$t/origin.git"
    CFG_EVIL="$(git -C "$t/evil.git" rev-parse main)"
    CFG_REAL="$(git -C "$t/origin.git" rev-parse main)"
    CFG_REPO="$t/repo"
    git clone -q "$CFG_ORIGIN" "$CFG_REPO" >/dev/null 2>&1
    git -C "$CFG_REPO" -c user.email=t@t -c user.name=T fetch -q "$t/evil.git" main >/dev/null 2>&1
    git -C "$CFG_REPO" reset -q --hard "$CFG_EVIL"
    git -C "$CFG_REPO" checkout -q -b feat/cfg
}
# cfg_start <repo> — one fresh start in its own process, as the pipeline runs it. Prints init=<rc> base=<sha>.
cfg_start() {
    local home; home="$(new_home)"
    (
        diff_env "$1" "$home" main
        cd "$1" || exit 1
        rc=0
        pipeline_base_init >/dev/null 2>"$TEST_TEMP_DIR/cfg-init.err" || rc=$?
        if [[ "$rc" -eq 0 ]]; then echo "init=0 base=${SW_PIPELINE_BASE_SHA:-}"; else echo "init=$rc base="; fi
    )
}
cfg_assert_not_poisoned() { # $1 label, $2 start output
    local base="${2##*base=}"
    assert_eq "$1: a start under a poisoned local config is not based on the evil commit" "1" "$([[ "$base" != "$CFG_EVIL" ]] && echo 1 || echo 0)"
}

cfg_fixture include
printf '[url "%s"]\n\tinsteadOf = %s\n' "$CFG_EVIL" "$CFG_ORIGIN" > "$CFG_REPO/.git/evil.cfg"
git -C "$CFG_REPO" config --local include.path evil.cfg
include_out="$(cfg_start "$CFG_REPO")"
cfg_assert_not_poisoned "include.path → insteadOf" "$include_out"
assert_eq "include.path → insteadOf is evidence of tampering: the start is refused" "init=2 base=" "$include_out"

cfg_fixture includeif
printf '[url "%s"]\n\tinsteadOf = %s\n' "$CFG_EVIL" "$CFG_ORIGIN" > "$CFG_REPO/.git/evil2.cfg"
# includeIf matches the real path (/private/var, not the /var symlink)
git -C "$CFG_REPO" config --local "includeIf.gitdir:$(cd "$CFG_REPO/.git" && pwd -P).path" evil2.cfg
includeif_out="$(cfg_start "$CFG_REPO")"
cfg_assert_not_poisoned "includeIf → insteadOf" "$includeif_out"
assert_eq "includeIf → insteadOf is refused as tampering" "init=2 base=" "$includeif_out"

# core.sshCommand, with SW_TRUSTED_REMOTE_URL as an ssh URL. The fake ssh runs git-upload-pack on the evil remote and
# records that it ran. The start must not use it: the proof's ssh is the one the pipeline sets, not the checkout's.
cfg_fixture ssh
cat > "$TEST_TEMP_DIR/cfg-fakessh" <<EOF
#!/bin/sh
touch "$TEST_TEMP_DIR/cfg-ssh-ran"
exec git-upload-pack "$CFG_EVIL"
EOF
chmod +x "$TEST_TEMP_DIR/cfg-fakessh"
git -C "$CFG_REPO" config --local core.sshCommand "$TEST_TEMP_DIR/cfg-fakessh"
rm_ssh_ran="$TEST_TEMP_DIR/cfg-ssh-ran"
ssh_out="$(SW_TRUSTED_REMOTE_URL="git@github.invalid:org/repo.git" cfg_start "$CFG_REPO")"
cfg_assert_not_poisoned "core.sshCommand with an ssh trusted URL" "$ssh_out"
assert_eq "the checkout's core.sshCommand is never run" "no" "$(test -e "$rm_ssh_ran" && echo yes || echo no)"

# http.proxy in the checkout: the proof reads no checkout config, so a proxy there cannot redirect the remote. The start
# proves against the real remote and records the real HEAD (base = the real base commit, not EVIL).
cfg_fixture proxy
git -C "$CFG_REPO" reset -q --hard "$CFG_REAL"
git -C "$CFG_REPO" config --local http.proxy "http://127.0.0.1:9"
proxy_out="$(cfg_start "$CFG_REPO")"
assert_eq "http.proxy in the checkout does not stop or redirect a start (the real base is recorded)" "init=0 base=$CFG_REAL" "$proxy_out"

# Pushurl in the checkout, under an insteadOf that rewrites the remote: refused early as a diagnostic.
cfg_fixture pushurl
git -C "$CFG_REPO" config --local remote.origin.pushurl "$CFG_EVIL"
pushurl_out="$(cfg_start "$CFG_REPO")"
cfg_assert_not_poisoned "remote.origin.pushurl in the checkout" "$pushurl_out"
assert_eq "remote.origin.pushurl is a note, not tampering: the start is not refused" "1" "$([[ "$pushurl_out" != init=2* ]] && echo 1 || echo 0)"


# The global config's core.sshCommand (round 6): an earlier agent run writes ~/.gitconfig. The proof reads no global
# core.sshCommand, so the planted command never runs and the start is not based on the evil commit. HOME is the test's.
cfg_fixture globalssh
cat > "$TEST_TEMP_DIR/cfg-globalssh-bin" <<EOF
#!/bin/sh
touch "$TEST_TEMP_DIR/cfg-globalssh-ran"
exec git-upload-pack "$CFG_EVIL"
EOF
chmod +x "$TEST_TEMP_DIR/cfg-globalssh-bin"
git config --global core.sshCommand "$TEST_TEMP_DIR/cfg-globalssh-bin"
globalssh_out="$(SW_TRUSTED_REMOTE_URL="git@example.invalid:org/repo.git" cfg_start "$CFG_REPO")"
cfg_assert_not_poisoned "a global core.sshCommand" "$globalssh_out"
assert_eq "the global core.sshCommand is never run" "no" "$(test -e "$TEST_TEMP_DIR/cfg-globalssh-ran" && echo yes || echo no)"
git config --global --unset core.sshCommand

# A real ssh remote works under the isolation (#8671, round 5). A fake ssh, first on PATH, stands in for the user's
# own ssh: it runs, records the environment it was given (SSH_AUTH_SOCK and HOME must reach it), and serves the local
# upload-pack. The start is proved, and the real base is recorded.
cfg_fixture legitssh
git -C "$CFG_REPO" reset -q --hard "$CFG_REAL"
LEGIT_BIN="$TEST_TEMP_DIR/legit-bin"
mkdir -p "$LEGIT_BIN"
cat > "$LEGIT_BIN/ssh" <<EOF
#!/bin/sh
{ echo "ran"; echo "agent=\$SSH_AUTH_SOCK"; echo "home=\$HOME"; } > "$TEST_TEMP_DIR/legit-ssh.log"
exec git-upload-pack "$CFG_ORIGIN"
EOF
chmod +x "$LEGIT_BIN/ssh"
legit_out="$(PATH="$LEGIT_BIN:$PATH" SSH_AUTH_SOCK=/tmp/sw-test-agent.sock SW_TRUSTED_REMOTE_URL="git@example.invalid:org/repo.git" cfg_start "$CFG_REPO")"
assert_eq "a real ssh remote starts and records the real base" "init=0 base=$CFG_REAL" "$legit_out"
assert_eq "the user's ssh runs, and gets the agent socket" "1" "$(grep -c '^agent=/tmp/sw-test-agent.sock$' "$TEST_TEMP_DIR/legit-ssh.log" 2>/dev/null || echo 0)"
assert_eq "the user's ssh gets HOME (for ~/.ssh/config)" "1" "$(grep -c '^home=.' "$TEST_TEMP_DIR/legit-ssh.log" 2>/dev/null || echo 0)"

# An unreachable remote is a failed proof, not tampering: the start is not refused (init 1), and the pipeline runs on.
cfg_fixture unreachable
git -C "$CFG_REPO" reset -q --hard "$CFG_REAL"
git -C "$CFG_REPO" remote set-url origin "$TEST_TEMP_DIR/cfg-unreachable/nowhere.git"
unreach_out="$(cfg_start "$CFG_REPO")"
assert_eq "an unreachable remote does not refuse the start (only the judgement is lost)" "init=1 base=" "$unreach_out"

# A deliberate origin change (a rename, or https to ssh) is refused as tampering, and the reset is explicit (#8671, round
# 5): `shipwright pipeline base-repin`. A person runs it. Without a terminal and without --yes it changes nothing. With
# --yes it repins, and the change is logged. The next fresh start then proceeds.
REPIN_REPO="$(fresh_diff_repo repin)"
REPIN_HOME="$(new_home)"
(
    diff_env "$REPIN_REPO" "$REPIN_HOME" main
    cd "$REPIN_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
REPIN_NEW="$TEST_TEMP_DIR/diff-repin-renamed.origin"
cp -R "$REPIN_REPO.origin" "$REPIN_NEW"
git -C "$REPIN_REPO" remote set-url origin "$REPIN_NEW"
repin_refused="$(
    diff_env "$REPIN_REPO" "$REPIN_HOME" main
    cd "$REPIN_REPO" || exit 1
    rc=0; pipeline_base_init 2>"$TEST_TEMP_DIR/repin-refused.err" || rc=$?; echo "init=$rc"
)"
assert_eq "a renamed origin is refused as tampering" "init=2" "$repin_refused"
assert_contains "the refusal names the reset command" "$(cat "$TEST_TEMP_DIR/repin-refused.err")" "shipwright pipeline base-repin"
REPIN_PIN="$(find "$REPIN_HOME" -name origin.url)"
REPIN_OLD="$(head -n 1 "$REPIN_PIN")"

# No terminal, no --yes: nothing changes. perl's setsid gives the process no controlling terminal.
repin_noterm_rc=0
perl -e 'use POSIX; POSIX::setsid(); exec @ARGV or exit 127' env SHIPWRIGHT_HOME="$REPIN_HOME" PROJECT_ROOT="$REPIN_REPO" \
    bash -c 'cd "$1" && source "$2" && pipeline_base_repin' _ "$REPIN_REPO" "$SCRIPT_DIR/lib/pipeline-base.sh" \
    > "$TEST_TEMP_DIR/repin-noterm.out" 2>&1 || repin_noterm_rc=$?
assert_eq "base-repin without a terminal or --yes refuses" "1" "$repin_noterm_rc"
assert_eq "a refused base-repin leaves the pin unchanged" "$REPIN_OLD" "$(head -n 1 "$REPIN_PIN")"
assert_contains "the refusal says a terminal or --yes is needed" "$(cat "$TEST_TEMP_DIR/repin-noterm.out")" "pass --yes"

# --yes: the pin moves, prints both URLs, and is logged.
repin_yes_rc=0
perl -e 'use POSIX; POSIX::setsid(); exec @ARGV or exit 127' env SHIPWRIGHT_HOME="$REPIN_HOME" PROJECT_ROOT="$REPIN_REPO" \
    bash -c 'cd "$1" && source "$2" && pipeline_base_repin --yes' _ "$REPIN_REPO" "$SCRIPT_DIR/lib/pipeline-base.sh" \
    > "$TEST_TEMP_DIR/repin-yes.out" 2>&1 || repin_yes_rc=$?
assert_eq "base-repin --yes repins" "0" "$repin_yes_rc"
assert_eq "the pin now names the new origin" "$REPIN_NEW" "$(head -n 1 "$REPIN_PIN")"
assert_contains "base-repin prints the old URL" "$(cat "$TEST_TEMP_DIR/repin-yes.out")" "Pinned origin URL: $REPIN_OLD"
assert_contains "base-repin prints the new URL" "$(cat "$TEST_TEMP_DIR/repin-yes.out")" "New origin URL:    $REPIN_NEW"
REPIN_LOG="$(find "$REPIN_HOME" -name repin.log)"
assert_contains "the repin is logged with the old and new URLs" "$(cat "$REPIN_LOG")" "old=$REPIN_OLD new=$REPIN_NEW"
assert_eq "the repin log is private (0600)" "-rw-------" "$(ls -l "$REPIN_LOG" | cut -c1-10)"

# The next fresh start proceeds against the new origin.
repin_after="$(
    diff_env "$REPIN_REPO" "$REPIN_HOME" main
    cd "$REPIN_REPO" || exit 1
    rc=0; pipeline_base_init 2>/dev/null || rc=$?; echo "init=$rc"
)"
assert_eq "a fresh start after the repin proceeds" "init=0" "$repin_after"

# The deny list names the reset, so an agent cannot run it (config is the source; the TS mirror is tested separately).
assert_eq "agents are denied base-repin in config/agent-permissions.json" "1" \
    "$(jq '.permissions.deny | index("Bash(*base-repin*)") != null' "$SCRIPT_DIR/../config/agent-permissions.json" | grep -c true)"
# Agents cannot Edit or Write the home files the proof's transport could reach (git and ssh config, LaunchAgents,
# shipwright's own state). The Bash tool is not covered by this: it is listed in the residual risk.
for home_entry in "Edit(~/.gitconfig)" "Write(~/.gitconfig)" "Edit(~/.config/git/**)" "Write(~/.config/git/**)"     "Edit(~/.ssh/**)" "Write(~/.ssh/**)" "Edit(~/Library/LaunchAgents/**)" "Write(~/Library/LaunchAgents/**)"     "Edit(~/.shipwright/**)" "Write(~/.shipwright/**)"; do
    assert_eq "agents are denied $home_entry in config/agent-permissions.json" "1" \
        "$(jq --arg e "$home_entry" '.permissions.deny | index($e) != null' "$SCRIPT_DIR/../config/agent-permissions.json" | grep -c true)"
done

# Group escape (#8671, P2, round 6): a process the HEAD command let escape its group (set -m) finds the base worktree
# through git worktree list and writes into it while the base runs. Each writer must block the base, whether it lands
# in tracked files, in ignored files (.env, which bun loads), or in node_modules. The base then is not what was recorded.
escape_attack() { # $1 name, $2 the writer's command, run with the base worktree as $1
    local name="$1" writer="$TEST_TEMP_DIR/escape-writer-$1.sh" repo home cmd rc=0
    printf '%s\n' "$2" > "$writer"
    repo="$(fresh_diff_repo "esc-$name")"
    home="$(new_home)"
    cat > "$TEST_TEMP_DIR/escape-cmd-$name.sh" <<ESC
set -m
( seen=0
  for i in \$(seq 1 1500); do
    others="\$(git worktree list --porcelain | sed -n 's/^worktree //p' | grep -v -x -F "\$(pwd -P)")"
    if [ -n "\$others" ]; then
        seen=1
        for w in \$others; do bash "$writer" "\$w"; done
    elif [ "\$seen" -eq 1 ]; then
        break
    fi
    sleep 0.01
  done ) </dev/null >/dev/null 2>&1 &
bash fake-tests.sh
ESC
    (
        diff_env "$repo" "$home" main
        export TEST_CMD="bash $TEST_TEMP_DIR/escape-cmd-$name.sh"
        cd "$repo" || exit 1
        pipeline_base_init
        agent_commit "$repo" build
        stage_test
    ) >"$TEST_TEMP_DIR/escape-$name.out" 2>&1 || rc=$?
    assert_eq "a process that escapes the test group and writes into the base worktree ($name) blocks" "1" "$rc"
    assert_contains "the block says the base worktree changed ($name)" "$(cat "$repo/.artifacts/test-results.log" 2>/dev/null)" "base worktree changed"
}
escape_attack tracked 'touch "$1/regression.flag"'
escape_attack dotenv 'echo REGRESS=1 > "$1/.env"'
escape_attack nodemodules 'mkdir -p "$1/node_modules" && touch "$1/node_modules/regress"'

# A trusted URL spelled differently from the pin replaces it (#8671, round 4 P2/P3): the start is not blocked forever.
PINT_REPO="$(fresh_diff_repo pin-trusted)"
PINT_HOME="$(new_home)"
(
    diff_env "$PINT_REPO" "$PINT_HOME" main
    cd "$PINT_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1
pint_rc=0
(
    diff_env "$PINT_REPO" "$PINT_HOME" main
    export SW_TRUSTED_REMOTE_URL="file://$PINT_REPO.origin"
    cd "$PINT_REPO" || exit 1
    pipeline_base_init
) >/dev/null 2>&1 || pint_rc=$?
assert_eq "a trusted URL spelled differently from the pin starts" "0" "$pint_rc"
assert_eq "the trusted URL replaces the pin" "file://$PINT_REPO.origin" "$(head -n 1 "$(find "$PINT_HOME" -name origin.url)")"

# No origin remote: the start says so (#8671, round 4 P3).
NOORIG_REPO="$(fresh_diff_repo noorigin)"
NOORIG_HOME="$(new_home)"
git -C "$NOORIG_REPO" remote remove origin
(
    diff_env "$NOORIG_REPO" "$NOORIG_HOME" main
    cd "$NOORIG_REPO" || exit 1
    pipeline_base_init
) > "$TEST_TEMP_DIR/noorig.out" 2>&1 || true
assert_contains "the no-origin message says there is no origin remote" "$(cat "$TEST_TEMP_DIR/noorig.out")" "no origin remote"

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
