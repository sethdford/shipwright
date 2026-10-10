#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/fleet-patterns test — Fleet-wide failure pattern store    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: fleet-patterns Tests"

setup_test_env "sw-lib-fleet-patterns-test"
trap cleanup_test_env EXIT

EVENTS_LOG="$TEST_TEMP_DIR/events.log"
emit_event() { echo "$*" >> "$EVENTS_LOG"; }

_FLEET_PATTERNS_LOADED=""
source "$SCRIPT_DIR/lib/fleet-patterns.sh"

STORE="$TEST_TEMP_DIR/home/.shipwright/fleet-patterns.json"

# The same failure as seen by two repos: different absolute paths, line:col,
# timestamps, durations and commit hashes.
ERR_A="FAIL /home/alice/repoA/src/session.test.js:42:7 TypeError: Cannot read properties of null (reading 'id') at 2026-10-10T18:00:01Z after 1234ms commit abc1234def"
ERR_B="  FAIL /Users/bob/work/repoB/lib/session.test.js:9:3 TypeError: Cannot read properties of null (reading 'id') at 2026-01-02T03:04:05Z after 88ms commit 9f8e7d6c5b"

reset_store() { rm -rf "$STORE" "$STORE".lock* "$STORE".corrupt.* 2>/dev/null || true; : > "$EVENTS_LOG"; }

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Fleet mode off"
# ═══════════════════════════════════════════════════════════════════════════════
unset SHIPWRIGHT_FLEET_PATTERNS_FILE
if fleet_patterns_enabled; then assert_fail "disabled without env var"; else assert_pass "disabled without env var"; fi
sig=$(fleet_pattern_signature "$ERR_A")
fleet_pattern_record "$sig" test_failure "$ERR_A" o/repoA test
assert_file_not_exists "record writes nothing when fleet mode is off" "$STORE"
assert_eq "triage returns nothing when fleet mode is off" "" "$(fleet_triage_known_fix 1 "$ERR_A" "" "$TEST_TEMP_DIR")"

export SHIPWRIGHT_FLEET_PATTERNS_FILE="$STORE"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Signatures"
# ═══════════════════════════════════════════════════════════════════════════════
sig_a=$(fleet_pattern_signature "$ERR_A")
sig_b=$(fleet_pattern_signature "$ERR_B")
assert_contains_regex "signature is <error_type>:<16 hex>" "$sig_a" '^[a-z_]+:[0-9a-f]{16}$'
assert_eq "same failure, different paths/lines/hashes/times → same signature" "$sig_a" "$sig_b"
assert_eq "test failure classified as test_failure" "test_failure" "${sig_a%%:*}"
sig_other=$(fleet_pattern_signature "FAIL /x/session.test.js:1:1 TypeError: Cannot read properties of null (reading 'name')")
if [[ "$sig_other" != "$sig_a" ]]; then assert_pass "different identifier → different signature"; else assert_fail "different identifier → different signature"; fi
sig_mod_x=$(fleet_pattern_signature "Error: Cannot find module 'left-pad'")
sig_mod_y=$(fleet_pattern_signature "Error: Cannot find module 'right-pad'")
if [[ "$sig_mod_x" != "$sig_mod_y" ]]; then assert_pass "module names are kept"; else assert_fail "module names are kept"; fi
assert_eq "missing module classified as dependency" "dependency" "${sig_mod_x%%:*}"
assert_eq "explicit error type overrides classification" "timeout" "$(fleet_pattern_signature "$ERR_A" timeout | cut -d: -f1)"
assert_eq "non-error text → empty signature" "" "$(fleet_pattern_signature "all 42 tests passed")"
assert_eq "empty text → empty signature" "" "$(fleet_pattern_signature "")"
norm=$(fleet_normalize_error "$ERR_A")
if [[ "$norm" == *"/home/alice"* ]]; then assert_fail "normalization strips paths" "$norm"; else assert_pass "normalization strips paths"; fi
assert_contains "normalization keeps the basename" "$norm" "session.test.js:n"
assert_eq "auth class" "auth" "$(fleet_error_type "Error: 401 Unauthorized")"
assert_eq "timeout class" "timeout" "$(fleet_error_type "Error: request timed out")"
assert_eq "lint class" "lint_error" "$(fleet_error_type "eslint: error no-unused-vars")"
assert_eq "build class" "build_error" "$(fleet_error_type "syntax error near unexpected token")"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Store: record, fix, outcome"
# ═══════════════════════════════════════════════════════════════════════════════
reset_store
fleet_pattern_record "$sig_a" test_failure "$ERR_A" o/repoA test
assert_file_exists "store created on first record" "$STORE"
assert_eq "schema version" "1" "$(jq -r '.version' "$STORE")"
assert_eq "seen_count starts at 1" "1" "$(jq -r --arg s "$sig_a" '.patterns[$s].seen_count' "$STORE")"
assert_eq "stored sample has no absolute paths" "0" "$(jq -r --arg s "$sig_a" '.patterns[$s].sample | test("/home/") | if . then 1 else 0 end' "$STORE")"
assert_contains "record emits fleet.pattern_recorded" "$(cat "$EVENTS_LOG")" "fleet.pattern_recorded"
fleet_pattern_record "$sig_a" test_failure "$ERR_A" o/repoA test
fleet_pattern_record "$sig_b" test_failure "$ERR_B" o/repoB test
assert_eq "upsert increments seen_count" "3" "$(jq -r --arg s "$sig_a" '.patterns[$s].seen_count' "$STORE")"
assert_eq "repos deduplicated" '["o/repoA","o/repoB"]' "$(jq -c --arg s "$sig_a" '.patterns[$s].repos' "$STORE")"
assert_eq "no fix yet → lookup empty" "" "$(fleet_pattern_lookup "$sig_a")"

fleet_pattern_update_fix "missing:0000000000000000" "rc" "fix" "cat" o/repoA
assert_eq "update_fix on unknown signature is a no-op" "null" "$(jq -r '.patterns["missing:0000000000000000"]' "$STORE")"
fleet_pattern_update_fix "$sig_a" "rc" "" "cat" o/repoA
assert_eq "empty fix is a no-op" "" "$(jq -r --arg s "$sig_a" '.patterns[$s].fix' "$STORE")"

fleet_pattern_update_fix "$sig_a" "session is null before login" "guard null session" "test" o/repoA
assert_eq "lookup returns the fix" "guard null session" "$(fleet_pattern_lookup "$sig_a" | jq -r '.fix')"
assert_eq "fix source repo recorded" "o/repoA" "$(fleet_pattern_lookup "$sig_a" | jq -r '.fix_source_repo')"

fleet_pattern_record_outcome "$sig_a" true
fleet_pattern_record_outcome "$sig_a" false
assert_eq "fix_applied counted" "2" "$(jq -r --arg s "$sig_a" '.patterns[$s].fix_applied' "$STORE")"
assert_eq "fix_resolved counted" "1" "$(jq -r --arg s "$sig_a" '.patterns[$s].fix_resolved' "$STORE")"
fleet_pattern_update_fix "$sig_a" "rc2" "different fix" "test" o/repoB
assert_eq "a changed fix resets its outcome counters" "0" "$(jq -r --arg s "$sig_a" '.patterns[$s].fix_applied' "$STORE")"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Demotion"
# ═══════════════════════════════════════════════════════════════════════════════
for _ in 1 2 3 4; do fleet_pattern_record_outcome "$sig_a" false; done
assert_eq "fix that failed 4/4 times is demoted" "" "$(fleet_pattern_lookup "$sig_a")"
reset_store
fleet_pattern_record "$sig_a" test_failure "$ERR_A" o/repoA test
fleet_pattern_update_fix "$sig_a" "rc" "guard null session" "test" o/repoA
fleet_pattern_record_outcome "$sig_a" false
fleet_pattern_record_outcome "$sig_a" false
assert_eq "below the minimum attempts the fix still surfaces" "guard null session" "$(fleet_pattern_lookup "$sig_a" | jq -r '.fix')"
fleet_pattern_record_outcome "$sig_a" true
assert_eq "1/3 resolved (33%) is above the threshold" "guard null session" "$(fleet_pattern_lookup "$sig_a" | jq -r '.fix')"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Cross-repo triage"
# ═══════════════════════════════════════════════════════════════════════════════
reset_store
repoA="$TEST_TEMP_DIR/repoA"; repoB="$TEST_TEMP_DIR/repoB"; workB="$TEST_TEMP_DIR/workB"
mkdir -p "$repoA" "$repoB" "$workB"
idA=$(fleet_repo_id "$repoA")
assert_eq "repo id falls back to the directory name" "repoA" "$idA"
# Learned in repo A...
(cd "$repoA" && fleet_pattern_record "$(fleet_pattern_signature "$ERR_A")" test_failure "$ERR_A" "$idA" test)
fleet_pattern_update_fix "$sig_a" "session is null before login" "guard null session" "test" "$idA"
# ...surfaced during triage of repo B, from the issue body alone.
: > "$EVENTS_LOG"
hit=$(cd "$repoB" && fleet_triage_known_fix 42 "Build is red
$ERR_B" "" "$workB")
assert_eq "repo B triage surfaces repo A's fix" "guard null session" "$(printf '%s' "$hit" | jq -r '.fix')"
assert_eq "hit names the source repo" "repoA" "$(printf '%s' "$hit" | jq -r '.fix_source_repo')"
assert_eq "hit carries the issue number" "42" "$(printf '%s' "$hit" | jq -r '.issue')"
assert_file_exists "known-fix artifact written to the work dir" "$workB/.claude/fleet-known-fix.json"
assert_eq "artifact is valid JSON with the fix" "guard null session" "$(jq -r '.fix' "$workB/.claude/fleet-known-fix.json")"
assert_contains "triage emits fleet.pattern_hit" "$(cat "$EVENTS_LOG")" "fleet.pattern_hit"

# Retry path: the issue body has no error, but the prior run's log does.
workC="$TEST_TEMP_DIR/workC"; mkdir -p "$workC"
priorlog="$TEST_TEMP_DIR/issue-43.log"
printf 'starting build\nrunning tests\n%s\nexit 1\n' "$ERR_B" > "$priorlog"
hit=$(fleet_triage_known_fix 43 "Add a logout button" "$priorlog" "$workC")
assert_eq "retry matches the error from the prior log" "guard null session" "$(printf '%s' "$hit" | jq -r '.fix')"
assert_eq "no error anywhere → no hit" "" "$(fleet_triage_known_fix 44 "Add a logout button" "" "$workC")"
workD="$TEST_TEMP_DIR/workD"; mkdir -p "$workD"
assert_eq "unknown error → no hit" "" "$(fleet_triage_known_fix 45 "Error: something brand new exploded" "" "$workD")"
assert_file_not_exists "no artifact without a hit" "$workD/.claude/fleet-known-fix.json"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Concurrency"
# ═══════════════════════════════════════════════════════════════════════════════
run_concurrent_records() {
    reset_store
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        fleet_pattern_record "$sig_a" test_failure "$ERR_A" "o/repo$i" test &
    done
    wait
}
if command -v flock >/dev/null 2>&1; then
    run_concurrent_records
    assert_eq "flock: 10 concurrent records → seen_count 10" "10" "$(jq -r --arg s "$sig_a" '.patterns[$s].seen_count' "$STORE")"
else
    assert_pass "flock: not installed on this host — covered by the mkdir path"
fi
export FLEET_PATTERNS_FORCE_MKDIR_LOCK=1
run_concurrent_records
assert_eq "mkdir lock: 10 concurrent records → seen_count 10" "10" "$(jq -r --arg s "$sig_a" '.patterns[$s].seen_count' "$STORE")"
assert_eq "mkdir lock: 10 repos recorded" "10" "$(jq -r --arg s "$sig_a" '.patterns[$s].repos | length' "$STORE")"
if [[ -d "$STORE.lock.d" ]]; then assert_fail "mkdir lock released"; else assert_pass "mkdir lock released"; fi
# A lock left behind by a crashed writer is broken once it is stale.
mkdir "$STORE.lock.d"
touch -t 202001010000 "$STORE.lock.d"
fleet_pattern_record "$sig_a" test_failure "$ERR_A" o/repoA test
assert_eq "stale mkdir lock is broken" "11" "$(jq -r --arg s "$sig_a" '.patterns[$s].seen_count' "$STORE")"
unset FLEET_PATTERNS_FORCE_MKDIR_LOCK

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Caps"
# ═══════════════════════════════════════════════════════════════════════════════
reset_store
(
    # shellcheck disable=SC2034  # read by fleet_pattern_record
    FLEET_PATTERNS_MAX=5
    for i in 1 2 3 4 5 6 7; do
        fleet_pattern_record "test_failure:000000000000000$i" test_failure "Error: case $i" o/repoA test
        jq --arg s "test_failure:000000000000000$i" --arg ts "2026-01-0${i}T00:00:00Z" \
            '.patterns[$s].last_seen = $ts' "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
    done
)
assert_eq "pattern cap enforced" "5" "$(jq '.patterns | length' "$STORE")"
assert_eq "oldest patterns evicted first" "null" "$(jq -r '.patterns["test_failure:0000000000000001"]' "$STORE")"
assert_eq "newest pattern kept" "1" "$(jq -r '.patterns["test_failure:0000000000000007"].seen_count' "$STORE")"
reset_store
(
    # shellcheck disable=SC2034  # read by fleet_pattern_record
    FLEET_PATTERNS_MAX_REPOS=3
    for i in 1 2 3 4 5; do fleet_pattern_record "$sig_a" test_failure "$ERR_A" "o/repo$i" test; done
)
assert_eq "repos per pattern capped, most recent kept" '["o/repo3","o/repo4","o/repo5"]' "$(jq -c --arg s "$sig_a" '.patterns[$s].repos' "$STORE")"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Corrupt store"
# ═══════════════════════════════════════════════════════════════════════════════
reset_store
echo '{garbage' > "$STORE"
assert_eq "lookup on a corrupt store returns nothing" "" "$(fleet_pattern_lookup "$sig_a")"
assert_eq "triage on a corrupt store returns nothing" "" "$(fleet_triage_known_fix 9 "$ERR_B" "" "$workD")"
fleet_pattern_record "$sig_a" test_failure "$ERR_A" o/repoA test 2>/dev/null
assert_eq "record recovers to a valid store" "1" "$(jq -r --arg s "$sig_a" '.patterns[$s].seen_count' "$STORE")"
backups=$(ls "$STORE".corrupt.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "corrupt store backed up" "1" "$backups"
assert_contains "corruption emits fleet.patterns_corrupt" "$(cat "$EVENTS_LOG")" "fleet.patterns_corrupt"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "List and prune"
# ═══════════════════════════════════════════════════════════════════════════════
reset_store
assert_eq "list on a missing store is empty" "" "$(fleet_patterns_list)"
fleet_pattern_record "$sig_a" test_failure "$ERR_A" o/repoA test
fleet_pattern_record "$sig_mod_x" dependency "Error: Cannot find module 'left-pad'" o/repoA build
jq --arg s "$sig_mod_x" '.patterns[$s].last_seen = "2020-01-01T00:00:00Z"' "$STORE" > "$STORE.t" && mv "$STORE.t" "$STORE"
assert_eq "list prints one line per pattern" "2" "$(fleet_patterns_list | wc -l | tr -d ' ')"
assert_eq "list is most recent first" "$sig_a" "$(fleet_patterns_list | head -1 | jq -r '.signature')"
assert_eq "prune removes patterns older than N days" "1" "$(fleet_pattern_prune 30)"
assert_eq "recent pattern survives prune" "1" "$(jq '.patterns | length' "$STORE")"
assert_eq "prune rejects a non-integer" "0" "$(fleet_pattern_prune abc 2>/dev/null)"

print_test_results
