#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-router test — ADR-0012 adaptive compute router  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun and gh are mocks (the TypeScript command has its own tests), temp HOME, no network.
# Checks what the bash side owns: the modes, what it passes, what apply mode changes, and the outcome.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: pipeline-router Tests"

setup_test_env "lib-pipeline-router"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log" BUN_EXIT=0 ROUTE_ACTION=build ROUTE_ADVICE=""
export ROUTE_ATTEMPTS=3
# The mock logs its argv one per line and answers like the real command.
mock_binary "bun" '
printf "%s\n" "$@" >> "$BUN_LOG"; printf -- "--\n" >> "$BUN_LOG"
[[ "$BUN_EXIT" == 0 ]] || exit "$BUN_EXIT"
case " $* " in
    *" decide "*)
        adv=""; [[ -n "$ROUTE_ADVICE" ]] && adv=",\"advice\":\"$ROUTE_ADVICE\""
        printf "%s\n" "{\"id\":\"rt-x-7\",\"difficulty\":{\"tier\":\"large\",\"prior\":\"large\",\"score\":70},\"applied\":{\"template\":\"cost-aware\",\"model\":\"opus\",\"effort\":\"high\",\"attempts\":$ROUTE_ATTEMPTS,\"budgetUsd\":30},\"action\":\"$ROUTE_ACTION\"$adv}" ;;
    *" outcome "*) echo "{}" ;;
esac'
mock_binary "gh" 'printf "%s\n" "{\"title\":\"Add thing\",\"body\":\"b\",\"labels\":[{\"name\":\"size/L\"}]}"'

export SW_TS_CLI="$SCRIPT_DIR/../src/cli.ts"
source "$SCRIPT_DIR/lib/pipeline-router.sh"
EVENTS_LOG="$TEST_TEMP_DIR/events.log"
emit_event() { printf '%s\n' "$*" >> "$EVENTS_LOG"; }
info() { :; }
warn() { printf 'WARN %s\n' "$*" >> "$EVENTS_LOG"; }
pipeline_template_is_reviewed() { [[ "$1" != "fast" ]]; }
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"

reset_run() {
    : > "$BUN_LOG"; : > "$EVENTS_LOG"
    MODEL=""; EFFORT_LEVEL_OVERRIDE=""; PIPELINE_NAME="standard"; ROUTER_DECISION_ID=""
    unset PIPELINE_ATTEMPTS PIPELINE_TOURNAMENT_BUDGET_USD SHIPWRIGHT_ROUTER
    ISSUE_NUMBER=7; GOAL="Add thing"; NO_GITHUB=false
    rm -rf "$ARTIFACTS_DIR"
}

print_test_section "modes"
assert_eq "default is shadow" "shadow" "$(router_mode)"
assert_eq "apply" "apply" "$(SHIPWRIGHT_ROUTER=APPLY router_mode)"
assert_eq "off" "off" "$(SHIPWRIGHT_ROUTER=off router_mode)"
assert_eq "unknown falls back to shadow" "shadow" "$(SHIPWRIGHT_ROUTER=maybe router_mode)"

print_test_section "shadow mode logs a decision and changes nothing"
reset_run
pipeline_route_start "standard"
assert_eq "decision id kept for the outcome" "rt-x-7" "$ROUTER_DECISION_ID"
assert_contains "issue JSON is passed" "$(cat "$BUN_LOG")" "--issue-json"
assert_contains "in shadow mode" "$(tr '\n' ' ' < "$BUN_LOG")" "--mode shadow"
assert_eq "template unchanged" "standard" "$PIPELINE_NAME"
assert_eq "model unchanged" "" "$MODEL"
assert_eq "attempts unchanged" "" "${PIPELINE_ATTEMPTS:-}"
assert_contains "an event records the decision" "$(cat "$EVENTS_LOG")" "router.decision"
assert_contains "the decision is saved with the run" "$(cat "$ARTIFACTS_DIR/routing-decision.json")" "rt-x-7"

print_test_section "apply mode fills only what the caller left unset"
reset_run
SHIPWRIGHT_ROUTER=apply pipeline_route_start "standard"
assert_eq "template from the route" "cost-aware" "$PIPELINE_NAME"
assert_eq "model from the route" "opus" "$MODEL"
assert_eq "effort from the route" "high" "$EFFORT_LEVEL_OVERRIDE"
assert_eq "attempts exported for tournament mode" "3" "${PIPELINE_ATTEMPTS:-}"
assert_eq "tournament budget from the route cap" "30" "${PIPELINE_TOURNAMENT_BUDGET_USD:-}"
reset_run
MODEL=sonnet; EFFORT_LEVEL_OVERRIDE=low; PIPELINE_NAME=tdd
SHIPWRIGHT_ROUTER=apply pipeline_route_start "tdd"
assert_eq "a --pipeline the user gave stays" "tdd" "$PIPELINE_NAME"
assert_eq "a --model the user gave stays" "sonnet" "$MODEL"
assert_eq "an --effort the user gave stays" "low" "$EFFORT_LEVEL_OVERRIDE"
assert_contains "and they are passed as overrides" "$(tr '\n' ' ' < "$BUN_LOG")" "--template tdd --model sonnet --effort low"
reset_run
ROUTE_ATTEMPTS=1 SHIPWRIGHT_ROUTER=apply pipeline_route_start "standard"
assert_eq "one attempt does not turn on tournament mode" "" "${PIPELINE_ATTEMPTS:-}"
reset_run
ROUTE_ACTION=defer ROUTE_ADVICE="split it" SHIPWRIGHT_ROUTER=apply pipeline_route_start "standard"
assert_contains "defer is a warning, not a stop" "$(cat "$EVENTS_LOG")" "WARN Router: no budget left"
assert_contains "advice is shown" "$(cat "$EVENTS_LOG")" "WARN Router: split it"

print_test_section "goal runs and failures never block"
reset_run
NO_GITHUB=true pipeline_route_start "standard"
assert_contains "no GitHub: the goal is the issue text" "$(tr '\n' ' ' < "$BUN_LOG")" "--goal Add thing --issue 7"
reset_run
BUN_EXIT=1 SHIPWRIGHT_ROUTER=apply pipeline_route_start "standard"
assert_eq "a failing command leaves no decision" "" "$ROUTER_DECISION_ID"
assert_eq "and changes nothing" "standard" "$PIPELINE_NAME"
assert_contains "and records why" "$(cat "$EVENTS_LOG")" "router.unavailable"
reset_run
SHIPWRIGHT_ROUTER=off pipeline_route_start "standard"
assert_eq "off does not run the command" "" "$(cat "$BUN_LOG")"
reset_run
SW_BUN=/nonexistent/bun pipeline_route_start "standard"
assert_eq "no Bun: no decision" "" "$ROUTER_DECISION_ID"

print_test_section "outcome"
reset_run
pipeline_route_start "standard"
: > "$BUN_LOG"
mkdir -p "$ARTIFACTS_DIR"
echo "https://github.com/o/r/pull/42" > "$ARTIFACTS_DIR/pr-url.txt"
pipeline_route_finish 0 "1.25"
assert_contains "success with cost and PR" "$(tr '\n' ' ' < "$BUN_LOG")" "outcome --decision rt-x-7 --result success --cost-usd 1.25 --pr 42"
: > "$BUN_LOG"; rm -f "$ARTIFACTS_DIR/pr-url.txt"
echo "context_exhaustion" > "$ARTIFACTS_DIR/failure-reason.txt"
pipeline_route_finish 1 "0"
assert_contains "context exhaustion is a max_turns failure" "$(tr '\n' ' ' < "$BUN_LOG")" "--result failure --failure-class max_turns --cost-usd 0"
: > "$BUN_LOG"; rm -f "$ARTIFACTS_DIR/failure-reason.txt"
LAST_STAGE_ERROR_CLASS=infrastructure pipeline_route_finish 1 ""
assert_contains "infrastructure errors are transient" "$(tr '\n' ' ' < "$BUN_LOG")" "--failure-class transient"
: > "$BUN_LOG"
ROUTER_DECISION_ID=""
pipeline_route_finish 0 "1"
assert_eq "no decision, nothing recorded" "" "$(cat "$BUN_LOG")"

print_test_results
