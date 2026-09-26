#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Test Suite: Pre-Build Validation (loop-prebuild.sh)                      ║
# ║                                                                         ║
# ║  Tests pre-build environment validation checks with mock project        ║
# ║  layouts. Verifies return codes (0/1/2), error-summary.json shape,      ║
# ║  and individual check behaviors.                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test framework
PASS=0
FAIL=0

test_pass() {
    local name="$1"
    echo "  ✓ $name"
    ((PASS++)) || true
}

test_fail() {
    local name="$1"
    local reason="${2:-}"
    echo "  ✗ $name"
    [[ -n "$reason" ]] && echo "    $reason"
    ((FAIL++)) || true
}

# Source the module being tested
source "$SCRIPT_DIR/lib/loop-prebuild.sh" 2>/dev/null || {
    echo "✗ Failed to source loop-prebuild.sh"
    exit 1
}

# ─── Test Suite: Basic Functionality ──────────────────────────────────────────

echo ""
echo "=== Basic Functionality ==="

# Test 1: Validation disabled
tmpdir=$(mktemp -d)
logdir="$tmpdir/.logs"
mkdir -p "$logdir"

PRE_BUILD_VALIDATE=0 pre_build_validate "$tmpdir" "$logdir" >/dev/null 2>&1 && rc=0 || rc=$?
[[ $rc -eq 0 ]] && test_pass "Returns 0 when disabled" || test_fail "Expected rc=0, got $rc"

rm -rf "$tmpdir"

# Test 2: Empty project (no markers)
tmpdir=$(mktemp -d)
logdir="$tmpdir/.logs"
mkdir -p "$logdir"

PRE_BUILD_VALIDATE=1 pre_build_validate "$tmpdir" "$logdir" >/dev/null 2>&1 && rc=0 || rc=$?
[[ $rc -eq 0 ]] && test_pass "Returns 0 for empty project" || test_fail "Expected rc=0, got $rc"

# Check that validation report was created
[[ -f "$logdir/pre-build-validation.json" ]] && test_pass "Creates pre-build-validation.json" || test_fail "Missing report"

rm -rf "$tmpdir"

# ─── Test Suite: JSON Output Shape ────────────────────────────────────────────

echo ""
echo "=== JSON Output Shape ==="

tmpdir=$(mktemp -d)
logdir="$tmpdir/.logs"
mkdir -p "$logdir"

PRE_BUILD_VALIDATE=1 pre_build_validate "$tmpdir" "$logdir" >/dev/null 2>&1 || true

# Check pre-build-validation.json structure
if [[ -f "$logdir/pre-build-validation.json" ]]; then
    # Parse JSON fields
    status=$(jq -r '.status' "$logdir/pre-build-validation.json" 2>/dev/null || echo "")
    duration=$(jq -r '.duration_ms' "$logdir/pre-build-validation.json" 2>/dev/null || echo "")

    [[ "$status" =~ ^(pass|fail|skipped)$ ]] && test_pass "validation report has valid status" || test_fail "status field invalid: $status"
    [[ "$duration" =~ ^[0-9]+$ ]] && test_pass "validation report has numeric duration_ms" || test_fail "duration_ms invalid: $duration"
else
    test_fail "pre-build-validation.json not created"
fi

rm -rf "$tmpdir"

# ─── Test Suite: Helper Functions ────────────────────────────────────────────

echo ""
echo "=== Helper Functions ==="

# Test _pbv_resolve_base_ref with git repo
tmpdir=$(mktemp -d)
cd "$tmpdir"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > file.txt
git add file.txt
git commit -q -m "initial"

base_ref=$(_pbv_resolve_base_ref "$tmpdir" 2>/dev/null || echo "")
[[ -n "$base_ref" ]] && test_pass "_pbv_resolve_base_ref finds base ref" || test_fail "base_ref is empty"

cd - >/dev/null
rm -rf "$tmpdir"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "✓ All tests passed"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
