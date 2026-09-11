#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-formal-spec-test.sh — Formal Specification System Test Suite        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if echo "$haystack" | grep -F "$needle" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    Actual: $haystack"
    fi
}

assert_file_exists() {
    local path="$1" description="${2:-}"
    if [[ -f "$path" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    File not found: $path"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TEST_DIR=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/formal-spec-test.$$")
mkdir -p "$TEST_DIR" 2>/dev/null || true
trap 'rm -rf "$TEST_DIR"' EXIT

# Source the module
emit_event() { true; }
export -f emit_event 2>/dev/null || true
source "$SCRIPT_DIR/lib/formal-spec.sh"

# ─── Test: module loads without error ───────────────────────────────────────
test_module_loads() {
    if type formal_spec_extract >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m module loads and exports formal_spec_extract"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m module loads and exports formal_spec_extract"
    fi
}

# ─── Test: extract JSDoc preconditions ──────────────────────────────────────
test_extract_jsdoc() {
    local src="$TEST_DIR/sample.js"
    cat > "$src" << 'JSEOF'
/**
 * @precondition input must be non-null
 * @postcondition returns a positive number
 */
function processInput(input) {
    if (!input) throw new Error("null");
    return input.length + 1;
}
JSEOF

    local out="$TEST_DIR/specs.json"
    formal_spec_extract "$src" "$out" >/dev/null 2>&1

    assert_file_exists "$out" "extract creates specs JSON file"

    local count
    count=$(jq -r '.count // 0' "$out" 2>/dev/null || echo "0")
    assert_equals "2" "$count" "extracts 2 specs (precondition + postcondition)"
}

# ─── Test: extract Python docstrings ────────────────────────────────────────
test_extract_python() {
    local src="$TEST_DIR/sample.py"
    cat > "$src" << 'PYEOF'
def validate_email(email):
    """Validate an email address.

    Precondition: email is a non-empty string
    Postcondition: returns True if valid, False otherwise
    Invariant: email format unchanged after validation
    """
    if not email:
        return False
    return "@" in email
PYEOF

    local out="$TEST_DIR/specs-py.json"
    formal_spec_extract "$src" "$out" >/dev/null 2>&1

    local count
    count=$(jq -r '.count // 0' "$out" 2>/dev/null || echo "0")
    assert_equals "3" "$count" "extracts 3 specs from Python docstring (pre + post + invariant)"
}

# ─── Test: extract from directory ───────────────────────────────────────────
test_extract_directory() {
    local dir="$TEST_DIR/project"
    mkdir -p "$dir"

    cat > "$dir/a.js" << 'EOF'
/** @precondition x > 0 */
function foo(x) { return x; }
EOF
    cat > "$dir/b.py" << 'EOF'
def bar():
    """Precondition: database connected"""
    pass
EOF

    local out="$TEST_DIR/specs-dir.json"
    formal_spec_extract "$dir" "$out" >/dev/null 2>&1

    local count
    count=$(jq -r '.count // 0' "$out" 2>/dev/null || echo "0")
    if [[ "$count" -ge 2 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m extracts specs from multiple files in directory"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m extracts specs from multiple files in directory (got $count, expected >= 2)"
    fi
}

# ─── Test: verify with no violations ────────────────────────────────────────
test_verify_clean() {
    local src="$TEST_DIR/clean.js"
    cat > "$src" << 'JSEOF'
/**
 * @precondition input must be validated
 */
function process(input) {
    if (!input) throw new Error("invalid input");
    return input.toString();
}
JSEOF

    local specs_out="$TEST_DIR/specs-clean.json"
    formal_spec_extract "$src" "$specs_out" >/dev/null 2>&1

    local report="$TEST_DIR/report-clean.json"
    formal_spec_verify "$specs_out" "$TEST_DIR" "$report" >/dev/null 2>&1

    assert_file_exists "$report" "verify creates compliance report"

    local violations
    violations=$(jq -r '.violations // -1' "$report" 2>/dev/null || echo "-1")
    assert_equals "0" "$violations" "no violations for code that validates preconditions"
}

# ─── Test: verify detects missing validation ────────────────────────────────
test_verify_violation() {
    local src="$TEST_DIR/bad.js"
    cat > "$src" << 'JSEOF'
/**
 * @precondition config must be checked
 */
function loadConfig(config) {
    return config.path;
}
JSEOF

    local specs_out="$TEST_DIR/specs-bad.json"
    formal_spec_extract "$src" "$specs_out" >/dev/null 2>&1

    local report="$TEST_DIR/report-bad.json"
    formal_spec_verify "$specs_out" "$TEST_DIR" "$report" >/dev/null 2>&1

    local violations
    violations=$(jq -r '.violations // 0' "$report" 2>/dev/null || echo "0")
    if [[ "$violations" -gt 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m detects missing precondition validation"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m detects missing precondition validation (got 0 violations)"
    fi
}

# ─── Test: verify empty specs file ──────────────────────────────────────────
test_verify_empty() {
    local empty_specs="$TEST_DIR/empty-specs.json"
    echo '{"specs":[],"count":0}' > "$empty_specs"

    local report="$TEST_DIR/report-empty.json"
    formal_spec_verify "$empty_specs" "$TEST_DIR" "$report" >/dev/null 2>&1

    local pct
    pct=$(jq -r '.compliance_pct // 0' "$report" 2>/dev/null || echo "0")
    assert_equals "100" "$pct" "empty specs file yields 100% compliance"
}

# ─── Test: inject produces prompt text ──────────────────────────────────────
test_inject_prompt() {
    local src="$TEST_DIR/inject.js"
    cat > "$src" << 'JSEOF'
/** @precondition user must be authenticated */
function getProfile(user) {
    if (!user) throw new Error("auth");
    return user.profile;
}
JSEOF

    local specs_out="$TEST_DIR/specs-inject.json"
    formal_spec_extract "$src" "$specs_out" >/dev/null 2>&1

    local prompt
    prompt=$(formal_spec_inject "$specs_out" "")
    assert_contains "$prompt" "Formal Specifications" "inject produces prompt with header"
    assert_contains "$prompt" "precondition" "inject includes spec type"
}

# ─── Test: extract handles nonexistent file gracefully ──────────────────────
test_extract_nonexistent() {
    local out="$TEST_DIR/specs-none.json"
    local result
    result=$(formal_spec_extract "/nonexistent/file.js" "$out" 2>/dev/null)
    # Should not crash, should echo output path
    if [[ -n "$result" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m extract handles nonexistent file gracefully"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m extract handles nonexistent file gracefully"
    fi
}

# ─── Test: invariant violation detection ────────────────────────────────────
test_invariant_violation() {
    local src="$TEST_DIR/invariant.js"
    cat > "$src" << 'JSEOF'
/**
 * @invariant counter is non-negative
 */
function decrement(counter) {
    counter = counter < 0;
    return counter;
}
JSEOF

    local specs_out="$TEST_DIR/specs-inv.json"
    formal_spec_extract "$src" "$specs_out" >/dev/null 2>&1

    local report="$TEST_DIR/report-inv.json"
    formal_spec_verify "$specs_out" "$TEST_DIR" "$report" >/dev/null 2>&1

    local violations
    violations=$(jq -r '.violations // 0' "$report" 2>/dev/null || echo "0")
    if [[ "$violations" -gt 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m detects invariant violation (counter < 0 pattern)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m detects invariant violation (got 0 violations)"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-formal-spec-test.sh"
test_module_loads
test_extract_jsdoc
test_extract_python
test_extract_directory
test_verify_clean
test_verify_violation
test_verify_empty
test_inject_prompt
test_extract_nonexistent
test_invariant_violation

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
