#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/test-gate-baseline test — differential test gate (#8633)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: test-gate-baseline Tests"

setup_test_env "sw-lib-test-gate-baseline-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

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
while IFS=: read -r s mode asserts total; do
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
    n=0
    for a in $list; do
        n=$((n + 1))
        if [[ "$a" == +* ]]; then sections="${sections}      ✓ ${a#+}"$'\n'; else sections="${sections}      ✗ ${a}"$'\n'; fi
    done
    # test-helpers prints a pass line for every passing assertion: fill the rest of the total.
    if [[ "$mode" == fail ]]; then
        for ((k = n; k < ${total:-3}; k++)); do sections="${sections}      ✓ filler-$k"$'\n'; done
    fi
    if [[ "$mode" == fail ]]; then sections="${sections}    1 of ${total:-3} tests failed"$'\n'; fi
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
assert_eq "complete failing suite: status, total and assertions, no INCOMPLETE" "$(printf 'suite-b::X#1\nsuite-b::Y#1\nsuite-b::exit=1\nsuite-b::total=3\n' | sort)" "$(printf '%s\n' "$TG_UNITS" | sort)"
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
if printf '%s\n' "$TG_UNITS" | grep -Fx -- "bad two#1" >/dev/null; then
    assert_pass "bun log: failing unit without timing"
else
    assert_fail "bun log: failing unit without timing" "got: $TG_UNITS"
fi

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
assert_eq "new failure lists only the new units" "$(printf 'suite-c::Z#1\nsuite-c::exit=1\nsuite-c::total=3\n' | sort)" "$(printf '%s\n' "$TG_NEW_FAILURES" | sort)"
assert_eq "new failure verdict" "new-failures" "$TG_VERDICT"

scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X,Y suite-c:pass"
judge_iter
assert_eq "new assertion inside a failing suite blocks" "1" "$JRC"
assert_eq "new assertion listed" "suite-b::Y#1" "$(echo "$TG_NEW_FAILURES" | grep 'suite-b::Y')"

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
# count_entries <glob-prefix-pattern> — number of TMPDIR entries matching the glob (no ls | grep).
count_entries() {
    local d n=0
    for d in "$TMPDIR"/$1; do
        [[ -e "$d" ]] && n=$((n + 1))
    done
    echo "$n"
}
if [[ "$(count_entries '*store*')" -gt 0 ]]; then
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
assert_eq "no base temp dirs left behind" "0" "$(count_entries 'sw-test-baseline*')"

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
assert_eq "SIGTERM during a base run: temp dir removed" "0" "$(count_entries 'sw-test-baseline*')"
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
# ═══════════════════════════════════════════════════════════════════════════════
# Totals and bun (round 3)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "totals and bun units"

# V: 20 tests vanish from an already-failing suite (1 of 30 vs 1 of 50) -> block
scenario "suite-a:pass suite-b:fail:X:50 suite-c:pass" "suite-a:pass suite-b:fail:X:30 suite-c:pass"
judge_iter
assert_eq "V: tests vanishing from a failing suite block" "1" "$JRC"
if printf '%s\n' "$TG_NEW_FAILURES" | grep -Fx -- "suite-b::total=30" >/dev/null; then
    assert_pass "V: the shrunken total is reported"
else
    assert_fail "V: the shrunken total is reported" "got: $TG_NEW_FAILURES"
fi

# more tests in a failing suite, same failure -> still pre-existing
scenario "suite-a:pass suite-b:fail:X:50 suite-c:pass" "suite-a:pass suite-b:fail:X:60 suite-c:pass"
judge_iter
assert_eq "a larger total with the same failure is pre-existing" "0" "$JRC"

# Real bun two-file fixture: a.test.ts has a pre-existing (fail); b.test.ts is then broken
if command -v bun >/dev/null 2>&1; then
    BREPO="$TEST_TEMP_DIR/bun-repo"
    mkdir -p "$BREPO"
    git -C "$BREPO" init -q
    bg() { git -C "$BREPO" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }
    echo project > "$BREPO/README.md"; bg add -A && bg commit -qm root   # the base must not be a root commit
    cat > "$BREPO/a.test.ts" <<'TS'
import { test, expect } from "bun:test";
test("T preexisting", () => { expect(1).toBe(2); });
test("A ok", () => { expect(1).toBe(1); });
TS
    cat > "$BREPO/b.test.ts" <<'TS'
import { test, expect } from "bun:test";
test("B1 important", () => { expect(1).toBe(1); });
test("B2 important", () => { expect(2).toBe(2); });
TS
    bg add -A && bg commit -qm base
    BUN_BASE="$(bg rev-parse HEAD)"
    OLD_ROOT="$PROJECT_ROOT"
    export PROJECT_ROOT="$BREPO"
    LOOP_START_COMMIT="$BUN_BASE"; tg_begin_gate
    # BUN2: a top-level throw in b.test.ts
    { echo 'throw new Error("boom");'; cat "$BREPO/b.test.ts"; } > "$BREPO/b.tmp" && mv "$BREPO/b.tmp" "$BREPO/b.test.ts"
    ( cd "$BREPO" && bun test ) > "$LOG_DIR/bun2.log" 2>&1 || true
    tg_parse_log "$LOG_DIR/bun2.log"
    if printf '%s\n' "$TG_UNITS" | grep -Fx -- "b.test.ts::LOAD_ERROR" >/dev/null; then
        assert_pass "bun: a load error in a file is a unit named after the file"
    else
        assert_fail "bun: a load error in a file is a unit named after the file" "got: $TG_UNITS"
    fi
    assert_eq "bun: two-file run counts files" "2" "$(printf '%s\n' "$TG_UNITS" | sed -n 's/^bun::files=//p')"
    rc=0; tg_judge "bun test" 1 "$LOG_DIR/bun2.log" 60 1 || rc=$?
    assert_eq "BUN2: a file that throws at load blocks despite a pre-existing (fail)" "1" "$rc"
    if printf '%s\n' "$TG_NEW_FAILURES" | grep -Fx -- "b.test.ts::LOAD_ERROR" >/dev/null; then
        assert_pass "BUN2: the load error is the reported new failure"
    else
        assert_fail "BUN2: the load error is the reported new failure" "got: $TG_NEW_FAILURES"
    fi
    # Control on the same fixture: the untouched repo's failure is pre-existing
    bg checkout -q -- b.test.ts
    LOOP_START_COMMIT="$BUN_BASE"; tg_begin_gate
    ( cd "$BREPO" && bun test ) > "$LOG_DIR/bun0.log" 2>&1 || true
    rc=0; tg_judge "bun test" 1 "$LOG_DIR/bun0.log" 60 1 || rc=$?
    assert_eq "bun control: the unchanged failing test is pre-existing" "0" "$rc"
    # BUN3: a test is skipped -> skip count grows -> block
    sed -i.bak 's/^test("B1/test.skip("B1/' "$BREPO/b.test.ts"; rm -f "$BREPO/b.test.ts.bak"
    ( cd "$BREPO" && bun test ) > "$LOG_DIR/bun3.log" 2>&1 || true
    rc=0; tg_judge "bun test" 1 "$LOG_DIR/bun3.log" 60 1 || rc=$?
    assert_eq "bun: a skipped test blocks" "1" "$rc"
    export PROJECT_ROOT="$OLD_ROOT"

    # DUP (review round 4): the same test name in two files. The base fails a.test.ts's
    # "handles errors"; the iteration fixes it and breaks b.test.ts's test of the same name.
    DREPO="$TEST_TEMP_DIR/bun-dup"
    mkdir -p "$DREPO"
    git -C "$DREPO" init -q
    dg() { git -C "$DREPO" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }
    echo project > "$DREPO/README.md"; dg add -A && dg commit -qm root
    cat > "$DREPO/a.test.ts" <<'TS'
import { test, expect } from "bun:test";
test("handles errors", () => { expect(1).toBe(2); });
TS
    cat > "$DREPO/b.test.ts" <<'TS'
import { test, expect } from "bun:test";
test("handles errors", () => { expect(1).toBe(1); });
test("other", () => {});
TS
    dg add -A && dg commit -qm base
    DUP_BASE="$(dg rev-parse HEAD)"
    cat > "$DREPO/a.test.ts" <<'TS'
import { test, expect } from "bun:test";
test("handles errors", () => { expect(1).toBe(1); });
TS
    cat > "$DREPO/b.test.ts" <<'TS'
import { test, expect } from "bun:test";
test("handles errors", () => { expect(1).toBe(3); });
test("other", () => {});
TS
    OLD_ROOT="$PROJECT_ROOT"
    export PROJECT_ROOT="$DREPO"
    LOOP_START_COMMIT="$DUP_BASE"; tg_begin_gate
    ( cd "$DREPO" && bun test ) > "$LOG_DIR/dup.log" 2>&1 || true
    rc=0; tg_judge "bun test" 1 "$LOG_DIR/dup.log" 60 1 || rc=$?
    export PROJECT_ROOT="$OLD_ROOT"
    assert_eq "DUP: a broken same-named test in another file blocks" "1" "$rc"
    if printf '%s\n' "$TG_NEW_FAILURES" | grep -Fx -- "b.test.ts::handles errors#1" >/dev/null; then
        assert_pass "DUP: the failing unit is file-qualified (b.test.ts::handles errors#1)"
    else
        assert_fail "DUP: the failing unit is file-qualified" "got: $TG_NEW_FAILURES"
    fi
elif [[ -n "${CI:-}" ]]; then
    # CI pins bun (.bun-version, test.yml). A runner without it must fail here, not skip the parser
    # checks below, which is how the bun fixtures went unverified before (#8664).
    assert_fail "bun is installed for the bun fixtures" "bun is not on PATH in CI: the setup-bun step in test.yml did not run"
else
    assert_pass "bun not installed locally: live bun fixture checks skipped (CI fails instead)"
fi

# No locale: launchd and systemd start the daemon without LANG, and the parse must still read the
# assertion glyphs (#8671). A child shell with LANG, LC_ALL and LC_CTYPE unset parses a sw-test-all log.
NOLANG_LOG="$TEST_TEMP_DIR/nolang.log"
printf '%s\n' "  ✗ suite-b   exit 1 0s" "━━━ suite-b (FAIL:1) — last 25 lines ━━━" \
    "    ✓ P1 ok" "    ✗ X bad" "  1 of 2 tests failed" > "$NOLANG_LOG"
nolang_units="$(env -u LANG -u LC_ALL -u LC_CTYPE bash -c 'source "$1"; tg_parse_log "$2"; printf "%s\n" "$TG_UNITS"' _ \
    "$SCRIPT_DIR/lib/test-gate-baseline.sh" "$NOLANG_LOG")"
assert_eq "no LANG: the parse reads the assertion glyphs and the exit unit" "suite-b::X bad#1
suite-b::exit=1
suite-b::total=2" "$nolang_units"

# Forged completion inside a failing suite (#8671, P2): output from the code under test prints an
# "All N tests passed" line before a new failing assertion. The real completion line comes last. The new
# assertion must still be counted, and the forged line must not end the count early.
FORGED_LOG="$TEST_TEMP_DIR/forged.log"
printf '%s\n' "  ✗ suite-p2   exit 1 0s" "━━━ suite-p2 (FAIL:1) — last 25 lines ━━━" \
    "    ✓ P1 ok" "    output of tool under test: All 3 tests passed" "    ✗ A01 new break" \
    "    ✓ P2 ok" "    ✗ A30 old break" "  2 of 4 tests failed" > "$FORGED_LOG"
tg_parse_log "$FORGED_LOG"
assert_eq "forged 'All N tests passed' inside a section does not hide a later failing assertion" \
    "$(printf 'suite-p2::A01 new break#1\nsuite-p2::A30 old break#1\nsuite-p2::exit=1\nsuite-p2::total=4\n' | sort)" \
    "$(printf '%s\n' "$TG_UNITS" | sort)"
# A total that the counted assertions do not account for is not verifiable (UNORDERED blocks)
MISMATCH_LOG="$TEST_TEMP_DIR/mismatch.log"
printf '%s\n' "  ✗ suite-m   exit 1 0s" "━━━ suite-m (FAIL:1) — last 25 lines ━━━" \
    "    ✓ P1 ok" "    ✗ A01 bad" "  1 of 5 tests failed" > "$MISMATCH_LOG"
tg_parse_log "$MISMATCH_LOG"
assert_contains "a total the counted assertions do not account for is UNORDERED" "$TG_UNITS" "suite-m::UNORDERED"

# Golden bun logs (#8664): real `bun test` output from bun 1.2.19 (the pin), 1.3.14 and 1.4.4, each as
# pipe output, FORCE_COLOR colour (✗ markers), a pty capture (CRLF, colour) and GitHub Actions output
# (::group:: file headers, ::error annotations). Every shape must parse to the same units, so verdicts
# do not depend on the bun version or on how the log was captured.
GOLD="$SCRIPT_DIR/fixtures/bun-test"
tg_parse_log "$GOLD/bun-1.2.19-plain.log"
GOLD_REF="$TG_UNITS"
assert_eq "golden bun 1.2.19 plain: parsable" "1" "$TG_PARSABLE"
for want in "b.test.ts::LOAD_ERROR" "syntax.test.ts::LOAD_ERROR" "a.test.ts::pre-existing failure#1" \
    "dup.test.ts::same name#1" "dup.test.ts::same name#2" "bun::ran=9" "bun::files=5" "bun::fail=5" \
    "bun::error=2" "bun::skip=1"; do
    if printf '%s\n' "$GOLD_REF" | grep -Fx -- "$want" >/dev/null; then
        assert_pass "golden bun 1.2.19 plain: unit $want"
    else
        assert_fail "golden bun 1.2.19 plain: unit $want" "got: $GOLD_REF"
    fi
done
for name in bun-1.2.19-color bun-1.2.19-tty bun-1.2.19-gha bun-1.3.14-plain bun-1.3.14-color bun-1.3.14-tty \
    bun-1.3.14-gha bun-1.4.4-plain bun-1.4.4-color bun-1.4.4-tty bun-1.4.4-gha; do
    tg_parse_log "$GOLD/$name.log"
    assert_eq "golden $name: parsable" "1" "$TG_PARSABLE"
    assert_eq "golden $name: same units as the plain 1.2.19 log" "$GOLD_REF" "$TG_UNITS"
done
# Singular summary variants ("Ran 1 test across 1 file", one failing test), plain and pty
for name in bun-single-1.2.19-plain bun-single-1.2.19-tty bun-single-1.2.19-gha; do
    tg_parse_log "$GOLD/$name.log"
    assert_eq "golden $name: one failing unit, one file" \
        "bun::error=0
bun::fail=1
bun::files=1
bun::ran=1
bun::skip=0
one.test.ts::only failure#1" "$TG_UNITS"
done

# Multiset (review round 4): a repeated assertion name in a failing suite must not hide a swap.
# The base has suite-b's "X" once; the iteration has "X" twice.
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X,X suite-c:pass"
judge_iter
assert_eq "a repeated assertion name beyond the base's count blocks" "1" "$JRC"
scenario "suite-a:pass suite-b:fail:X,X suite-c:pass" "suite-a:pass suite-b:fail:X,X suite-c:pass"
judge_iter
assert_eq "the same repeated names on both sides are pre-existing" "0" "$JRC"

# SWAP (review round 5): two assertions share a description. The base fails the first instance
# only; the iteration fixes it and breaks the second. The output is the same line either way, so
# only the occurrence number tells them apart: X#1 on the base, X#2 in the iteration -> block.
scenario "suite-a:pass suite-b:fail:X,+X suite-c:pass" "suite-a:pass suite-b:fail:+X,X suite-c:pass"
judge_iter
assert_eq "SWAP: a swapped instance of a repeated name blocks" "1" "$JRC"
if printf '%s\n' "$TG_NEW_FAILURES" | grep -Fx -- "suite-b::X#2" >/dev/null; then
    assert_pass "SWAP: the second instance is the new unit (X#2)"
else
    assert_fail "SWAP: the second instance is the new unit (X#2)" "got: $TG_NEW_FAILURES"
fi

# GROW: the base fails the first instance; the iteration fails both.
scenario "suite-a:pass suite-b:fail:X,+X suite-c:pass" "suite-a:pass suite-b:fail:X,X suite-c:pass"
judge_iter
assert_eq "GROW: a second failing instance of a repeated name blocks" "1" "$JRC"

# A suite whose log lists its failing assertion but no passing one (test-helpers always prints a
# pass line): the occurrence numbers are unknown, so it blocks. The base has passing lines, so the
# unit is new here; the ::UNORDERED rule also blocks when the base has the same unit.
scenario "suite-a:pass suite-b:fail:X:50 suite-c:pass" "suite-a:pass suite-b:fail:X:50 suite-c:pass"
cat > "$LOG_DIR/unordered.log" <<'UNORD'
  ✓ suite-a                                        0s
  ✗ suite-b                                        exit 1 0s
  ✓ suite-c                                        0s
━━━ suite-b (FAIL:1) — last 25 lines ━━━
      ✗ X
    1 of 50 tests failed

  2 passed  1 failed  0 timed out  (3 suites, 0s)
UNORD
rc=0; tg_judge "$CMD" 1 "$LOG_DIR/unordered.log" 120 1 || rc=$?
assert_eq "UNORDERED: a suite with no pass lines blocks even when the base matches" "1" "$rc"
if printf '%s\n' "$TG_NEW_FAILURES" | grep -Fx -- "suite-b::UNORDERED" >/dev/null; then
    assert_pass "UNORDERED: the unit is reported"
else
    assert_fail "UNORDERED: the unit is reported" "got: $TG_NEW_FAILURES"
fi

# An unrelated passing assertion added above a pre-existing failure must not shift its unit.
scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:+New,X suite-c:pass"
judge_iter
assert_eq "an unrelated passing assertion above a pre-existing failure stays pre-existing" "0" "$JRC"
scenario "suite-a:pass suite-b:fail:+A,X suite-c:pass" "suite-a:pass suite-b:fail:+A,+B,X suite-c:pass"
judge_iter
assert_eq "several unrelated additions above it stay pre-existing" "0" "$JRC"

# ═══════════════════════════════════════════════════════════════════════════════
# Process cleanup: the group is killed even after the leader exited (orphans), and the
# tree-walk fallback matches the worktree path.
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "orphaned children and path fallback"

if command -v perl >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\nsleep 4712 &\nexit 1\n' > "$REPO/orphan.sh"
    git_in_repo add -A >/dev/null 2>&1; git_in_repo commit -q --allow-empty -m orphan >/dev/null 2>&1
    LOOP_START_COMMIT="$(git_in_repo rev-parse HEAD)"
    rc=0; tg_judge "bash orphan.sh" 1 "$ITER_LOG" 120 1 || rc=$?
    if ps -axo command= | grep -x 'sleep 4712' >/dev/null; then
        assert_fail "a background child of the base run is killed with the run"
        for pid in $(ps -axo pid=,command= | awk '$2=="sleep" && $3=="4712" {print $1}'); do kill -KILL "$pid" 2>/dev/null || true; done
    else
        assert_pass "a background child of the base run is killed with the run"
    fi
else
    assert_pass "perl not installed: process-group orphan check skipped"
fi

marker="$TEST_TEMP_DIR/pathmark-$$"
sh -c 'sleep 4713; :' "$marker" & fpid=$!
sleep 0.5
_tg_kill_by_path "$marker"
{ wait "$fpid"; } 2>/dev/null || true
if ps -axo command= | grep -F -- "$marker" | grep -v grep >/dev/null; then
    assert_fail "path fallback kills processes whose command line names the worktree"
else
    assert_pass "path fallback kills processes whose command line names the worktree"
fi
for pid in $(ps -axo pid=,command= | awk '$2=="sleep" && $3=="4713" {print $1}'); do kill -KILL "$pid" 2>/dev/null || true; done

# ═══════════════════════════════════════════════════════════════════════════════
# tg_record: evidence JSON
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tg_record evidence"

if command -v jq >/dev/null 2>&1; then
    scenario "suite-a:pass suite-b:fail:X suite-c:pass" "suite-a:pass suite-b:fail:X suite-c:fail:Z"
    tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
    results="$(tg_record "[]" "$CMD" "$ITER_RC" 7)"
    assert_eq "evidence: baseline_exit_code recorded (base fails: 1)" "1" "$(echo "$results" | jq -r '.[0].baseline_exit_code')"
    assert_eq "evidence: new_failures listed" "suite-c::Z#1,suite-c::exit=1,suite-c::total=3" "$(echo "$results" | jq -r '.[0].new_failures | sort | join(",")')"
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
