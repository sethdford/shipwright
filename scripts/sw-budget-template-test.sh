#!/bin/bash
# Budget-aware template selection — smoke test
# VERSION:1.0.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/budget-template.sh"

# Simple counter
PASS=0
FAIL=0

echo "Budget-Aware Template Selection Smoke Tests"
echo "=========================================="

# Test 1: Tier ladder full -> standard
if [[ "$(budget_template_downgrade "full")" == "standard" ]]; then
    echo "[✓] Tier ladder: full -> standard"; PASS=$((PASS+1))
else
    echo "[✗] Tier ladder: full -> standard"; FAIL=$((FAIL+1))
fi

# Test 2: Tier ladder standard -> fast
if [[ "$(budget_template_downgrade "standard")" == "fast" ]]; then
    echo "[✓] Tier ladder: standard -> fast"; PASS=$((PASS+1))
else
    echo "[✗] Tier ladder: standard -> fast"; FAIL=$((FAIL+1))
fi

# Test 3: Tier floor
if [[ "$(budget_template_downgrade "fast")" == "fast" ]]; then
    echo "[✓] Tier floor: fast -> fast"; PASS=$((PASS+1))
else
    echo "[✗] Tier floor: fast -> fast"; FAIL=$((FAIL+1))
fi

# Test 4: Unknown template pass-through
if [[ "$(budget_template_downgrade "unknown")" == "unknown" ]]; then
    echo "[✓] Unknown template pass-through"; PASS=$((PASS+1))
else
    echo "[✗] Unknown template pass-through"; FAIL=$((FAIL+1))
fi

# Test 5: budget_remaining_usd returns a string
REMAINING=$(budget_remaining_usd)
if [[ -n "$REMAINING" ]]; then
    echo "[✓] budget_remaining_usd works: $REMAINING"; PASS=$((PASS+1))
else
    echo "[✗] budget_remaining_usd failed"; FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ $FAIL -eq 0 ]]; then
    echo "✓ All tests passed"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
