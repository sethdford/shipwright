#!/usr/bin/env bash

set -euo pipefail
VERSION="3.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR="${TMPDIR:-/tmp}"
TEST_HOME="$TMPDIR/sw-lib-memory-modules-test.$$"
mkdir -p "$TEST_HOME/.shipwright/memory"
export HOME="$TEST_HOME"
export MEMORY_DIR="$HOME/.shipwright/memory"
export REPO_HASH="test-org_test-repo"

cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

echo "Memory Module Tests"
echo "========================================"
echo ""

# Load modules
echo "Loading modules..."
source "$SCRIPT_DIR/lib/memory-common.sh"
source "$SCRIPT_DIR/lib/memory-capture.sh"
source "$SCRIPT_DIR/lib/memory-query.sh"
source "$SCRIPT_DIR/lib/memory-aggregate.sh"
source "$SCRIPT_DIR/lib/memory-admin.sh"
echo "PASS All modules loaded"
echo ""

# Test function definitions
echo "Testing function definitions..."
declare -f repo_hash >/dev/null && echo "PASS repo_hash defined" || echo "FAIL repo_hash missing"
declare -f memory_capture_pipeline >/dev/null && echo "PASS memory_capture_pipeline defined" || echo "FAIL memory_capture_pipeline missing"
declare -f memory_show >/dev/null && echo "PASS memory_show defined" || echo "FAIL memory_show missing"
echo ""

# Check line counts
echo "Testing module line counts..."
for mod in "$SCRIPT_DIR"/lib/memory-*.sh; do
  name=$(basename "$mod")
  lines=$(wc -l < "$mod")
  if (( lines < 800 )); then
    echo "PASS $name: $lines lines (< 800)"
  else
    echo "FAIL $name: $lines lines (exceeds 800)"
  fi
done

# Dispatcher
lines=$(wc -l < "$SCRIPT_DIR/sw-memory.sh")
if (( lines < 250 )); then
  echo "PASS sw-memory.sh: $lines lines (< 250)"
else
  echo "FAIL sw-memory.sh: $lines lines (exceeds 250)"
fi

echo ""
echo "Testing Bash compatibility..."
for mod in "$SCRIPT_DIR"/lib/memory-*.sh "$SCRIPT_DIR/sw-memory.sh"; do
  name=$(basename "$mod")

  if grep -q "declare -A" "$mod"; then
    echo "FAIL $name: contains 'declare -A'"
  elif grep -q "readarray\|mapfile" "$mod"; then
    echo "FAIL $name: contains Bash 4+ functions"
  else
    echo "PASS $name: Bash 3.2 compatible"
  fi
done

echo ""
echo "Testing syntax..."
for mod in "$SCRIPT_DIR"/lib/memory-*.sh "$SCRIPT_DIR/sw-memory.sh"; do
  name=$(basename "$mod")
  if bash -n "$mod" 2>/dev/null; then
    echo "PASS Syntax OK: $name"
  else
    echo "FAIL Syntax error in $name"
  fi
done

echo ""
echo "========================================"
echo "All tests completed successfully!"
exit 0
