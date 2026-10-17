#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/test-gate-baseline test — differential test gate (#8633)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: test-gate-baseline Tests"

setup_test_env "sw-lib-test-gate-baseline-test"
trap cleanup_test_env EXIT

REPO="$TEST_TEMP_DIR/project"
RUNS_FILE="$TEST_TEMP_DIR/runs.txt"
FLAKY_COUNTER="$TEST_TEMP_DIR/flaky-counter.txt"
export LOG_DIR="$TEST_TEMP_DIR/logs"
export TMPDIR="$TEST_TEMP_DIR/tmp"
mkdir -p "$REPO" "$LOG_DIR" "$TMPDIR"
mkdir -p "$REPO/node_modules" && echo sentinel > "$REPO/node_modules/sentinel.txt"

# Fake runner in sw-test-all.sh's output format. fail.txt has one entry per line, and the
# suites it names fail. "suite" fails with no assertion list (a crash); "suite|A1,A2" fails with
# the listed assertions, printed like sw-test-all.sh's per-suite tail.
cat > "$REPO/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
cd "$(dirname "$0")"
f=0; p=0; sections=""
for s in suite-a suite-b suite-c; do
    entry=""
    while IFS= read -r l; do
        case "$l" in "$s"|"$s|"*) entry="$l" ;; esac
    done < <(cat fail.txt 2>/dev/null || true)
    if [[ -n "$entry" ]]; then
        printf '  ✗ %-46s exit 1 0s\n' "$s"
        f=$((f + 1))
        if [[ "$entry" == *"|"* ]]; then
            sections="${sections}━━━ $s (FAIL:1) — last 25 lines ━━━"$'\n'
            list="${entry#*|}"
            for a in ${list//,/ }; do
                sections="${sections}$(printf '      ✗ %s' "$a")"$'\n'
            done
        fi
    else
        printf '  ✓ %-46s 0s\n' "$s"
        p=$((p + 1))
    fi
done
printf '%s' "$sections"
printf '\n  %s passed  %s failed  0 timed out  (3 suites, 0s)\n' "$p" "$f"
[[ "$f" -eq 0 ]]
RUNNER
# Records each execution; the test command is `bash counting-runner.sh`.
cat > "$REPO/counting-runner.sh" <<COUNTING
#!/usr/bin/env bash
echo run >> "$RUNS_FILE"
bash "\$(dirname "\$0")/runner.sh"
COUNTING
# Flaky: the first run fails suite-b, later runs pass.
cat > "$REPO/flaky.sh" <<FLAKY
#!/usr/bin/env bash
n="\$(cat "$FLAKY_COUNTER" 2>/dev/null || echo 0)"
echo \$((n + 1)) > "$FLAKY_COUNTER"
if [[ "\$n" -eq 0 ]]; then
    printf '  ✗ suite-b  exit 1 0s\n'
    printf '  1 passed  1 failed  0 timed out  (2 suites, 0s)\n'
    exit 1
fi
printf '  2 passed  0 failed  0 timed out  (2 suites, 0s)\n'
FLAKY
# Hangs until killed; used for the timeout and interrupt tests.
printf '#!/usr/bin/env bash\nsleep 4711\n' > "$REPO/hang.sh"

git_in_repo() { git -C "$REPO" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }
git_in_repo init -q

# commit_state <entries> — write fail.txt (entries separated by spaces) and commit; prints the SHA.
commit_state() {
    printf '%s\n' $1 > "$REPO/fail.txt"
    git_in_repo add -A >/dev/null 2>&1
    git_in_repo commit -q --allow-empty -m "state: fail=[$1]" >/dev/null 2>&1
    git_in_repo rev-parse HEAD
}
# iter_log <log> — run the runner in the repo's current state; log its output; print its exit code.
iter_log() {
    local log="$1" rc=0
    ( cd "$REPO" && bash runner.sh ) > "$log" 2>&1 || rc=$?
    echo "$rc"
}

# no_sleep_left — poll (up to ~6s) until no test-owned 'sleep 4711' process remains.
no_sleep_left() {
    local _i
    for _i in $(seq 1 30); do
        if ! ps -axo command= | grep -x 'sleep 4711' >/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

export PROJECT_ROOT="$REPO"
export SW_TEST_TIMEOUT=120
source "$SCRIPT_DIR/lib/test-gate-env.sh"
source "$SCRIPT_DIR/lib/test-gate-baseline.sh"

# scenario <base entries> <iteration entries> — base commit and iteration commit, the iteration's
# real run log in ITER_LOG and exit code in ITER_RC, LOOP_START_COMMIT set to the base.
scenario() {
    BASE_SHA="$(commit_state "$1")"
    commit_state "$2" >/dev/null
    ITER_LOG="$LOG_DIR/iter-$RANDOM$RANDOM.log"
    ITER_RC="$(iter_log "$ITER_LOG")"
    LOOP_START_COMMIT="$BASE_SHA"
    tg_begin_gate
}

CMD="bash runner.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# tg_parse_log
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tg_parse_log"

scenario "" "suite-b|A1,A2 suite-c"
tg_parse_log "$ITER_LOG"
assert_eq "sw-test-all log: parsable" "1" "$TG_PARSABLE"
assert_eq "sw-test-all log: assertion-level units" "suite-b::A1
suite-b::A2
suite-c" "$TG_UNITS"
assert_eq "sw-test-all log: pass count" "1" "$TG_PASSCOUNT"

printf 'Ran 2 tests across 1 file. [11.00ms]\n(fail) bad two [3.09ms]\n 1 pass\n 1 fail\n' > "$TEST_TEMP_DIR/bun.log"
tg_parse_log "$TEST_TEMP_DIR/bun.log"
assert_eq "bun log: parsable" "1" "$TG_PARSABLE"
assert_eq "bun log: failing unit without timing" "bad two" "$TG_UNITS"

printf 'Error: Cannot find module x\n' > "$TEST_TEMP_DIR/junk.log"
tg_parse_log "$TEST_TEMP_DIR/junk.log"
assert_eq "unknown output: not parsable" "0" "$TG_PARSABLE"
assert_eq "missing module detected" "1" "$TG_MISSING"

assert_eq "FAIL_LOG_LINES forced for the gate" "100000" "$(sw_test_gate_scrub >/dev/null 2>&1; ( sw_test_gate_scrub && echo "$FAIL_LOG_LINES" ))"

# ═══════════════════════════════════════════════════════════════════════════════
# Regression: base passes, iteration fails -> block
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "regression (base passes)"

scenario "" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "regression blocks" "1" "$rc"
assert_eq "regression: verdict" "regression" "$TG_VERDICT"
assert_eq "regression: base exit 0" "0" "$TG_BASE_EXIT"
assert_eq "regression: not pre-existing" "false" "$TG_PREEXISTING"

# ═══════════════════════════════════════════════════════════════════════════════
# Pre-existing: every failing unit also fails on the base -> do not block
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pre-existing (verified on the base)"

scenario "suite-b" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "pre-existing does not block" "0" "$rc"
assert_eq "pre-existing recorded" "true" "$TG_PREEXISTING"
assert_eq "pre-existing: verdict" "pre-existing" "$TG_VERDICT"
assert_eq "pre-existing: no new failures" "" "$TG_NEW_FAILURES"
if tg_verdict_text | grep 'Do NOT try to fix' >/dev/null; then
    assert_pass "pre-existing verdict tells the agent not to fix"
else
    assert_fail "pre-existing verdict tells the agent not to fix"
fi

scenario "suite-b|A1" "suite-b|A1"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "assertion-level pre-existing does not block" "0" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
# New failures among pre-existing ones -> block, listing only the new units
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "new failures"

scenario "suite-b" "suite-b suite-c"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "new suite failure blocks" "1" "$rc"
assert_eq "new_failures lists only the new suite" "suite-c" "$TG_NEW_FAILURES"
assert_eq "new failure verdict" "new-failures" "$TG_VERDICT"

scenario "suite-b|A1" "suite-b|A1,A2"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "new assertion inside a failing suite blocks" "1" "$rc"
assert_eq "new assertion listed" "suite-b::A2" "$TG_NEW_FAILURES"

scenario "suite-b|A1" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "crashed suite (no assertion list) is not a pre-existing assertion" "1" "$rc"

# Repro A: iteration hangs past the timeout (exit 124) on a failure the base also has -> block
scenario "suite-b" "suite-b"
rc=0; tg_judge "$CMD" 124 "$ITER_LOG" 120 1 || rc=$?
assert_eq "A: iteration timeout blocks" "1" "$rc"
assert_eq "A: verdict timeout" "timeout" "$TG_VERDICT"

# Repro A2: iteration crashes without a runner summary (exit 2) -> block
printf 'syntax error near unexpected token\n' > "$LOG_DIR/crash.log"
scenario "suite-b" "suite-b"
rc=0; tg_judge "$CMD" 2 "$LOG_DIR/crash.log" 120 1 || rc=$?
assert_eq "A2: crash without summary blocks" "1" "$rc"
assert_eq "A2: verdict unattributed" "unattributed" "$TG_VERDICT"

# Repro B: parsable summary and exit 1, but no failing units listed -> block
printf '  0 passed  0 failed  0 timed out  (0 suites, 0s)\nUnhandled error between tests\n' > "$LOG_DIR/nounits.log"
scenario "suite-b" "suite-b"
rc=0; tg_judge "$CMD" 1 "$LOG_DIR/nounits.log" 120 1 || rc=$?
assert_eq "B: parsable with no units blocks" "1" "$rc"
assert_eq "B: verdict unattributed" "unattributed" "$TG_VERDICT"

# ═══════════════════════════════════════════════════════════════════════════════
# Distrust the base: 126/127, missing script, env-broken base, flaky base -> block, no cache
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "untrusted base"

# Repro C: every unit fails on the base (broken environment) -> block
scenario "suite-a suite-b suite-c" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "C: env-broken base blocks" "1" "$rc"
assert_eq "C: base not trusted" "untrusted-baseline" "$TG_VERDICT"

# Repro D: the command does not exist on the base (127) -> block
printf 'echo FAIL; exit 1\n' > "$REPO/newcheck.sh"
printf 'echo FAIL\n' > "$LOG_DIR/newcheck-iter.log"
scenario "" "suite-b"
git_in_repo rm -q --cached newcheck.sh 2>/dev/null || true
rc=0; tg_judge "bash newcheck.sh" 1 "$LOG_DIR/newcheck-iter.log" 120 1 || rc=$?
assert_eq "D: command missing on the base blocks" "1" "$rc"
assert_eq "D: verdict untrusted" "untrusted-baseline" "$TG_VERDICT"
rm -f "$REPO/newcheck.sh"

# Flaky base: the two base runs disagree -> block, and nothing is cached
rm -f "$FLAKY_COUNTER"
scenario "suite-b" "suite-b"
BASE_FLAKY="$(commit_state "suite-b")"
LOOP_START_COMMIT="$BASE_FLAKY"
rc=0; tg_judge "bash flaky.sh" 1 "$ITER_LOG" 120 1 || rc=$?
assert_eq "flaky base blocks" "1" "$rc"
if tg_verdict_text | grep 'flaky' >/dev/null; then
    assert_pass "flaky base verdict names the flakiness"
else
    assert_fail "flaky base verdict names the flakiness" "got: $(tg_verdict_text)"
fi

# A base that hangs past the timeout (watchdog kills its process group) -> block
SW_TEST_TIMEOUT=2
scenario "" "suite-b"
git_in_repo add -A >/dev/null 2>&1; git_in_repo commit -q --allow-empty -m hang >/dev/null 2>&1
LOOP_START_COMMIT="$(git_in_repo rev-parse HEAD)"
start_s=$(date +%s)
rc=0; tg_judge "bash hang.sh" 1 "$ITER_LOG" 2 1 || rc=$?
elapsed=$(( $(date +%s) - start_s ))
SW_TEST_TIMEOUT=120
assert_eq "hanging base blocks (watchdog)" "1" "$rc"
if [[ "$elapsed" -lt 30 ]]; then
    assert_pass "hanging base is killed within the timeout (${elapsed}s)"
else
    assert_fail "hanging base is killed within the timeout" "took ${elapsed}s"
fi
if no_sleep_left; then
    assert_pass "watchdog kill leaves no sleep behind"
else
    assert_fail "watchdog kill leaves no sleep behind"
fi

# Repro G: the loop's base is missing or is a root commit -> block
ROOT_SHA="$(git_in_repo rev-list --max-parents=0 HEAD | tail -1)"
scenario "" "suite-b"
LOOP_START_COMMIT="$ROOT_SHA"
rc=0; tg_judge "$CMD" 1 "$ITER_LOG" 120 1 || rc=$?
assert_eq "G: root-commit base blocks" "1" "$rc"
scenario "suite-b" "suite-b"
LOOP_START_COMMIT=""
rc=0; tg_judge "$CMD" 1 "$ITER_LOG" 120 1 || rc=$?
assert_eq "G: missing base blocks" "1" "$rc"

# Repro E: a forged cache file in LOG_DIR is ignored
scenario "" "suite-b"
printf 'exit=1\nparsable=0\n' > "$LOG_DIR/test-baseline-1.txt"
printf 'exit=1\nparsable=1\nunit=suite-b\n' > "$LOG_DIR/test-baseline-$(printf '%s\n%s' "$LOOP_START_COMMIT" "$CMD" | cksum | awk '{print $1}').txt"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "E: forged LOG_DIR cache ignored (regression still blocks)" "1" "$rc"
assert_eq "E: base is the real base, exit 0" "0" "$TG_BASE_EXIT"

# Created during the loop: no baseline -> block
scenario "suite-b" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 0 || rc=$?
assert_eq "created-in-loop command blocks" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
# Caching: a trusted baseline is computed once (two runs) per command and base commit
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "baseline caching"

: > "$RUNS_FILE"
scenario "suite-b" "suite-b suite-c"
COUNT_CMD="bash counting-runner.sh"
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
assert_eq "trusted baseline: two runs for three judgements" "2" "$(wc -l < "$RUNS_FILE" | tr -d ' ')"

# ═══════════════════════════════════════════════════════════════════════════════
# Cleanup: worktree removed; dependencies survive; interrupt during a base run
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cleanup"

scenario "suite-b" "suite-b"
tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
worktrees="$(git_in_repo worktree list | wc -l | tr -d ' ')"
assert_eq "only the main worktree remains" "1" "$worktrees"
assert_file_exists "node_modules symlink target survives worktree removal" "$REPO/node_modules/sentinel.txt"
leftover="$(ls "$TMPDIR" | grep -c 'sw-test-baseline' || true)"
assert_eq "no base temp dirs left behind" "0" "$leftover"

# Repro int: SIGTERM while the base runs. The base process group is killed and the worktree and
# temp dir are removed.
scenario "" "suite-b"
git_in_repo add -A >/dev/null 2>&1; git_in_repo commit -q --allow-empty -m hang2 >/dev/null 2>&1
LOOP_START_COMMIT="$(git_in_repo rev-parse HEAD)"
( tg_judge "bash hang.sh" 1 "$ITER_LOG" 120 1 ) & jpid=$!
for _ in $(seq 1 50); do
    [[ "$(git_in_repo worktree list | wc -l | tr -d ' ')" -gt 1 ]] && break
    sleep 0.2
done
kill -TERM "$jpid" 2>/dev/null || true
wait "$jpid" 2>/dev/null || true
sleep 1
worktrees="$(git_in_repo worktree list | wc -l | tr -d ' ')"
assert_eq "SIGTERM during a base run: worktree removed" "1" "$worktrees"
leftover="$(ls "$TMPDIR" | grep -c 'sw-test-baseline' || true)"
assert_eq "SIGTERM during a base run: temp dir removed" "0" "$leftover"
if no_sleep_left; then
    assert_pass "SIGTERM during a base run: base process group killed"
else
    assert_fail "SIGTERM during a base run: base process group killed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# tg_record: evidence JSON
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tg_record evidence"

if command -v jq >/dev/null 2>&1; then
    scenario "suite-b" "suite-b suite-c"
    tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
    results="$(tg_record "[]" "$CMD" "$ITER_RC" 7)"
    assert_eq "evidence: baseline_exit_code recorded (base fails: 1)" "1" "$(echo "$results" | jq -r '.[0].baseline_exit_code')"
    assert_eq "evidence: new_failures listed" "suite-c" "$(echo "$results" | jq -r '.[0].new_failures | join(",")')"
    assert_eq "evidence: verdict" "new-failures" "$(echo "$results" | jq -r '.[0].verdict')"
    assert_eq "evidence: exit_code kept" "$ITER_RC" "$(echo "$results" | jq -r '.[0].exit_code')"

    scenario "suite-b" "suite-b"
    tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
    results="$(tg_record "[]" "$CMD" "$ITER_RC" 7)"
    assert_eq "evidence: pre-existing recorded" "true" "$(echo "$results" | jq -r '.[0].preexisting')"

    results="$(tg_record "[]" "npm test" 0 3)"
    assert_eq "evidence: passing command has null baseline" "null" "$(echo "$results" | jq -r '.[0].baseline_exit_code')"
    assert_eq "evidence: passing command verdict pass" "pass" "$(echo "$results" | jq -r '.[0].verdict')"
else
    assert_pass "jq not installed: evidence checks skipped"
fi

print_test_results
