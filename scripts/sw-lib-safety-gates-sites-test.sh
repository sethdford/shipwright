#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright safety-gates sites test — automated filings use intake caps  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: the intake gate (_sw_ts) is a stub, gh is a mock; no tmux, no network, temp HOME.
# Each automated `gh issue create` site must go through patrol_issue_create with its own label.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Safety gates: automated issue-filing sites"

setup_test_env "safety-gates-sites"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export CALLS="$TEST_TEMP_DIR/calls.log"
export TEST_TEMP_DIR
touch "$CALLS"
# gh: log every call; `issue view` answers decompose's parent lookups; `issue create` prints a URL
mock_binary "gh" 'printf "gh %s\n" "$*" >> "$CALLS"
case "${1:-} ${2:-}" in
    "issue create") echo "https://github.com/o/r/issues/77" ;;
    "issue view") case "$*" in *labels*) echo "shipwright" ;; *) echo "Parent" ;; esac ;;
esac
exit 0'

calls() { cat "$CALLS"; }
count_calls() { local n; n=$(grep -c -- "$1" "$CALLS" || true); echo "${n:-0}"; }
# The stub gate: logs its argv and returns $INTAKE_RC
INTAKE_RC=1

# run_site <function> — runs one site function in a subshell, output discarded
run_site() {
    : > "$CALLS"
    ( "$1" ) >/dev/null 2>&1 || true
}
# stub_gate — the intake gate: logs its argv and returns $INTAKE_RC (call after sourcing)
stub_gate() {
    _sw_ts() { printf "intake %s\n" "$*" >> "$CALLS"; return "$INTAKE_RC"; }
}

# ─── Structural ratchet: no bare `gh issue create` at the routed sites ───
print_test_section "routed files file issues only through patrol_issue_create"

for f in sw-incident.sh sw-autonomous.sh sw-decompose.sh sw-decide.sh sw-patrol-meta.sh \
    sw-strategic.sh lib/pipeline-stages-monitor.sh lib/root-cause.sh lib/daemon-patrol.sh; do
    n=$(grep -cE '(^|[^_[:alnum:]])gh issue create' "$REAL_SCRIPT_DIR/$f" || true)
    assert_eq "${f}: no bare gh issue create" "0" "${n:-0}"
done
# sw-feedback.sh: only the two --repo passthrough sites (402, 434) remain (follow-up)
n=$(grep -cE '(^|[^_[:alnum:]])gh issue create' "$REAL_SCRIPT_DIR/sw-feedback.sh" || true)
assert_eq "sw-feedback.sh: only the two known follow-up sites remain" "2" "${n:-0}"
monitor_sites=$(grep -c 'patrol_issue_create --intake-label "incident"' "$REAL_SCRIPT_DIR/lib/pipeline-stages-monitor.sh" || true)
assert_eq "lib/pipeline-stages-monitor.sh: both incident sites use the incident label" "2" "${monitor_sites:-0}"
assert_contains "sw-feedback.sh: regression issue uses the hotfix label" \
    "$(grep -A1 'patrol_issue_create' "$REAL_SCRIPT_DIR/sw-feedback.sh")" '--intake-label "hotfix"'

# ─── sw-incident.sh ──────────────────────────────────────────────────────
site_hotfix() {
    source "$REAL_SCRIPT_DIR/sw-incident.sh"
    stub_gate
    create_hotfix_issue inc-1 P1 "disk full" || echo "site_rc=$?" >> "$CALLS"
}
print_test_section "sw-incident hotfix issue"

for INTAKE_RC in 1 0; do
    run_site site_hotfix
    assert_contains "hotfix: gate asked with the hotfix label (intake ${INTAKE_RC})" "$(calls)" \
        "intake intake check --title [HOTFIX] P1: disk full --label hotfix"
    if [[ "$INTAKE_RC" -eq 0 ]]; then
        assert_eq "hotfix: filed when allowed" "1" "$(count_calls 'gh issue create')"
    else
        assert_eq "hotfix: nothing filed when refused" "0" "$(count_calls 'gh issue create')"
        assert_contains "hotfix: refusal returns 1" "$(calls)" "site_rc=1"
    fi
done

# ─── sw-autonomous.sh ────────────────────────────────────────────────────
site_autonomous() {
    source "$REAL_SCRIPT_DIR/sw-autonomous.sh"
    stub_gate
    NO_GITHUB=false
    create_issue_from_finding "Speed up CI" "d" P2 small "perf" || echo "site_rc=$?" >> "$CALLS"
}
print_test_section "sw-autonomous finding issue"

for INTAKE_RC in 1 0; do
    run_site site_autonomous
    assert_contains "autonomous: gate asked with the shipwright label (intake ${INTAKE_RC})" "$(calls)" \
        "intake intake check --title Speed up CI --label shipwright"
    if [[ "$INTAKE_RC" -eq 0 ]]; then
        assert_eq "autonomous: filed when allowed" "1" "$(count_calls 'gh issue create')"
    else
        assert_eq "autonomous: nothing filed when refused" "0" "$(count_calls 'gh issue create')"
        assert_contains "autonomous: refusal returns 1" "$(calls)" "site_rc=1"
    fi
done

# ─── sw-decompose.sh ─────────────────────────────────────────────────────
print_test_section "sw-decompose subtasks"

analysis=$(jq -n '{subtasks: [range(1;11) | {title: ("Subtask \(.)"), description: "d"}]}')
site_decompose() {
    source "$REAL_SCRIPT_DIR/sw-decompose.sh"
    stub_gate
    NO_GITHUB=false
    decompose_create_subtasks 42 "$analysis"
}
INTAKE_RC=0
run_site site_decompose
assert_eq "decompose: at most 8 subtasks are filed" "8" "$(count_calls 'gh issue create')"
assert_contains "decompose: gate asked with the subtask label" "$(calls)" \
    "intake intake check --title Subtask 1 --label subtask"
assert_eq "decompose: subtasks past the cap never reach the gate" "0" "$(count_calls 'Subtask 9 ')"

INTAKE_RC=1
run_site site_decompose
assert_eq "decompose: nothing filed when refused" "0" "$(count_calls 'gh issue create')"

# ─── lib/root-cause.sh ───────────────────────────────────────────────────
site_rootcause() {
    source "$REAL_SCRIPT_DIR/lib/root-cause.sh"
    stub_gate
    NO_GITHUB=""
    rootcause_create_platform_issue '{"category":"platform_bug","confidence":90}' "boom" build \
        || echo "site_rc=$?" >> "$CALLS"
}
print_test_section "root-cause platform issue"

for INTAKE_RC in 1 0; do
    run_site site_rootcause
    assert_contains "root-cause: gate asked with the auto-created label (intake ${INTAKE_RC})" "$(calls)" \
        "--label auto-created"
    if [[ "$INTAKE_RC" -eq 0 ]]; then
        assert_eq "root-cause: filed when allowed" "1" "$(count_calls 'gh issue create')"
    else
        assert_eq "root-cause: nothing filed when refused" "0" "$(count_calls 'gh issue create')"
        assert_contains "root-cause: refusal returns 1" "$(calls)" "site_rc=1"
    fi
done

# ─── sw-decide.sh: a refused filing is recorded as refused ───────────────
print_test_section "sw-decide refused filing"

site_decide() {
    source "$REAL_SCRIPT_DIR/sw-decide.sh" > "$TEST_TEMP_DIR/decide-source.out"
    stub_gate
    NO_GITHUB=false
    TIERS_DATA='{"tiers":{"auto":{"labels":["shipwright","shipwright:auto"]}}}'
    _execute_decision '{"id":"d1","title":"Bump deps","category":"deps","value_score":60,"dedup_key":"deps:x"}' auto false
    cp "$(_daily_log_file)" "$TEST_TEMP_DIR/decide-log.json"
}
INTAKE_RC=1
run_site site_decide
assert_eq "decide: sourcing does not run main (no usage printed)" "" "$(cat "$TEST_TEMP_DIR/decide-source.out" 2>/dev/null || echo missing)"
assert_contains "decide: gate asked with the tier label" "$(calls)" \
    "intake intake check --title Bump deps --label shipwright:auto"
assert_eq "decide: nothing filed when refused" "0" "$(count_calls 'gh issue create')"
record=$(jq -s -c 'map(select(.id == "d1")) | last' "$TEST_TEMP_DIR/decide-log.json" 2>/dev/null || true)
assert_eq "decide: recorded as refused" "issue_refused" "$(echo "$record" | jq -r '.action' 2>/dev/null)"
assert_eq "decide: a refusal costs nothing" "0" "$(echo "$record" | jq -r '.estimated_cost_usd' 2>/dev/null)"
assert_eq "decide: a refusal keeps no dedup key (retried next cycle)" "" "$(echo "$record" | jq -r '.dedup_key' 2>/dev/null)"

print_test_results
