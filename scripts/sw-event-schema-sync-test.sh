#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright event-schema sync test — Unit tests for sw-event-schema-sync ║
# ║  Runs the real script against a fixture repo, never the real config/     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC_SRC="$SCRIPT_DIR/sw-event-schema-sync.sh"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

# The script derives its repo root from its own location, so each test copies
# it into a fixture tree at <fixture>/tools/ and points scripts/ + config/ at
# the fixture. The real config/event-schema.json is never touched.
FIXTURE=""

setup_fixture() {
    FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/sw-event-sync-test.XXXXXX")"
    mkdir -p "$FIXTURE/tools" "$FIXTURE/scripts/lib" "$FIXTURE/config"
    cp "$SYNC_SRC" "$FIXTURE/tools/sw-event-schema-sync.sh"
    # Fixture emit sites: two literal types, one with a key, one with none,
    # plus one variable-typed call that must be counted as dynamic, not missing.
    cat > "$FIXTURE/scripts/emitter.sh" <<'SH'
emit_event "fixture.alpha" "job=1" "status=ok"
emit_event "fixture.beta"
emit_event "$dynamic_type" "x=1"
SH
    # fixture.alpha is registered with a stale field set; fixture.gone has no call site.
    cat > "$FIXTURE/config/event-schema.json" <<'JSON'
{
  "$schema": "https://shipwright.dev/schemas/events-v1.json",
  "description": "fixture",
  "version": "1",
  "event_types": {
    "fixture.alpha": { "required": ["job"], "optional": [] },
    "fixture.gone": { "required": [], "optional": ["old"] }
  }
}
JSON
}

cleanup_fixture() {
    [[ -n "$FIXTURE" && -d "$FIXTURE" ]] && rm -rf "$FIXTURE"
    FIXTURE=""
}

sync_cmd() {
    bash "$FIXTURE/tools/sw-event-schema-sync.sh" "$@"
}

echo ""
print_test_header "Event Schema Sync — Test Suite"

# ─── Report mode ────────────────────────────────────────────────────────────
print_test_section "Report mode (no --write)"
setup_fixture

out=$(sync_cmd 2>&1); rc=$?
assert_exit_code "reports drift with exit 1 when a type is missing" "1" "$rc"
assert_contains "lists the missing fixture.beta type" "$out" "fixture.beta"
assert_contains "tells the user how to apply the fix" "$out" "run with --write"
assert_contains_regex "counts the variable-typed emit as dynamic" "$out" "variable type"

before=$(cat "$FIXTURE/config/event-schema.json")
sync_cmd >/dev/null 2>&1
assert_eq "report mode leaves the schema file byte-identical" "$before" "$(cat "$FIXTURE/config/event-schema.json")"

# ─── Write mode ─────────────────────────────────────────────────────────────
print_test_section "Write mode (--write)"

out=$(sync_cmd --write 2>&1); rc=$?
assert_exit_code "--write exits 0" "0" "$rc"
assert_contains "--write reports how many types it added" "$out" "wrote 1 new event types"
assert_eq "new type gets observed keys as optional, none required" "" "$(jq -r '.event_types["fixture.beta"].required | join(",")' "$FIXTURE/config/event-schema.json")"
assert_eq "new type with no observed keys has an empty optional list" "0" "$(jq -r '.event_types["fixture.beta"].optional | length' "$FIXTURE/config/event-schema.json")"

assert_eq "existing registered type keeps its hand-written required list" "job" "$(jq -r '.event_types["fixture.alpha"].required | join(",")' "$FIXTURE/config/event-schema.json")"
assert_eq "registered type with no call site is kept, not deleted" "old" "$(jq -r '.event_types["fixture.gone"].optional | join(",")' "$FIXTURE/config/event-schema.json")"

out2=$(sync_cmd 2>&1); rc2=$?
assert_exit_code "a second run after --write is clean (idempotent)" "0" "$rc2"
assert_contains "second run reports the schema is in sync" "$out2" "schema is in sync"
cleanup_fixture

# ─── Edge cases ─────────────────────────────────────────────────────────────
print_test_section "Edge cases"

setup_fixture
# A fixture where every emitted type is already registered must be clean.
cat > "$FIXTURE/scripts/emitter.sh" <<'SH'
emit_event "fixture.alpha" "job=1"
SH
out=$(sync_cmd 2>&1); rc=$?
assert_exit_code "no missing types exits 0 even with stale registrations" "0" "$rc"
assert_contains "stale registrations are reported, not treated as drift" "$out" "no-call-site"
cleanup_fixture

setup_fixture
# A type containing characters outside [a-zA-Z0-9_.-] is not a valid emit
# site for the sync, so it must not be reported as missing.
cat > "$FIXTURE/scripts/emitter.sh" <<'SH'
emit_event "bad type with spaces" "x=1"
SH
out=$(sync_cmd 2>&1); rc=$?
assert_exit_code "a type with spaces is not treated as an emit site" "0" "$rc"
cleanup_fixture

# ─── Error handling ─────────────────────────────────────────────────────────
print_test_section "Error handling"

setup_fixture
# Without python3 on PATH the script must refuse to run, with exit 2.
nopy_bin="$(mktemp -d "${TMPDIR:-/tmp}/sw-event-sync-nopy.XXXXXX")"
ln -s "$(command -v dirname)" "$nopy_bin/dirname"
out=$(env PATH="$nopy_bin" "$(command -v bash)" "$FIXTURE/tools/sw-event-schema-sync.sh" 2>&1); rc=$?
assert_exit_code "missing python3 exits 2" "2" "$rc"
assert_contains "missing python3 explains the requirement" "$out" "python3 required"
rm -rf "$nopy_bin"
cleanup_fixture

# ─── Real repo smoke (read-only) ────────────────────────────────────────────
print_test_section "Real repo (read-only)"
if [[ -f "$REPO_DIR/config/event-schema.json" ]]; then
    real_before=$(cksum < "$REPO_DIR/config/event-schema.json")
    real_out=$(bash "$SYNC_SRC" 2>&1); real_rc=$?
    assert_contains "real repo: script reports registered/emitted counts" "$real_out" "registered :"
    assert_contains_regex "real repo: exit is 0 or 1, never a crash" "$real_rc" "^[01]$"
    assert_eq "real repo: running without --write leaves the schema untouched" "$real_before" "$(cksum < "$REPO_DIR/config/event-schema.json")"
else
    assert_fail "real repo: config/event-schema.json exists" "not found under $REPO_DIR"
fi

print_test_results
