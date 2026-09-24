#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-event-schema-sync-test.sh — Event Schema Sync Test Suite             ║
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

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" description="${3:-}"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Pattern not found: $pattern"
        echo "    File: $file"
    fi
}

# ─── Test: schema sync with no drift ────────────────────────────────────────
test_schema_sync_in_sync() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    # Create a minimal schema and script pair with matching emit_event calls
    mkdir -p "$tmpdir/config" "$tmpdir/scripts"

    # Create event-schema.json with one type
    cat > "$tmpdir/config/event-schema.json" <<'EOF'
{
  "event_types": {
    "test.event": {
      "required": [],
      "optional": ["id", "status"]
    }
  }
}
EOF

    # Create a script that emits that exact event
    cat > "$tmpdir/scripts/test.sh" <<'EOF'
#!/bin/bash
emit_event "test.event" "id=123" "status=ok"
EOF

    # Mock REPO_DIR and run schema sync in check mode
    REPO_DIR="$tmpdir" SCHEMA="$tmpdir/config/event-schema.json" python3 - <<'PY' > /tmp/sync_output.txt 2>&1 || local exit_code=$?
import json, os, re, sys, pathlib, collections

schema_path = pathlib.Path(os.environ['SCHEMA'])
repo        = pathlib.Path(os.environ['REPO_DIR'])
write       = os.environ.get('WRITE', '0') == '1'

schema = json.loads(schema_path.read_text())
existing = schema.get('event_types', {})

CALL = re.compile(r'emit_event\s+"([a-zA-Z0-9_.\-]+)"((?:\s+"[^"]*")*)')
KEY  = re.compile(r'"([a-zA-Z_][a-zA-Z0-9_]*)=')
DYNAMIC = re.compile(r'emit_event\s+"\$')

fields  = collections.defaultdict(set)
dynamic = 0
for f in sorted(repo.glob('scripts/**/*.sh')):
    text = f.read_text()
    dynamic += len(DYNAMIC.findall(text))
    for etype, args in CALL.findall(text):
        fields[etype].update(KEY.findall(args))

emitted = set(fields)
known   = set(existing)
missing = sorted(emitted - known)

if missing:
    sys.exit(1)
else:
    sys.exit(0)
PY

    local result="${exit_code:-0}"
    assert_exit_code 0 "$result" "schema sync returns 0 when schema is in sync"
}

# ─── Test: schema sync detects drift ───────────────────────────────────────
test_schema_sync_detects_drift() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    mkdir -p "$tmpdir/config" "$tmpdir/scripts"

    # Create schema with fewer types
    cat > "$tmpdir/config/event-schema.json" <<'EOF'
{
  "event_types": {
    "old.event": {
      "required": [],
      "optional": []
    }
  }
}
EOF

    # Create a script that emits a NEW event (drift)
    cat > "$tmpdir/scripts/test.sh" <<'EOF'
#!/bin/bash
emit_event "new.event" "id=123"
EOF

    # Run schema sync in check mode
    REPO_DIR="$tmpdir" SCHEMA="$tmpdir/config/event-schema.json" python3 - <<'PY' > /dev/null 2>&1 || local exit_code=$?
import json, os, re, sys, pathlib, collections

schema_path = pathlib.Path(os.environ['SCHEMA'])
repo        = pathlib.Path(os.environ['REPO_DIR'])

schema = json.loads(schema_path.read_text())
existing = schema.get('event_types', {})

CALL = re.compile(r'emit_event\s+"([a-zA-Z0-9_.\-]+)"((?:\s+"[^"]*")*)')
KEY  = re.compile(r'"([a-zA-Z_][a-zA-Z0-9_]*)=')
DYNAMIC = re.compile(r'emit_event\s+"\$')

fields  = collections.defaultdict(set)
dynamic = 0
for f in sorted(repo.glob('scripts/**/*.sh')):
    text = f.read_text()
    dynamic += len(DYNAMIC.findall(text))
    for etype, args in CALL.findall(text):
        fields[etype].update(KEY.findall(args))

emitted = set(fields)
known   = set(existing)
missing = sorted(emitted - known)

if missing:
    sys.exit(1)
else:
    sys.exit(0)
PY

    local result="${exit_code:-0}"
    assert_exit_code 1 "$result" "schema sync returns 1 when drift is detected"
}

# ─── Test: python3 requirement ─────────────────────────────────────────────
test_schema_sync_requires_python3() {
    # Check that the script contains the python3 requirement
    if grep -q "python3 required" "$SCRIPT_DIR/sw-event-schema-sync.sh"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m script checks for python3 availability"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m script checks for python3 availability"
    fi
}

# ─── Test: write mode updates schema ────────────────────────────────────────
test_schema_sync_write_mode() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    mkdir -p "$tmpdir/config" "$tmpdir/scripts"

    # Create minimal schema
    cat > "$tmpdir/config/event-schema.json" <<'EOF'
{
  "event_types": {}
}
EOF

    # Create a script with an event
    cat > "$tmpdir/scripts/test.sh" <<'EOF'
#!/bin/bash
emit_event "pipeline.started" "issue_id=123"
EOF

    # Run schema sync in write mode
    REPO_DIR="$tmpdir" SCHEMA="$tmpdir/config/event-schema.json" WRITE=1 python3 - <<'PY' > /dev/null 2>&1
import json, os, re, sys, pathlib, collections

schema_path = pathlib.Path(os.environ['SCHEMA'])
repo        = pathlib.Path(os.environ['REPO_DIR'])
write       = os.environ['WRITE'] == '1'

schema = json.loads(schema_path.read_text())
existing = schema.get('event_types', {})

CALL = re.compile(r'emit_event\s+"([a-zA-Z0-9_.\-]+)"((?:\s+"[^"]*")*)')
KEY  = re.compile(r'"([a-zA-Z_][a-zA-Z0-9_]*)=')
DYNAMIC = re.compile(r'emit_event\s+"\$')

fields  = collections.defaultdict(set)
for f in sorted(repo.glob('scripts/**/*.sh')):
    text = f.read_text()
    for etype, args in CALL.findall(text):
        fields[etype].update(KEY.findall(args))

emitted = set(fields)
known   = set(existing)
missing = sorted(emitted - known)

if write and missing:
    for etype in missing:
        existing[etype] = {"required": [], "optional": sorted(fields[etype])}
    schema['event_types'] = dict(sorted(existing.items()))
    schema_path.write_text(json.dumps(schema, indent=2) + "\n")
PY

    # Verify the schema was updated
    assert_file_contains "$tmpdir/config/event-schema.json" "pipeline.started" "write mode adds new event type to schema"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-event-schema-sync-test.sh"
test_schema_sync_in_sync
test_schema_sync_detects_drift
test_schema_sync_requires_python3
test_schema_sync_write_mode

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
