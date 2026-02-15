#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright release test — Release train automation                     ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-release-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    describe)
        echo "v1.2.3" ;;
    log)
        echo "abc1234|fix: something|" ;;
    rev-list)
        echo "3" ;;
    tag)
        echo "tagged" ;;
    branch)
        echo "main" ;;
    show)
        echo "commit message" ;;
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
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Release Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-release.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"
assert_contains "help shows prepare" "$output" "prepare"
assert_contains "help shows changelog" "$output" "changelog"
assert_contains "help shows tag" "$output" "tag"
assert_contains "help shows publish" "$output" "publish"

# ─── Test 2: Version functions via sourcing ───────────────────────────────
echo ""
echo -e "${BOLD}  Version Parsing${RESET}"
# Test parse_version
result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    parse_version "v1.2.3"
')
assert_eq "parse_version v1.2.3" "1|2|3" "$result"

result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    parse_version "v10.20.30"
')
assert_eq "parse_version v10.20.30" "10|20|30" "$result"

# ─── Test 3: Version bumping ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Version Bumping${RESET}"
result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    bump_version "v1.2.3" "patch"
')
assert_eq "bump patch v1.2.3 -> v1.2.4" "v1.2.4" "$result"

result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    bump_version "v1.2.3" "minor"
')
assert_eq "bump minor v1.2.3 -> v1.3.0" "v1.3.0" "$result"

result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    bump_version "v1.2.3" "major"
')
assert_eq "bump major v1.2.3 -> v2.0.0" "v2.0.0" "$result"

# ─── Test 4: Version comparison ───────────────────────────────────────────
echo ""
echo -e "${BOLD}  Version Comparison${RESET}"
result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    compare_versions "v1.2.3" "v1.2.3"
')
assert_eq "compare v1.2.3 == v1.2.3" "0" "$result"

result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    compare_versions "v1.2.3" "v1.3.0"
')
assert_eq "compare v1.2.3 < v1.3.0" "-1" "$result"

result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    compare_versions "v2.0.0" "v1.9.9"
')
assert_eq "compare v2.0.0 > v1.9.9" "1" "$result"

# ─── Test 5: Commit type extraction ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Commit Type Extraction${RESET}"
result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    get_commit_type "feat: add authentication"
')
assert_eq "get_commit_type feat" "feat" "$result"

result=$(bash -c '
    export PATH="'"$TEMP_DIR/bin"':$PATH"
    export HOME="'"$TEMP_DIR/home"'"
    source "'"$SCRIPT_DIR/sw-release.sh"'" 2>/dev/null
    get_commit_type "fix: prevent data loss"
')
assert_eq "get_commit_type fix" "fix" "$result"

# ─── Test 6: Status command ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Status Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-release.sh" status 2>&1) || true
assert_contains "status shows version" "$output" "v1.2.3"
assert_contains "status shows header" "$output" "Release Status"

# ─── Test 7: Tag dry-run with valid version ───────────────────────────────
echo ""
echo -e "${BOLD}  Tag Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-release.sh" tag v2.0.0 --dry-run 2>&1) || true
assert_contains "tag dry-run shows version" "$output" "v2.0.0"
assert_contains "tag dry-run shows DRY RUN" "$output" "DRY RUN"

# ─── Test 8: Tag with invalid format ─────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-release.sh" tag invalid-version --dry-run 2>&1) && rc=0 || rc=$?
assert_eq "tag invalid format exits non-zero" "1" "$rc"
assert_contains "tag invalid format shows error" "$output" "Invalid version"

# ─── Test 9: Changelog ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Changelog Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-release.sh" changelog --dry-run 2>&1) || true
assert_contains "changelog shows from tag" "$output" "v1.2.3"
assert_contains "changelog shows generated msg" "$output" "Changelog generated"

# ─── Test 10: Unknown command ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-release.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
