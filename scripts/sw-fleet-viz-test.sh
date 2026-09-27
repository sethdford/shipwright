#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-viz test — Validate fleet visualization dashboard,    ║
# ║  overview, workers, insights, queue, costs, and export subcommands.    ║
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
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Copy script under test
    cp "$SCRIPT_DIR/sw-fleet-viz.sh" "$TEST_TEMP_DIR/repo/scripts/"

    # Create compat.sh stub
    touch "$TEST_TEMP_DIR/repo/scripts/lib/compat.sh"

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

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    # Create fleet-state.json with mock data
    cat > "$TEST_TEMP_DIR/home/.shipwright/fleet-state.json" <<'EOF'
{
    "active_jobs": [
        {"repo": "/home/user/project-a", "status": "running", "issue_number": 42, "worker_id": "w1"},
        {"repo": "/home/user/project-a", "status": "queued", "issue_number": 43, "priority": "high", "queued_for": "5m", "worker_id": "w2"},
        {"repo": "/home/user/project-b", "status": "running", "issue_number": 10, "worker_id": "w3"}
    ],
    "completed": [],
    "failed": []
}
EOF

    # Create costs.json with mock data
    cat > "$TEST_TEMP_DIR/home/.shipwright/costs.json" <<'EOF'
{
    "entries": [
        {"repo": "project-a", "cost": 1.50, "model": "opus"},
        {"repo": "project-a", "cost": 0.75, "model": "sonnet"},
        {"repo": "project-b", "cost": 2.00, "model": "opus"}
    ]
}
EOF

    # Create machines.json
    cat > "$TEST_TEMP_DIR/home/.shipwright/machines.json" <<'EOF'
{
    "machines": []
}
EOF

    # Create events.jsonl
    touch "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

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
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

setup_env

SUT="$TEST_TEMP_DIR/repo/scripts/sw-fleet-viz.sh"

echo ""
print_test_header "shipwright fleet-viz test"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}Script Safety${RESET}"

_src=$(cat "$SCRIPT_DIR/sw-fleet-viz.sh")

_count=$(printf '%s\n' "$_src" | grep -cF 'set -euo pipefail' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

_count=$(printf '%s\n' "$_src" | grep -cF 'trap' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

_count=$(printf '%s\n' "$_src" | grep -c 'if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "source guard uses if/then/fi pattern"
else
    assert_fail "source guard uses if/then/fi pattern"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────
echo -e "${BOLD}Version${RESET}"

_count=$(printf '%s\n' "$_src" | grep -c '^VERSION=' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

echo ""

# ─── 3. Help Output ─────────────────────────────────────────────────────────
echo -e "${BOLD}Help Output${RESET}"

help_out=$(bash "$SUT" help 2>&1) || true
assert_contains "help contains USAGE" "$help_out" "USAGE"
assert_contains "help contains overview subcommand" "$help_out" "overview"
assert_contains "help contains workers subcommand" "$help_out" "workers"
assert_contains "help contains insights subcommand" "$help_out" "insights"
assert_contains "help contains queue subcommand" "$help_out" "queue"
assert_contains "help contains costs subcommand" "$help_out" "costs"
assert_contains "help contains export subcommand" "$help_out" "export"

# --help flag also works
help_flag_out=$(bash "$SUT" --help 2>&1) || true
assert_contains "--help flag works" "$help_flag_out" "USAGE"

echo ""

# ─── 4. Unknown Command ─────────────────────────────────────────────────────
echo -e "${BOLD}Error Handling${RESET}"

unknown_rc=0
unknown_out=$(bash "$SUT" boguscmd 2>&1) || unknown_rc=$?
assert_eq "unknown command exits non-zero" "1" "$unknown_rc"
assert_contains "unknown command error message" "$unknown_out" "Unknown command"

echo ""

# ─── 5. Overview Subcommand ─────────────────────────────────────────────────
echo -e "${BOLD}Overview Subcommand${RESET}"

overview_out=$(bash "$SUT" overview 2>&1) || true
assert_contains "overview shows Fleet Overview" "$overview_out" "Fleet Overview"
assert_contains "overview shows Active count" "$overview_out" "Active"
assert_contains "overview shows Queued count" "$overview_out" "Queued"
assert_contains "overview shows Repos count" "$overview_out" "Repos"

echo ""

# ─── 6. Workers Subcommand ──────────────────────────────────────────────────
echo -e "${BOLD}Workers Subcommand${RESET}"

workers_out=$(bash "$SUT" workers 2>&1) || true
assert_contains "workers shows Worker Allocation" "$workers_out" "Worker Allocation"
assert_contains "workers shows Remote Machines" "$workers_out" "Remote Machines"

echo ""

# ─── 7. Queue Subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}Queue Subcommand${RESET}"

queue_out=$(bash "$SUT" queue 2>&1) || true
assert_contains "queue shows Issue Queue" "$queue_out" "Issue Queue"
assert_contains "queue shows queued items" "$queue_out" "Queued"

echo ""

# ─── 8. Costs Subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}Costs Subcommand${RESET}"

costs_out=$(bash "$SUT" costs 2>&1) || true
assert_contains "costs shows Fleet Costs" "$costs_out" "Fleet Costs"
assert_contains "costs shows Total Spend" "$costs_out" "Total Spend"
assert_contains "costs shows Per-Repo" "$costs_out" "Per-Repo"
assert_contains "costs shows Per-Model" "$costs_out" "Per-Model"

echo ""

# ─── 9. Export Subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}Export Subcommand${RESET}"

export_out=$(bash "$SUT" export 2>&1) || true
assert_contains "export produces JSON with active_jobs" "$export_out" "active_jobs"

echo ""

# ─── 10. Insights Subcommand ────────────────────────────────────────────────
echo -e "${BOLD}Insights Subcommand${RESET}"

insights_out=$(bash "$SUT" insights 2>&1) || true
assert_contains "insights shows Fleet Insights" "$insights_out" "Fleet Insights"
assert_contains "insights shows Success Rate" "$insights_out" "Success Rate"

echo ""

# ─── 11. Default Command ────────────────────────────────────────────────────
echo -e "${BOLD}Default Command${RESET}"

# Running with no args should default to overview
default_out=$(bash "$SUT" 2>&1) || true
assert_contains "default command shows Fleet Overview" "$default_out" "Fleet Overview"

echo ""

# ─── 12. Health Status Helper ────────────────────────────────────────────────
echo -e "${BOLD}Health Helpers${RESET}"

assert_contains "get_health_status function defined" "$_src" "get_health_status"
assert_contains "color_health function defined" "$_src" "color_health"
assert_contains "healthy status handled" "$_src" "healthy"
assert_contains "degraded status handled" "$_src" "degraded"
assert_contains "failing status handled" "$_src" "failing"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo ""
print_test_results
