#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright frontier test — Validate adversarial review, developer      ║
# ║  simulation, and architecture enforcer with mock Claude responses.      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-frontier-test.XXXXXX")
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/project/.claude"
    mkdir -p "$TEMP_DIR/bin"

    # Scripts live under project/scripts/ so REPO_DIR resolves to project/
    mkdir -p "$TEMP_DIR/project/scripts"

    # Copy scripts under test
    cp "$SCRIPT_DIR/sw-adversarial.sh" "$TEMP_DIR/project/scripts/"
    cp "$SCRIPT_DIR/sw-developer-simulation.sh" "$TEMP_DIR/project/scripts/"
    cp "$SCRIPT_DIR/sw-architecture-enforcer.sh" "$TEMP_DIR/project/scripts/"
    cp "$SCRIPT_DIR/sw-intelligence.sh" "$TEMP_DIR/project/scripts/"

    # Create daemon-config with all flags enabled
    cat > "$TEMP_DIR/project/.claude/daemon-config.json" <<'EOF'
{
    "intelligence": {
        "enabled": true,
        "adversarial_enabled": true,
        "simulation_enabled": true,
        "architecture_enabled": true
    }
}
EOF

    # Mock git for repo_hash
    cat > "$TEMP_DIR/bin/git" <<'GITEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "config" && "${2:-}" == "--get" && "${3:-}" == "remote.origin.url" ]]; then
    echo "https://github.com/test/repo.git"
    exit 0
fi
echo "mock-git"
GITEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock shasum
    cat > "$TEMP_DIR/bin/shasum" <<'SHAEOF'
#!/usr/bin/env bash
echo "abcdef123456  -"
SHAEOF
    chmod +x "$TEMP_DIR/bin/shasum"

    # Mock md5 for _intelligence_md5
    cat > "$TEMP_DIR/bin/md5" <<'MD5EOF'
#!/usr/bin/env bash
echo "d41d8cd98f00b204e9800998ecf8427e"
MD5EOF
    chmod +x "$TEMP_DIR/bin/md5"
}

# Create a mock claude that returns adversarial findings
_setup_mock_claude_adversarial() {
    cat > "$TEMP_DIR/bin/claude" <<'CLEOF'
#!/usr/bin/env bash
echo '[{"severity":"critical","category":"security","description":"SQL injection in user input","location":"src/db.ts:42","exploit_scenario":"Attacker sends malicious input"},{"severity":"high","category":"logic","description":"Off-by-one error in pagination","location":"src/api.ts:88","exploit_scenario":"Last page returns wrong results"},{"severity":"low","category":"edge_case","description":"Empty array not handled","location":"src/utils.ts:15","exploit_scenario":"Crash on empty input"}]'
CLEOF
    chmod +x "$TEMP_DIR/bin/claude"
}

# Mock claude that returns converged (no critical findings)
_setup_mock_claude_converged() {
    cat > "$TEMP_DIR/bin/claude" <<'CLEOF'
#!/usr/bin/env bash
echo '[{"severity":"low","category":"edge_case","description":"Minor style issue","location":"src/utils.ts:5","exploit_scenario":"N/A"}]'
CLEOF
    chmod +x "$TEMP_DIR/bin/claude"
}

# Mock claude for simulation (returns concerns from a persona)
_setup_mock_claude_simulation() {
    cat > "$TEMP_DIR/bin/claude" <<'CLEOF'
#!/usr/bin/env bash
echo '[{"concern":"Potential XSS in template rendering","severity":"high","suggestion":"Sanitize output with escape function"},{"concern":"Missing rate limiting on API endpoint","severity":"medium","suggestion":"Add rate limiter middleware"}]'
CLEOF
    chmod +x "$TEMP_DIR/bin/claude"
}

# Mock claude for architecture model
_setup_mock_claude_architecture() {
    cat > "$TEMP_DIR/bin/claude" <<'CLEOF'
#!/usr/bin/env bash
echo '{"layers":["presentation","business","data"],"patterns":["pipeline","provider","event-driven"],"conventions":["set -euo pipefail","atomic writes","jq for JSON"],"dependencies":["bash","jq","git","claude"]}'
CLEOF
    chmod +x "$TEMP_DIR/bin/claude"
}

# Mock claude for architecture violations
_setup_mock_claude_violations() {
    cat > "$TEMP_DIR/bin/claude" <<'CLEOF'
#!/usr/bin/env bash
echo '[{"violation":"Direct echo to file instead of atomic write","severity":"high","pattern_broken":"atomic writes","suggestion":"Use tmp file + mv pattern"}]'
CLEOF
    chmod +x "$TEMP_DIR/bin/claude"
}

# Mock claude that fails (simulates unavailable)
_setup_mock_claude_unavailable() {
    cat > "$TEMP_DIR/bin/claude" <<'CLEOF'
#!/usr/bin/env bash
exit 1
CLEOF
    chmod +x "$TEMP_DIR/bin/claude"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════
# ADVERSARIAL TESTS
# ═══════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────
# 1. Adversarial review produces structured findings
# ──────────────────────────────────────────────────────────────────────────
test_adversarial_structured_findings() {
    _setup_mock_claude_adversarial

    # Clear intelligence cache to avoid stale results
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-adversarial.sh" review "diff --git a/src/db.ts" "test context" 2>/dev/null
    )

    # Should be valid JSON array
    if ! echo "$output" | jq 'type == "array"' >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} Output is not a JSON array"
        return 1
    fi

    # Should have findings with required fields
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected findings, got $count"
        return 1
    fi

    # Check required fields on first finding
    local has_severity has_category has_description
    has_severity=$(echo "$output" | jq '.[0] | has("severity")' 2>/dev/null || echo "false")
    has_category=$(echo "$output" | jq '.[0] | has("category")' 2>/dev/null || echo "false")
    has_description=$(echo "$output" | jq '.[0] | has("description")' 2>/dev/null || echo "false")

    if [[ "$has_severity" != "true" || "$has_category" != "true" || "$has_description" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Missing required fields (severity=$has_severity, category=$has_category, description=$has_description)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# 2. Adversarial iteration converges when no critical findings
# ──────────────────────────────────────────────────────────────────────────
test_adversarial_converges() {
    _setup_mock_claude_converged
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"

    # Pass findings with no critical/high items
    local findings='[{"severity":"low","category":"edge_case","description":"minor issue"}]'

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-adversarial.sh" iterate "some code" "$findings" 1 2>/dev/null
    )

    # Should return empty array (converged)
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo "-1")
    if [[ "$count" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected empty findings (converged), got $count items"
        return 1
    fi

    # Check event was emitted
    local converged_events
    converged_events=$(grep -c '"adversarial.converged"' "$TEMP_DIR/home/.shipwright/events.jsonl" 2>/dev/null || true)
    converged_events="${converged_events:-0}"
    if [[ "$converged_events" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} No adversarial.converged event emitted"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# DEVELOPER SIMULATION TESTS
# ═══════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────
# 3. Simulation generates objections from 3 personas
# ──────────────────────────────────────────────────────────────────────────
test_simulation_three_personas() {
    _setup_mock_claude_simulation
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-developer-simulation.sh" review "diff --git a/src/api.ts" "Add new endpoint" 2>/dev/null
    )

    # Should be valid JSON array
    if ! echo "$output" | jq 'type == "array"' >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} Output is not a JSON array"
        return 1
    fi

    # Should have objections from multiple personas
    local personas_found
    personas_found=$(echo "$output" | jq '[.[].persona] | unique | length' 2>/dev/null || echo "0")
    if [[ "$personas_found" -lt 3 ]]; then
        echo -e "    ${RED}✗${RESET} Expected 3 personas, found $personas_found"
        return 1
    fi

    # Check for simulation.objection events
    local objection_events
    objection_events=$(grep -c '"simulation.objection"' "$TEMP_DIR/home/.shipwright/events.jsonl" 2>/dev/null || true)
    objection_events="${objection_events:-0}"
    if [[ "$objection_events" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} No simulation.objection events emitted"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# 4. Simulation address returns action items
# ──────────────────────────────────────────────────────────────────────────
test_simulation_address() {
    # Mock claude that returns addressed objections
    cat > "$TEMP_DIR/bin/claude" <<'CLEOF'
#!/usr/bin/env bash
echo '[{"concern":"XSS risk","response":"Added sanitization","action":"will_fix","code_change":"escape(input)"},{"concern":"Rate limiting","response":"Already handled by middleware","action":"already_addressed","code_change":""}]'
CLEOF
    chmod +x "$TEMP_DIR/bin/claude"
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"

    local objections='[{"persona":"security","concern":"XSS risk","severity":"high"},{"persona":"performance","concern":"Rate limiting","severity":"medium"}]'

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-developer-simulation.sh" address "$objections" "implementation context" 2>/dev/null
    )

    # Should have action items
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected action items, got $count"
        return 1
    fi

    # Check for action field
    local has_action
    has_action=$(echo "$output" | jq '.[0] | has("action")' 2>/dev/null || echo "false")
    if [[ "$has_action" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Missing 'action' field in response"
        return 1
    fi

    # Check simulation.complete event
    local complete_events
    complete_events=$(grep -c '"simulation.complete"' "$TEMP_DIR/home/.shipwright/events.jsonl" 2>/dev/null || true)
    complete_events="${complete_events:-0}"
    if [[ "$complete_events" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} No simulation.complete event emitted"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# ARCHITECTURE ENFORCER TESTS
# ═══════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────
# 5. Architecture model has valid schema
# ──────────────────────────────────────────────────────────────────────────
test_architecture_model_schema() {
    _setup_mock_claude_architecture
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"

    # Create minimal repo structure
    echo "# Test Repo" > "$TEMP_DIR/project/README.md"
    echo '{"name":"test"}' > "$TEMP_DIR/project/package.json"

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-architecture-enforcer.sh" build "$TEMP_DIR/project" 2>/dev/null
    )

    # Check required arrays exist
    local has_layers has_patterns has_conventions
    has_layers=$(echo "$output" | jq 'has("layers")' 2>/dev/null || echo "false")
    has_patterns=$(echo "$output" | jq 'has("patterns")' 2>/dev/null || echo "false")
    has_conventions=$(echo "$output" | jq 'has("conventions")' 2>/dev/null || echo "false")

    if [[ "$has_layers" != "true" || "$has_patterns" != "true" || "$has_conventions" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Missing schema fields (layers=$has_layers, patterns=$has_patterns, conventions=$has_conventions)"
        return 1
    fi

    # Check arrays have content
    local layer_count
    layer_count=$(echo "$output" | jq '.layers | length' 2>/dev/null || echo "0")
    if [[ "$layer_count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected layers, got $layer_count"
        return 1
    fi

    # Check model was stored
    local model_file="$TEMP_DIR/home/.shipwright/memory/abcdef123456/architecture.json"
    if [[ ! -f "$model_file" ]]; then
        echo -e "    ${RED}✗${RESET} Model file not stored at expected path"
        return 1
    fi

    # Check architecture.model_built event
    local built_events
    built_events=$(grep -c '"architecture.model_built"' "$TEMP_DIR/home/.shipwright/events.jsonl" 2>/dev/null || true)
    built_events="${built_events:-0}"
    if [[ "$built_events" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} No architecture.model_built event emitted"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# 6. Architecture validates changes (mock violation detected)
# ──────────────────────────────────────────────────────────────────────────
test_architecture_validates_changes() {
    _setup_mock_claude_violations
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"

    # Create a model file for validation
    local model_file="$TEMP_DIR/home/.shipwright/memory/abcdef123456/architecture.json"
    mkdir -p "$(dirname "$model_file")"
    cat > "$model_file" <<'EOF'
{"layers":["presentation","data"],"patterns":["atomic writes"],"conventions":["set -euo pipefail"],"dependencies":["jq"]}
EOF

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-architecture-enforcer.sh" validate "echo data > file.txt" "$model_file" 2>/dev/null
    )

    # Should return violations array
    if ! echo "$output" | jq 'type == "array"' >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} Output is not a JSON array"
        return 1
    fi

    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected violations, got $count"
        return 1
    fi

    # Check violation has pattern_broken field
    local has_pattern
    has_pattern=$(echo "$output" | jq '.[0] | has("pattern_broken")' 2>/dev/null || echo "false")
    if [[ "$has_pattern" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Missing pattern_broken field"
        return 1
    fi

    # Check architecture.violation event
    local violation_events
    violation_events=$(grep -c '"architecture.violation"' "$TEMP_DIR/home/.shipwright/events.jsonl" 2>/dev/null || true)
    violation_events="${violation_events:-0}"
    if [[ "$violation_events" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} No architecture.violation event emitted"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# 7. All three degrade gracefully when claude unavailable
# ──────────────────────────────────────────────────────────────────────────
test_graceful_degradation() {
    _setup_mock_claude_unavailable
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"

    # Adversarial should return empty array, not crash
    local adv_output
    local adv_exit=0
    adv_output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-adversarial.sh" review "some diff" "context" 2>/dev/null
    ) || adv_exit=$?

    if [[ "$adv_exit" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Adversarial crashed (exit $adv_exit) instead of degrading"
        return 1
    fi

    # Simulation should return empty array, not crash
    local sim_output
    local sim_exit=0
    sim_output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-developer-simulation.sh" review "some diff" "desc" 2>/dev/null
    ) || sim_exit=$?

    if [[ "$sim_exit" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Simulation crashed (exit $sim_exit) instead of degrading"
        return 1
    fi

    # Architecture validate should return empty array, not crash
    local model_file="$TEMP_DIR/home/.shipwright/memory/abcdef123456/architecture.json"
    mkdir -p "$(dirname "$model_file")"
    echo '{"layers":[],"patterns":[],"conventions":[],"dependencies":[]}' > "$model_file"

    local arch_output
    local arch_exit=0
    arch_output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/project/scripts/sw-architecture-enforcer.sh" validate "some diff" "$model_file" 2>/dev/null
    ) || arch_exit=$?

    if [[ "$arch_exit" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Architecture crashed (exit $arch_exit) instead of degrading"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright frontier — Test Suite                 ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for frontier tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Adversarial tests
echo -e "${PURPLE}${BOLD}Adversarial Review${RESET}"
run_test "Adversarial review produces structured findings" test_adversarial_structured_findings
run_test "Adversarial iteration converges on no critical findings" test_adversarial_converges
echo ""

# Simulation tests
echo -e "${PURPLE}${BOLD}Developer Simulation${RESET}"
run_test "Simulation generates objections from 3 personas" test_simulation_three_personas
run_test "Simulation address returns action items" test_simulation_address
echo ""

# Architecture tests
echo -e "${PURPLE}${BOLD}Architecture Enforcer${RESET}"
run_test "Architecture model has valid schema" test_architecture_model_schema
run_test "Architecture validates changes (violation detected)" test_architecture_validates_changes
echo ""

# Degradation tests
echo -e "${PURPLE}${BOLD}Graceful Degradation${RESET}"
run_test "All three degrade gracefully when claude unavailable" test_graceful_degradation
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

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
