#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright test-helpers — Shared test harness for all unit tests        ║
# ║  Source this from any *-test.sh file to get assert_*, setup, teardown    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/test-helpers.sh"
#
# Provides:
#   Colors, counters, assert_pass/fail/eq/contains/contains_regex/gt/json_key
#   setup_test_env / cleanup_test_env  (temp dir, mock PATH, mock HOME)
#   print_test_header / print_test_results
#   Mock helpers: mock_binary, mock_jq, mock_git, mock_gh, mock_claude

[[ -n "${_TEST_HELPERS_LOADED:-}" ]] && return 0
_TEST_HELPERS_LOADED=1

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
PURPLE='\033[38;2;168;85;247m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()

# ─── Auto-initialize TEST_TEMP_DIR ──────────────────────────────────────────
# Many test files use TEST_TEMP_DIR in their setup_env() without calling
# setup_test_env(). Auto-create a temp dir so $TEST_TEMP_DIR is never empty.
# Save originals now so cleanup_test_env() can always restore them.
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-test-auto.XXXXXX")
mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
mkdir -p "$TEST_TEMP_DIR/bin"

# ─── Assertions ──────────────────────────────────────────────────────────────

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if grep -qF -- "$needle" <<< "$haystack" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_contains_regex() {
    local desc="$1"
    local haystack="$2"
    local pattern="$3"
    if grep -qE -- "$pattern" <<< "$haystack" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing pattern: $pattern"
    fi
}

assert_gt() {
    local desc="$1"
    local actual="$2"
    local threshold="$3"
    if [[ "$actual" -gt "$threshold" ]] 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected >$threshold, got: $actual"
    fi
}

assert_json_key() {
    local desc="$1"
    local json="$2"
    local key="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$key" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "key $key: expected $expected, got: $actual"
    fi
}

assert_exit_code() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc (exit $actual)"
    else
        assert_fail "$desc" "expected exit code: $expected, got: $actual"
    fi
}

assert_file_exists() {
    local desc="$1"
    local filepath="$2"
    if [[ -f "$filepath" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "file not found: $filepath"
    fi
}

assert_file_not_exists() {
    local desc="$1"
    local filepath="$2"
    if [[ ! -f "$filepath" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "file should not exist: $filepath"
    fi
}

# ─── Test Environment ────────────────────────────────────────────────────────

setup_test_env() {
    local test_name="${1:-sw-test}"
    # Clean up auto-created temp dir and create a named one
    [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${test_name}.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/logs"

    # ORIG_HOME/ORIG_PATH already saved at source time
    export HOME="$TEST_TEMP_DIR/home"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export NO_GITHUB=true

    # Link real jq if available
    if command -v jq >/dev/null 2>&1; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
}

cleanup_test_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    [[ -n "${ORIG_HOME:-}" ]] && export HOME="$ORIG_HOME" || true
    [[ -n "${ORIG_PATH:-}" ]] && export PATH="$ORIG_PATH" || true
}

# ─── Mock Helpers ────────────────────────────────────────────────────────────

mock_binary() {
    local name="$1"
    local script="${2:-exit 0}"
    cat > "$TEST_TEMP_DIR/bin/$name" <<MOCK
#!/usr/bin/env bash
$script
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/$name"
}

mock_git() {
    mock_binary "git" 'case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "/tmp/mock-repo"
        fi ;;
    remote) echo "https://github.com/testuser/testrepo.git" ;;
    branch) echo "" ;;
    log) echo "" ;;
    *) echo "" ;;
esac
exit 0'
}

mock_gh() {
    mock_binary "gh" 'case "${1:-}" in
    api) echo "{}" ;;
    issue) echo "[]" ;;
    pr) echo "[]" ;;
    *) echo "" ;;
esac
exit 0'
}

mock_claude() {
    mock_binary "claude" 'echo "Mock claude response"
exit 0'
}

# ─── Output Helpers ──────────────────────────────────────────────────────────

print_test_header() {
    local title="$1"
    echo ""
    echo -e "${CYAN}${BOLD}  ${title}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
}

print_test_section() {
    local title="$1"
    echo ""
    echo -e "  ${CYAN}${title}${RESET}"
}

print_test_results() {
    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    echo ""
    if [[ $FAIL -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
    else
        echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
        echo ""
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
    fi
    echo ""
    exit "$FAIL"
}

# ─── Source-inspection helpers ──────────────────────────────────────────────
# Match a regex inside a grep context window, without a pipeline.
#
# `grep -A N anchor files | grep -q needle` races under `set -o pipefail`:
# grep -q exits at its first match, the upstream grep then dies on SIGPIPE
# (141), and pipefail promotes that to a pipeline failure — so the assertion
# fails intermittently even though the needle is present. Capture the window
# first, then match a here-string so there is no pipe to break.
#
# Usage: grep_ctx_q [-i] -A60 'anchor_pattern' 'needle_pattern' file [file...]
# A leading -i makes the needle match case-insensitive (the anchor stays exact).
grep_ctx_q() {
    local needle_opts=""
    if [[ "${1:-}" == "-i" ]]; then
        needle_opts="-i"
        shift
    fi
    local ctx_flag="$1" anchor="$2" needle="$3"
    shift 3
    local window
    window=$(grep "$ctx_flag" "$anchor" "$@" 2>/dev/null || true)
    [[ -n "$window" ]] || return 1
    grep -q $needle_opts "$needle" <<<"$window"
}
