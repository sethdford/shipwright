#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adversarial — Adversarial Agent Code Review                 ║
# ║  Red-team code changes · Find security flaws · Iterative hardening     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.7.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"; shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"; local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"; json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

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

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
