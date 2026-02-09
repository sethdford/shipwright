#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright heartbeat + checkpoint test — Validate heartbeat lifecycle,  ║
# ║  stale detection, checkpoint save/restore, and edge cases.              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-heartbeat-test.XXXXXX")
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/home/.claude-teams/heartbeats"
    mkdir -p "$TEMP_DIR/project/.claude/pipeline-artifacts/checkpoints"

    # Copy scripts under test
    cp "$SCRIPT_DIR/cct-heartbeat.sh" "$TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/cct-checkpoint.sh" "$TEMP_DIR/scripts/"

    # Mock git for checkpoint tests
    mkdir -p "$TEMP_DIR/bin"
    cat > "$TEMP_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "HEAD" ]]; then
    echo "abc1234567890"
    exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--show-toplevel" ]]; then
    echo "${GIT_TOPLEVEL:-/tmp}"
    exit 0
fi
echo "mock-git"
EOF
    chmod +x "$TEMP_DIR/bin/git"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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
# HEARTBEAT TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Write heartbeat creates JSON file
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_write() {
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "test-job-1" \
            --pid $$ \
            --issue 42 \
            --stage "build" \
            --iteration 3 \
            --activity "Running tests" 2>/dev/null

    local hb_file="$TEMP_DIR/home/.claude-teams/heartbeats/test-job-1.json"
    if [[ ! -f "$hb_file" ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat file not created"
        return 1
    fi

    # Validate JSON fields
    local stage
    stage=$(jq -r '.stage' "$hb_file")
    if [[ "$stage" != "build" ]]; then
        echo -e "    ${RED}✗${RESET} Expected stage 'build', got: '$stage'"
        return 1
    fi

    local issue
    issue=$(jq -r '.issue' "$hb_file")
    if [[ "$issue" != "42" ]]; then
        echo -e "    ${RED}✗${RESET} Expected issue 42, got: '$issue'"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Check heartbeat reports alive
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_check_alive() {
    # Write a fresh heartbeat
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "test-job-alive" \
            --pid $$ --stage "build" 2>/dev/null

    local exit_code=0
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" check "test-job-alive" \
            --timeout 120 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected alive (exit 0), got exit $exit_code"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Check heartbeat reports stale with old timestamp
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_check_stale() {
    # Create a heartbeat with an old timestamp
    local hb_file="$TEMP_DIR/home/.claude-teams/heartbeats/test-job-stale.json"
    cat > "$hb_file" <<'EOF'
{"pid":99999,"issue":null,"stage":"build","iteration":1,"memory_mb":0,"cpu_pct":0,"last_activity":"test","updated_at":"2020-01-01T00:00:00Z"}
EOF

    local exit_code=0
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" check "test-job-stale" \
            --timeout 120 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected stale (exit 1), got exit 0"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Clear heartbeat removes file
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_clear() {
    # Ensure a heartbeat exists
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "test-job-clear" \
            --pid $$ --stage "test" 2>/dev/null

    local hb_file="$TEMP_DIR/home/.claude-teams/heartbeats/test-job-clear.json"
    if [[ ! -f "$hb_file" ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat file not created for clear test"
        return 1
    fi

    # Clear it
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" clear "test-job-clear" 2>/dev/null

    if [[ -f "$hb_file" ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat file still exists after clear"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. List heartbeats returns valid JSON array
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_list() {
    # Write two heartbeats
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "list-job-1" \
            --pid $$ --stage "build" --issue 10 2>/dev/null
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "list-job-2" \
            --pid $$ --stage "test" --issue 20 2>/dev/null

    local output
    output=$(HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" list 2>/dev/null)

    # Should be valid JSON array
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$count" -lt 2 ]]; then
        echo -e "    ${RED}✗${RESET} Expected at least 2 heartbeats in list, got: $count"
        return 1
    fi

    # Each entry should have job_id field
    local has_job_id
    has_job_id=$(echo "$output" | jq '.[0] | has("job_id")' 2>/dev/null || echo false)
    if [[ "$has_job_id" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} List entries missing job_id field"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Heartbeat updates overwrite existing file
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_update_overwrites() {
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "test-overwrite" \
            --pid $$ --stage "build" --iteration 1 2>/dev/null

    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "test-overwrite" \
            --pid $$ --stage "test" --iteration 5 2>/dev/null

    local hb_file="$TEMP_DIR/home/.claude-teams/heartbeats/test-overwrite.json"
    local stage iteration
    stage=$(jq -r '.stage' "$hb_file")
    iteration=$(jq -r '.iteration' "$hb_file")

    if [[ "$stage" != "test" || "$iteration" != "5" ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat not updated: stage=$stage iter=$iteration"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Check missing heartbeat returns error
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_check_missing() {
    local exit_code=0
    HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" check "nonexistent-job" 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected error for missing heartbeat"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Heartbeat dir auto-created when missing
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_dir_autocreate() {
    local fresh_home="$TEMP_DIR/fresh-home"
    mkdir -p "$fresh_home"
    # No heartbeats dir exists

    HOME="$fresh_home" \
        bash "$TEMP_DIR/scripts/cct-heartbeat.sh" write "auto-create-test" \
            --pid $$ --stage "build" 2>/dev/null

    if [[ ! -d "$fresh_home/.claude-teams/heartbeats" ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat dir not auto-created"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECKPOINT TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 9. Checkpoint save creates JSON file
# ──────────────────────────────────────────────────────────────────────────────
test_checkpoint_save() {
    (
        cd "$TEMP_DIR/project"
        PATH="$TEMP_DIR/bin:$PATH" \
        GIT_TOPLEVEL="$TEMP_DIR/project" \
            bash "$TEMP_DIR/scripts/cct-checkpoint.sh" save \
                --stage "build" \
                --iteration 5 \
                --git-sha "abc123" 2>/dev/null
    )

    local cp_file="$TEMP_DIR/project/.claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
    if [[ ! -f "$cp_file" ]]; then
        echo -e "    ${RED}✗${RESET} Checkpoint file not created"
        return 1
    fi

    local stage iteration
    stage=$(jq -r '.stage' "$cp_file")
    iteration=$(jq -r '.iteration' "$cp_file")

    if [[ "$stage" != "build" || "$iteration" != "5" ]]; then
        echo -e "    ${RED}✗${RESET} Checkpoint data wrong: stage=$stage iter=$iteration"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Checkpoint restore outputs JSON
# ──────────────────────────────────────────────────────────────────────────────
test_checkpoint_restore() {
    # Save first
    (
        cd "$TEMP_DIR/project"
        PATH="$TEMP_DIR/bin:$PATH" \
        GIT_TOPLEVEL="$TEMP_DIR/project" \
            bash "$TEMP_DIR/scripts/cct-checkpoint.sh" save \
                --stage "test" \
                --iteration 3 \
                --tests-passing \
                --git-sha "def456" 2>/dev/null
    )

    local output
    output=$(
        cd "$TEMP_DIR/project"
        bash "$TEMP_DIR/scripts/cct-checkpoint.sh" restore --stage "test" 2>/dev/null
    )

    # Should be valid JSON with expected fields
    local tests_passing
    tests_passing=$(echo "$output" | jq -r '.tests_passing' 2>/dev/null || echo "")
    if [[ "$tests_passing" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Expected tests_passing=true, got: '$tests_passing'"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Checkpoint restore missing stage fails
# ──────────────────────────────────────────────────────────────────────────────
test_checkpoint_restore_missing() {
    local exit_code=0
    (
        cd "$TEMP_DIR/project"
        bash "$TEMP_DIR/scripts/cct-checkpoint.sh" restore --stage "nonexistent" 2>/dev/null
    ) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected failure for missing checkpoint"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Checkpoint clear removes file
# ──────────────────────────────────────────────────────────────────────────────
test_checkpoint_clear() {
    # Save a checkpoint
    (
        cd "$TEMP_DIR/project"
        PATH="$TEMP_DIR/bin:$PATH" \
        GIT_TOPLEVEL="$TEMP_DIR/project" \
            bash "$TEMP_DIR/scripts/cct-checkpoint.sh" save \
                --stage "review" \
                --iteration 1 \
                --git-sha "ghi789" 2>/dev/null
    )

    local cp_file="$TEMP_DIR/project/.claude/pipeline-artifacts/checkpoints/review-checkpoint.json"
    if [[ ! -f "$cp_file" ]]; then
        echo -e "    ${RED}✗${RESET} Checkpoint not created for clear test"
        return 1
    fi

    (
        cd "$TEMP_DIR/project"
        bash "$TEMP_DIR/scripts/cct-checkpoint.sh" clear --stage "review" 2>/dev/null
    )

    if [[ -f "$cp_file" ]]; then
        echo -e "    ${RED}✗${RESET} Checkpoint still exists after clear"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Checkpoint clear --all removes all checkpoints
# ──────────────────────────────────────────────────────────────────────────────
test_checkpoint_clear_all() {
    # Save multiple checkpoints
    (
        cd "$TEMP_DIR/project"
        PATH="$TEMP_DIR/bin:$PATH" \
        GIT_TOPLEVEL="$TEMP_DIR/project" \
            bash "$TEMP_DIR/scripts/cct-checkpoint.sh" save --stage "build" --iteration 1 --git-sha "a" 2>/dev/null
        bash "$TEMP_DIR/scripts/cct-checkpoint.sh" save --stage "test" --iteration 2 --git-sha "b" 2>/dev/null
    )

    (
        cd "$TEMP_DIR/project"
        bash "$TEMP_DIR/scripts/cct-checkpoint.sh" clear --all 2>/dev/null
    )

    local remaining=0
    for f in "$TEMP_DIR/project/.claude/pipeline-artifacts/checkpoints"/*-checkpoint.json; do
        [[ -f "$f" ]] && remaining=$((remaining + 1))
    done

    if [[ $remaining -gt 0 ]]; then
        echo -e "    ${RED}✗${RESET} $remaining checkpoint(s) remain after clear --all"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Checkpoint save with files-modified
# ──────────────────────────────────────────────────────────────────────────────
test_checkpoint_files_modified() {
    (
        cd "$TEMP_DIR/project"
        PATH="$TEMP_DIR/bin:$PATH" \
        GIT_TOPLEVEL="$TEMP_DIR/project" \
            bash "$TEMP_DIR/scripts/cct-checkpoint.sh" save \
                --stage "build" \
                --iteration 7 \
                --files-modified "src/auth.ts,src/middleware.ts" \
                --git-sha "xyz" 2>/dev/null
    )

    local cp_file="$TEMP_DIR/project/.claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
    local file_count
    file_count=$(jq '.files_modified | length' "$cp_file" 2>/dev/null || echo 0)

    if [[ "$file_count" -ne 2 ]]; then
        echo -e "    ${RED}✗${RESET} Expected 2 files, got: $file_count"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Pipeline script has heartbeat functions
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_has_heartbeat() {
    local pipeline="$SCRIPT_DIR/cct-pipeline.sh"

    if ! grep -q "start_heartbeat()" "$pipeline" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} start_heartbeat() not found in pipeline"
        return 1
    fi
    if ! grep -q "stop_heartbeat()" "$pipeline" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} stop_heartbeat() not found in pipeline"
        return 1
    fi
    if ! grep -q "stop_heartbeat" "$pipeline" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} stop_heartbeat not called in cleanup"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Loop script has heartbeat and checkpoint calls
# ──────────────────────────────────────────────────────────────────────────────
test_loop_has_heartbeat_checkpoint() {
    local loop="$SCRIPT_DIR/cct-loop.sh"

    if ! grep -q "cct-heartbeat.sh" "$loop" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} cct-heartbeat.sh not referenced in loop"
        return 1
    fi
    if ! grep -q "cct-checkpoint.sh" "$loop" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} cct-checkpoint.sh not referenced in loop"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Pipeline has human intervention checks
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_human_intervention() {
    local pipeline="$SCRIPT_DIR/cct-pipeline.sh"

    if ! grep -q "skip-stage.txt" "$pipeline" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} skip-stage.txt check not found in pipeline"
        return 1
    fi
    if ! grep -q "human-message.txt" "$pipeline" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} human-message.txt check not found in pipeline"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright heartbeat + checkpoint — Test Suite   ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for heartbeat/checkpoint tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Heartbeat tests
echo -e "${PURPLE}${BOLD}Heartbeat Lifecycle${RESET}"
run_test "Write heartbeat creates JSON file" test_heartbeat_write
run_test "Check heartbeat reports alive" test_heartbeat_check_alive
run_test "Check heartbeat reports stale" test_heartbeat_check_stale
run_test "Clear heartbeat removes file" test_heartbeat_clear
run_test "List heartbeats returns JSON array" test_heartbeat_list
run_test "Heartbeat update overwrites existing" test_heartbeat_update_overwrites
run_test "Check missing heartbeat returns error" test_heartbeat_check_missing
run_test "Heartbeat dir auto-created when missing" test_heartbeat_dir_autocreate
echo ""

# Checkpoint tests
echo -e "${PURPLE}${BOLD}Checkpoint Lifecycle${RESET}"
run_test "Checkpoint save creates JSON file" test_checkpoint_save
run_test "Checkpoint restore outputs JSON" test_checkpoint_restore
run_test "Checkpoint restore missing stage fails" test_checkpoint_restore_missing
run_test "Checkpoint clear removes file" test_checkpoint_clear
run_test "Checkpoint clear --all removes all" test_checkpoint_clear_all
run_test "Checkpoint save with files-modified" test_checkpoint_files_modified
echo ""

# Integration tests
echo -e "${PURPLE}${BOLD}Integration${RESET}"
run_test "Pipeline script has heartbeat functions" test_pipeline_has_heartbeat
run_test "Loop script has heartbeat and checkpoint" test_loop_has_heartbeat_checkpoint
run_test "Pipeline has human intervention checks" test_pipeline_human_intervention
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
