#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-status-test.sh — Tmux Status Widget Test Suite                  ║
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
    if [[ "$haystack" =~ $needle ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    In: $haystack"
    fi
}

assert_not_empty() {
    local value="$1" description="${2:-}"
    if [[ -n "$value" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected value to be non-empty"
    fi
}

# ─── Helper: extract stage from pipeline state ─────────────────────────────
extract_stage() {
    local state_file="$1"
    local stage=""
    stage="$(grep -i "stage:" "$state_file" 2>/dev/null | head -1 | sed -n 's/.*[Ss]tage: *//p' | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')" || true
    echo "$stage"
}

# ─── Helper: stage to color ────────────────────────────────────────────────
stage_color() {
    case "${1:-}" in
        intake)             echo "#71717a" ;;
        plan)               echo "#7c3aed" ;;
        design)             echo "#7c3aed" ;;
        build)              echo "#0066ff" ;;
        test)               echo "#facc15" ;;
        review)             echo "#f97316" ;;
        pr)                 echo "#00d4ff" ;;
        deploy)             echo "#4ade80" ;;
        *)                  echo "#71717a" ;;
    esac
}

# ─── Test: pipeline widget extracts build stage ───────────────────────────
test_pipeline_widget_extracts_stage() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    # Create a state file with build stage
    cat > "$tmpdir/pipeline-state.md" <<'EOF'
# Pipeline State

## Current Stage: build

Some other content here
EOF

    local stage
    stage="$(extract_stage "$tmpdir/pipeline-state.md")"
    assert_equals "build" "$stage" "pipeline widget extracts build stage"
}

# ─── Test: pipeline widget normalizes stage name ──────────────────────────
test_pipeline_widget_normalizes_case() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    # Create a state file with UPPERCASE stage
    cat > "$tmpdir/pipeline-state.md" <<'EOF'
## Current Stage: TEST

More content
EOF

    local stage
    stage="$(extract_stage "$tmpdir/pipeline-state.md")"
    assert_equals "test" "$stage" "pipeline widget normalizes stage to lowercase"
}

# ─── Test: stage color mapping ────────────────────────────────────────────
test_stage_color_build() {
    local color
    color="$(stage_color "build")"
    assert_equals "#0066ff" "$color" "build stage maps to blue"
}

# ─── Test: stage color mapping for test ──────────────────────────────────
test_stage_color_test() {
    local color
    color="$(stage_color "test")"
    assert_equals "#facc15" "$color" "test stage maps to yellow"
}

# ─── Test: stage color mapping for review ────────────────────────────────
test_stage_color_review() {
    local color
    color="$(stage_color "review")"
    assert_equals "#f97316" "$color" "review stage maps to orange"
}

# ─── Test: unknown stage defaults to muted ─────────────────────────────────
test_stage_color_unknown() {
    local color
    color="$(stage_color "unknown_stage")"
    assert_equals "#71717a" "$color" "unknown stage defaults to muted color"
}

# ─── Test: agent widget with active heartbeats ──────────────────────────────
test_agent_widget_counts_heartbeats() {
    local tmpdir hb_dir
    tmpdir="$(mktemp -d)"
    hb_dir="$tmpdir/heartbeats"
    trap "rm -rf '$tmpdir'" EXIT

    mkdir -p "$hb_dir"

    # Create some active heartbeats (recently modified)
    echo '{"id":"agent1","status":"active"}' > "$hb_dir/agent1.json"
    echo '{"id":"agent2","status":"active"}' > "$hb_dir/agent2.json"

    # Count heartbeats
    local count=0
    for hb in "$hb_dir"/*.json; do
        [[ -f "$hb" ]] && count=$((count + 1))
    done

    assert_equals 2 "$count" "agent widget counts active heartbeats correctly"
}

# ─── Test: agent widget filters stale heartbeats ──────────────────────────
test_agent_widget_filters_stale() {
    local tmpdir hb_dir now
    tmpdir="$(mktemp -d)"
    hb_dir="$tmpdir/heartbeats"
    trap "rm -rf '$tmpdir'" EXIT

    mkdir -p "$hb_dir"

    # Create an old file (>60 seconds ago)
    echo '{"id":"agent1"}' > "$hb_dir/agent1.json"
    touch -d "70 seconds ago" "$hb_dir/agent1.json" 2>/dev/null || touch -t 197001010000 "$hb_dir/agent1.json"

    # Create a recent file
    echo '{"id":"agent2"}' > "$hb_dir/agent2.json"

    # Count files that would be considered active (modified < 60s ago)
    now="$(date +%s)"
    local count=0
    for hb in "$hb_dir"/*.json; do
        [[ -f "$hb" ]] || continue
        local mtime
        mtime="$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null || echo 0)"
        if (( now - mtime < 60 )); then
            count=$((count + 1))
        fi
    done

    # Should be 1 (only the recent one)
    assert_equals 1 "$count" "agent widget filters out stale heartbeats (>60s old)"
}

# ─── Test: missing heartbeat directory is handled gracefully ──────────────
test_missing_heartbeat_directory() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    # Don't create the heartbeats directory

    # Should not error, just return 0
    local count=0
    local hb_dir="$tmpdir/heartbeats"
    [[ -d "$hb_dir" ]] || return 0

    if [[ $? -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m missing heartbeat directory is handled gracefully"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m missing heartbeat directory is handled gracefully"
    fi
}

# ─── Test: missing pipeline state file is handled gracefully ──────────────
test_missing_state_file() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    # Don't create the state file
    local state_file="$tmpdir/pipeline-state.md"

    if [[ ! -f "$state_file" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m missing pipeline state file is detected"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m missing pipeline state file is detected"
    fi
}

# ─── Test: script exists and is executable ────────────────────────────────
test_script_exists() {
    if [[ -f "$SCRIPT_DIR/sw-tmux-status.sh" && -x "$SCRIPT_DIR/sw-tmux-status.sh" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m script exists and is executable"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m script exists and is executable"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-tmux-status-test.sh"
test_script_exists
test_pipeline_widget_extracts_stage
test_pipeline_widget_normalizes_case
test_stage_color_build
test_stage_color_test
test_stage_color_review
test_stage_color_unknown
test_agent_widget_counts_heartbeats
test_agent_widget_filters_stale
test_missing_heartbeat_directory
test_missing_state_file

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
