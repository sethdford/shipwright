#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  test-flakiness test suite                                               ║
# ║  Runner detection, ID extraction, isolated rerun, repeat-offender cap,   ║
# ║  fail-safe paths, shell-injection safety, breaker/aggregate helpers      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: test-flakiness Tests"

setup_test_env "sw-lib-test-flakiness-test"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/test-flakiness.sh"

# Hermetic: no repo config, a known timeout binary
unset SW_FLAKY_DETECTION SW_FLAKY_RERUN_TEMPLATE SW_FLAKY_MAX_RERUN_TESTS \
    SW_FLAKY_RERUN_TIMEOUT SW_FLAKY_MAX_REPEATS SW_FLAKY_HISTORY_FILE 2>/dev/null || true
TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || echo "")"
if [[ -z "$TIMEOUT_CMD" ]]; then
    echo "  (skipping: no timeout/gtimeout binary on this machine)"
    exit 0
fi

WORK="$TEST_TEMP_DIR/project"
LOGS="$TEST_TEMP_DIR/logs"
COUNTER="$TEST_TEMP_DIR/rerun-count"
ARGS_LOG="$TEST_TEMP_DIR/rerun-args"

# Stub runner: records invocations and args, behavior chosen by STUB_MODE
#   pass | fail | sleep | missing
cat > "$TEST_TEMP_DIR/bin/flakystub" <<STUB
#!/usr/bin/env bash
n=\$(cat "$COUNTER" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$COUNTER"
: > "$ARGS_LOG"
for a in "\$@"; do printf '%s\n' "\$a" >> "$ARGS_LOG"; done
case "\${STUB_MODE:-pass}" in
    pass)  exit 0 ;;
    fail)  echo "FAIL again"; exit 1 ;;
    sleep) sleep 5; exit 0 ;;
    missing) exit 127 ;;
esac
STUB
chmod +x "$TEST_TEMP_DIR/bin/flakystub"

# Fresh state for every scenario
reset_state() {
    rm -f "$COUNTER" "$ARGS_LOG" "$LOGS"/flaky-* 2>/dev/null || true
    export STUB_MODE=pass
    export SW_FLAKY_RERUN_TEMPLATE="flakystub {test}"
    unset SW_FLAKY_DETECTION SW_FLAKY_MAX_RERUN_TESTS SW_FLAKY_RERUN_TIMEOUT SW_FLAKY_MAX_REPEATS 2>/dev/null || true
}

rerun_count() { cat "$COUNTER" 2>/dev/null || echo 0; }

write_vitest_log() {
    local file="$1"; shift
    {
        echo " RUN  v1.6.0 /repo"
        local t
        for t in "$@"; do printf ' \033[31mFAIL\033[0m  %s\n' "$t"; done
        echo " Test Files  1 failed (1)"
    } > "$file"
}

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Runner detection"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "vitest from command" "vitest" "$(flaky_detect_runner "npx vitest run")"
assert_eq "jest from command" "jest" "$(flaky_detect_runner "jest --ci")"
assert_eq "pytest from command" "pytest" "$(flaky_detect_runner "python -m pytest -q")"
assert_eq "go from command" "go" "$(flaky_detect_runner "go test ./...")"
assert_eq "sw-suite from command" "sw-suite" "$(flaky_detect_runner "bash scripts/sw-test-all.sh")"
assert_eq "unknown with no log" "unknown" "$(flaky_detect_runner "make check")"

write_vitest_log "$LOGS/v.log" "src/a.test.ts > retries > ok"
assert_eq "vitest sniffed from npm test log" "vitest" "$(flaky_detect_runner "npm test" "$LOGS/v.log")"
printf '  FAILING SUITES\n    sw-foo-test.sh   exit 1\n' > "$LOGS/s.log"
assert_eq "sw-suite sniffed from log" "sw-suite" "$(flaky_detect_runner "npm test" "$LOGS/s.log")"
printf 'FAILED tests/test_a.py::test_x - assert 0\n== short test summary info ==\n' > "$LOGS/p.log"
assert_eq "pytest sniffed from log" "pytest" "$(flaky_detect_runner "make test" "$LOGS/p.log")"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Failing-test extraction"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "vitest ID (ANSI stripped)" "src/a.test.ts > retries > ok" \
    "$(flaky_extract_failed_tests "$LOGS/v.log" vitest)"

printf 'FAIL src/a.test.js\n  ● suite › x\nFAIL src/a.test.js\nPASS src/b.test.js\n' > "$LOGS/j.log"
assert_eq "jest file IDs deduplicated" "src/a.test.js" "$(flaky_extract_failed_tests "$LOGS/j.log" jest)"

assert_eq "pytest node ID" "tests/test_a.py::test_x" "$(flaky_extract_failed_tests "$LOGS/p.log" pytest)"

printf -- '--- FAIL: TestFoo (0.01s)\n    --- FAIL: TestFoo/sub (0.00s)\nFAIL\n' > "$LOGS/g.log"
assert_eq "go top-level test only" "TestFoo" "$(flaky_extract_failed_tests "$LOGS/g.log" go)"

printf '  \033[31m✗\033[0m sw-foo-test.sh                exit 1 3s\n  ✗ some assertion text\n' > "$LOGS/s2.log"
assert_eq "sw-suite row, assertion lines ignored" "sw-foo-test.sh" "$(flaky_extract_failed_tests "$LOGS/s2.log" sw-suite)"

echo "nothing to see" > "$LOGS/empty.log"
assert_eq "no match yields nothing" "" "$(flaky_extract_failed_tests "$LOGS/empty.log" vitest)"
assert_eq "missing log yields nothing" "" "$(flaky_extract_failed_tests "$LOGS/nope.log" vitest)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Rerun command construction"
# ═══════════════════════════════════════════════════════════════════════════════

unset SW_FLAKY_RERUN_TEMPLATE
assert_eq "vitest: file + name filter" "npx vitest run src/a.test.ts -t ok" \
    "$(flaky_build_rerun_cmd vitest "src/a.test.ts > retries > ok")"
assert_eq "pytest node" "python -m pytest tests/test_a.py::test_x" \
    "$(flaky_build_rerun_cmd pytest "tests/test_a.py::test_x")"
assert_eq "go anchored -run" 'go test -count=1 -run \^TestFoo\$ ./...' "$(flaky_build_rerun_cmd go TestFoo)"
assert_eq "sw-suite script" "bash scripts/sw-foo-test.sh" "$(flaky_build_rerun_cmd sw-suite sw-foo-test.sh)"
assert_eq "unknown runner unsupported" "" "$(flaky_build_rerun_cmd unknown x)"
SW_FLAKY_RERUN_TEMPLATE="run {test} && again {test}"
assert_eq "template replaces every {test}" "run a\ b && again a\ b" "$(flaky_build_rerun_cmd vitest "a b")"
SW_FLAKY_RERUN_TEMPLATE="run {test}"
assert_eq "template value with & is literal" 'run x\&y' "$(flaky_build_rerun_cmd vitest "x&y")"
unset SW_FLAKY_RERUN_TEMPLATE

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "AC1: flaky test passes on rerun"
# ═══════════════════════════════════════════════════════════════════════════════

reset_state
write_vitest_log "$LOGS/t1.log" "src/a.test.ts > x"
cls="$(detect_flaky_failure "$LOGS/t1.log" "npm test" "$WORK" "$LOGS/flaky-result-1.json")"
assert_eq "classified flaky" "flaky" "$cls"
assert_eq "exactly one rerun" "1" "$(rerun_count)"
res="$(cat "$LOGS/flaky-result-1.json")"
assert_json_key "reason rerun_pass" "$res" ".reason" "rerun_pass"
assert_json_key "flaky_tests populated" "$res" ".flaky_tests[0]" "src/a.test.ts > x"
assert_json_key "regression_tests empty" "$res" ".regression_tests | length" "0"
assert_json_key "rerun exit recorded" "$res" ".rerun.exit_code" "0"
assert_file_exists "rerun log written" "$LOGS/flaky-result-1-rerun.log"
assert_eq "flaky excluded from breaker" "1" "$(flaky_counts_toward_breaker "$cls" && echo 0 || echo 1)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "AC4: genuine failure fails on rerun"
# ═══════════════════════════════════════════════════════════════════════════════

reset_state
export STUB_MODE=fail
write_vitest_log "$LOGS/t2.log" "a.test.ts > x"
cls="$(detect_flaky_failure "$LOGS/t2.log" "npm test" "$WORK" "$LOGS/flaky-result-2.json")"
assert_eq "classified regression" "regression" "$cls"
res="$(cat "$LOGS/flaky-result-2.json")"
assert_json_key "reason rerun_fail" "$res" ".reason" "rerun_fail"
assert_json_key "regression_tests populated" "$res" ".regression_tests | tostring" '["a.test.ts > x"]'
assert_json_key "flaky_tests empty" "$res" ".flaky_tests | length" "0"
assert_eq "regression counts toward breaker" "0" "$(flaky_counts_toward_breaker "$cls" && echo 0 || echo 1)"
assert_file_not_exists "no history entry for a regression" "$LOGS/flaky-history.json"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Fail-safe paths"
# ═══════════════════════════════════════════════════════════════════════════════

reset_state
export STUB_MODE=sleep SW_FLAKY_RERUN_TIMEOUT=1
write_vitest_log "$LOGS/t3.log" "a.test.ts > slow"
cls="$(detect_flaky_failure "$LOGS/t3.log" "npm test" "$WORK" "$LOGS/flaky-result-3.json")"
assert_eq "timeout → regression" "regression" "$cls"
assert_json_key "reason rerun_timeout" "$(cat "$LOGS/flaky-result-3.json")" ".reason" "rerun_timeout"

reset_state
export STUB_MODE=missing
cls="$(detect_flaky_failure "$LOGS/t3.log" "npm test" "$WORK" "$LOGS/flaky-result-4.json")"
assert_eq "exit 127 → unclassified" "unclassified" "$cls"
assert_json_key "reason rerun_error" "$(cat "$LOGS/flaky-result-4.json")" ".reason" "rerun_error"

reset_state
saved_timeout="$TIMEOUT_CMD"; TIMEOUT_CMD=""
cls="$(detect_flaky_failure "$LOGS/t3.log" "npm test" "$WORK" "$LOGS/flaky-result-5.json")"
TIMEOUT_CMD="$saved_timeout"
assert_eq "no timeout binary → unclassified" "unclassified" "$cls"
assert_eq "no timeout binary → no rerun" "0" "$(rerun_count)"
assert_json_key "reason no_timeout_bin" "$(cat "$LOGS/flaky-result-5.json")" ".reason" "no_timeout_bin"

reset_state
write_vitest_log "$LOGS/t6.log" "a.test.ts > one" "a.test.ts > two" "b.test.ts > three"
cls="$(detect_flaky_failure "$LOGS/t6.log" "npm test" "$WORK" "$LOGS/flaky-result-6.json")"
assert_eq "3 failures over cap 1 → unclassified" "unclassified" "$cls"
assert_eq "over cap → no rerun" "0" "$(rerun_count)"
assert_json_key "reason over_cap" "$(cat "$LOGS/flaky-result-6.json")" ".reason" "over_cap"

reset_state
cls="$(detect_flaky_failure "$LOGS/empty.log" "make check" "$WORK" "$LOGS/flaky-result-7.json")"
assert_eq "unknown runner → unclassified" "unclassified" "$cls"
assert_json_key "reason unknown_runner" "$(cat "$LOGS/flaky-result-7.json")" ".reason" "unknown_runner"

reset_state
cls="$(detect_flaky_failure "$LOGS/empty.log" "npx vitest run" "$WORK" "$LOGS/flaky-result-8.json")"
assert_eq "no parsable IDs → unclassified" "unclassified" "$cls"
assert_json_key "reason no_ids" "$(cat "$LOGS/flaky-result-8.json")" ".reason" "no_ids"

reset_state
export SW_FLAKY_DETECTION=false
cls="$(detect_flaky_failure "$LOGS/t1.log" "npm test" "$WORK" "$LOGS/flaky-result-9.json")"
assert_eq "kill switch → unclassified" "unclassified" "$cls"
assert_eq "kill switch → no rerun" "0" "$(rerun_count)"
assert_json_key "reason disabled" "$(cat "$LOGS/flaky-result-9.json")" ".reason" "disabled"

reset_state
rc=0
( set -e; detect_flaky_failure "$LOGS/nope.log" "" "$WORK" "" >/dev/null ) || rc=$?
assert_exit_code "always exits 0, even with bad input under set -e" "0" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Multiple IDs within a raised cap"
# ═══════════════════════════════════════════════════════════════════════════════

reset_state
export SW_FLAKY_MAX_RERUN_TESTS=2
write_vitest_log "$LOGS/t10.log" "a.test.ts > one" "a.test.ts > two"
cls="$(detect_flaky_failure "$LOGS/t10.log" "npm test" "$WORK" "$LOGS/flaky-result-10.json")"
assert_eq "both pass on rerun → flaky" "flaky" "$cls"
assert_eq "one rerun per ID" "2" "$(rerun_count)"
assert_json_key "both listed as flaky" "$(cat "$LOGS/flaky-result-10.json")" ".flaky_tests | length" "2"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Repeat-offender cap"
# ═══════════════════════════════════════════════════════════════════════════════

reset_state
write_vitest_log "$LOGS/t11.log" "a.test.ts > order"
cls1="$(detect_flaky_failure "$LOGS/t11.log" "npm test" "$WORK" "$LOGS/flaky-result-11.json")"
assert_eq "first occurrence excused" "flaky" "$cls1"
assert_file_exists "history recorded" "$LOGS/flaky-history.json"
assert_json_key "history count 1" "$(cat "$LOGS/flaky-history.json")" '.tests["a.test.ts > order"].count' "1"
# A passing gate in between changes nothing; history survives a session restart
# because it is a file, not loop state.
rm -f "$COUNTER"
cls2="$(detect_flaky_failure "$LOGS/t11.log" "npm test" "$WORK" "$LOGS/flaky-result-12.json")"
assert_eq "second occurrence → regression" "regression" "$cls2"
assert_json_key "reason repeat_offender" "$(cat "$LOGS/flaky-result-12.json")" ".reason" "repeat_offender"
assert_eq "repeat offender skips the rerun" "0" "$(rerun_count)"

reset_state
export SW_FLAKY_HISTORY_FILE="$TEST_TEMP_DIR/no-such-dir/history.json"
cls="$(detect_flaky_failure "$LOGS/t11.log" "npm test" "$WORK" "$LOGS/flaky-result-13.json")"
unset SW_FLAKY_HISTORY_FILE
assert_eq "unwritable history → regression (fail-safe)" "regression" "$cls"
assert_json_key "reason history_unwritable" "$(cat "$LOGS/flaky-result-13.json")" ".reason" "history_unwritable"

# History is trimmed to the newest entries
reset_state
hist="$LOGS/flaky-history.json"
jq -n '{tests: ([range(0; 105)] | map({key: "t\(.)", value: {count: 1, last: "2026-01-01T00:00:\(. % 60)Z"}}) | from_entries)}' > "$hist"
_flaky_history_record "$hist" "newest"
assert_json_key "history capped at 100" "$(cat "$hist")" ".tests | length" "100"
assert_json_key "newest kept" "$(cat "$hist")" '.tests.newest.count' "1"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Shell-injection safety"
# ═══════════════════════════════════════════════════════════════════════════════

reset_state
evil="a.test.ts > it '\"\$(touch $TEST_TEMP_DIR/pwned)\"'"
write_vitest_log "$LOGS/t14.log" "$evil"
cls="$(detect_flaky_failure "$LOGS/t14.log" "npm test" "$WORK" "$LOGS/flaky-result-14.json")"
assert_eq "hostile ID still classified" "flaky" "$cls"
assert_file_not_exists "no command substitution executed" "$TEST_TEMP_DIR/pwned"
assert_eq "ID reaches runner as one literal argument" "$evil" "$(cat "$ARGS_LOG")"

# Default (non-template) vitest path through a mocked npx
reset_state
unset SW_FLAKY_RERUN_TEMPLATE
cat > "$TEST_TEMP_DIR/bin/npx" <<STUB
#!/usr/bin/env bash
: > "$ARGS_LOG"
for a in "\$@"; do printf '%s\n' "\$a" >> "$ARGS_LOG"; done
exit 0
STUB
chmod +x "$TEST_TEMP_DIR/bin/npx"
cls="$(detect_flaky_failure "$LOGS/t14.log" "npm test" "$WORK" "$LOGS/flaky-result-15.json")"
assert_eq "default vitest rerun classified" "flaky" "$cls"
assert_file_not_exists "no injection via default command" "$TEST_TEMP_DIR/pwned"
assert_eq "name filter is a single argument" "it '\"\$(touch $TEST_TEMP_DIR/pwned)\"'" "$(sed -n 5p "$ARGS_LOG")"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Consumer helpers"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "blank class counts toward breaker" "0" "$(flaky_counts_toward_breaker "" && echo 0 || echo 1)"
assert_eq "unclassified counts toward breaker" "0" "$(flaky_counts_toward_breaker unclassified && echo 0 || echo 1)"
assert_eq "aggregate: none" "" "$(flaky_gate_aggregate)"
assert_eq "aggregate: all flaky" "flaky" "$(flaky_gate_aggregate flaky flaky)"
assert_eq "aggregate: any regression wins" "regression" "$(flaky_gate_aggregate flaky regression unclassified)"
assert_eq "aggregate: flaky + unclassified" "unclassified" "$(flaky_gate_aggregate flaky unclassified)"

print_test_results
