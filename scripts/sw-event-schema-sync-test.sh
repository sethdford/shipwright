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

# ─── Test 2: Script requires python3 ────────────────────────────────────────
test_requires_python3() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"
    echo '{"version":"1.0","event_types":{}}' > "$tmpdir/config/event-schema.json"

    cd "$tmpdir"
    if PATH="/empty" bash scripts/sw-event-schema-sync.sh 2>&1 | grep -q "python3 required"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m requires python3"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m requires python3"
    fi
}

# ─── Test 3: --write flag is recognized ─────────────────────────────────────
test_write_flag_recognized() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"

    # Create a valid event schema with empty types
    cat > "$tmpdir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{}}
JSON

    # Create a script with one emit_event call
    cat > "$tmpdir/scripts/test.sh" <<'SH'
#!/bin/bash
emit_event "test.event" "key=val"
SH

    cd "$tmpdir"
    # --write should update the schema
    bash scripts/sw-event-schema-sync.sh --write > /dev/null 2>&1

    # After write, file should contain the new event type
    if grep -q '"test.event"' "$tmpdir/config/event-schema.json"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m --write flag updates schema"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m --write flag updates schema"
    fi
}

# ─── Test 4: Schema output is valid JSON ────────────────────────────────────
test_output_is_json() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"

    cat > "$tmpdir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{}}
JSON

    cat > "$tmpdir/scripts/test.sh" <<'SH'
emit_event "json.test" "x=y"
SH

    cd "$tmpdir"
    bash scripts/sw-event-schema-sync.sh --write > /dev/null 2>&1

    if command -v jq >/dev/null 2>&1; then
        if jq -e . "$tmpdir/config/event-schema.json" > /dev/null 2>&1; then
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
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"

    # Create schema with only one type
    cat > "$tmpdir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{"registered.type":{"required":[],"optional":[]}}}
JSON

    # But emit a different type
    cat > "$tmpdir/scripts/test.sh" <<'SH'
emit_event "missing.type" "x=y"
SH

    cd "$tmpdir"
    if bash scripts/sw-event-schema-sync.sh 2>&1 | grep -q "missing"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m detects missing types"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m detects missing types"
    fi
}

# ─── Test 6: Handles nested scripts ─────────────────────────────────────────
test_scans_nested_scripts() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts/lib" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"

    echo '{"version":"1.0","event_types":{}}' > "$tmpdir/config/event-schema.json"

    # Place emit_event in nested lib file
    cat > "$tmpdir/scripts/lib/helper.sh" <<'SH'
emit_event "lib.nested" "k=v"
SH

    cd "$tmpdir"
    bash scripts/sw-event-schema-sync.sh --write > /dev/null 2>&1

    if grep -q '"lib.nested"' "$tmpdir/config/event-schema.json"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m scans nested script files"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m scans nested script files"
    fi
}

# ─── Test 7: Exits with 0 when in sync ──────────────────────────────────────
test_exits_zero_in_sync() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"

    cat > "$tmpdir/config/event-schema.json" <<'JSON'
{"version":"1.0","event_types":{"sync.type":{"required":[],"optional":[]}}}
JSON

    cat > "$tmpdir/scripts/test.sh" <<'SH'
emit_event "sync.type" "x=y"
SH

    cd "$tmpdir"
    if bash scripts/sw-event-schema-sync.sh > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m exits 0 when in sync"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m exits 0 when in sync"
    fi
}

# ─── Test 8: Exits with 1 when out of sync ──────────────────────────────────
test_exits_one_out_of_sync() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"

    echo '{"version":"1.0","event_types":{}}' > "$tmpdir/config/event-schema.json"

    cat > "$tmpdir/scripts/test.sh" <<'SH'
emit_event "out.of.sync" "x=y"
SH

    cd "$tmpdir"
    if ! bash scripts/sw-event-schema-sync.sh > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m exits 1 when out of sync"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m exits 1 when out of sync"
    fi
}

# ─── Test 9: Prints "run with --write" on mismatch ────────────────────────────
test_suggests_write() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync.XXXXXX")
    TEMP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/scripts" "$tmpdir/config"
    cp "$SCRIPT_DIR/sw-event-schema-sync.sh" "$tmpdir/scripts/"

    echo '{"version":"1.0","event_types":{}}' > "$tmpdir/config/event-schema.json"

    cat > "$tmpdir/scripts/test.sh" <<'SH'
emit_event "test.suggest" "x=y"
SH

    cd "$tmpdir"
    if bash scripts/sw-event-schema-sync.sh 2>&1 | grep -q "run with --write"; then
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
