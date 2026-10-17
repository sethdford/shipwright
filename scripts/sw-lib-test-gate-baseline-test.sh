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

# Fake runner in sw-test-all.sh's output shape. state.txt has one "suite:mode[:assertions]" line
# per suite; modes: pass | fail | crash (dies before its completion line) | timeout. Every failing
# suite's section also mentions "No such file or directory" and "command not found", the way real
# suite logs do, so the untrusted-base check must not be fooled by them.
cat > "$REPO/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
cd "$(dirname "$0")"
p=0; f=0; t=0; sections=""
while IFS=: read -r s mode asserts; do
    [[ -z "$s" ]] && continue
    case "$mode" in
        pass) printf '  ✓ %-46s 0s\n' "$s"; p=$((p + 1)); continue ;;
        fail|crash) printf '  ✗ %-46s exit 1 0s\n' "$s"; f=$((f + 1)) ;;
        timeout) printf '  ⧗ %-46s TIMEOUT after 300s\n' "$s"; t=$((t + 1)) ;;
    esac
    sections="${sections}━━━ $s (FAIL:1) — last 25 lines ━━━"$'\n'
    sections="${sections}    log: No such file or directory: /missing/file"$'\n'
    sections="${sections}    error: command not found: foo"$'\n'
    list="${asserts//,/ }"
    for a in $list; do sections="${sections}      ✗ ${a}"$'\n'; done
    if [[ "$mode" == fail ]]; then sections="${sections}    1 of 3 tests failed"$'\n'; fi
done < state.txt
printf '%s' "$sections"
printf '\n  %s passed  %s failed  %s timed out  (n suites, 0s)\n' "$p" "$f" "$t"
[[ $((f + t)) -eq 0 ]]
RUNNER
# Records each execution; the counting test command is `bash counting-runner.sh`.
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
# Hangs until killed; used for the timeout, interrupt and owner-death tests.
printf '#!/usr/bin/env bash\nsleep 4711\n' > "$REPO/hang.sh"

git_in_repo() { git -C "$REPO" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }
git_in_repo init -q

# commit_state <specs> — write state.txt (space-separated specs) and commit; prints the SHA.
commit_state() {
    printf '%s\n' $1 > "$REPO/state.txt"
    git_in_repo add -A >/dev/null 2>&1
    git_in_repo commit -q --allow-empty -m "state: $1" >/dev/null 2>&1
    git_in_repo rev-parse HEAD
}
# no_sleep_left — poll (up to ~6s) until no 'sleep 4711' of the tests is left running.
no_sleep_left() {
    local _i
    for _i in $(seq 1 30); do
        ps -axo command= | grep -x 'sleep 4711' >/dev/null || return 0
        sleep 0.2
    done
    return 1
}
# iter_log <log> — run the runner in the repo's current state; log its output; print its exit code.
iter_log() {
    local log="$1" rc=0
    ( cd "$REPO" && bash runner.sh ) > "$log" 2>&1 || rc=$?
    echo "$rc"
}

export PROJECT_ROOT="$REPO"
export SW_TEST_TIMEOUT=120
source "$SCRIPT_DIR/lib/test-gate-env.sh"
source "$SCRIPT_DIR/lib/test-gate-baseline.sh"

# scenario <base specs> <iteration specs> — base commit, then iteration commit; the iteration's
# real run log is ITER_LOG and its exit code ITER_RC; LOOP_START_COMMIT is the base.
scenario() {
    BASE_SHA="$(commit_state "$1")"
    commit_state "$2" >/dev/null
    ITER_LOG="$LOG_DIR/iter-$RANDOM$RANDOM.log"
    ITER_RC="$(iter_log "$ITER_LOG")"
    LOOP_START_COMMIT="$BASE_SHA"
    tg_begin_gate
}
# judge_iter — judge the scenario's iteration as the loop would; sets JRC to the blocking rc.
judge_iter() {
    JRC=0
    tg_judge "${1:-bash runner.sh}" "$ITER_RC" "$ITER_LOG" 120 1 || JRC=$?
}

CMD="bash runner.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# tg_parse_log
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tg_parse_log"

scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X,Y suite-c:pass"
tg_parse_log "$ITER_LOG"
assert_eq "complete failing suite: parsable" "1" "$TG_PARSABLE"
assert_eq "complete failing suite: status and assertions, no INCOMPLETE" "$(printf 'suite-b::X\nsuite-b::Y\nsuite-b::exit=1\n' | sort)" "$(printf '%s\n' "$TG_UNITS" | sort)"
assert_eq "complete failing suite: pass count" "2" "$TG_PASSCOUNT"

scenario "" "suite-b:crash:X"
tg_parse_log "$ITER_LOG"
if printf '%s\n' "$TG_UNITS" | grep -Fx -- "suite-b::INCOMPLETE" >/dev/null; then
    assert_pass "suite that dies before its completion line is INCOMPLETE"
else
    assert_fail "suite that dies before its completion line is INCOMPLETE" "got: $TG_UNITS"
fi

scenario "" "suite-b:timeout:X"
tg_parse_log "$ITER_LOG"
if printf '%s\n' "$TG_UNITS" | grep -Fx -- "suite-b::TIMEOUT" >/dev/null; then
    assert_pass "timed-out suite has a TIMEOUT unit"
else
    assert_fail "timed-out suite has a TIMEOUT unit" "got: $TG_UNITS"
fi

printf 'Ran 2 tests across 1 file. [11.00ms]\n(fail) bad two [3.09ms]\n 1 pass\n 1 fail\n' > "$TEST_TEMP_DIR/bun.log"
tg_parse_log "$TEST_TEMP_DIR/bun.log"
assert_eq "bun log: parsable" "1" "$TG_PARSABLE"
assert_eq "bun log: failing unit without timing" "bad two" "$TG_UNITS"

printf 'Error: Cannot find module x\n' > "$TEST_TEMP_DIR/junk.log"
tg_parse_log "$TEST_TEMP_DIR/junk.log"
assert_eq "unknown output: not parsable" "0" "$TG_PARSABLE"

assert_eq "FAIL_LOG_LINES is not forced for other sw_test_gate_env callers" "" "$(unset FAIL_LOG_LINES; sw_test_gate_scrub >/dev/null 2>&1; ( sw_test_gate_scrub && echo "${FAIL_LOG_LINES:-}" ))"

# ═══════════════════════════════════════════════════════════════════════════════
# Pre-existing, verified: every iteration unit also fails on the base
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pre-existing (verified on the base)"

scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
judge_iter
assert_eq "identical failure does not block" "0" "$JRC"
assert_eq "identical failure: verdict pre-existing" "pre-existing" "$TG_VERDICT"
assert_eq "identical failure: recorded as pre-existing" "true" "$TG_PREEXISTING"
if tg_verdict_text | grep 'Do NOT try to fix' >/dev/null; then
    assert_pass "pre-existing verdict tells the agent not to fix"
else
    assert_fail "pre-existing verdict tells the agent not to fix"
fi

scenario "suite-a:pass suite-b:fail:X,Y suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
judge_iter
assert_eq "a subset of the base's failures is pre-existing" "0" "$JRC"

# ═══════════════════════════════════════════════════════════════════════════════
# Regressions and new failures -> block
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "regression and new failures"

scenario "suite-a:pass suite-b:pass suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
judge_iter
assert_eq "regression blocks" "1" "$JRC"
assert_eq "regression: verdict" "regression" "$TG_VERDICT"
assert_eq "regression: base exit 0" "0" "$TG_BASE_EXIT"

scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:fail:Z"
judge_iter
assert_eq "new suite failure blocks" "1" "$JRC"
assert_eq "new failure lists only the new units" "$(printf 'suite-c::Z\nsuite-c::exit=1\n' | sort)" "$(printf '%s\n' "$TG_NEW_FAILURES" | sort)"
assert_eq "new failure verdict" "new-failures" "$TG_VERDICT"

scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X,Y suite-c:pass"
judge_iter
assert_eq "new assertion inside a failing suite blocks" "1" "$JRC"
assert_eq "new assertion listed" "suite-b::Y" "$(echo "$TG_NEW_FAILURES" | grep 'suite-b::Y')"

# Repro H: suite-b times out after its pre-existing assertion X -> block
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:timeout:X suite-c:pass"
judge_iter
assert_eq "H: a suite that times out inside sw-test-all blocks" "1" "$JRC"
if printf '%s\n' "$TG_NEW_FAILURES" | grep -Fx -- "suite-b::TIMEOUT" >/dev/null; then
    assert_pass "H: the TIMEOUT unit is reported as new"
else
    assert_fail "H: the TIMEOUT unit is reported as new" "got: $TG_NEW_FAILURES"
fi

# Repro I: suite-b crashes after its pre-existing assertion X (no completion line) -> block
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:crash:X suite-c:pass"
judge_iter
assert_eq "I: a suite that crashes after X blocks" "1" "$JRC"
if printf '%s\n' "$TG_NEW_FAILURES" | grep -Fx -- "suite-b::INCOMPLETE" >/dev/null; then
    assert_pass "I: the INCOMPLETE unit is reported as new"
else
    assert_fail "I: the INCOMPLETE unit is reported as new" "got: $TG_NEW_FAILURES"
fi

# A timeout on both sides still blocks: a hang proves nothing about later assertions
scenario "suite-a:pass suite-b:timeout:X suite-c:pass" "suite-a:pass suite-b:timeout:X suite-c:pass"
judge_iter
assert_eq "a timeout also on the base blocks (unverifiable)" "1" "$JRC"
assert_eq "unverifiable verdict" "unverifiable" "$TG_VERDICT"

# An incomplete suite (no completion line) on both sides still blocks: its later assertions are unknown
scenario "suite-a:pass suite-b:crash:X suite-c:pass" "suite-a:pass suite-b:crash:X suite-c:pass"
judge_iter
assert_eq "an incomplete suite on both sides blocks" "1" "$JRC"

# Command-level failures without suite units
printf 'syntax error near unexpected token\n' > "$LOG_DIR/crash.log"
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
rc=0; tg_judge "$CMD" 2 "$LOG_DIR/crash.log" 120 1 || rc=$?
assert_eq "A2: crash without a summary blocks" "1" "$rc"
assert_eq "A2: verdict unattributed" "unattributed" "$TG_VERDICT"

printf '  0 passed  0 failed  0 timed out  (0 suites, 0s)\nUnhandled error between tests\n' > "$LOG_DIR/nounits.log"
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
rc=0; tg_judge "$CMD" 1 "$LOG_DIR/nounits.log" 120 1 || rc=$?
assert_eq "B: parsable summary with no units blocks" "1" "$rc"

scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
rc=0; tg_judge "$CMD" 124 "$ITER_LOG" 120 1 || rc=$?
assert_eq "A: iteration timeout (124) blocks" "1" "$rc"
assert_eq "A: verdict timeout" "timeout" "$TG_VERDICT"

# ═══════════════════════════════════════════════════════════════════════════════
# Untrusted base -> block, not cached
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "untrusted base"

# Repro C: every unit fails on the base -> block
scenario "suite-a:fail:P suite-b:fail:X suite-c:fail:Q" "suite-a:pass suite-b:fail:X suite-c:pass"
judge_iter
assert_eq "C: env-broken base (every unit fails) blocks" "1" "$JRC"
assert_eq "C: base not trusted" "untrusted-baseline" "$TG_VERDICT"

# Repro D: the command does not exist on the base (127) -> block
printf 'echo FAIL; exit 1\n' > "$REPO/newcheck.sh"
scenario "suite-a:pass suite-b:pass suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
rc=0; tg_judge "bash newcheck.sh" 1 "$ITER_LOG" 120 1 || rc=$?
assert_eq "D: command missing on the base blocks" "1" "$rc"
assert_eq "D: verdict untrusted" "untrusted-baseline" "$TG_VERDICT"
rm -f "$REPO/newcheck.sh"

# Missing-command text inside suite logs is not a reason to distrust the base (review item 4):
# base suite-b fails with "No such file or directory" in its log; the iteration fails it again.
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
judge_iter
assert_eq "suite logs mentioning missing files do not make the base untrusted" "0" "$JRC"
assert_eq "...and the unrelated iteration converges as pre-existing" "pre-existing" "$TG_VERDICT"

# Flaky base: the two base runs disagree -> block
rm -f "$FLAKY_COUNTER"
scenario "suite-a:pass suite-b:pass" "suite-a:pass suite-b:fail:X"
BASE_FLAKY="$(commit_state "suite-a:pass suite-b:fail:X")"
LOOP_START_COMMIT="$BASE_FLAKY"
rc=0; tg_judge "bash flaky.sh" 1 "$ITER_LOG" 120 1 || rc=$?
assert_eq "flaky base blocks" "1" "$rc"
if tg_verdict_text | grep 'flaky' >/dev/null; then
    assert_pass "flaky base verdict names the flakiness"
else
    assert_fail "flaky base verdict names the flakiness" "got: $(tg_verdict_text)"
fi

# A hanging base is stopped by the watchdog -> block
SW_TEST_TIMEOUT=2
scenario "" "suite-a:pass suite-b:fail:X suite-c:pass"
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
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
LOOP_START_COMMIT="$ROOT_SHA"
rc=0; tg_judge "$CMD" 1 "$ITER_LOG" 120 1 || rc=$?
assert_eq "G: root-commit base blocks" "1" "$rc"
LOOP_START_COMMIT=""
rc=0; tg_judge "$CMD" 1 "$ITER_LOG" 120 1 || rc=$?
assert_eq "G: missing base blocks" "1" "$rc"

# Forged files: nothing is read from disk as a baseline any more (review item 2)
scenario "suite-a:pass suite-b:pass suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
forged="$TMPDIR/sw-test-gate-store.forged"; mkdir -p "$forged"
printf 'exit=1\nunit=suite-b::X\n' > "$forged/base-1.txt"
printf 'exit=1\nunit=suite-b::X\n' > "$LOG_DIR/test-baseline-1.txt"
judge_iter
rm -f "$forged"/*.txt "$LOG_DIR/test-baseline-1.txt"; rmdir "$forged"
assert_eq "forged files on disk are ignored (regression still blocks)" "1" "$JRC"
assert_eq "...and the base is the real base, exit 0" "0" "$TG_BASE_EXIT"

# created during the loop: no baseline -> block
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 0 || rc=$?
assert_eq "created-in-loop command blocks" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
# Caching: in memory, one trusted computation (two runs) per command and base commit
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "baseline caching"

: > "$RUNS_FILE"
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
COUNT_CMD="bash counting-runner.sh"
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
assert_eq "trusted baseline: two runs for three judgements" "2" "$(wc -l < "$RUNS_FILE" | tr -d ' ')"
if [[ -n "$(ls "$TMPDIR" 2>/dev/null | grep 'store' || true)" ]]; then
    assert_fail "no baseline store is written to disk"
else
    assert_pass "no baseline store is written to disk"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Cleanup: worktree removed; dependencies survive; interrupts and owner death
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cleanup"

scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
assert_eq "only the main worktree remains" "1" "$(git_in_repo worktree list | wc -l | tr -d ' ')"
assert_file_exists "node_modules symlink target survives worktree removal" "$REPO/node_modules/sentinel.txt"
assert_eq "no base temp dirs left behind" "0" "$(ls "$TMPDIR" | grep -c 'sw-test-baseline' || true)"

# SIGTERM while the base runs, in a subshell with its own handler
scenario "" "suite-a:pass suite-b:fail:X suite-c:pass"
git_in_repo add -A >/dev/null 2>&1; git_in_repo commit -q --allow-empty -m hang2 >/dev/null 2>&1
LOOP_START_COMMIT="$(git_in_repo rev-parse HEAD)"
( tg_judge "bash hang.sh" 1 "$ITER_LOG" 120 1 ) & jpid=$!
for _ in $(seq 1 50); do
    [[ "$(git_in_repo worktree list | wc -l | tr -d ' ')" -gt 1 ]] && break
    sleep 0.2
done
kill -TERM "$jpid" 2>/dev/null || true
{ wait "$jpid"; } 2>/dev/null || true
assert_eq "SIGTERM during a base run: worktree removed" "1" "$(git_in_repo worktree list | wc -l | tr -d ' ')"
assert_eq "SIGTERM during a base run: temp dir removed" "0" "$(ls "$TMPDIR" | grep -c 'sw-test-baseline' || true)"
if no_sleep_left; then
    assert_pass "SIGTERM during a base run: base process tree killed"
else
    assert_fail "SIGTERM during a base run: base process tree killed"
fi

# Owner death without any handler (SIGKILL of the loop process): the watchdog cleans up
scenario "" "suite-a:pass suite-b:fail:X suite-c:pass"
git_in_repo add -A >/dev/null 2>&1; git_in_repo commit -q --allow-empty -m hang3 >/dev/null 2>&1
OWNER_BASE="$(git_in_repo rev-parse HEAD)"
cat > "$TEST_TEMP_DIR/owner.sh" <<OWNER
#!/usr/bin/env bash
source "$SCRIPT_DIR/lib/test-gate-env.sh"
source "$SCRIPT_DIR/lib/test-gate-baseline.sh"
export PROJECT_ROOT="$REPO" LOOP_START_COMMIT="$OWNER_BASE" SW_TEST_TIMEOUT=120
tg_begin_gate
tg_judge "bash hang.sh" 1 "$ITER_LOG" 120 1 || true
OWNER
bash "$TEST_TEMP_DIR/owner.sh" & opid=$!
for _ in $(seq 1 50); do
    [[ "$(git_in_repo worktree list | wc -l | tr -d ' ')" -gt 1 ]] && break
    sleep 0.2
done
kill -KILL "$opid" 2>/dev/null || true
{ wait "$opid"; } 2>/dev/null || true
owner_ok=0
for _ in $(seq 1 50); do
    if [[ "$(git_in_repo worktree list | wc -l | tr -d ' ')" -eq 1 ]] && no_sleep_left; then owner_ok=1; break; fi
    sleep 0.2
done
if [[ "$owner_ok" -eq 1 ]]; then
    assert_pass "owner killed without a handler: watchdog removes the worktree and the run"
else
    assert_fail "owner killed without a handler: watchdog removes the worktree and the run"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# tg_record: evidence JSON
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tg_record evidence"

if command -v jq >/dev/null 2>&1; then
    scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:fail:Z"
    tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
    results="$(tg_record "[]" "$CMD" "$ITER_RC" 7)"
    assert_eq "evidence: baseline_exit_code recorded (base fails: 1)" "1" "$(echo "$results" | jq -r '.[0].baseline_exit_code')"
    assert_eq "evidence: new_failures listed" "suite-c::Z,suite-c::exit=1" "$(echo "$results" | jq -r '.[0].new_failures | sort | join(",")')"
    assert_eq "evidence: verdict" "new-failures" "$(echo "$results" | jq -r '.[0].verdict')"

    scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:pass"
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
