#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright discovery test — Cross-Pipeline Real-Time Learning tests     ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-discovery-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/discoveries"
    mkdir -p "$TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
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
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
    export SHIPWRIGHT_PIPELINE_ID="test-pipeline-001"
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Discovery Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright discovery"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: broadcast missing args ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" broadcast 2>&1) && rc=0 || rc=$?
assert_eq "broadcast without args exits 1" "1" "$rc"

# ─── Test 5: query missing args ───────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" query 2>&1) && rc=0 || rc=$?
assert_eq "query without args exits 1" "1" "$rc"

# ─── Test 6: inject missing args ──────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" inject 2>&1) && rc=0 || rc=$?
assert_eq "inject without args exits 1" "1" "$rc"

# ─── Test 7: broadcast a discovery ────────────────────────────────────────
echo ""
echo -e "  ${CYAN}broadcast subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" broadcast "auth-fix" "src/auth/*.ts" "JWT validation fixed" "Added claim check" 2>&1) && rc=0 || rc=$?
assert_eq "broadcast exits 0" "0" "$rc"
assert_contains "broadcast confirms" "$output" "Broadcast discovery"

# ─── Test 8: discoveries file created ─────────────────────────────────────
if [[ -f "$HOME/.shipwright/discoveries.jsonl" ]]; then
    assert_pass "discoveries.jsonl created"
else
    assert_fail "discoveries.jsonl created"
fi

# ─── Test 9: discoveries file has valid JSONL ─────────────────────────────
line=$(head -1 "$HOME/.shipwright/discoveries.jsonl" 2>/dev/null || echo "")
if echo "$line" | jq . >/dev/null 2>&1; then
    assert_pass "discoveries.jsonl contains valid JSON"
else
    assert_fail "discoveries.jsonl contains valid JSON" "line: $line"
fi

# ─── Test 10: query for matching pattern ──────────────────────────────────
echo ""
echo -e "  ${CYAN}query subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" query "src/auth/*.ts" 2>&1) && rc=0 || rc=$?
assert_eq "query exits 0" "0" "$rc"
assert_contains "query finds discovery" "$output" "auth-fix"

# ─── Test 11: query for non-matching pattern ──────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" query "nonexistent/path/*.go" 2>&1) && rc=0 || rc=$?
assert_eq "query non-match exits 0" "0" "$rc"
assert_contains "query reports no discoveries" "$output" "No relevant discoveries"

# ─── Test 12: status subcommand ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}status subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" status 2>&1) && rc=0 || rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status shows total" "$output" "Total discoveries"

# ─── Test 13: clean subcommand (nothing to clean) ─────────────────────────
echo ""
echo -e "  ${CYAN}clean subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" clean 2>&1) && rc=0 || rc=$?
assert_eq "clean exits 0" "0" "$rc"
assert_contains "clean reports result" "$output" "discoveries"

# ─── Test 14: inject subcommand ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}inject subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" inject "src/auth/*.ts" 2>&1) && rc=0 || rc=$?
assert_eq "inject exits 0" "0" "$rc"

# ─── Test 15: patterns_overlap function ────────────────────────────────────
echo ""
echo -e "  ${CYAN}internal patterns_overlap${RESET}"
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-discovery.sh"

    # Same pattern should match
    if patterns_overlap "src/auth/*.ts" "src/auth/*.ts"; then
        echo "SAME_MATCH"
    else
        echo "SAME_NO_MATCH"
    fi

    # Non-overlapping should not match
    if patterns_overlap "src/auth/*.ts" "lib/db/*.go"; then
        echo "DIFF_MATCH"
    else
        echo "DIFF_NO_MATCH"
    fi
) > "$TEMP_DIR/overlap_output" 2>/dev/null
overlap_result=$(cat "$TEMP_DIR/overlap_output")
if echo "$overlap_result" | grep -qF "SAME_MATCH"; then
    assert_pass "patterns_overlap matches same pattern"
else
    assert_fail "patterns_overlap matches same pattern" "got: $overlap_result"
fi
if echo "$overlap_result" | grep -qF "DIFF_NO_MATCH"; then
    assert_pass "patterns_overlap rejects different paths"
else
    assert_fail "patterns_overlap rejects different paths" "got: $overlap_result"
fi

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
