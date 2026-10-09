#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright test-all runner test — Unit tests for sw-test-all.sh         ║
# ║  Runs a COPY of the runner against stub suites in a temp dir. Never runs ║
# ║  the real scripts/*-test.sh set, or this suite would recurse into itself ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_SRC="$SCRIPT_DIR/sw-test-all.sh"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

ROOT=""
cleanup_root() {
    [[ -n "$ROOT" && -d "$ROOT" ]] && rm -rf "$ROOT"
    ROOT=""
}
trap cleanup_root EXIT

# Build <root>/<name>/scripts/ containing a copy of the runner plus the stub
# suites named on the command line (e.g. alpha-test.sh). Stubs are written by
# name so each test controls exactly what the runner discovers.
make_fixture() {
    local name="$1"; shift
    local dir="$ROOT/$name/scripts"
    mkdir -p "$dir" "$ROOT/$name/tmp"
    cp "$RUNNER_SRC" "$dir/sw-test-all.sh"
    local stub
    for stub in "$@"; do
        case "$stub" in
            alpha-test.sh) printf '#!/usr/bin/env bash\necho "alpha ran"\nexit 0\n' > "$dir/$stub" ;;
            beta-test.sh)  printf '#!/usr/bin/env bash\necho "beta boom marker"\nexit 3\n' > "$dir/$stub" ;;
            slow-test.sh)  printf '#!/usr/bin/env bash\nsleep 30\nexit 0\n' > "$dir/$stub" ;;
            *)             printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/$stub" ;;
        esac
    done
    echo "$dir/sw-test-all.sh"
}

# Run the runner from a fixture. TMPDIR is pointed into the fixture so the
# runner's per-run results dir and its EXIT trap never touch the real /tmp.
run_runner() {
    local name="$1"; shift
    TMPDIR="$ROOT/$name/tmp" bash "$ROOT/$name/scripts/sw-test-all.sh" "$@" 2>&1
}

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-all-test.XXXXXX")"

echo ""
print_test_header "Test-All Runner — Test Suite"

# ─── Discovery & listing ────────────────────────────────────────────────────
print_test_section "Discovery"

make_fixture mixed alpha-test.sh beta-test.sh notes.sh >/dev/null
out=$(run_runner mixed --list); rc=$?
assert_exit_code "--list exits 0" "0" "$rc"
assert_eq "--list prints only *-test.sh suites, sorted" \
    "$(printf 'alpha-test.sh\nbeta-test.sh')" "$out"

out=$(run_runner mixed --list --pattern beta)
assert_eq "--pattern narrows the discovered list" "beta-test.sh" "$out"

make_fixture empty >/dev/null
out=$(run_runner empty --list); rc=$?
assert_exit_code "no discoverable suites exits 2" "2" "$rc"
assert_contains "no discoverable suites says so" "$out" "no test suites discovered"

# ─── Argument handling ──────────────────────────────────────────────────────
print_test_section "Argument handling"

out=$(run_runner mixed --bogus); rc=$?
assert_exit_code "unknown option exits 2" "2" "$rc"
assert_contains "unknown option is named in the error" "$out" "unknown option: --bogus"

run_runner mixed --timeout >/dev/null; rc=$?
if [[ "$rc" -ne 0 ]]; then
    assert_pass "--timeout with no value aborts rather than running with a blank limit"
else
    assert_fail "--timeout with no value aborts rather than running with a blank limit" "exit was 0"
fi

# ─── Full run: failure is data, not a crash ─────────────────────────────────
print_test_section "Full run (mixed pass/fail)"

out=$(run_runner mixed); rc=$?
assert_exit_code "any failing suite makes the run exit 1" "1" "$rc"
assert_contains_regex "summary counts one pass and one fail" "$out" "1 passed.*1 failed"
assert_contains "failing suite is listed with its exit code" "$out" "beta-test"
assert_contains "failing suite's exit code is reported" "$out" "FAIL:3"
assert_contains "failing suite's log tail is echoed into the summary" "$out" "beta boom marker"
failing_block=$(sed -n '/FAILING SUITES/,$p' <<< "$out")
if grep -q 'alpha-test' <<< "$failing_block"; then
    assert_fail "FAILING SUITES block omits the passing suite" "alpha-test appeared in the failure block"
else
    assert_pass "FAILING SUITES block omits the passing suite"
fi

make_fixture allpass alpha-test.sh >/dev/null
out=$(run_runner allpass); rc=$?
assert_exit_code "an all-green run exits 0" "0" "$rc"
assert_contains_regex "all-green summary reports 1 passed and 0 failed" "$out" "1 passed.*0 failed"

# ─── Concurrency ────────────────────────────────────────────────────────────
print_test_section "Concurrency (--jobs)"

out=$(run_runner mixed --jobs 2); rc=$?
assert_exit_code "--jobs 2 keeps the same exit semantics" "1" "$rc"
assert_contains_regex "--jobs 2 still reports both suites" "$out" "1 passed.*1 failed.*\(2 suites"

# ─── Machine-readable report ────────────────────────────────────────────────
print_test_section "Report file (SW_TEST_REPORT)"

report="$ROOT/report.tsv"
export SW_TEST_REPORT="$report"
run_runner mixed >/dev/null
unset SW_TEST_REPORT
assert_file_exists "SW_TEST_REPORT is written" "$report"
assert_contains_regex "report has a PASS row for alpha-test" "$(cat "$report" 2>/dev/null)" "^alpha-test[[:space:]]PASS[[:space:]][0-9]+$"
assert_contains_regex "report has the exact FAIL status for beta-test" "$(cat "$report" 2>/dev/null)" "^beta-test[[:space:]]FAIL:3[[:space:]][0-9]+$"

# ─── Timeout ────────────────────────────────────────────────────────────────
print_test_section "Per-suite timeout"

make_fixture hang slow-test.sh >/dev/null
start=$(date +%s)
out=$(run_runner hang --timeout 1); rc=$?
elapsed=$(( $(date +%s) - start ))
assert_exit_code "a suite past the timeout fails the run" "1" "$rc"
assert_contains_regex "hung suite is reported as TIMEOUT, not FAIL" "$out" "slow-test +TIMEOUT"
if [[ "$elapsed" -lt 30 ]]; then
    assert_pass "hung suite is killed well before its 30s sleep (${elapsed}s)"
else
    assert_fail "hung suite is killed well before its 30s sleep" "run took ${elapsed}s"
fi

print_test_results
