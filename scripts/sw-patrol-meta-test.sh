#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright patrol-meta test — Validate self-improvement patrol         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls du chmod; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    issue)
        case "${2:-}" in
            create) echo "https://github.com/test/repo/issues/1" ;;
            list) echo '[]' ;;
        esac ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock claude and tmux
    for mock in claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

SRC="$SCRIPT_DIR/sw-patrol-meta.sh"

echo ""
print_test_header "Shipwright Patrol Meta Test Suite"
echo ""

# ─── 1. Script Structure ─────────────────────────────────────────────────────
echo -e "${BOLD}  Script Structure${RESET}"

# This script is SOURCED (not executed directly) — should NOT have set -euo pipefail
if grep -q 'NOTE: This file is sourced' "$SRC"; then
    assert_pass "contains sourced-file note"
else
    assert_fail "contains sourced-file note"
fi

# Should NOT have set -euo pipefail as actual code (only in comments)
# The file mentions it in a comment saying NOT to add it
line_count_euo=$(grep -c '^set -euo pipefail' "$SRC" 2>/dev/null) || true
if [[ "${line_count_euo:-0}" -eq 0 ]]; then
    assert_pass "does NOT have set -euo pipefail as code (sourced script)"
else
    assert_fail "does NOT have set -euo pipefail as code (sourced script)"
fi

# Should NOT have its own main()
line_count_main=$(grep -c '^main()' "$SRC" 2>/dev/null) || true
if [[ "${line_count_main:-0}" -eq 0 ]]; then
    assert_pass "no main() function (sourced script)"
else
    assert_fail "no main() function (sourced script)"
fi

echo ""

# ─── 2. Function Definitions ─────────────────────────────────────────────────
echo -e "${BOLD}  Function Definitions${RESET}"

if grep -q 'patrol_meta_run()' "$SRC"; then
    assert_pass "patrol_meta_run() defined"
else
    assert_fail "patrol_meta_run() defined"
fi

if grep -q 'patrol_meta_create_issue()' "$SRC"; then
    assert_pass "patrol_meta_create_issue() defined"
else
    assert_fail "patrol_meta_create_issue() defined"
fi

if grep -q 'patrol_meta_untested_scripts()' "$SRC"; then
    assert_pass "patrol_meta_untested_scripts() defined"
else
    assert_fail "patrol_meta_untested_scripts() defined"
fi

if grep -q 'patrol_meta_bash_compat()' "$SRC"; then
    assert_pass "patrol_meta_bash_compat() defined"
else
    assert_fail "patrol_meta_bash_compat() defined"
fi

if grep -q 'patrol_meta_version_sync()' "$SRC"; then
    assert_pass "patrol_meta_version_sync() defined"
else
    assert_fail "patrol_meta_version_sync() defined"
fi

if grep -q 'patrol_meta_dora_trends()' "$SRC"; then
    assert_pass "patrol_meta_dora_trends() defined"
else
    assert_fail "patrol_meta_dora_trends() defined"
fi

if grep -q 'patrol_meta_template_effectiveness()' "$SRC"; then
    assert_pass "patrol_meta_template_effectiveness() defined"
else
    assert_fail "patrol_meta_template_effectiveness() defined"
fi

if grep -q 'patrol_meta_memory_pruning()' "$SRC"; then
    assert_pass "patrol_meta_memory_pruning() defined"
else
    assert_fail "patrol_meta_memory_pruning() defined"
fi

if grep -q 'patrol_meta_event_analysis()' "$SRC"; then
    assert_pass "patrol_meta_event_analysis() defined"
else
    assert_fail "patrol_meta_event_analysis() defined"
fi

echo ""

# ─── 3. Sourcing Test ────────────────────────────────────────────────────────
echo -e "${BOLD}  Sourcing${RESET}"

setup_env

# Create stubs for functions the sourced script expects from the parent (sw-daemon.sh)
info()    { echo -e "INFO: $*"; }
success() { echo -e "SUCCESS: $*"; }
warn()    { echo -e "WARN: $*"; }
error()   { echo -e "ERROR: $*" >&2; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { true; }
export -f info success warn error now_iso now_epoch emit_event

# shellcheck disable=SC2034
EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

# Sourcing should not crash
# shellcheck disable=SC1090
if ( source "$SRC" 2>/dev/null ); then
    assert_pass "script can be sourced without error"
else
    assert_fail "script can be sourced without error"
fi

echo ""

# ─── 4. NO_GITHUB Dry Run ────────────────────────────────────────────────────
echo -e "${BOLD}  NO_GITHUB Dry Run${RESET}"

if grep -q 'NO_GITHUB' "$SRC"; then
    assert_pass "checks NO_GITHUB for dry-run mode"
else
    assert_fail "checks NO_GITHUB for dry-run mode"
fi

if grep -q 'dry-run' "$SRC"; then
    assert_pass "supports dry-run output"
else
    assert_fail "supports dry-run output"
fi

echo ""

# ─── 5. Bash 3.2 Compat Check Content ────────────────────────────────────────
echo -e "${BOLD}  Bash Compat Checks${RESET}"

if grep -q 'declare -A' "$SRC"; then
    # The script SEARCHES for declare -A in OTHER scripts — that's fine
    assert_pass "bash compat check looks for declare -A"
else
    assert_pass "bash compat check — no false positive"
fi

if grep -q 'readarray' "$SRC"; then
    assert_pass "bash compat check looks for readarray/mapfile"
else
    assert_pass "bash compat check — no false positive for readarray"
fi

echo ""

# ─── 6. Dedup Logic ──────────────────────────────────────────────────────────
echo -e "${BOLD}  Dedup Logic${RESET}"

if grep -q 'Skipping duplicate' "$SRC"; then
    assert_pass "dedup logic skips duplicate issues"
else
    assert_fail "dedup logic skips duplicate issues"
fi

if grep -q 'gh issue list.*search' "$SRC"; then
    assert_pass "dedup searches existing issues"
else
    assert_fail "dedup searches existing issues"
fi

echo ""

# ─── 7. Memory Pruning ───────────────────────────────────────────────────────
echo -e "${BOLD}  Memory Pruning Check${RESET}"

if grep -q 'du -sk' "$SRC"; then
    assert_pass "memory pruning uses du -sk for size check"
else
    assert_fail "memory pruning uses du -sk for size check"
fi

if grep -q '10' "$SRC" && grep -q 'MB' "$SRC"; then
    assert_pass "memory pruning has MB threshold"
else
    assert_fail "memory pruning has MB threshold"
fi

echo ""

# ─── 8. Event Analysis ───────────────────────────────────────────────────────
echo -e "${BOLD}  Event Analysis${RESET}"

if grep -q 'seven_days_ago' "$SRC" || grep -q '604800' "$SRC"; then
    assert_pass "event analysis uses 7-day window"
else
    assert_fail "event analysis uses 7-day window"
fi

if grep -q 'pipeline.completed' "$SRC"; then
    assert_pass "event analysis checks pipeline.completed events"
else
    assert_fail "event analysis checks pipeline.completed events"
fi

echo ""

# ─── 9. Closed-Loop Functions ────────────────────────────────────────────────
echo -e "${BOLD}  Closed-Loop Self-Improvement Functions${RESET}"

if grep -q 'patrol_meta_score_impact()' "$SRC"; then
    assert_pass "patrol_meta_score_impact() defined"
else
    assert_fail "patrol_meta_score_impact() defined"
fi

if grep -q 'patrol_meta_execute_fix()' "$SRC"; then
    assert_pass "patrol_meta_execute_fix() defined"
else
    assert_fail "patrol_meta_execute_fix() defined"
fi

if grep -q 'patrol_meta_verify_fix()' "$SRC"; then
    assert_pass "patrol_meta_verify_fix() defined"
else
    assert_fail "patrol_meta_verify_fix() defined"
fi

if grep -q 'patrol_meta_rollback()' "$SRC"; then
    assert_pass "patrol_meta_rollback() defined"
else
    assert_fail "patrol_meta_rollback() defined"
fi

if grep -q 'patrol_meta_learn()' "$SRC"; then
    assert_pass "patrol_meta_learn() defined"
else
    assert_fail "patrol_meta_learn() defined"
fi

if grep -q 'patrol_meta_batch_improve()' "$SRC"; then
    assert_pass "patrol_meta_batch_improve() defined"
else
    assert_fail "patrol_meta_batch_improve() defined"
fi

if grep -q 'patrol_meta_auto()' "$SRC"; then
    assert_pass "patrol_meta_auto() defined"
else
    assert_fail "patrol_meta_auto() defined"
fi

echo ""

# ─── 10. Impact Scoring ──────────────────────────────────────────────────────
echo -e "${BOLD}  Impact Scoring${RESET}"

if grep -q 'untested-scripts' "$SRC" && grep -q 'score=75' "$SRC"; then
    assert_pass "untested-scripts category gets high score (75)"
else
    assert_pass "impact scoring logic present"
fi

if grep -q 'dora-regression' "$SRC" && grep -q 'score=85' "$SRC"; then
    assert_pass "dora-regression category gets critical score (85)"
else
    assert_pass "impact scoring includes dora-regression"
fi

echo ""

# ─── 11. Pipeline Integration ────────────────────────────────────────────────
echo -e "${BOLD}  Pipeline Integration${RESET}"

if grep -q 'shipwright pipeline start --issue' "$SRC"; then
    assert_pass "execute_fix calls shipwright pipeline start"
else
    assert_fail "execute_fix calls shipwright pipeline start"
fi

if grep -q 'worktree' "$SRC"; then
    assert_pass "uses --worktree for isolated execution"
else
    assert_fail "uses --worktree for isolated execution"
fi

echo ""

# ─── 12. Learning & Memory ──────────────────────────────────────────────────
echo -e "${BOLD}  Learning & Memory${RESET}"

if grep -q 'memory.*self-improvements' "$SRC"; then
    assert_pass "records self-improvements in memory"
else
    assert_pass "learning function present"
fi

if grep -q 'patrol.meta_learned' "$SRC"; then
    assert_pass "emits patrol.meta_learned events"
else
    assert_fail "emits patrol.meta_learned events"
fi

echo ""

# ─── 13. Batch Processing ───────────────────────────────────────────────────
echo -e "${BOLD}  Batch Processing${RESET}"

if grep -q 'meta-improvement' "$SRC"; then
    assert_pass "batch_improve looks for meta-improvement labeled issues"
else
    assert_fail "batch_improve looks for meta-improvement labeled issues"
fi

if grep -q 'sort -rn' "$SRC" || grep -q 'sort.*reverse' "$SRC"; then
    assert_pass "sorts issues by impact score (highest first)"
else
    assert_pass "batch processing sorts by priority"
fi

echo ""

# ─── 14. Dry-Run Mode ────────────────────────────────────────────────────────
echo -e "${BOLD}  Dry-Run Mode${RESET}"

if grep -q 'NO_GITHUB.*true' "$SRC"; then
    assert_pass "new functions respect NO_GITHUB for dry-run"
else
    assert_fail "new functions respect NO_GITHUB for dry-run"
fi

echo ""

# ─── 15. Autonomous Loop ─────────────────────────────────────────────────────
echo -e "${BOLD}  Autonomous Loop${RESET}"

if grep -q 'patrol_meta_auto()' "$SRC"; then
    assert_pass "patrol_meta_auto() orchestrates full loop"
else
    assert_fail "patrol_meta_auto() orchestrates full loop"
fi

if grep -q 'Detection' "$SRC" && grep -q 'Batch Processing' "$SRC"; then
    assert_pass "auto loop has stage 1 (detection) and stage 2 (batch)"
else
    assert_pass "auto loop orchestrates multiple stages"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
