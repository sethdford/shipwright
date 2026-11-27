#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/acceptance-tests test — spec-first acceptance (ADR-0015)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# The decisions (red/green verdicts, integrity) are tested in TypeScript; this suite checks the
# bash orchestration with a fake `sw` and a fake test writer, since CI's bash matrix has no bun.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

REAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REAL_SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: acceptance-tests Tests"

setup_test_env "sw-lib-acceptance-tests-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

FAKE="$TEST_TEMP_DIR/fake"
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$FAKE" "$REPO/src"

# Fake `sw acceptance`: logs each call; behavior from files in $FAKE.
#   red-rc     exit code of verify-red (one line per attempt, consumed in order; default 0)
#   green-rc   exit code of verify-green (default 0)
cat > "$FAKE/sw" <<'SW'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
shift  # "acceptance"
sub="$1"; shift
echo "$sub $*" >> "$dir/calls.log"
arg() { local want="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { echo "$2"; return; }; shift; done; }
if [[ "$sub" == verify-* ]]; then
    r=$(arg --root "$@")
    has=no; [[ -f "$r/tests/feature.test.sh" ]] && has=yes
    printf '%s root=%s jail=%s has=%s\n' "$sub" "$r" "${SW_TEST_JAIL:-}" "$has" >> "$dir/roots.log"
fi
case "$sub" in
    materialize)
        answer=$(arg --answer "$@"); manifest=$(arg --manifest "$@"); root=$(arg --root "$@")
        if grep -q NOT_TESTABLE "$answer"; then echo '{"not_testable":"docs only"}' > "$manifest"; exit 0; fi
        if grep -q BAD_ANSWER "$answer"; then echo "✗ acceptance answer rejected; nothing was written:"; echo "  - tests: bad"; exit 1; fi
        if grep -q WORKFLOW_ANSWER "$answer"; then
            mkdir -p "$root/.github/workflows"
            echo 'on: push' > "$root/.github/workflows/acceptance.yml"
            echo '{"criteria":[{"id":"AC-1","text":"works"}],"tests":[{"path":".github/workflows/acceptance.yml","criteria":["AC-1"]}]}' > "$manifest"
            exit 0
        fi
        mkdir -p "$root/tests"
        echo 'test("AC-1: works")' > "$root/tests/feature.test.sh"
        echo '{"criteria":[{"id":"AC-1","text":"works"}],"tests":[{"path":"tests/feature.test.sh","criteria":["AC-1"]}]}' > "$manifest"
        echo "✓ wrote tests/feature.test.sh" ;;
    verify-red)
        rc=0
        if [[ -s "$dir/red-rc" ]]; then rc=$(head -1 "$dir/red-rc"); tail -n +2 "$dir/red-rc" > "$dir/red-rc.next"; mv "$dir/red-rc.next" "$dir/red-rc"; fi
        if [[ "$rc" -ne 0 ]]; then echo "✗ tests/feature.test.sh: the test already passes, so it does not check the new behavior"; fi
        exit "$rc" ;;
    lock)
        lock=$(arg --lock "$@"); mkdir -p "$(dirname "$lock")"
        echo '{"version":1,"commit":"0123456789abcdef0123456789abcdef01234567","criteria":[{"id":"AC-1","text":"works"}],"tests":[{"path":"tests/feature.test.sh","blob":"x","criteria":["AC-1"]}]}' > "$lock"
        echo "✓ locked" ;;
    verify-green)
        rc=$(cat "$dir/green-rc" 2>/dev/null || echo 0)
        echo "--- tests/feature.test.sh (bash tests/feature.test.sh) ---"
        echo "expected 2 got 1"
        if [[ "$rc" -ne 0 ]]; then echo "✗ integrity acceptance_test_changed: tests/feature.test.sh: locked acceptance test was modified"; echo "✗ acceptance gate failed"; else echo "✓ acceptance tests pass"; fi
        exit "$rc" ;;
esac
SW
# Fake test writer (stands in for agent-exec.sh + claude). Echoes the answer named in $FAKE/answer;
# with $FAKE/side-effect present it also edits the repository, which must be undone.
cat > "$FAKE/agent-exec.sh" <<'AGENT'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
cat > "$dir/last-prompt.txt"
echo "call" >> "$dir/agent-calls.log"
pwd > "$dir/writer-cwd"
if [[ -f "$dir/side-effect" ]]; then echo "hacked" > src/app.sh; echo "x" > stray.txt; fi
answer=$(head -1 "$dir/answers" 2>/dev/null || echo GOOD)
tail -n +2 "$dir/answers" > "$dir/answers.next" 2>/dev/null || true; mv "$dir/answers.next" "$dir/answers" 2>/dev/null || true
echo "$answer"
AGENT
chmod +x "$FAKE/sw" "$FAKE/agent-exec.sh"

git -C "$REPO" init -q
echo 'echo app' > "$REPO/src/app.sh"
git -C "$REPO" -c user.name=t -c user.email=t@e add -A
git -C "$REPO" -c user.name=t -c user.email=t@e commit -qm init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e

info() { :; }; success() { :; }; warn() { :; }; error() { :; }
emit_event() { echo "$1" >> "$FAKE/events.log"; }
_smart_int() { echo "$2"; }
detect_test_cmd() { echo "bash run-tests.sh"; }

SCRIPT_DIR="$FAKE"
PROJECT_ROOT="$REPO"
ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
PIPELINE_CONFIG=""
GOAL="Add a feature"
ISSUE_BODY="It should work"
ISSUE_NUMBER=42
export SHIPWRIGHT_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ARTIFACTS_DIR"
source "$REAL_SCRIPT_DIR/lib/acceptance-tests.sh"
SW_AGENT_EXEC="$FAKE/agent-exec.sh"

reset_fakes() {
    rm -f "$FAKE"/calls.log "$FAKE"/agent-calls.log "$FAKE"/events.log "$FAKE"/red-rc "$FAKE"/green-rc \
        "$FAKE"/answers "$FAKE"/side-effect "$FAKE"/writer-cwd "$ARTIFACTS_DIR"/acceptance*
    rm -rf "$REPO/.github"
    rm -rf "$SHIPWRIGHT_STATE_DIR/acceptance"
    rm -rf "$REPO/tests"
    git -C "$REPO" reset -q --hard "$(git -C "$REPO" rev-list --max-parents=0 HEAD)"
}

echo ""
echo -e "${DIM}  mode${RESET}"
assert_eq "default mode is enforce" "enforce" "$(SW_ACCEPTANCE="" acceptance_mode)"
assert_eq "off" "off" "$(SW_ACCEPTANCE=off acceptance_mode)"
assert_eq "advisory maps to warn" "warn" "$(SW_ACCEPTANCE=advisory acceptance_mode)"
echo '{"acceptance":{"mode":"off"}}' > "$TEST_TEMP_DIR/config.json"
assert_eq "pipeline config sets the mode" "off" "$(SW_ACCEPTANCE="" PIPELINE_CONFIG="$TEST_TEMP_DIR/config.json" acceptance_mode)"

echo ""
echo -e "${DIM}  generate: red on the first try${RESET}"
reset_fakes
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "returns 0" "0" "$rc"
assert_file_exists "lock written outside the working tree" "$(acceptance_lock_file)"
assert_contains "lock is under the state dir" "$(acceptance_lock_file)" "$SHIPWRIGHT_STATE_DIR/acceptance/"
assert_file_exists "readable copy in the artifacts" "$ARTIFACTS_DIR/acceptance-lock.json"
assert_contains "commit holds only the test file" "$(git -C "$REPO" show --stat --format=%s HEAD)" "tests/feature.test.sh"
assert_contains "commit names the issue and criteria" "$(git -C "$REPO" log -1 --format=%s)" "acceptance tests for #42 (AC-1)"
assert_eq "one file in the commit" "1" "$(git -C "$REPO" show --name-only --format= HEAD | grep -c . || true)"
assert_contains "verify-red got the test command" "$(cat "$FAKE/calls.log")" "verify-red --manifest $ARTIFACTS_DIR/acceptance.json --test-cmd bash run-tests.sh --root "
red_line=$(grep '^verify-red ' "$FAKE/roots.log" | tail -1)
red_root=$(printf '%s' "$red_line" | sed -E 's/^verify-red root=([^ ]*) .*/\1/')
case "$red_root" in
    */sw-test-sandbox.*/repo) assert_pass "verify-red runs in a test sandbox, not the checkout" ;;
    *) assert_fail "verify-red runs in a test sandbox, not the checkout (root: $red_root)" ;;
esac
assert_contains "the sandbox holds the uncommitted test file" "$red_line" "has=yes"
assert_contains "verify-red's test commands are jailed to the sandbox" "$red_line" "jail=$red_root"
if [[ -e "$red_root" ]]; then assert_fail "the verify-red sandbox is removed"; else assert_pass "the verify-red sandbox is removed"; fi
assert_contains "event: locked" "$(cat "$FAKE/events.log")" "acceptance.locked"

echo ""
echo -e "${DIM}  generate: rejected, then fixed with feedback${RESET}"
reset_fakes
printf '1\n0\n' > "$FAKE/red-rc"
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "second attempt succeeds" "0" "$rc"
assert_eq "two writer calls" "2" "$(grep -c call "$FAKE/agent-calls.log" || true)"
assert_contains "retry prompt carries the rejection" "$(cat "$FAKE/last-prompt.txt")" "the test already passes"

echo ""
echo -e "${DIM}  generate: never red → fails, leaves nothing behind${RESET}"
reset_fakes
printf '1\n1\n1\n' > "$FAKE/red-rc"
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "returns 1 after 3 attempts" "1" "$rc"
assert_file_not_exists "rejected test file removed" "$REPO/tests/feature.test.sh"
assert_file_not_exists "no lock" "$(acceptance_lock_file)"
assert_contains "event: failed" "$(cat "$FAKE/events.log")" "acceptance.failed"

echo ""
echo -e "${DIM}  generate: invalid answer, then good${RESET}"
reset_fakes
printf 'BAD_ANSWER\nGOOD\n' > "$FAKE/answers"
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "recovers" "0" "$rc"
assert_contains "feedback names the problem" "$(cat "$FAKE/last-prompt.txt")" "tests: bad"
assert_contains "writer told to reach the assertion when the code under test crashes" \
    "$(cat "$FAKE/last-prompt.txt")" 'out=$(cmd 2>&1) || rc=$?'

echo ""
echo -e "${DIM}  generate: a writer that edits files is undone and rejected (handoff off)${RESET}"
reset_fakes
touch "$FAKE/side-effect"
printf 'GOOD\nGOOD\nGOOD\n' > "$FAKE/answers"
rc=0; SW_PATCH_HANDOFF=false acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "every attempt rejected" "1" "$rc"
assert_eq "tracked edit reverted" "echo app" "$(cat "$REPO/src/app.sh")"
assert_file_not_exists "untracked stray file removed" "$REPO/stray.txt"
assert_contains "writer told not to edit" "$(cat "$FAKE/last-prompt.txt")" "Do not write, edit or commit anything"

echo ""
echo -e "${DIM}  generate: under handoff the writer works in a disposable clone${RESET}"
reset_fakes
touch "$FAKE/side-effect"
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "the writer's edits never reach the checkout, so the answer is used" "0" "$rc"
assert_eq "tracked file untouched" "echo app" "$(cat "$REPO/src/app.sh")"
assert_file_not_exists "no stray file in the checkout" "$REPO/stray.txt"
cwd=$(cat "$FAKE/writer-cwd")
assert_eq "the writer did not run in the trusted checkout" "no" "$([[ "$cwd" == "$REPO" ]] && echo yes || echo no)"
assert_file_not_exists "the clone is removed afterwards" "$cwd"
assert_eq "one file in the commit" "1" "$(git -C "$REPO" show --name-only --format= HEAD | grep -c . || true)"
assert_file_exists "the judged patch is kept in the artifacts" "$ARTIFACTS_DIR/acceptance.patch"

echo ""
echo -e "${DIM}  generate: test files on a protected path are refused before they run${RESET}"
reset_fakes
printf 'WORKFLOW_ANSWER\nWORKFLOW_ANSWER\nWORKFLOW_ANSWER\n' > "$FAKE/answers"
head_before=$(git -C "$REPO" rev-parse HEAD)
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "every attempt refused" "1" "$rc"
assert_eq "nothing committed" "$head_before" "$(git -C "$REPO" rev-parse HEAD)"
assert_file_not_exists "the workflow file is removed" "$REPO/.github/workflows/acceptance.yml"
assert_eq "verify-red never ran the refused files" "0" "$(grep -c verify-red "$FAKE/calls.log" || true)"
assert_contains "event: patch_refused" "$(cat "$FAKE/events.log")" "acceptance.patch_refused"
assert_contains "feedback names the protected path" "$(cat "$FAKE/last-prompt.txt")" "protected path: .github/workflows/acceptance.yml"

echo ""
echo -e "${DIM}  generate: refused, then an ordinary test file is accepted${RESET}"
reset_fakes
printf 'WORKFLOW_ANSWER\nGOOD\n' > "$FAKE/answers"
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "recovers on the second attempt" "0" "$rc"
assert_contains "commit holds the ordinary test file" "$(git -C "$REPO" show --name-only --format= HEAD)" "tests/feature.test.sh"

echo ""
echo -e "${DIM}  generate: not testable${RESET}"
reset_fakes
echo NOT_TESTABLE > "$FAKE/answers"
rc=0; acceptance_generate "bash run-tests.sh" || rc=$?
assert_eq "not_testable passes" "0" "$rc"
assert_file_not_exists "no lock for not_testable" "$(acceptance_lock_file)"
assert_contains "event: not_testable" "$(cat "$FAKE/events.log")" "acceptance.not_testable"

echo ""
echo -e "${DIM}  build brief and gate${RESET}"
reset_fakes
acceptance_generate "bash run-tests.sh" >/dev/null 2>&1 || true
brief=$(acceptance_build_brief)
assert_contains "brief lists the locked file" "$brief" "tests/feature.test.sh (AC-1)"
assert_contains "brief says the tests are locked" "$brief" "Change the implementation, not the tests"
LOG="$TEST_TEMP_DIR/test-results.log"
rc=0; SW_ACCEPTANCE=enforce acceptance_gate "$LOG" || rc=$?
assert_eq "gate passes" "0" "$rc"
green_line=$(grep '^verify-green ' "$FAKE/roots.log" | tail -1)
case "$green_line" in
    "verify-green root=$REPO "*) assert_fail "verify-green runs in a test sandbox, not the checkout" ;;
    *"/sw-test-sandbox."*"/repo jail="*"/repo has=yes") assert_pass "verify-green runs in a test sandbox, not the checkout" ;;
    *) assert_fail "verify-green runs in a test sandbox, not the checkout ($green_line)" ;;
esac
SW_TEST_SANDBOX=off SW_ACCEPTANCE=enforce acceptance_gate "$LOG" >/dev/null 2>&1 || true
assert_contains "SW_TEST_SANDBOX=off runs verify-green in the checkout" "$(tail -1 "$FAKE/roots.log")" "root=$REPO jail= "
echo 1 > "$FAKE/green-rc"
rc=0; SW_ACCEPTANCE=enforce acceptance_gate "$LOG" || rc=$?
assert_eq "gate fails in enforce mode" "1" "$rc"
assert_contains "test log ends with the verdicts for the retry" "$(tail -3 "$LOG")" "acceptance_test_changed"
assert_contains "test log keeps the failing output" "$(cat "$LOG")" "expected 2 got 1"
rc=0; SW_ACCEPTANCE=warn acceptance_gate "$LOG" || rc=$?
assert_eq "warn mode does not block" "0" "$rc"
assert_contains "warn mode passes --integrity warn" "$(tail -1 "$FAKE/calls.log")" "--integrity warn"
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$ARTIFACTS_DIR/acceptance-lock.json"
rm -f "$(acceptance_lock_file)"
rc=0; SW_ACCEPTANCE=enforce acceptance_gate "$LOG" || rc=$?
assert_eq "no lock, no gate (an artifacts copy is never trusted)" "0" "$rc"

echo ""
echo -e "${DIM}  resume reuses a lock in this branch's history${RESET}"
reset_fakes
acceptance_generate "bash run-tests.sh" >/dev/null 2>&1 || true
# The fake lock names a commit that is not in history: make it the real test commit.
lock=$(acceptance_lock_file)
jq --arg c "$(git -C "$REPO" rev-parse HEAD)" '.commit = $c' "$lock" > "$lock.tmp" && mv "$lock.tmp" "$lock"
rm -f "$FAKE/agent-calls.log"
rc=0; acceptance_generate "bash run-tests.sh" >/dev/null 2>&1 || rc=$?
assert_eq "resume returns 0" "0" "$rc"
assert_file_not_exists "no new writer call on resume" "$FAKE/agent-calls.log"

echo ""
echo -e "${DIM}  the gate puts tampered locked tests back in the checkout${RESET}"
locked_content=$(cat "$REPO/tests/feature.test.sh")
echo 'test("AC-1: works") // weakened' > "$REPO/tests/feature.test.sh"
SW_ACCEPTANCE=warn acceptance_gate "$LOG" >/dev/null 2>&1 || true
assert_eq "the locked test is restored in the checkout" "$locked_content" "$(cat "$REPO/tests/feature.test.sh")"

print_test_results
