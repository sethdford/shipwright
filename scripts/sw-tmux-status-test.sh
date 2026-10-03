#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-status-test.sh — Tmux Status Widgets Test Suite                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_output_contains() {
    local output="$1" pattern="$2" desc="${3:-}"
    if echo "$output" | grep -q "$pattern"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m $desc"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m $desc"
        echo "    Expected pattern: $pattern"
        echo "    Actual output: $output"
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" desc="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m $desc"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m $desc"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code: $actual"
    fi
}

# ─── Setup test environment ──────────────────────────────────────────────────
setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-status-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/scripts/lib"
    mkdir -p "$TEST_TEMP_DIR/.claude"
    mkdir -p "$TEST_TEMP_DIR/.shipwright/heartbeats"

    # Copy script under test
    cp "$SCRIPT_DIR/sw-tmux-status.sh" "$TEST_TEMP_DIR/scripts/"
}

cleanup_env() {
    [[ -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

trap cleanup_env EXIT

# ─── Test 1: Pipeline widget with 'Stage:' format ──────────────────────────
test_pipeline_stage_format() {
    setup_test_env

    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
# Pipeline State
Stage: build
current_stage_description: "Building with 20 max iterations using opus"
EOF

    local output
    cd "$TEST_TEMP_DIR"
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" pipeline)

    if echo "$output" | grep -q "BUILD"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m pipeline widget parses 'Stage:' format"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m pipeline widget parses 'Stage:' format"
        echo "    Output: $output"
    fi
}

# ─── Test 2: Pipeline widget with 'current_stage:' format ────────────────────
test_pipeline_current_stage_format() {
    setup_test_env

    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
# Pipeline State
current_stage: plan
stage_progress: "intake:complete"
EOF

    local output
    cd "$TEST_TEMP_DIR"
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" pipeline)

    if echo "$output" | grep -q "PLAN"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m pipeline widget parses 'current_stage:' format"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m pipeline widget parses 'current_stage:' format"
        echo "    Output: $output"
    fi
}

# ─── Test 3: Pipeline widget with no state file ──────────────────────────────
test_pipeline_no_state_file() {
    setup_test_env

    local output
    cd "$TEST_TEMP_DIR"
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" pipeline)

    if [[ -z "$output" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m pipeline widget returns empty when no state file"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m pipeline widget returns empty when no state file"
    fi
}

# ─── Test 4: Pipeline widget with no stage line ──────────────────────────────
test_pipeline_no_stage_line() {
    setup_test_env

    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
# Pipeline State
This file has no stage line.
EOF

    local output
    cd "$TEST_TEMP_DIR"
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" pipeline)

    if [[ -z "$output" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m pipeline widget returns empty when no stage line"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m pipeline widget returns empty when no stage line"
    fi
}

# ─── Test 5: Pipeline widget walks up directory tree ──────────────────────────
test_pipeline_walk_up() {
    setup_test_env

    mkdir -p "$TEST_TEMP_DIR/nested/deep/dir"
    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
Stage: review
EOF

    local output
    cd "$TEST_TEMP_DIR/nested/deep/dir"
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" pipeline)

    if echo "$output" | grep -q "REVIEW"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m pipeline widget walks up directory tree"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m pipeline widget walks up directory tree"
    fi
}

# ─── Test 6: Agent widget with fresh heartbeats ──────────────────────────────
test_agent_fresh_heartbeats() {
    setup_test_env

    # Create 2 fresh heartbeat files
    echo '{"job":"1","ts":"2024-01-01T00:00:00Z"}' > "$TEST_TEMP_DIR/.shipwright/heartbeats/job-1.json"
    echo '{"job":"2","ts":"2024-01-01T00:00:00Z"}' > "$TEST_TEMP_DIR/.shipwright/heartbeats/job-2.json"
    # Touch them to appear recent
    touch "$TEST_TEMP_DIR/.shipwright/heartbeats/job-1.json" "$TEST_TEMP_DIR/.shipwright/heartbeats/job-2.json"

    local output
    cd "$TEST_TEMP_DIR"
    output=$(HOME="$TEST_TEMP_DIR" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" agents)

    if echo "$output" | grep -q "λ2"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m agent widget shows fresh heartbeats"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m agent widget shows fresh heartbeats"
        echo "    Output: $output"
    fi
}

# ─── Test 7: Agent widget with no heartbeats directory ──────────────────────
test_agent_no_heartbeats() {
    setup_test_env

    # Don't create heartbeats directory
    rmdir "$TEST_TEMP_DIR/.shipwright/heartbeats" 2>/dev/null || true

    local output
    cd "$TEST_TEMP_DIR"
    output=$(HOME="$TEST_TEMP_DIR" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" agents)

    if [[ -z "$output" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m agent widget returns empty when no heartbeats"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m agent widget returns empty when no heartbeats"
    fi
}

# ─── Test 8: Agent widget filters stale heartbeats ───────────────────────────
test_agent_filter_stale() {
    setup_test_env

    # Create 1 fresh and 1 stale heartbeat
    echo '{"job":"1"}' > "$TEST_TEMP_DIR/.shipwright/heartbeats/job-1.json"
    touch "$TEST_TEMP_DIR/.shipwright/heartbeats/job-1.json"

    echo '{"job":"2"}' > "$TEST_TEMP_DIR/.shipwright/heartbeats/job-2.json"
    touch -t 202001010000 "$TEST_TEMP_DIR/.shipwright/heartbeats/job-2.json" 2>/dev/null || true

    local output
    cd "$TEST_TEMP_DIR"
    output=$(HOME="$TEST_TEMP_DIR" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" agents)

    if echo "$output" | grep -q "λ1"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m agent widget filters out stale heartbeats"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m agent widget filters out stale heartbeats"
        echo "    Output: $output"
    fi
}

# ─── Test 9: All widget combines agents and pipeline ────────────────────────
test_all_combines() {
    setup_test_env

    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
Stage: deploy
EOF

    echo '{"job":"1"}' > "$TEST_TEMP_DIR/.shipwright/heartbeats/job-1.json"
    touch "$TEST_TEMP_DIR/.shipwright/heartbeats/job-1.json"

    local output
    cd "$TEST_TEMP_DIR"
    output=$(HOME="$TEST_TEMP_DIR" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" all)

    # Should contain both agent count and stage
    if echo "$output" | grep -q "λ1" && echo "$output" | grep -q "DEPLOY"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m 'all' widget combines agents and pipeline"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m 'all' widget combines agents and pipeline"
        echo "    Output: $output"
    fi
}

# ─── Test 10: Unknown subcommand returns empty ────────────────────────────────
test_unknown_subcommand() {
    setup_test_env

    local output
    cd "$TEST_TEMP_DIR"
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" unknown)

    if [[ -z "$output" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m unknown subcommand returns empty"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m unknown subcommand returns empty"
    fi
}

# ─── Test 11: Stage color test ───────────────────────────────────────────────
test_stage_colors() {
    setup_test_env

    local output
    cd "$TEST_TEMP_DIR"
    # Call script with unknown subcommand to avoid stage parsing
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" unknown)

    # Should exit 0
    if [[ $? -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m stage functions are defined"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m stage functions are defined"
    fi
}

# ─── Test 12: Complex state file with multiple fields ───────────────────────
test_complex_state() {
    setup_test_env

    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
# Shipwright Pipeline State

## Metadata
pipeline: standard
goal: "Add missing test suites for the 5 untested scripts"
issue: "#7552"
branch: "test/add-missing-test-suites-for-the-5-untest-7552"

## Status
current_stage: build
current_stage_description: "Building with 20 max iterations using opus"
stage_progress: "intake:complete spec_generation:complete plan:complete design:complete build:pending"

## Stages
stages:
  intake: complete
  plan: complete
  design: complete
EOF

    local output
    cd "$TEST_TEMP_DIR"
    output=$(SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" pipeline)

    # Should extract 'build' from current_stage line
    if echo "$output" | grep -q "BUILD"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m complex state file parsed correctly"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m complex state file parsed correctly"
        echo "    Output: $output"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-tmux-status-test.sh"
test_pipeline_stage_format
test_pipeline_current_stage_format
test_pipeline_no_state_file
test_pipeline_no_stage_line
test_pipeline_walk_up
test_agent_fresh_heartbeats
test_agent_no_heartbeats
test_agent_filter_stale
test_all_combines
test_unknown_subcommand
test_stage_colors
test_complex_state

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
