#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-event-schema-sync-test.sh — Event Schema Sync Test Suite            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'cleanup_all' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0
TEMP_DIRS=()

cleanup_all() {
    for d in "${TEMP_DIRS[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d" 2>/dev/null || true
    done
}

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_command() {
    local desc="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m $desc"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m $desc"
    fi
}

# ─── Test 1: Script exists and is executable ────────────────────────────────
test_script_exists() {
    assert_command "script exists" test -x "$SCRIPT_DIR/sw-event-schema-sync.sh"
}

# ─── Test 2: Script checks for python3 ──────────────────────────────────────
test_requires_python3() {
    # Verify the script contains python3 requirement check
    if grep -q "command -v python3" "$SCRIPT_DIR/sw-event-schema-sync.sh"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m requires python3"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m requires python3"
    fi
}

# ─── Test 3: --write flag is recognized ─────────────────────────────────────
test_write_flag_recognized() {
    local tmpdir repo_dir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")
    repo_dir="$tmpdir/repo"

    mkdir -p "$repo_dir/scripts" "$repo_dir/config"

    # Create a valid event schema with empty types
    cat > "$repo_dir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{}}
JSON

    # Create a script with one emit_event call
    cat > "$repo_dir/scripts/test.sh" <<'SH'
#!/bin/bash
emit_event "test.event" "key=val"
SH

    # Run with REPO_DIR override via wrapper
    if (cd "$repo_dir" && REPO_DIR="$repo_dir" bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write > /dev/null 2>&1); then
        # After write, file should contain the new event type
        if grep -q '"test.event"' "$repo_dir/config/event-schema.json"; then
            PASS=$((PASS + 1))
            echo -e "  \033[38;2;74;222;128m✓\033[0m --write flag updates schema"
        else
            FAIL=$((FAIL + 1))
            echo -e "  \033[38;2;248;113;113m✗\033[0m --write flag updates schema"
        fi
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m --write flag updates schema"
    fi
}

# ─── Test 4: Schema output is valid JSON ────────────────────────────────────
test_output_is_json() {
    local tmpdir repo_dir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")
    repo_dir="$tmpdir/repo"

    mkdir -p "$repo_dir/scripts" "$repo_dir/config"

    cat > "$repo_dir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{}}
JSON

    cat > "$repo_dir/scripts/test.sh" <<'SH'
emit_event "json.test" "x=y"
SH

    REPO_DIR="$repo_dir" bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write > /dev/null 2>&1

    if command -v jq >/dev/null 2>&1; then
        if jq -e . "$repo_dir/config/event-schema.json" > /dev/null 2>&1; then
            PASS=$((PASS + 1))
            echo -e "  \033[38;2;74;222;128m✓\033[0m output is valid JSON"
        else
            FAIL=$((FAIL + 1))
            echo -e "  \033[38;2;248;113;113m✗\033[0m output is valid JSON"
        fi
    else
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m skipped JSON validation (jq not available)"
    fi
}

# ─── Test 5: Detects missing types ──────────────────────────────────────────
test_detects_missing_types() {
    local tmpdir repo_dir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")
    repo_dir="$tmpdir/repo"

    mkdir -p "$repo_dir/scripts" "$repo_dir/config"

    # Create schema with only one type
    cat > "$repo_dir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{"registered.type":{"required":[],"optional":[]}}}
JSON

    # But emit a different type
    cat > "$repo_dir/scripts/test.sh" <<'SH'
emit_event "missing.type" "x=y"
SH

    if (REPO_DIR="$repo_dir" bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 || true) | grep -q "missing"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m detects missing types"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m detects missing types"
    fi
}

# ─── Test 6: Handles nested scripts ─────────────────────────────────────────
test_scans_nested_scripts() {
    local tmpdir repo_dir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")
    repo_dir="$tmpdir/repo"

    mkdir -p "$repo_dir/scripts/lib" "$repo_dir/config"

    echo '{"version":"1.0","event_types":{}}' > "$repo_dir/config/event-schema.json"

    # Place emit_event in nested lib file
    cat > "$repo_dir/scripts/lib/helper.sh" <<'SH'
emit_event "lib.nested" "k=v"
SH

    REPO_DIR="$repo_dir" bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write > /dev/null 2>&1

    if grep -q '"lib.nested"' "$repo_dir/config/event-schema.json"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m scans nested script files"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m scans nested script files"
    fi
}

# ─── Test 7: Exits with 0 when in sync ──────────────────────────────────────
test_exits_zero_in_sync() {
    local tmpdir repo_dir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")
    repo_dir="$tmpdir/repo"

    mkdir -p "$repo_dir/scripts" "$repo_dir/config"

    cat > "$repo_dir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{"sync.type":{"required":[],"optional":[]}}}
JSON

    cat > "$repo_dir/scripts/test.sh" <<'SH'
emit_event "sync.type" "x=y"
SH

    if REPO_DIR="$repo_dir" bash "$SCRIPT_DIR/sw-event-schema-sync.sh" > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m exits 0 when in sync"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m exits 0 when in sync"
    fi
}

# ─── Test 8: Exits with 1 when out of sync ──────────────────────────────────
test_exits_one_out_of_sync() {
    local tmpdir repo_dir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")
    repo_dir="$tmpdir/repo"

    mkdir -p "$repo_dir/scripts" "$repo_dir/config"

    echo '{"version":"1.0","event_types":{}}' > "$repo_dir/config/event-schema.json"

    cat > "$repo_dir/scripts/test.sh" <<'SH'
emit_event "out.of.sync" "x=y"
SH

    if ! REPO_DIR="$repo_dir" bash "$SCRIPT_DIR/sw-event-schema-sync.sh" > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m exits 1 when out of sync"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m exits 1 when out of sync"
    fi
}

# ─── Test 9: Prints "run with --write" on mismatch ────────────────────────────
test_suggests_write() {
    local tmpdir repo_dir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")
    repo_dir="$tmpdir/repo"

    mkdir -p "$repo_dir/scripts" "$repo_dir/config"

    echo '{"version":"1.0","event_types":{}}' > "$repo_dir/config/event-schema.json"

    cat > "$repo_dir/scripts/test.sh" <<'SH'
emit_event "test.suggest" "x=y"
SH

    if (REPO_DIR="$repo_dir" bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 || true) | grep -q "run with --write"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m suggests --write on mismatch"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m suggests --write on mismatch"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-event-schema-sync-test.sh"
test_script_exists
test_requires_python3
test_write_flag_recognized
test_output_is_json
test_detects_missing_types
test_scans_nested_scripts
test_exits_zero_in_sync
test_exits_one_out_of_sync
test_suggests_write

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
