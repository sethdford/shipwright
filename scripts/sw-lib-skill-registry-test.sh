#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/skill-registry test — complexity weighting               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: skill-registry Tests"

setup_test_env "sw-lib-skill-registry-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

mkdir -p "$TEST_TEMP_DIR/skills"
: > "$TEST_TEMP_DIR/skills/security-audit.md"
: > "$TEST_TEMP_DIR/skills/performance.md"
export SKILLS_DIR="$TEST_TEMP_DIR/skills"
_SKILL_REGISTRY_LOADED=""
source "$SCRIPT_DIR/lib/skill-registry.sh"

SKILLS="$(printf '%s\n' /s/one.md /s/two.md)"
count() { printf '%s\n' "$1" | grep -c . || true; }

print_test_section "skill_weight_by_complexity"
assert_eq "complexity 2 keeps only the first skill" "1" "$(count "$(skill_weight_by_complexity 2 "$SKILLS")")"
assert_eq "complexity 5 keeps every skill" "2" "$(count "$(skill_weight_by_complexity 5 "$SKILLS")")"
assert_eq "complexity 9 adds security and performance" "4" "$(count "$(skill_weight_by_complexity 9 "$SKILLS")")"
# A decimal used to become "75" (printf's partial output plus the fallback) and was treated as 10.
assert_eq "complexity 7.5 is standard (7), not complex" "2" "$(count "$(skill_weight_by_complexity 7.5 "$SKILLS")")"
assert_eq "non-numeric complexity falls back to 5" "2" "$(count "$(skill_weight_by_complexity high "$SKILLS")")"
assert_eq "leading zero is decimal, not octal (08 is 8)" "4" "$(count "$(skill_weight_by_complexity 08 "$SKILLS")")"

print_test_results
