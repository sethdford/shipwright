#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright activity test — Validate live agent activity stream          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-activity-test.XXXXXX")
    # Scripts under test read and write the intelligence cache here, not in the repo (#8609).
    export SHIPWRIGHT_INTELLIGENCE_CACHE="$TEST_TEMP_DIR/project/.claude/intelligence-cache.json"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls tac shasum; do
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
    log) echo "abc1234 Mock commit" ;;
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

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

# ─── Setup ────────────────────────────────────────────────────────────────────
setup_env

SRC="$SCRIPT_DIR/sw-activity.sh"

print_test_header "Shipwright Activity Tests"

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

SRC_CONTENT=$(cat "$SRC")

_count=$(printf '%s\n' "$SRC_CONTENT" | grep -cF 'set -euo pipefail' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

_count=$(printf '%s\n' "$SRC_CONTENT" | grep -cF 'trap' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -qE 'if \[.*BASH_SOURCE' "$SRC" 2>/dev/null; then
    assert_pass "Source guard pattern (if/then/fi)"
else
    assert_fail "Source guard pattern (if/then/fi)"
fi

_count=$(printf '%s\n' "$SRC_CONTENT" | grep -cE '^VERSION=' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

echo ""

# ─── 2. Help ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

HELP_OUT=$(bash "$SRC" help 2>&1) || true

assert_contains "help exits 0 and contains USAGE" "$HELP_OUT" "USAGE"
assert_contains "help lists 'watch' subcommand" "$HELP_OUT" "watch"
assert_contains "help lists 'snapshot' subcommand" "$HELP_OUT" "snapshot"
assert_contains "help lists 'history' subcommand" "$HELP_OUT" "history"
assert_contains "help lists 'stats' subcommand" "$HELP_OUT" "stats"
assert_contains "help lists 'agents' subcommand" "$HELP_OUT" "agents"

HELP2=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help alias works" "$HELP2" "USAGE"

echo ""

# ─── 3. Error Handling ───────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_fail "Unknown command exits non-zero"
else
    assert_pass "Unknown command exits non-zero"
fi

echo ""

# ─── 4. Snapshot / Stats / Agents require events file ────────────────────────
echo -e "${BOLD}  Subcommands Without Events File${RESET}"

# Remove events file if present
rm -f "$HOME/.shipwright/events.jsonl"

if bash "$SRC" snapshot 2>/dev/null; then
    assert_fail "snapshot exits non-zero with no events"
else
    assert_pass "snapshot exits non-zero with no events"
fi

if bash "$SRC" stats 2>/dev/null; then
    assert_fail "stats exits non-zero with no events"
else
    assert_pass "stats exits non-zero with no events"
fi

if bash "$SRC" agents 2>/dev/null; then
    assert_fail "agents exits non-zero with no events"
else
    assert_pass "agents exits non-zero with no events"
fi

echo ""

# ─── 5. emit_event and events file ───────────────────────────────────────────
echo -e "${BOLD}  Event Emission${RESET}"

# Source the script to get emit_event function
# shellcheck disable=SC1090
source "$SRC"

emit_event "test.event" "agent=test-agent" "count=5"

if [[ -f "$HOME/.shipwright/events.jsonl" ]]; then
    assert_pass "emit_event creates events.jsonl"
else
    assert_fail "emit_event creates events.jsonl"
fi

LAST_LINE=$(tail -1 "$HOME/.shipwright/events.jsonl")

if echo "$LAST_LINE" | jq empty 2>/dev/null; then
    assert_pass "emit_event writes valid JSON"
else
    assert_fail "emit_event writes valid JSON" "$LAST_LINE"
fi

assert_contains "Event contains type field" "$LAST_LINE" '"type":"test.event"'
assert_contains "Event contains agent field" "$LAST_LINE" '"agent":"test-agent"'
assert_contains "Event contains numeric count" "$LAST_LINE" '"count":5'

echo ""

# ─── 6. Format helpers ──────────────────────────────────────────────────────
echo -e "${BOLD}  Format Helpers${RESET}"

ICON=$(get_icon_for_type "commit")
assert_eq "get_icon_for_type commit returns icon" "📦" "$ICON"

ICON=$(get_icon_for_type "test.passed")
assert_eq "get_icon_for_type test.passed returns icon" "✅" "$ICON"

ICON=$(get_icon_for_type "unknown_type")
assert_eq "get_icon_for_type unknown returns bullet" "•" "$ICON"

TS_FMT=$(format_timestamp "2026-01-15T10:30:00Z")
assert_contains "format_timestamp strips T and Z" "$TS_FMT" "2026-01-15 10:30:00"

echo ""

# ─── 7. Stats with events data ──────────────────────────────────────────────
echo -e "${BOLD}  Stats With Events${RESET}"

# Create some test events
cat > "$HOME/.shipwright/events.jsonl" <<'EOF'
{"ts":"2026-01-15T10:00:00Z","ts_epoch":1768480800,"type":"pipeline.started","agent":"builder1","pipeline":"standard"}
{"ts":"2026-01-15T10:01:00Z","ts_epoch":1768480860,"type":"stage.started","agent":"builder1","stage":"build"}
{"ts":"2026-01-15T10:05:00Z","ts_epoch":1768481100,"type":"commit","agent":"builder1","message":"Add feature"}
{"ts":"2026-01-15T10:10:00Z","ts_epoch":1768481400,"type":"test.passed","agent":"tester1","count":"42"}
{"ts":"2026-01-15T10:15:00Z","ts_epoch":1768481700,"type":"pipeline.completed","agent":"builder1","result":"success"}
EOF

STATS_OUT=$(bash "$SRC" stats 2>/dev/null) || true
assert_contains "stats shows Total Events" "$STATS_OUT" "Total Events"
assert_contains "stats shows Commits count" "$STATS_OUT" "Commits"
assert_contains "stats shows Pipelines count" "$STATS_OUT" "Pipelines"

echo ""

# ─── 8. History subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}  History Subcommand${RESET}"

HIST_OUT=$(bash "$SRC" history all 2>&1) || true
assert_contains "history all shows activity header" "$HIST_OUT" "Activity from"

echo ""

print_test_results
