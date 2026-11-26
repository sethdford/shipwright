#!/usr/bin/env bash
# pipeline-router.sh — adaptive compute router for pipeline runs (ADR-0012).
# The TypeScript command `shipwright route` does the work; this file calls it at the start and the end
# of a run. SHIPWRIGHT_ROUTER picks the mode:
#   shadow (default)  decide and log the route, change nothing (data for the scorecard and the ratchet)
#   apply             also use the route's template, model, effort and attempts where the caller set none
#   off               skip the router
# The router is advice, not a gate: when it cannot run, the pipeline goes on with its defaults and an
# event records why. Budget enforcement stays with `sw cost check-budget` and the daemon.
[[ -n "${_PIPELINE_ROUTER_LOADED:-}" ]] && return 0
_PIPELINE_ROUTER_LOADED=1

_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DECISION_ID=""

_router_cli() {
    local bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-$(cd "${_ROUTER_DIR}/../.." && pwd)/src/cli.ts}"
    command -v "$bun_bin" >/dev/null 2>&1 || return 1
    "$bun_bin" "$cli" route "$@"
}

_router_event() {
    if type emit_event >/dev/null 2>&1; then emit_event "$@" 2>/dev/null || true; fi
    return 0
}

# Prints shadow, apply or off. Anything else is reported and treated as shadow.
router_mode() {
    local m
    m="$(printf '%s' "${SHIPWRIGHT_ROUTER:-shadow}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$m" in
        ""|shadow) echo "shadow" ;;
        apply|on) echo "apply" ;;
        off|0|false|no) echo "off" ;;
        *) _router_event "router.bad_mode" "value=$m"; echo "shadow" ;;
    esac
}

# Money left under the daily cap, or nothing when there is no cap or it cannot be read.
_router_remaining_usd() {
    local out
    [[ -x "${_ROUTER_DIR}/../sw-cost.sh" ]] || return 0
    out="$(bash "${_ROUTER_DIR}/../sw-cost.sh" remaining-budget 2>/dev/null || true)"
    [[ "$out" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && printf '%s\n' "$out"
    return 0
}

# Writes the issue (gh issue view JSON) to $1; returns 1 when there is no issue to read.
_router_issue_json() {
    local dest="$1"
    [[ -n "${ISSUE_NUMBER:-}" && "${NO_GITHUB:-false}" != "true" ]] || return 1
    command -v gh >/dev/null 2>&1 || return 1
    gh issue view "$ISSUE_NUMBER" --json title,body,labels > "$dest" 2>/dev/null || return 1
    [[ -s "$dest" ]]
}

# The caller's explicit settings, which the route never replaces. $1: the --pipeline the user gave
# ("standard" is the default and does not count as a choice).
_router_override_args() {
    local user_pipeline="${1:-standard}"
    [[ "$user_pipeline" != "standard" ]] && printf '%s\n' --template "$user_pipeline"
    [[ -n "${MODEL:-}" ]] && printf '%s\n' --model "$MODEL"
    [[ -n "${EFFORT_LEVEL_OVERRIDE:-}" ]] && printf '%s\n' --effort "$EFFORT_LEVEL_OVERRIDE"
    [[ -n "${PIPELINE_ATTEMPTS:-}" ]] && printf '%s\n' --attempts "$PIPELINE_ATTEMPTS"
    return 0
}

# pipeline_route_start <user-pipeline> — decide (and in apply mode, use) a route for this run.
pipeline_route_start() {
    local user_pipeline="${1:-standard}" mode tmp out remaining line
    local -a args=()
    mode="$(router_mode)"
    [[ "$mode" == "off" ]] && return 0
    tmp="$(mktemp "${TMPDIR:-/tmp}/sw-route-issue.XXXXXX")" || return 0
    if _router_issue_json "$tmp"; then
        args+=(--issue-json "$tmp" --issue "$ISSUE_NUMBER")
    elif [[ -n "${GOAL:-}" ]]; then
        args+=(--goal "$GOAL")
        [[ -n "${ISSUE_NUMBER:-}" ]] && args+=(--issue "$ISSUE_NUMBER")
    else
        rm -f "$tmp"
        return 0
    fi
    [[ -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]] && args+=(--repo "${REPO_OWNER}/${REPO_NAME}")
    remaining="$(_router_remaining_usd)"
    [[ -n "$remaining" ]] && args+=(--remaining-usd "$remaining")
    while IFS= read -r line; do [[ -n "$line" ]] && args+=("$line"); done < <(_router_override_args "$user_pipeline")
    if ! out="$(_router_cli decide --mode "$mode" "${args[@]}" --json 2>/dev/null)" \
        || ! ROUTER_DECISION_ID="$(printf '%s' "$out" | jq -er '.id' 2>/dev/null)"; then
        rm -f "$tmp"
        ROUTER_DECISION_ID=""
        _router_event "router.unavailable" "issue=${ISSUE_NUMBER:-0}" "mode=$mode"
        return 0
    fi
    rm -f "$tmp"
    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        mkdir -p "$ARTIFACTS_DIR" 2>/dev/null && printf '%s\n' "$out" > "$ARTIFACTS_DIR/routing-decision.json"
    fi
    _router_report "$out" "$mode"
    [[ "$mode" == "apply" ]] && _router_apply "$out" "$user_pipeline"
    return 0
}

_router_report() {
    local out="$1" mode="$2" summary
    summary="$(printf '%s' "$out" | jq -r '"\(.difficulty.tier) (score \(.difficulty.score)): \(.applied.template), \(.applied.model), effort \(.applied.effort), \(.applied.attempts) attempt(s), cap $\(.applied.budgetUsd)"' 2>/dev/null || true)"
    if type info >/dev/null 2>&1; then info "Router (${mode}): ${summary}"; fi
    local advice
    advice="$(printf '%s' "$out" | jq -r '.advice // empty' 2>/dev/null || true)"
    [[ -n "$advice" ]] && type warn >/dev/null 2>&1 && warn "Router: $advice"
    _router_event "router.decision" "issue=${ISSUE_NUMBER:-0}" "decision=${ROUTER_DECISION_ID}" "mode=$mode" \
        "tier=$(printf '%s' "$out" | jq -r '.difficulty.tier' 2>/dev/null)" \
        "prior=$(printf '%s' "$out" | jq -r '.difficulty.prior' 2>/dev/null)" \
        "template=$(printf '%s' "$out" | jq -r '.applied.template' 2>/dev/null)" \
        "model=$(printf '%s' "$out" | jq -r '.applied.model' 2>/dev/null)" \
        "effort=$(printf '%s' "$out" | jq -r '.applied.effort' 2>/dev/null)" \
        "attempts=$(printf '%s' "$out" | jq -r '.applied.attempts' 2>/dev/null)" \
        "action=$(printf '%s' "$out" | jq -r '.action' 2>/dev/null)"
}

# Uses the route where the caller set nothing. A template without plan and review is never used (#241).
_router_apply() {
    local out="$1" user_pipeline="$2" template model effort attempts budget
    template="$(printf '%s' "$out" | jq -r '.applied.template')"
    model="$(printf '%s' "$out" | jq -r '.applied.model')"
    effort="$(printf '%s' "$out" | jq -r '.applied.effort')"
    attempts="$(printf '%s' "$out" | jq -r '.applied.attempts')"
    budget="$(printf '%s' "$out" | jq -r '.applied.budgetUsd')"
    if [[ "$(printf '%s' "$out" | jq -r '.action')" == "defer" ]]; then
        type warn >/dev/null 2>&1 && warn "Router: no budget left today; the budget gate decides whether this run goes on"
    fi
    if [[ "$user_pipeline" == "standard" && -n "$template" ]]; then
        if ! type pipeline_template_is_reviewed >/dev/null 2>&1 || pipeline_template_is_reviewed "$template"; then
            PIPELINE_NAME="$template"
        fi
    fi
    [[ -z "${MODEL:-}" && -n "$model" ]] && MODEL="$model"
    [[ -z "${EFFORT_LEVEL_OVERRIDE:-}" && -n "$effort" ]] && EFFORT_LEVEL_OVERRIDE="$effort"
    if [[ -z "${PIPELINE_ATTEMPTS:-}" && "$attempts" =~ ^[2-5]$ ]]; then
        export PIPELINE_ATTEMPTS="$attempts"
        [[ -z "${PIPELINE_TOURNAMENT_BUDGET_USD:-}" ]] && export PIPELINE_TOURNAMENT_BUDGET_USD="$budget"
    fi
    return 0
}

# Maps the pipeline's failure evidence to the router's failure classes (learning context names).
_router_failure_class() {
    local reason="" cls="${LAST_STAGE_ERROR_CLASS:-}"
    [[ -n "${ARTIFACTS_DIR:-}" && -f "$ARTIFACTS_DIR/failure-reason.txt" ]] && reason="$(head -1 "$ARTIFACTS_DIR/failure-reason.txt" 2>/dev/null || true)"
    case "$reason" in
        context_exhaustion|max_turns) echo "max_turns"; return 0 ;;
        budget|budget_exceeded) echo "budget"; return 0 ;;
    esac
    case "$cls" in
        infrastructure) echo "transient" ;;
        configuration) echo "environment" ;;
        logic|build) echo "execution" ;;
        *) echo "unknown" ;;
    esac
}

# pipeline_route_finish <exit-code> <cost-usd> — record how the routed run ended.
pipeline_route_finish() {
    local code="${1:-1}" cost="${2:-}" pr="" url
    [[ -n "${ROUTER_DECISION_ID:-}" ]] || return 0
    local -a args=(--decision "$ROUTER_DECISION_ID")
    if [[ "$code" -eq 0 ]]; then
        args+=(--result success)
    else
        args+=(--result failure --failure-class "$(_router_failure_class)")
    fi
    [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] && args+=(--cost-usd "$cost")
    url="$(cat "${ARTIFACTS_DIR:-/nonexistent}/pr-url.txt" 2>/dev/null || true)"
    pr="${url##*/pull/}"
    [[ "$pr" =~ ^[0-9]+$ ]] && args+=(--pr "$pr")
    if ! _router_cli outcome "${args[@]}" >/dev/null 2>&1; then
        _router_event "router.outcome_unrecorded" "decision=${ROUTER_DECISION_ID}"
    fi
    return 0
}
