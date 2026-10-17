#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-mutation-executor-test.sh — Mutation Testing Engine Test Suite       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-isolate.sh"
sw_test_isolate
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

assert_gt() {
    local threshold="$1" actual="$2" description="${3:-}"
    if [[ "$actual" -gt "$threshold" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected > $threshold, got $actual"
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
TEST_DIR=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/mutation-test.$$")
mkdir -p "$TEST_DIR" 2>/dev/null || true
trap 'rm -rf "$TEST_DIR"; sw_test_teardown' EXIT

# Source the module
emit_event() { true; }
export -f emit_event 2>/dev/null || true
source "$SCRIPT_DIR/lib/mutation-executor.sh"

# ─── Test: module loads without error ───────────────────────────────────────
test_module_loads() {
    local all_ok=true
    for fn in mutation_generate mutation_execute mutation_report; do
        if ! type "$fn" >/dev/null 2>&1; then
            all_ok=false
            break
        fi
    done
    if [[ "$all_ok" == "true" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m module loads and exports all functions"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m module loads and exports all functions"
    fi
}

# ─── Test: generate mutations from comparison operators ─────────────────────
test_generate_comparisons() {
    local src="$TEST_DIR/compare.sh"
    cat > "$src" << 'SHEOF'
#!/usr/bin/env bash
if [[ "$count" == 0 ]]; then
    echo "empty"
fi
if [[ "$x" != "y" ]]; then
    echo "different"
fi
SHEOF

    local mut_dir="$TEST_DIR/muts-compare"
    local count
    count=$(mutation_generate "$src" "$mut_dir" 2>/dev/null)
    assert_gt 0 "$count" "generates mutations for comparison operators (got $count)"

    # Check mutation files exist
    local mut_files
    mut_files=$(ls "$mut_dir"/mut_*.json 2>/dev/null | wc -l | xargs)
    assert_gt 0 "$mut_files" "mutation descriptor files created"
}

# ─── Test: generate mutations for boolean flips ─────────────────────────────
test_generate_booleans() {
    local src="$TEST_DIR/bool.js"
    cat > "$src" << 'JSEOF'
function check() {
    var enabled = true;
    var disabled = false;
    return enabled && disabled;
}
JSEOF

    local mut_dir="$TEST_DIR/muts-bool"
    local count
    count=$(mutation_generate "$src" "$mut_dir" 2>/dev/null)
    assert_gt 1 "$count" "generates multiple mutations for booleans and logical ops (got $count)"
}

# ─── Test: generate mutations for logical operators ─────────────────────────
test_generate_logical() {
    local src="$TEST_DIR/logic.js"
    cat > "$src" << 'JSEOF'
function validate(a, b) {
    if (a && b) return true;
    if (a || b) return false;
}
JSEOF

    local mut_dir="$TEST_DIR/muts-logic"
    local count
    count=$(mutation_generate "$src" "$mut_dir" 2>/dev/null)
    assert_gt 1 "$count" "generates mutations for && and || operators (got $count)"

    # Verify mutation categories
    local has_logical=false
    local f
    for f in "$mut_dir"/mut_*.json; do
        [[ ! -f "$f" ]] && continue
        local cat
        cat=$(jq -r '.category // ""' "$f" 2>/dev/null || true)
        if [[ "$cat" == "logical_flip" ]]; then
            has_logical=true
            break
        fi
    done
    if [[ "$has_logical" == "true" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m mutation category tagged as logical_flip"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m mutation category tagged as logical_flip"
    fi
}

# ─── Test: generate handles nonexistent file ────────────────────────────────
test_generate_nonexistent() {
    local count
    count=$(mutation_generate "/nonexistent/file" "$TEST_DIR/muts-none" 2>/dev/null)
    assert_equals "0" "$count" "returns 0 for nonexistent file"
}

# ─── Test: execute kills mutants with good tests ────────────────────────────
test_execute_kills() {
    # Create a simple source file with mutable operators
    local src="$TEST_DIR/src-kill.sh"
    cat > "$src" << 'SHEOF'
#!/usr/bin/env bash
check_value() {
    local val="$1"
    if [[ "$val" == "good" ]]; then
        echo "match"
        return 0
    fi
    echo "nomatch"
    return 1
}
SHEOF

    # Generate mutations (== will be flipped to !=)
    local mut_dir="$TEST_DIR/muts-kill"
    mutation_generate "$src" "$mut_dir" >/dev/null 2>&1

    # Create a test that catches the mutation
    local test_script="$TEST_DIR/test-kill.sh"
    cat > "$test_script" << TESTEOF
#!/usr/bin/env bash
source "$src"
result=\$(check_value "good")
[[ "\$result" == "match" ]] || exit 1
TESTEOF
    chmod +x "$test_script"

    local result
    result=$(mutation_execute "$mut_dir" "bash $test_script" "$TEST_DIR" 2>/dev/null)
    local killed
    killed=$(echo "$result" | jq -r '.killed // 0' 2>/dev/null || echo "0")

    if [[ "$killed" -gt 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m mutations killed by good tests ($killed killed)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m expected some mutations killed, got 0"
    fi
}

# ─── Test: execute requires test command ────────────────────────────────────
test_execute_no_cmd() {
    local result
    result=$(mutation_execute "$TEST_DIR/muts-none" "" "$TEST_DIR" 2>/dev/null || true)
    local total
    total=$(echo "$result" | jq -r '.total // 0' 2>/dev/null || echo "0")
    assert_equals "0" "$total" "returns 0 total when no test command provided"
}

# ─── Test: report generates valid JSON ──────────────────────────────────────
test_report_json() {
    # Create a mutation dir with known results
    local mut_dir="$TEST_DIR/muts-report"
    mkdir -p "$mut_dir"

    echo '{"id":"mut_1","file":"a.js","line":1,"category":"comparison_flip","description":"eq to neq","sed_expression":"s/==/!=/","result":"killed"}' \
        > "$mut_dir/mut_1.json"
    echo '{"id":"mut_2","file":"a.js","line":5,"category":"boolean_flip","description":"true to false","sed_expression":"s/true/false/","result":"survived"}' \
        > "$mut_dir/mut_2.json"
    echo '{"id":"mut_3","file":"b.js","line":3,"category":"logical_flip","description":"and to or","sed_expression":"s/&&/||/","result":"killed"}' \
        > "$mut_dir/mut_3.json"

    local report="$TEST_DIR/mutation-report.json"
    mutation_report "$mut_dir" "$report" >/dev/null 2>&1

    assert_file_exists "$report" "report file created"

    local score
    score=$(jq -r '.mutation_score_pct // -1' "$report" 2>/dev/null || echo "-1")
    # 2 killed out of 3 = 66%
    assert_equals "66" "$score" "mutation score is 66% (2/3 killed)"

    local survived_count
    survived_count=$(jq -r '.survived // -1' "$report" 2>/dev/null || echo "-1")
    assert_equals "1" "$survived_count" "1 surviving mutant reported"
}

# ─── Test: report identifies weak files ─────────────────────────────────────
test_report_weak_files() {
    local mut_dir="$TEST_DIR/muts-weak"
    mkdir -p "$mut_dir"

    echo '{"id":"mut_w1","file":"weak.js","line":1,"category":"comparison_flip","description":"eq to neq","result":"survived"}' \
        > "$mut_dir/mut_w1.json"
    echo '{"id":"mut_w2","file":"weak.js","line":5,"category":"boolean_flip","description":"true to false","result":"survived"}' \
        > "$mut_dir/mut_w2.json"

    local report="$TEST_DIR/report-weak.json"
    mutation_report "$mut_dir" "$report" >/dev/null 2>&1

    local weak_count
    weak_count=$(jq -r '.weak_files | length // 0' "$report" 2>/dev/null || echo "0")
    assert_gt 0 "$weak_count" "identifies weak files in report"

    local meets_target
    meets_target=$(jq -r '.meets_target' "$report" 2>/dev/null || echo "true")
    assert_equals "false" "$meets_target" "correctly reports below 80% target"
}

# ─── Test: max mutants limit ───────────────────────────────────────────────
test_max_mutants_limit() {
    local src="$TEST_DIR/many.sh"
    # Create a file with lots of mutable lines
    {
        echo "#!/usr/bin/env bash"
        local i=0
        while [[ "$i" -lt 30 ]]; do
            echo "if [[ \"\$x\" == \"$i\" ]]; then echo \"$i\"; fi"
            i=$((i + 1))
        done
    } > "$src"

    local mut_dir="$TEST_DIR/muts-max"
    MUTATION_MAX_MUTANTS=5
    local count
    count=$(mutation_generate "$src" "$mut_dir" 2>/dev/null)
    MUTATION_MAX_MUTANTS=50

    if [[ "$count" -le 5 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m respects MUTATION_MAX_MUTANTS limit ($count <= 5)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m should respect max mutants limit (got $count, expected <= 5)"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-mutation-executor-test.sh"
test_module_loads
test_generate_comparisons
test_generate_booleans
test_generate_logical
test_generate_nonexistent
test_execute_kills
test_execute_no_cmd
test_report_json
test_report_weak_files
test_max_mutants_limit

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
