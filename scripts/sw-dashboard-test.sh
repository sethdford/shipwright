#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright dashboard smoke test — validates dashboard structure        ║
# ║  Checks server.ts, public/, routes, and syntax. No server startup.       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_DIR="$REPO_DIR/dashboard"
SERVER_TS="$DASHBOARD_DIR/server.ts"
PUBLIC_DIR="$DASHBOARD_DIR/public"
INDEX_HTML="$PUBLIC_DIR/index.html"
APP_JS="$PUBLIC_DIR/app.js"

# ─── Colors (matches shipwright theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_dir_exists() {
    local dirpath="$1" label="${2:-dir exists}"
    if [[ -d "$dirpath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Directory not found: $dirpath ($label)"
    return 1
}

assert_file_contains() {
    local filepath="$1" pattern="$2" label="${3:-file content}"
    if [[ ! -f "$filepath" ]]; then
        echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
        return 1
    fi
    if grep -qiE "$pattern" "$filepath"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File $filepath missing pattern: $pattern ($label)"
    return 1
}

assert_file_matches_grep() {
    local filepath="$1" pattern="$2" label="${3:-grep match}"
    if [[ ! -f "$filepath" ]]; then
        echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
        return 1
    fi
    if grep -qE "$pattern" "$filepath"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File $filepath missing pattern: $pattern ($label)"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_server_ts_exists() {
    assert_file_exists "$SERVER_TS" "server.ts exists"
}

test_server_ts_valid_syntax_basic() {
    # Basic syntax: must have valid import/export and no obvious parse errors
    assert_file_contains "$SERVER_TS" "^import " "has import statement" &&
    assert_file_contains "$SERVER_TS" "fetch\(req" "has fetch handler"
}

test_public_dir_exists() {
    assert_dir_exists "$PUBLIC_DIR" "public/ directory exists"
}

test_index_html_exists() {
    assert_file_exists "$INDEX_HTML" "index.html exists"
}

test_app_js_exists() {
    assert_file_exists "$APP_JS" "app.js exists"
}

test_server_exports_api_routes() {
    assert_file_matches_grep "$SERVER_TS" "/api/health" "exports /api/health" &&
    assert_file_matches_grep "$SERVER_TS" "/api/status" "exports /api/status"
}

test_server_exports_ws_route() {
    assert_file_matches_grep "$SERVER_TS" 'pathname === "/ws"' "exports /ws route"
}

test_bun_check_passes() {
    if ! command -v bun &>/dev/null; then
        echo -e "    ${DIM}(bun not installed, skipping)${RESET}"
        return 0
    fi
    local tmpout
    tmpout=$(mktemp -d "${TMPDIR:-/tmp}/sw-dashboard-build.XXXXXX")
    if bun build "$SERVER_TS" --outdir="$tmpout" --target=bun &>/dev/null; then
        rm -rf "$tmpout"
        return 0
    fi
    rm -rf "$tmpout"
    echo -e "    ${RED}✗${RESET} bun build failed on server.ts"
    return 1
}

test_html_references_app_js() {
    assert_file_contains "$INDEX_HTML" 'app\.js' "HTML references app.js"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${PURPLE}${BOLD}Dashboard Smoke Tests${RESET}"
echo ""

echo -e "${PURPLE}${BOLD}Structure${RESET}"
run_test "server.ts exists" test_server_ts_exists
run_test "server.ts has valid structure (imports, fetch)" test_server_ts_valid_syntax_basic
run_test "public/ directory exists" test_public_dir_exists
run_test "index.html exists" test_index_html_exists
run_test "app.js exists" test_app_js_exists
echo ""

echo -e "${PURPLE}${BOLD}Routes${RESET}"
run_test "Server exports /api/health and /api/status" test_server_exports_api_routes
run_test "Server exports /ws WebSocket route" test_server_exports_ws_route
echo ""

echo -e "${PURPLE}${BOLD}Integrity${RESET}"
run_test "bun check passes (if bun available)" test_bun_check_passes
run_test "index.html references app.js" test_html_references_app_js
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
