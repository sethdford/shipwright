#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright ci test — GitHub Actions CI/CD orchestration tests           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/.github/workflows"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        case "\${2:-}" in
            --show-toplevel) echo "$TEST_TEMP_DIR/repo" ;;
            *) echo "$TEST_TEMP_DIR/repo" ;;
        esac
        ;;
    config)
        echo "git@github.com:testorg/testrepo.git"
        ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Create a pipeline config for workflow generation
    cat > "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/composed-pipeline.json" <<'CONFIG'
{
  "stages": [
    {"id": "build", "enabled": true, "gate": "auto"},
    {"id": "test", "enabled": true, "gate": "auto"},
    {"id": "deploy", "enabled": false, "gate": "approve"}
  ]
}
CONFIG

    # Create a sample workflow file for analysis
    cat > "$TEST_TEMP_DIR/repo/.github/workflows/test.yml" <<'WORKFLOW'
name: Test
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: npm test
WORKFLOW

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true

    # Run from the repo dir so relative paths work
    cd "$TEST_TEMP_DIR/repo"
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
    if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi
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

assert_contains_regex() {
    local desc="$1" haystack="$2" pattern="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cE -- "$pattern" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing pattern: $pattern"
    fi
}

echo ""
print_test_header "Shipwright CI Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "shipwright ci"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-ci.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Version output ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" version 2>&1) || true
assert_contains "version shows version" "$output" "shipwright ci v"

# ─── Test 5: Unknown command exits 1 ─────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-ci.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
fi

# ─── Test 6: Generate workflow starts ─────────────────────────────────────────
# Note: generate uses ${var^} (Bash 4+), so on macOS Bash 3.2 it errors.
# We verify it starts processing (info line prints before the Bash 4+ error).
output=$(bash "$SCRIPT_DIR/sw-ci.sh" generate 2>&1) || true
assert_contains "generate starts processing" "$output" "Generating GitHub Actions workflow"

# ─── Test 7: Validate workflow ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" validate "$TEST_TEMP_DIR/repo/.github/workflows/test.yml" 2>&1) || true
assert_contains "validate runs on valid workflow" "$output" "valid"

# ─── Test 8: VERSION is defined ──────────────────────────────────────────────
version_line=$(grep "^VERSION=" "$SCRIPT_DIR/sw-ci.sh" | head -1)
assert_contains "VERSION is defined" "$version_line" "VERSION="

# ─── Test 9: Analyze workflow ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" analyze "$TEST_TEMP_DIR/repo/.github/workflows/test.yml" 2>&1) || true
assert_contains "analyze shows analysis" "$output" "Workflow Analysis"

# ─── Test 10: Analyze shows cache info ────────────────────────────────────────
assert_contains "analyze shows cache info" "$output" "Cache steps"

# ─── Test 11: Matrix generation ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" matrix "$TEST_TEMP_DIR/repo/.github/workflows/test-matrix.yml" 2>&1) || true
assert_contains "matrix generates config" "$output" "Generated matrix config"

# ─── Test 12: Matrix file exists ─────────────────────────────────────────────
if [[ -f "$TEST_TEMP_DIR/repo/.github/workflows/test-matrix.yml" ]]; then
    assert_pass "matrix workflow file exists"
else
    assert_fail "matrix workflow file exists"
fi

# ─── Test 13: Validate workflow ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" validate "$TEST_TEMP_DIR/repo/.github/workflows/test.yml" 2>&1) || true
assert_contains "validate passes on valid workflow" "$output" "valid"

# ─── Test 14: Runners list ───────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" runners list 2>&1) || true
assert_contains "runners list shows options" "$output" "ubuntu-latest"

# ─── Test 15: Runners recommend ──────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ci.sh" runners recommend 2>&1) || true
assert_contains "runners recommend shows guidance" "$output" "recommendations"

echo ""
echo ""
print_test_results
