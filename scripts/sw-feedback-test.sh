#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright feedback test — Production Feedback Loop tests               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-feedback-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/scripts"
    mkdir -p "$TEMP_DIR/repo/.claude/pipeline-artifacts"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
# Handle -C <dir> by shifting past it
if [[ "\${1:-}" == "-C" ]]; then shift; shift; fi
case "\${1:-}" in
    rev-parse) echo "$TEMP_DIR/repo" ;;
    log) echo "abc1234 fix: something" ;;
    show) echo "1 file changed" ;;
    config) echo "git@github.com:test/repo.git" ;;
    remote)
        case "\${2:-}" in
            get-url) echo "git@github.com:test/repo.git" ;;
            *) echo "" ;;
        esac
        ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"
    cat > "$TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/claude"
    if command -v shasum &>/dev/null; then
        ln -sf "$(command -v shasum)" "$TEMP_DIR/bin/shasum"
    fi
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1"; local detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cE -- "$pattern" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Feedback Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright feedback"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown subcommand"

# ─── Test 4: collect with empty dir ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}collect subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" collect "$TEMP_DIR/repo/.claude/pipeline-artifacts" 2>&1) && rc=0 || rc=$?
assert_eq "collect on empty dir exits 0" "0" "$rc"
assert_contains "collect shows collecting" "$output" "Collecting"

# ─── Test 5: collect reports save location ────────────────────────────────
# Note: collect saves to the git repo root, not the input dir
assert_contains "collect shows save path" "$output" "Saved to"

# ─── Test 6: collect with log file containing errors ──────────────────────
echo ""
echo -e "  ${CYAN}collect with error log${RESET}"
cat > "$TEMP_DIR/repo/.claude/pipeline-artifacts/test.log" <<'LOG'
2026-01-01 Starting pipeline
Error: connection timeout
2026-01-01 Retrying...
Exception: null pointer in handler
Fatal: unrecoverable error
Normal operation resumed
LOG
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" collect "$TEMP_DIR/repo/.claude/pipeline-artifacts/test.log" 2>&1) && rc=0 || rc=$?
assert_eq "collect with errors exits 0" "0" "$rc"
assert_contains "collect reports errors" "$output" "Collected"

# ─── Test 7: analyze with no error file ────────────────────────────────────
echo ""
echo -e "  ${CYAN}analyze subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" analyze "$TEMP_DIR/nonexistent.json" 2>&1) && rc=0 || rc=$?
assert_eq "analyze missing file exits 1" "1" "$rc"
assert_contains "analyze shows not found" "$output" "not found"

# ─── Test 8: analyze with collected errors ─────────────────────────────────
# Create the errors file that collect would normally produce
echo '{"total_errors": 5, "error_types": "timeout;crash;"}' > "$TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" analyze "$TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json" 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 0" "0" "$rc"
assert_contains "analyze shows report" "$output" "Error Analysis"

# ─── Test 9: learn subcommand ─────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}learn subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" learn "Off-by-one in pagination" "Fixed loop boundary" 2>&1) && rc=0 || rc=$?
assert_eq "learn exits 0" "0" "$rc"
assert_contains "learn confirms capture" "$output" "Incident captured"

# ─── Test 10: learn creates incidents file ─────────────────────────────────
if [[ -f "$HOME/.shipwright/incidents.jsonl" ]]; then
    assert_pass "incidents.jsonl created"
    line=$(head -1 "$HOME/.shipwright/incidents.jsonl")
    if echo "$line" | jq . >/dev/null 2>&1; then
        assert_pass "incidents.jsonl has valid JSONL"
    else
        assert_fail "incidents.jsonl has valid JSONL"
    fi
else
    assert_fail "incidents.jsonl created"
    assert_fail "incidents.jsonl has valid JSONL" "file missing"
fi

# ─── Test 11: report with incidents ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}report subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0" "0" "$rc"
assert_contains "report shows incidents" "$output" "Incident Report"
assert_contains "report shows total" "$output" "Total incidents"

# ─── Test 12: report with no incidents ─────────────────────────────────────
rm -f "$HOME/.shipwright/incidents.jsonl"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report no incidents exits 0" "0" "$rc"
assert_contains "report says no incidents" "$output" "No incidents"

# ─── Test 13: create-issue with NO_GITHUB ──────────────────────────────────
echo ""
echo -e "  ${CYAN}create-issue subcommand${RESET}"
# First create an error file with enough errors to exceed threshold
echo '{"total_errors": 10, "error_types": "timeout;crash;"}' > "$TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" create-issue "$TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json" 2>&1) && rc=0 || rc=$?
assert_eq "create-issue with NO_GITHUB exits 0" "0" "$rc"
assert_contains "create-issue skips with NO_GITHUB" "$output" "NO_GITHUB"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
