#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright decompose test — Intelligent Issue Decomposition tests       ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-decompose-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
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
echo '{"issue_number": 42, "complexity_score": 85, "should_decompose": true, "subtasks": []}'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/claude"
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
echo -e "${CYAN}${BOLD}  Shipwright Decompose Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright decompose"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: --version flag ───────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}version flag${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" --version 2>&1) && rc=0 || rc=$?
assert_eq "--version exits 0" "0" "$rc"
assert_contains "--version shows version" "$output" "2.1.0"

# ─── Test 4: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 5: analyze missing args ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" analyze 2>&1) && rc=0 || rc=$?
assert_eq "analyze without issue exits 1" "1" "$rc"
assert_contains "analyze shows usage" "$output" "Usage"

# ─── Test 6: decompose missing args ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" decompose 2>&1) && rc=0 || rc=$?
assert_eq "decompose without issue exits 1" "1" "$rc"

# ─── Test 7: auto missing args ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" auto 2>&1) && rc=0 || rc=$?
assert_eq "auto without issue exits 1" "1" "$rc"

# ─── Test 8: analyze with NO_GITHUB ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}analyze subcommand (mock)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" analyze 42 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "analyze outputs complexity_score" "$output" "complexity_score"
assert_contains "analyze outputs should_decompose" "$output" "should_decompose"
assert_contains "analyze outputs subtasks" "$output" "subtasks"

# ─── Test 9: analyze JSON is valid ────────────────────────────────────────
# Extract JSON block from output (from first { to last })
json_output=$(printf '%s\n' "$output" | sed -n '/^{/,/^}/p')
if [[ -n "$json_output" ]] && printf '%s\n' "$json_output" | jq . >/dev/null 2>&1; then
    assert_pass "analyze outputs valid JSON"
else
    assert_fail "analyze outputs valid JSON"
fi

# ─── Test 10: analyze mock returns expected fields ─────────────────────────
complexity=$(printf '%s\n' "$json_output" | jq -r '.complexity_score' 2>/dev/null || echo "")
assert_eq "analyze returns complexity_score 85" "85" "$complexity"
should_decompose=$(printf '%s\n' "$json_output" | jq -r '.should_decompose' 2>/dev/null || echo "")
assert_eq "analyze returns should_decompose true" "true" "$should_decompose"

# ─── Test 11: decompose with NO_GITHUB (mock) ─────────────────────────────
echo ""
echo -e "  ${CYAN}decompose subcommand (mock)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" decompose 42 2>&1) && rc=0 || rc=$?
assert_eq "decompose exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "decompose shows decomposing" "$output" "Decomposing"

# ─── Test 12: auto with NO_GITHUB (mock) ──────────────────────────────────
echo ""
echo -e "  ${CYAN}auto subcommand (mock)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" auto 42 2>&1) && rc=0 || rc=$?
assert_eq "auto exits 0 with NO_GITHUB" "0" "$rc"

# ─── Test 13: events file created ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}state file creation${RESET}"
if [[ -f "$HOME/.shipwright/events.jsonl" ]]; then
    assert_pass "events.jsonl created"
else
    assert_fail "events.jsonl created"
fi

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
