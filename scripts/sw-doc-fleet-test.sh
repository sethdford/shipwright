#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright doc-fleet test — Validate documentation fleet operations     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/doc-fleet"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/agents"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEST_TEMP_DIR/repo/docs/strategy"
    mkdir -p "$TEST_TEMP_DIR/repo/docs/patterns"
    mkdir -p "$TEST_TEMP_DIR/repo/docs/tmux-research"
    mkdir -p "$TEST_TEMP_DIR/repo/claude-code"

    # Link real jq if available
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock binaries
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "abc1234" ;;
    diff) echo "docs/README.md" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    has-session) exit 1 ;;
    new-session) exit 0 ;;
    kill-session) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock stat to return a recent modification time
    cat > "$TEST_TEMP_DIR/bin/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-f" ]]; then
    echo "$(date +%s)"
elif [[ "${1:-}" == "-c" ]]; then
    echo "$(date +%s)"
else
    /usr/bin/stat "$@" 2>/dev/null || echo "0"
fi
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/stat"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true

    # Create mock documentation files
    echo "# Test README" > "$TEST_TEMP_DIR/repo/README.md"
    echo "# Strategy" > "$TEST_TEMP_DIR/repo/STRATEGY.md"
    cat > "$TEST_TEMP_DIR/repo/STRATEGY.md" <<'DOC'
# Strategy

This is the Shipwright strategy document with enough content
to pass the line count check in the audit function.

## Priorities

- P0: Reliability
- P1: Developer Experience
- P2: Intelligence
- P3: Cost Optimization
- P4: Observability
- P5: Community
- P6: Platform Self-Improvement

## Metrics

Current metrics and targets are listed below.

## Vision

Make autonomous delivery accessible.

## Mission

Continuously improve via data from each run.

## Principles

- Bash-first
- Atomic operations
- Graceful degradation
- Data-driven decisions

## Out of Scope

- GUI applications
- Non-Claude integration

Lots of filler content to get past the line check threshold
so we have more than 50 lines in this mock strategy document.
More lines here to pad it out sufficiently for the test suite
to verify that the health audit does not flag it as too thin.
DOC

    echo "# Changelog" > "$TEST_TEMP_DIR/repo/CHANGELOG.md"
    echo "# Tips" > "$TEST_TEMP_DIR/repo/docs/TIPS.md"
    echo "# Known Issues" > "$TEST_TEMP_DIR/repo/docs/KNOWN-ISSUES.md"
    echo "# Config Policy" > "$TEST_TEMP_DIR/repo/docs/config-policy.md"
    echo "# Strategy Index" > "$TEST_TEMP_DIR/repo/docs/strategy/README.md"
    echo "# Patterns Index" > "$TEST_TEMP_DIR/repo/docs/patterns/README.md"
    echo "# tmux Index" > "$TEST_TEMP_DIR/repo/docs/tmux-research/TMUX-RESEARCH-INDEX.md"

    # Create CLAUDE.md and agent definitions
    cat > "$TEST_TEMP_DIR/repo/.claude/CLAUDE.md" <<'DOC'
# Shipwright
Commands and documentation
<!-- AUTO:test-section -->
test content
<!-- /AUTO:test-section -->
DOC

    for agent in pipeline-agent code-reviewer test-specialist devops-engineer shell-script-specialist doc-fleet-agent; do
        echo "# ${agent}" > "$TEST_TEMP_DIR/repo/.claude/agents/${agent}.md"
    done

    # Create sw-docs.sh mock that succeeds
    cat > "$TEST_TEMP_DIR/repo/scripts/sw-docs.sh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    check) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/repo/scripts/sw-docs.sh"

    # Create sw-loop.sh mock
    cat > "$TEST_TEMP_DIR/repo/scripts/sw-loop.sh" <<'MOCK'
#!/usr/bin/env bash
echo "Mock loop"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/repo/scripts/sw-loop.sh"

    # Create some scripts for ratio check
    for s in sw-pipeline sw-daemon sw-loop sw-status sw-doctor; do
        echo "#!/usr/bin/env bash" > "$TEST_TEMP_DIR/repo/scripts/${s}.sh"
    done
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
echo ""
print_test_header "Shipwright Doc Fleet Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# Copy the script under test to the mock repo's scripts dir so SCRIPT_DIR
# resolves to the mock environment (finding mock sw-docs.sh, sw-loop.sh)
cp "$SCRIPT_DIR/sw-doc-fleet.sh" "$TEST_TEMP_DIR/repo/scripts/sw-doc-fleet.sh"
chmod +x "$TEST_TEMP_DIR/repo/scripts/sw-doc-fleet.sh"
# Also copy lib files if they exist
if [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
    cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_TEMP_DIR/repo/scripts/lib/compat.sh" 2>/dev/null || true
fi
if [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]]; then
    cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/repo/scripts/lib/helpers.sh" 2>/dev/null || true
fi

# Use the copy in the mock environment for all tests
TEST_SCRIPT="$TEST_TEMP_DIR/repo/scripts/sw-doc-fleet.sh"
export REPO_DIR="$TEST_TEMP_DIR/repo"

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$TEST_SCRIPT" help 2>&1) || true
assert_contains "help shows title" "$output" "Documentation Fleet Orchestrator"
assert_contains "help shows commands section" "$output" "COMMANDS"
assert_contains "help shows fleet roles section" "$output" "FLEET ROLES"
assert_contains "help shows examples" "$output" "EXAMPLES"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$TEST_SCRIPT" --help 2>&1) || true
assert_contains "--help flag works" "$output" "Documentation Fleet Orchestrator"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$TEST_SCRIPT" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Roles listing ──────────────────────────────────────────
echo -e "${BOLD}  Roles${RESET}"
output=$(bash "$TEST_SCRIPT" roles 2>&1) || true
assert_contains "roles lists doc-architect" "$output" "doc-architect"
assert_contains "roles lists claude-md" "$output" "claude-md"
assert_contains "roles lists strategy-curator" "$output" "strategy-curator"
assert_contains "roles lists pattern-writer" "$output" "pattern-writer"
assert_contains "roles lists readme-optimizer" "$output" "readme-optimizer"

# ─── Test 5: Audit ──────────────────────────────────────────────────
echo -e "${BOLD}  Audit${RESET}"
output=$(bash "$TEST_SCRIPT" audit 2>&1) || true
assert_contains "audit shows health header" "$output" "Health Audit"
assert_contains "audit shows health score" "$output" "Health Score"
assert_contains "audit checks doc inventory" "$output" "documentation files"
assert_contains "audit checks CLAUDE.md" "$output" "CLAUDE.md"
assert_contains "audit checks agent roles" "$output" "agent role definitions"

# ─── Test 6: Audit creates state file ────────────────────────────────
if [[ -f "$HOME/.shipwright/doc-fleet/state.json" ]]; then
    assert_pass "audit creates state file"
    local_health=$(jq -r '.docs_health_score' "$HOME/.shipwright/doc-fleet/state.json" 2>/dev/null) || local_health="0"
    if [[ "$local_health" -gt 0 ]]; then
        assert_pass "audit records health score ($local_health%)"
    else
        assert_fail "audit records health score" "score was 0"
    fi
else
    assert_fail "audit creates state file" "state.json not found"
    assert_fail "audit records health score" "no state file"
fi

# ─── Test 7: Launch dry-run ──────────────────────────────────────────
echo -e "${BOLD}  Launch${RESET}"
output=$(bash "$TEST_SCRIPT" launch --dry-run 2>&1) || true
assert_contains "launch dry-run shows header" "$output" "Launch"
assert_contains "launch dry-run mentions dry-run" "$output" "dry-run"
assert_contains "launch dry-run lists doc-architect" "$output" "doc-architect"
assert_contains "launch dry-run lists claude-md" "$output" "claude-md"
assert_contains "launch dry-run lists strategy-curator" "$output" "strategy-curator"
assert_contains "launch dry-run lists pattern-writer" "$output" "pattern-writer"
assert_contains "launch dry-run lists readme-optimizer" "$output" "readme-optimizer"
assert_contains "launch dry-run shows agent count" "$output" "5 agents"

# ─── Test 8: Launch specific role dry-run ─────────────────────────────
output=$(bash "$TEST_SCRIPT" launch --dry-run --role claude-md 2>&1) || true
assert_contains "launch specific role shows role" "$output" "claude-md"
assert_contains "launch specific role shows 1 agent" "$output" "1 agents"

# ─── Test 9: Launch invalid role ──────────────────────────────────────
output=$(bash "$TEST_SCRIPT" launch --role nonexistent 2>&1) || true
assert_contains "launch invalid role shows error" "$output" "Unknown role"

# ─── Test 10: Status ────────────────────────────────────────────────
echo -e "${BOLD}  Status${RESET}"
output=$(bash "$TEST_SCRIPT" status 2>&1) || true
assert_contains "status shows header" "$output" "Status"
assert_contains "status shows last run" "$output" "Last run"
assert_contains "status shows health score" "$output" "Health score"
assert_contains "status shows session list" "$output" "Active Doc Fleet Sessions"

# ─── Test 11: Manifest ──────────────────────────────────────────────
echo -e "${BOLD}  Manifest${RESET}"
output=$(bash "$TEST_SCRIPT" manifest 2>&1) || true
assert_contains "manifest shows generation" "$output" "manifest"
if [[ -f "$REPO_DIR/.claude/pipeline-artifacts/docs-manifest.json" ]]; then
    assert_pass "manifest file created"
    manifest_count=$(jq -r '.total_documents' "$REPO_DIR/.claude/pipeline-artifacts/docs-manifest.json" 2>/dev/null) || manifest_count="0"
    if [[ "$manifest_count" -gt 0 ]]; then
        assert_pass "manifest has documents ($manifest_count)"
    else
        assert_fail "manifest has documents" "count was 0"
    fi
else
    assert_fail "manifest file created" "docs-manifest.json not found"
    assert_fail "manifest has documents" "no manifest file"
fi

# ─── Test 12: Report ────────────────────────────────────────────────
echo -e "${BOLD}  Report${RESET}"
output=$(bash "$TEST_SCRIPT" report 2>&1) || true
assert_contains "report shows header" "$output" "Report"
assert_contains "report shows inventory" "$output" "Documentation Inventory"
assert_contains "report shows volume" "$output" "Documentation Volume"
assert_contains "report shows fleet state" "$output" "Fleet State"

# ─── Test 13: Report JSON output ─────────────────────────────────────
output=$(bash "$TEST_SCRIPT" report --json 2>&1) || true
assert_contains "report json shows JSON" "$output" "JSON report"
# Check a JSON report file was created
report_files=$(find "$HOME/.shipwright/doc-fleet/reports" -name "report-*.json" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$report_files" -gt 0 ]]; then
    assert_pass "JSON report file created"
else
    assert_fail "JSON report file created" "no report files found"
fi

# ─── Test 14: Retire (no sessions running) ───────────────────────────
echo -e "${BOLD}  Retire${RESET}"
output=$(bash "$TEST_SCRIPT" retire 2>&1) || true
assert_contains "retire shows retiring" "$output" "Retiring"
assert_contains "retire shows count" "$output" "Retired"

# ─── Test 15: State persistence across commands ──────────────────────
echo -e "${BOLD}  State Persistence${RESET}"
# Run audit, then check status references it
bash "$TEST_SCRIPT" audit >/dev/null 2>&1 || true
output=$(bash "$TEST_SCRIPT" status 2>&1) || true
assert_contains "status shows run count after commands" "$output" "Total runs"

# ─── Test 16: Event logging ──────────────────────────────────────────
echo -e "${BOLD}  Events${RESET}"
if [[ -f "$HOME/.shipwright/events.jsonl" ]]; then
    local_events=$(grep -c "doc_fleet" "$HOME/.shipwright/events.jsonl" 2>/dev/null) || local_events=0
    if [[ "$local_events" -gt 0 ]]; then
        assert_pass "doc_fleet events logged ($local_events events)"
    else
        assert_fail "doc_fleet events logged" "no doc_fleet events found"
    fi
else
    assert_fail "doc_fleet events logged" "events.jsonl not found"
fi

# ─── Test 17: CLI aliases ─────────────────────────────────────────────
echo -e "${BOLD}  Aliases${RESET}"
output=$(bash "$TEST_SCRIPT" start --dry-run 2>&1) || true
assert_contains "start alias works" "$output" "Launch"
output=$(bash "$TEST_SCRIPT" stop 2>&1) || true
assert_contains "stop alias works" "$output" "Retiring"

echo ""
echo ""
print_test_results
