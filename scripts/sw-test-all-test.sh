#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-all test — named test files (the acceptance stage's per-file run) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Only the named-file path: running every suite from inside a suite would recurse.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "sw-test-all: named test files"

setup_test_env "sw-test-all-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

RUNNER="$SCRIPT_DIR/sw-test-all.sh"
D="$TEST_TEMP_DIR/suites"
mkdir -p "$D" "$TEST_TEMP_DIR/bin"
printf '#!/usr/bin/env bash\necho "  ✓ fine"\n' > "$D/green-test.sh"
printf '#!/usr/bin/env bash\necho "  ✗ AC-1: broken"\nexit 1\n' > "$D/red-test.sh"
echo 'test("x", () => {});' > "$D/a.test.ts"
printf '#!/usr/bin/env bash\necho "fake bun $*"\n' > "$TEST_TEMP_DIR/bin/bun"
chmod +x "$TEST_TEMP_DIR/bin/bun"

run() { # <var> <args...>: sets rc and out
    rc=0
    out=$(bash "$RUNNER" "$@" </dev/null 2>&1) || rc=$?
}

print_test_section "bash suites"
run "$D/green-test.sh"
assert_eq "a passing named suite exits 0" "0" "$rc"
assert_contains "only the named suite runs" "$out" "1 passed  0 failed"
run "$D/red-test.sh"
assert_eq "a failing named suite exits 1" "1" "$rc"
assert_contains "its output is shown, so the acceptance red check sees the assertion" "$out" "AC-1: broken"
assert_contains "the suite is named" "$out" "red-test"
run "$D/green-test.sh" "$D/red-test.sh"
assert_contains "several named suites all run" "$out" "1 passed  1 failed"

print_test_section "captured output"
start=$(date +%s)
out=$(bash "$RUNNER" --timeout 30 "$D/green-test.sh" </dev/null 2>&1) || true
elapsed=$(( $(date +%s) - start ))
assert_eq "a caller capturing the output is not held open by the watchdog (${elapsed}s)" "yes" \
    "$([[ $elapsed -lt 10 ]] && echo yes || echo no)"

print_test_section "TypeScript files"
rc=0
out=$(PATH="$TEST_TEMP_DIR/bin:$PATH" bash "$RUNNER" "$D/a.test.ts" </dev/null 2>&1) || rc=$?
assert_eq "a *.test.ts file goes to bun test" "fake bun test $D/a.test.ts" "$out"

print_test_section "refusals"
run "$D/nope-test.sh"
assert_eq "a missing file is refused" "2" "$rc"
run "$TEST_TEMP_DIR/bin/bun"
assert_eq "a file that is not a test is refused" "2" "$rc"
run "$D/a.test.ts" "$D/green-test.sh"
assert_eq "TypeScript and bash files cannot be mixed" "2" "$rc"
run --bogus
assert_eq "an unknown option is still refused" "2" "$rc"

print_test_results
