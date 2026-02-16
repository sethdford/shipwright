#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adversarial — Adversarial Agent Code Review                 ║
# ║  Red-team code changes · Find security flaws · Iterative hardening     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── Source Intelligence Core ─────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
fi

# ─── Configuration ───────────────────────────────────────────────────────
MAX_ROUNDS="${ADVERSARIAL_MAX_ROUNDS:-3}"

_adversarial_enabled() {
    local config="${REPO_DIR}/.claude/daemon-config.json"
    if [[ -f "$config" ]]; then
        local enabled
        enabled=$(jq -r '.intelligence.adversarial_enabled // false' "$config" 2>/dev/null || echo "false")
        [[ "$enabled" == "true" ]]
    else
        return 1
    fi
}

# ─── GitHub Security Context ─────────────────────────────────────────────

_adversarial_security_context() {
    local diff_paths="$1"
    local context=""

    type _gh_detect_repo &>/dev/null 2>&1 || { echo ""; return 0; }
    _gh_detect_repo 2>/dev/null || { echo ""; return 0; }

    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && { echo ""; return 0; }

    # Get CodeQL alerts for changed files
    if type gh_security_alerts &>/dev/null 2>&1; then
        local alerts
        alerts=$(gh_security_alerts "$owner" "$repo" 2>/dev/null || echo "[]")
        local relevant_alerts
        relevant_alerts=$(echo "$alerts" | jq -c --arg paths "$diff_paths" \
            '[.[] | select(.most_recent_instance.location.path as $p | ($paths | split("\n") | any(. == $p)))]' 2>/dev/null || echo "[]")
        local alert_count
        alert_count=$(echo "$relevant_alerts" | jq 'length' 2>/dev/null || echo "0")
        if [[ "${alert_count:-0}" -gt 0 ]]; then
            local alert_summary
            alert_summary=$(echo "$relevant_alerts" | jq -r '.[] | "- \(.rule.description // .rule.id): \(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)"' 2>/dev/null || echo "")
            context="EXISTING SECURITY ALERTS in changed files:
${alert_summary}
"
        fi
    fi

    # Get Dependabot alerts
    if type gh_dependabot_alerts &>/dev/null 2>&1; then
        local dep_alerts
        dep_alerts=$(gh_dependabot_alerts "$owner" "$repo" 2>/dev/null || echo "[]")
        local dep_count
        dep_count=$(echo "$dep_alerts" | jq 'length' 2>/dev/null || echo "0")
        if [[ "${dep_count:-0}" -gt 0 ]]; then
            local dep_summary
            dep_summary=$(echo "$dep_alerts" | jq -r '.[0:5] | .[] | "- \(.security_advisory.summary // "unknown"): \(.dependency.package.name // "unknown") (\(.security_vulnerability.severity // "unknown"))"' 2>/dev/null || echo "")
            context="${context}DEPENDENCY VULNERABILITIES:
${dep_summary}
"
        fi
    fi

    echo "$context"
}

# ─── Adversarial Review ──────────────────────────────────────────────────

adversarial_review() {
    local code_diff="${1:-}"
    local context="${2:-}"

    if ! _adversarial_enabled; then
        warn "Adversarial review disabled — enable intelligence.adversarial_enabled" >&2
        echo "[]"
        return 0
    fi

    if [[ -z "$code_diff" ]]; then
        error "Usage: adversarial review <code_diff> [context]"
        return 1
    fi

    info "Running adversarial review..." >&2

    # Inject GitHub security context if available
    local security_context=""
    local diff_paths
    diff_paths=$(echo "$code_diff" | grep '^[+-][+-][+-] [ab]/' | sed 's|^[+-]\{3\} [ab]/||' | sort -u 2>/dev/null || true)
    if [[ -n "$diff_paths" ]]; then
        security_context=$(_adversarial_security_context "$diff_paths" 2>/dev/null || true)
    fi
    if [[ -n "$security_context" ]]; then
        context="The following security alerts exist for files in this change. Pay special attention to these areas:
${security_context}
${context}"
    fi

    local prompt
    prompt=$(jq -n --arg diff "$code_diff" --arg ctx "$context" '{
        role: "You are a hostile security researcher and QA expert. Your job is to find bugs, security vulnerabilities, race conditions, edge cases, and logic errors in this code change. Be thorough and adversarial.",
        instruction: "Analyze this code diff and return a JSON array of findings. Each finding must have: severity (critical|high|medium|low), category (security|logic|race_condition|edge_case), description, location, and exploit_scenario.",
        diff: $diff,
        context: $ctx
    }' | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n\n")')

    local result
    if ! result=$(_intelligence_call_claude "$prompt" "adversarial_review_$(echo -n "$code_diff" | head -c 200 | _intelligence_md5)" 300); then
        warn "Claude call failed — returning empty findings" >&2
        echo "[]"
        return 0
    fi

    # Ensure result is a JSON array
    if ! echo "$result" | jq 'if type == "array" then . else empty end' >/dev/null 2>&1; then
        # Try to extract array from response
        local extracted
        extracted=$(echo "$result" | jq '.findings // .results // []' 2>/dev/null || echo "[]")
        result="$extracted"
    fi

    # Emit events for each finding
    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
    local i=0
    while [[ $i -lt $count ]]; do
        local severity category
        severity=$(echo "$result" | jq -r ".[$i].severity // \"unknown\"" 2>/dev/null || echo "unknown")
        category=$(echo "$result" | jq -r ".[$i].category // \"unknown\"" 2>/dev/null || echo "unknown")
        emit_event "adversarial.finding" "severity=$severity" "category=$category" "index=$i"
        i=$((i + 1))
    done

    echo "$result"
}

# ─── Adversarial Iteration ───────────────────────────────────────────────

adversarial_iterate() {
    local primary_code="${1:-}"
    local findings="${2:-[]}"
    local round="${3:-1}"

    if [[ -z "$primary_code" ]]; then
        error "Usage: adversarial iterate <primary_code> <findings_json> [round]"
        return 1
    fi

    if [[ "$round" -gt "$MAX_ROUNDS" ]]; then
        info "Max adversarial rounds ($MAX_ROUNDS) reached" >&2
        echo "$findings"
        return 0
    fi

    emit_event "adversarial.round" "round=$round" "max_rounds=$MAX_ROUNDS"

    local critical_count
    critical_count=$(echo "$findings" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")

    if [[ "$critical_count" -eq 0 ]]; then
        success "No critical/high findings — adversarial review converged at round $round" >&2
        emit_event "adversarial.converged" "round=$round" "total_findings=0"
        echo "[]"
        return 0
    fi

    info "Round $round: $critical_count critical/high findings — requesting fixes..." >&2

    local prompt
    prompt=$(jq -n --arg code "$primary_code" --arg findings "$findings" --arg round "$round" '{
        instruction: "These issues were found by adversarial security review. For each critical/high finding, suggest a specific fix. Return a JSON array with: original_finding, suggested_fix, fixed_code_snippet.",
        code: $code,
        findings: $findings,
        round: $round
    }' | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n\n")')

    local result
    if ! result=$(_intelligence_call_claude "$prompt" "adversarial_iterate_r${round}_$(echo -n "$primary_code" | head -c 200 | _intelligence_md5)" 300); then
        warn "Claude call failed during iteration" >&2
        echo "$findings"
        return 0
    fi

    echo "$result"
}

# ─── Help ─────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Adversarial${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright adversarial <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}review${RESET}   <diff> [context]              Run adversarial review on code diff"
    echo -e "    ${CYAN}iterate${RESET}  <code> <findings> [round]     Fix findings and re-review"
    echo -e "    ${CYAN}help${RESET}                                   Show this help"
    echo ""
    echo -e "  ${BOLD}CONFIGURATION${RESET}"
    echo -e "    Feature flag:  ${DIM}intelligence.adversarial_enabled${RESET} in daemon-config.json"
    echo -e "    Max rounds:    ${DIM}ADVERSARIAL_MAX_ROUNDS env var (default: 3)${RESET}"
    echo ""
}

# ─── Command Router ──────────────────────────────────────────────────────

main() {
    case "${1:-help}" in
        review)   shift; adversarial_review "$@" ;;
        iterate)  shift; adversarial_iterate "$@" ;;
        help|--help|-h) show_help ;;
        *)        error "Unknown: $1"; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
