#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright simulation — Multi-Persona Developer Simulation             ║
# ║  Internal debate · PR quality gates · Automated reviewer personas      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
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
# ─── Source Intelligence Core ─────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
fi

# ─── Configuration ───────────────────────────────────────────────────────
MAX_SIMULATION_ROUNDS="${SIMULATION_MAX_ROUNDS:-3}"

_simulation_enabled() {
    local config="${REPO_DIR}/.claude/daemon-config.json"
    if [[ -f "$config" ]]; then
        local enabled
        enabled=$(jq -r '.intelligence.simulation_enabled // false' "$config" 2>/dev/null || echo "false")
        [[ "$enabled" == "true" ]]
    else
        return 1
    fi
}

# ─── Persona Prompts ─────────────────────────────────────────────────────

_build_persona_prompt() {
    local persona="$1"
    local diff="$2"
    local description="$3"

    local role=""
    case "$persona" in
        security)
            role="You are a senior security engineer reviewing a pull request. Focus on authentication issues, injection risks, data exposure, privilege escalation, and input validation. Be thorough and skeptical."
            ;;
        performance)
            role="You are a senior performance engineer reviewing a pull request. Focus on N+1 queries, unnecessary allocations, missing caching opportunities, algorithmic complexity, and resource leaks. Be precise."
            ;;
        maintainability)
            role="You are a senior software architect reviewing a pull request. Focus on code smells, missing tests, poor naming, unclear logic, coupling issues, and violations of established patterns. Be constructive."
            ;;
    esac

    jq -n --arg role "$role" --arg persona "$persona" --arg diff "$diff" --arg desc "$description" '{
        role: $role,
        instruction: "Review this PR diff and return a JSON array of concerns. Each concern must have: persona, concern (description), severity (critical|high|medium|low), and suggestion (specific fix).",
        persona: $persona,
        diff: $diff,
        pr_description: $desc
    }' | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n\n")'
}

# ─── Simulation Review ───────────────────────────────────────────────────

simulation_review() {
    local pr_diff="${1:-}"
    local pr_description="${2:-}"

    if ! _simulation_enabled; then
        warn "Developer simulation disabled — enable intelligence.simulation_enabled" >&2
        echo "[]"
        return 0
    fi

    if [[ -z "$pr_diff" ]]; then
        error "Usage: simulation review <pr_diff> [pr_description]"
        return 1
    fi

    info "Running developer simulation (3 personas)..." >&2

    local all_objections="[]"
    local personas="security performance maintainability"

    for persona in $personas; do
        info "  Persona: ${persona}..." >&2

        local prompt
        prompt=$(_build_persona_prompt "$persona" "$pr_diff" "$pr_description")

        local cache_key="simulation_${persona}_$(echo -n "$pr_diff" | head -c 200 | _intelligence_md5)"
        local result
        if ! result=$(_intelligence_call_claude "$prompt" "$cache_key" 300); then
            warn "  ${persona} persona failed — skipping" >&2
            continue
        fi

        # Ensure result is a JSON array
        if ! echo "$result" | jq 'if type == "array" then . else empty end' >/dev/null 2>&1; then
            result=$(echo "$result" | jq '.concerns // .objections // .findings // []' 2>/dev/null || echo "[]")
        fi

        # Inject persona into each objection
        result=$(echo "$result" | jq --arg p "$persona" '[.[] | . + {persona: $p}]' 2>/dev/null || echo "[]")

        # Emit events
        local count
        count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
        local i=0
        while [[ $i -lt $count ]]; do
            local severity concern_text
            severity=$(echo "$result" | jq -r ".[$i].severity // \"medium\"" 2>/dev/null || echo "medium")
            concern_text=$(echo "$result" | jq -r ".[$i].concern // \"\"" 2>/dev/null | head -c 100)
            emit_event "simulation.objection" "persona=$persona" "severity=$severity" "concern=$concern_text"
            i=$((i + 1))
        done

        # Merge into all_objections
        all_objections=$(jq -n --argjson existing "$all_objections" --argjson new "$result" '$existing + $new')
    done

    local total
    total=$(echo "$all_objections" | jq 'length' 2>/dev/null || echo "0")
    info "Simulation complete: $total total objections" >&2

    echo "$all_objections"
}

# ─── Address Objections ──────────────────────────────────────────────────

simulation_address_objections() {
    local objections_json="${1:-[]}"
    local implementation_context="${2:-}"

    local count
    count=$(echo "$objections_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        success "No objections to address" >&2
        emit_event "simulation.complete" "objections=0" "rounds=0"
        echo "[]"
        return 0
    fi

    info "Addressing $count objections..." >&2

    local prompt
    prompt=$(jq -n --arg objections "$objections_json" --arg ctx "$implementation_context" '{
        instruction: "These concerns were raised about your PR by security, performance, and maintainability reviewers. Address each one. Return a JSON array with: concern (original), response (your explanation), action (will_fix|wont_fix|already_addressed), and code_change (if applicable).",
        objections: $objections,
        implementation_context: $ctx
    }' | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n\n")')

    local result
    if ! result=$(_intelligence_call_claude "$prompt" "simulation_address_$(echo -n "$objections_json" | head -c 200 | _intelligence_md5)" 300); then
        warn "Claude call failed — returning unaddressed objections" >&2
        echo "[]"
        return 0
    fi

    # Ensure result is a JSON array
    if ! echo "$result" | jq 'if type == "array" then . else empty end' >/dev/null 2>&1; then
        result=$(echo "$result" | jq '.responses // .actions // []' 2>/dev/null || echo "[]")
    fi

    local addressed
    addressed=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
    emit_event "simulation.addressed" "count=$addressed"
    emit_event "simulation.complete" "objections=$count" "addressed=$addressed"

    success "Addressed $addressed of $count objections" >&2
    echo "$result"
}

# ─── Help ─────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Simulation${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright simulation <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}review${RESET}   <diff> [description]           Run multi-persona PR review"
    echo -e "    ${CYAN}address${RESET}  <objections_json> [context]    Address reviewer objections"
    echo -e "    ${CYAN}help${RESET}                                    Show this help"
    echo ""
    echo -e "  ${BOLD}PERSONAS${RESET}"
    echo -e "    ${CYAN}security${RESET}          Auth, injection, data exposure"
    echo -e "    ${CYAN}performance${RESET}       N+1 queries, allocations, caching"
    echo -e "    ${CYAN}maintainability${RESET}   Code smells, naming, test coverage"
    echo ""
    echo -e "  ${BOLD}CONFIGURATION${RESET}"
    echo -e "    Feature flag:  ${DIM}intelligence.simulation_enabled${RESET} in daemon-config.json"
    echo -e "    Max rounds:    ${DIM}SIMULATION_MAX_ROUNDS env var (default: 3)${RESET}"
    echo ""
}

# ─── Command Router ──────────────────────────────────────────────────────

main() {
    case "${1:-help}" in
        review)   shift; simulation_review "$@" ;;
        address)  shift; simulation_address_objections "$@" ;;
        help|--help|-h) show_help ;;
        *)        error "Unknown: $1"; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
