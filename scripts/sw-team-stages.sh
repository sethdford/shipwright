#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright team-stages — Multi-agent execution with leader/specialist roles ║
# ║  Decompose stages into parallel tasks · Consensus voting · Result aggregation║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.13.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Team Configuration ─────────────────────────────────────────────────────
TEAM_STATE_DIR="${HOME}/.shipwright/team-state"
INTELLIGENCE_CACHE="${REPO_DIR}/.claude/intelligence-cache.json"

ensure_team_dir() {
    mkdir -p "$TEAM_STATE_DIR"
}

# ─── Role Definitions ───────────────────────────────────────────────────────
# Each role has a prompt injection template that guides the agent's focus

declare_role() {
    local role="$1"
    case "$role" in
        builder)
            echo "Implementation specialist — focuses on code quality, architecture, patterns"
            ;;
        reviewer)
            echo "Code reviewer — validates correctness, design, performance, security"
            ;;
        tester)
            echo "Test specialist — writes tests, validates coverage, detects edge cases"
            ;;
        security)
            echo "Security engineer — scans for vulns, auth issues, injection risks"
            ;;
        docs)
            echo "Documentation specialist — API docs, examples, type definitions"
            ;;
        *)
            echo "$role — specialist agent"
            ;;
    esac
}

# ─── Compose: Generate team for a stage ─────────────────────────────────────
cmd_compose() {
    local stage="${1:-build}"
    local complexity="${2:-medium}"

    ensure_team_dir

    local team_json
    local leader="lead-agent"
    local specialists=""

    case "$stage" in
        build)
            specialists="builder builder reviewer"
            ;;
        test)
            specialists="tester tester security"
            ;;
        review)
            specialists="reviewer reviewer security"
            ;;
        *)
            specialists="builder reviewer tester"
            ;;
    esac

    # Count specialists
    local spec_count
    spec_count=$(echo "$specialists" | wc -w)

    team_json=$(jq -n \
        --arg stage "$stage" \
        --arg complexity "$complexity" \
        --arg leader "$leader" \
        --argjson spec_count "$spec_count" \
        --arg specialists "$specialists" \
        '{
            stage: $stage,
            complexity: $complexity,
            created_at: "'$(now_iso)'",
            leader: $leader,
            specialists: ($specialists | split(" ")),
            specialist_count: $spec_count,
            status: "pending"
        }')

    echo "$team_json"

    emit_event "team_composed" \
        "stage=$stage" \
        "complexity=$complexity" \
        "specialist_count=$spec_count"
}

# ─── Delegate: Break stage into agent tasks with file assignments ───────────
cmd_delegate() {
    local stage="${1:-build}"
    local complexity="${2:-medium}"

    ensure_team_dir

    local team_json
    team_json=$(cmd_compose "$stage" "$complexity")

    # Read hotspots from intelligence cache if available
    local hotspots=""
    if [[ -f "$INTELLIGENCE_CACHE" ]]; then
        hotspots=$(jq -r '.hotspots[]? // empty' "$INTELLIGENCE_CACHE" 2>/dev/null | head -10 || true)
    fi

    # Collect changed files for this stage
    local changed_files=""
    if git rev-parse HEAD >/dev/null 2>&1; then
        changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git ls-files || true)
    fi

    # Distribute files across specialists
    local specialist_count
    specialist_count=$(echo "$team_json" | jq -r '.specialist_count // 1')

    local tasks="[]"
    local file_count=0

    # Assign files round-robin to specialists
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local spec_idx=$((file_count % specialist_count))
        local task_json
        task_json=$(jq -n \
            --arg file "$file" \
            --arg spec_idx "$spec_idx" \
            --arg status "pending" \
            '{
                file: $file,
                specialist_idx: ($spec_idx | tonumber),
                status: $status,
                assigned_at: "'$(now_iso)'",
                result: null
            }')
        tasks=$(echo "$tasks" | jq ". += [$task_json]")
        ((file_count++))
    done < <(echo "$changed_files")

    # Output delegation result
    local result
    result=$(echo "$team_json" | jq \
        --argjson tasks "$tasks" \
        --argjson file_count "$file_count" \
        '.tasks = $tasks | .file_count = $file_count')

    echo "$result"

    emit_event "stage_delegated" \
        "stage=$stage" \
        "specialist_count=$specialist_count" \
        "file_count=$file_count"
}

# ─── Status: Show team member status for active stage ───────────────────────
cmd_status() {
    local stage="${1:-}"

    ensure_team_dir

    if [[ -z "$stage" ]]; then
        # List all active teams
        if [[ ! -d "$TEAM_STATE_DIR" ]] || [[ -z "$(ls -A "$TEAM_STATE_DIR" 2>/dev/null)" ]]; then
            info "No active teams"
            return 0
        fi

        for team_file in "$TEAM_STATE_DIR"/*.json; do
            [[ -f "$team_file" ]] || continue
            local ts
            ts=$(stat -f %Bm "$team_file" 2>/dev/null || stat -c %Y "$team_file" 2>/dev/null || echo 0)
            local name
            name=$(basename "$team_file" .json)
            local status
            status=$(jq -r '.status // "unknown"' "$team_file" 2>/dev/null || echo "error")
            printf "  %-30s  %-15s  %-20s\n" "$name" "$status" "$(date -r "$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
        done
        return 0
    fi

    # Show details for specific stage
    local team_file="$TEAM_STATE_DIR/${stage}.json"
    if [[ ! -f "$team_file" ]]; then
        error "No team state for stage: $stage"
        exit 1
    fi

    local team_json
    team_json=$(cat "$team_file")

    # Display leader
    local leader
    leader=$(echo "$team_json" | jq -r '.leader // "unknown"')
    echo ""
    echo -e "  ${BOLD}${CYAN}Stage:${RESET}  $(echo "$team_json" | jq -r '.stage')"
    echo -e "  ${BOLD}${CYAN}Leader:${RESET}  $leader"
    echo -e "  ${BOLD}${CYAN}Status:${RESET}  $(echo "$team_json" | jq -r '.status // "unknown"')"
    echo ""

    # Display specialists
    echo -e "  ${BOLD}Specialists${RESET}"
    local specs
    specs=$(echo "$team_json" | jq -r '.specialists[]? // empty')
    local spec_idx=0
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        local spec_status
        spec_status=$(echo "$team_json" | jq -r ".specialist_status[$spec_idx] // \"pending\"" 2>/dev/null || echo "pending")
        printf "    ${DIM}%-3d${RESET}  %-20s  %-15s\n" "$((spec_idx + 1))" "$spec" "$spec_status"
        ((spec_idx++))
    done < <(echo "$specs")
    echo ""
}

# ─── Vote: Collect and tally review votes ──────────────────────────────────
cmd_vote() {
    local stage="${1:-}"
    local team_file="$TEAM_STATE_DIR/${stage}.json"

    if [[ -z "$stage" ]]; then
        error "Usage: shipwright team-stages vote <stage>"
        exit 1
    fi

    if [[ ! -f "$team_file" ]]; then
        error "No team state for stage: $stage"
        exit 1
    fi

    local team_json
    team_json=$(cat "$team_file")

    # Collect verdicts from all specialists
    local approve_count=0
    local reject_count=0
    local neutral_count=0
    local total=0

    local specs
    specs=$(echo "$team_json" | jq -r '.specialists[]? // empty')

    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        local verdict
        verdict=$(echo "$team_json" | jq -r ".verdicts[\"$spec\"]? // \"neutral\"" 2>/dev/null || echo "neutral")
        case "$verdict" in
            approve) ((approve_count++)) ;;
            reject)  ((reject_count++)) ;;
            *)       ((neutral_count++)) ;;
        esac
        ((total++))
    done < <(echo "$specs")

    # Consensus: majority vote with leader tiebreak
    local consensus="neutral"
    if [[ $approve_count -gt $reject_count ]]; then
        consensus="approve"
    elif [[ $reject_count -gt $approve_count ]]; then
        consensus="reject"
    elif [[ $approve_count -eq $reject_count ]] && [[ $approve_count -gt 0 ]]; then
        # Tiebreak: check leader verdict
        local leader_verdict
        leader_verdict=$(echo "$team_json" | jq -r '.verdicts.leader? // "neutral"' 2>/dev/null || echo "neutral")
        consensus="$leader_verdict"
    fi

    local result
    result=$(jq -n \
        --argjson approve_count "$approve_count" \
        --argjson reject_count "$reject_count" \
        --argjson neutral_count "$neutral_count" \
        --argjson total "$total" \
        --arg consensus "$consensus" \
        '{
            approve: $approve_count,
            reject: $reject_count,
            neutral: $neutral_count,
            total: $total,
            consensus: $consensus,
            decided_at: "'$(now_iso)'"
        }')

    echo "$result"

    emit_event "vote_tallied" \
        "stage=$stage" \
        "consensus=$consensus" \
        "approve=$approve_count" \
        "reject=$reject_count"
}

# ─── Aggregate: Combine outputs from all agents ──────────────────────────────
cmd_aggregate() {
    local stage="${1:-}"
    local team_file="$TEAM_STATE_DIR/${stage}.json"

    if [[ -z "$stage" ]]; then
        error "Usage: shipwright team-stages aggregate <stage>"
        exit 1
    fi

    if [[ ! -f "$team_file" ]]; then
        error "No team state for stage: $stage"
        exit 1
    fi

    local team_json
    team_json=$(cat "$team_file")

    # Collect task results from all specialists
    local results="[]"
    local success_count=0
    local failure_count=0

    local tasks
    tasks=$(echo "$team_json" | jq -r '.tasks[]? // empty' 2>/dev/null)

    while IFS= read -r task_line; do
        [[ -z "$task_line" ]] && continue
        local result
        result=$(echo "$task_line" | jq -r '.result? // empty' 2>/dev/null)

        if [[ -n "$result" ]]; then
            if echo "$result" | jq -e '.success' >/dev/null 2>&1; then
                ((success_count++))
            else
                ((failure_count++))
            fi
            results=$(echo "$results" | jq ". += [$result]")
        fi
    done < <(echo "$tasks" | jq -c '.[]')

    # Build aggregated output
    local aggregated
    aggregated=$(jq -n \
        --arg stage "$stage" \
        --argjson results "$results" \
        --argjson success_count "$success_count" \
        --argjson failure_count "$failure_count" \
        '{
            stage: $stage,
            task_count: ($results | length),
            success_count: $success_count,
            failure_count: $failure_count,
            success_rate: (if ($results | length) > 0 then ($success_count / ($results | length) * 100) | floor else 0 end),
            results: $results,
            aggregated_at: "'$(now_iso)'"
        }')

    echo "$aggregated"

    emit_event "results_aggregated" \
        "stage=$stage" \
        "task_count=$(echo "$aggregated" | jq -r '.task_count')" \
        "success_rate=$(echo "$aggregated" | jq -r '.success_rate')"
}

# ─── Roles: List available roles and their descriptions ──────────────────────
cmd_roles() {
    echo ""
    echo -e "  ${BOLD}${CYAN}Available Roles${RESET}"
    echo -e "  ${DIM}═══════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${CYAN}builder${RESET}"
    echo "    $(declare_role builder)"
    echo ""
    echo -e "  ${CYAN}reviewer${RESET}"
    echo "    $(declare_role reviewer)"
    echo ""
    echo -e "  ${CYAN}tester${RESET}"
    echo "    $(declare_role tester)"
    echo ""
    echo -e "  ${CYAN}security${RESET}"
    echo "    $(declare_role security)"
    echo ""
    echo -e "  ${CYAN}docs${RESET}"
    echo "    $(declare_role docs)"
    echo ""
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Shipwright Team Stages${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "  ${DIM}════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright team-stages <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}compose${RESET} <stage> [complexity]     Generate team for a stage"
    echo -e "    ${CYAN}delegate${RESET} <stage> [complexity]    Break stage into agent tasks"
    echo -e "    ${CYAN}status${RESET} [stage]                   Show team member status"
    echo -e "    ${CYAN}vote${RESET} <stage>                     Collect and tally review votes"
    echo -e "    ${CYAN}aggregate${RESET} <stage>                Combine agent outputs into stage result"
    echo -e "    ${CYAN}roles${RESET}                             List available roles and descriptions"
    echo -e "    ${CYAN}help${RESET}                              Show this help message"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}# Compose a team for the build stage${RESET}"
    echo -e "    shipwright team-stages compose build medium"
    echo ""
    echo -e "    ${DIM}# Delegate build stage into parallel tasks${RESET}"
    echo -e "    shipwright team-stages delegate build medium"
    echo ""
    echo -e "    ${DIM}# Show status of all active teams${RESET}"
    echo -e "    shipwright team-stages status"
    echo ""
    echo -e "    ${DIM}# Tally votes from review team${RESET}"
    echo -e "    shipwright team-stages vote review"
    echo ""
    echo -e "    ${DIM}# Combine results from all agents${RESET}"
    echo -e "    shipwright team-stages aggregate build"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        compose)
            cmd_compose "$@"
            ;;
        delegate)
            cmd_delegate "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        vote)
            cmd_vote "$@"
            ;;
        aggregate)
            cmd_aggregate "$@"
            ;;
        roles)
            cmd_roles
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
