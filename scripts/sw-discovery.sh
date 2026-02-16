#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright discovery — Cross-Pipeline Real-Time Learning                ║
# ║  Enables knowledge sharing between concurrent pipelines via discovery     ║
# ║  channel: broadcast, query, inject, clean, status                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.2"
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

# ─── Discovery Storage ──────────────────────────────────────────────────────
DISCOVERIES_FILE="${HOME}/.shipwright/discoveries.jsonl"
DISCOVERIES_DIR="${HOME}/.shipwright/discoveries"
DISCOVERY_TTL_SECS=$((24 * 60 * 60))  # 24 hours default

ensure_discoveries_dir() {
    mkdir -p "$DISCOVERIES_DIR"
}

get_seen_file() {
    local pipeline_id="$1"
    echo "${DISCOVERIES_DIR}/seen-${pipeline_id}.json"
}

# ─── Discovery Functions ───────────────────────────────────────────────────

# broadcast: write a new discovery event
broadcast_discovery() {
    local category="$1"
    local file_patterns="$2"
    local discovery_text="$3"
    local resolution="${4:-}"

    ensure_discoveries_dir

    local pipeline_id="${SHIPWRIGHT_PIPELINE_ID:-unknown}"

    # Use jq to build compact JSON (single line)
    local entry
    entry=$(jq -cn \
        --arg ts "$(now_iso)" \
        --argjson ts_epoch "$(now_epoch)" \
        --arg pipeline_id "$pipeline_id" \
        --arg category "$category" \
        --arg file_patterns "$file_patterns" \
        --arg discovery "$discovery_text" \
        --arg resolution "$resolution" \
        '{ts: $ts, ts_epoch: $ts_epoch, pipeline_id: $pipeline_id, category: $category, file_patterns: $file_patterns, discovery: $discovery, resolution: $resolution}')

    echo "$entry" >> "$DISCOVERIES_FILE"
    success "Broadcast discovery: ${category} (${file_patterns})"
}

# query: find relevant discoveries for given file patterns
query_discoveries() {
    local file_patterns="$1"
    local limit="${2:-10}"

    ensure_discoveries_dir

    [[ ! -f "$DISCOVERIES_FILE" ]] && {
        info "No discoveries yet"
        return 0
    }

    local count=0
    local found=false

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local disc_patterns
        disc_patterns=$(echo "$line" | jq -r '.file_patterns // ""' 2>/dev/null || echo "")

        # Check if patterns overlap
        if patterns_overlap "$file_patterns" "$disc_patterns"; then
            if [[ "$found" == "false" ]]; then
                success "Found relevant discoveries:"
                found=true
            fi

            local category discovery
            category=$(echo "$line" | jq -r '.category' 2>/dev/null || echo "?")
            discovery=$(echo "$line" | jq -r '.discovery' 2>/dev/null || echo "?")

            echo -e "  ${DIM}→${RESET} [${category}] ${discovery} [${disc_patterns}]"

            ((count++))
            [[ "$count" -ge "$limit" ]] && break
        fi
    done < "$DISCOVERIES_FILE"

    if [[ "$found" == "false" ]]; then
        info "No relevant discoveries found for patterns: ${file_patterns}"
    fi
}

# inject: return discoveries for current pipeline that haven't been seen
inject_discoveries() {
    local file_patterns="$1"
    local pipeline_id="${SHIPWRIGHT_PIPELINE_ID:-unknown}"

    ensure_discoveries_dir

    [[ ! -f "$DISCOVERIES_FILE" ]] && {
        info "No discoveries available"
        return 0
    }

    local seen_file
    seen_file=$(get_seen_file "$pipeline_id")

    # Find relevant discoveries not yet seen
    local new_count=0
    local injected_entries=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ts_epoch
        ts_epoch=$(echo "$line" | jq -r '.ts_epoch' 2>/dev/null || echo "0")

        # Skip if already seen
        if [[ -f "$seen_file" ]]; then
            if jq -e ".seen | contains([${ts_epoch}])" "$seen_file" 2>/dev/null | grep -q "true"; then
                continue
            fi
        fi

        # Check if relevant to current file patterns
        local disc_patterns
        disc_patterns=$(echo "$line" | jq -r '.file_patterns // ""' 2>/dev/null || echo "")

        if [[ -n "$disc_patterns" ]] && patterns_overlap "$file_patterns" "$disc_patterns"; then
            injected_entries+=("$line")
            ((new_count++))
        fi
    done < "$DISCOVERIES_FILE"

    if [[ "$new_count" -eq 0 ]]; then
        info "No new discoveries to inject"
        return 0
    fi

    # Update seen set
    local new_seen
    new_seen="{\"seen\":["

    local first=true

    # Add previously seen entries
    if [[ -f "$seen_file" ]]; then
        while IFS= read -r ts; do
            [[ -z "$ts" ]] && continue
            [[ "$first" == "false" ]] && new_seen="${new_seen},"
            new_seen="${new_seen}${ts}"
            first=false
        done < <(jq -r '.seen[]? // empty' "$seen_file" 2>/dev/null || true)
    fi

    # Add newly seen entries
    for entry in "${injected_entries[@]}"; do
        local ts_epoch
        ts_epoch=$(echo "$entry" | jq -r '.ts_epoch' 2>/dev/null || echo "0")
        [[ "$first" == "false" ]] && new_seen="${new_seen},"
        new_seen="${new_seen}${ts_epoch}"
        first=false
    done

    new_seen="${new_seen}]}"

    # Atomic write
    local tmp_seen
    tmp_seen=$(mktemp)
    echo "$new_seen" > "$tmp_seen"
    mv "$tmp_seen" "$seen_file"

    success "Injected ${new_count} new discoveries"

    # Output for injection into pipeline
    for entry in "${injected_entries[@]}"; do
        echo "$entry" | jq -r '"[\(.category)] \(.discovery) — Resolution: \(.resolution)"' 2>/dev/null || true
    done
}

# patterns_overlap: check if two comma-separated patterns overlap
patterns_overlap() {
    local patterns1="$1"
    local patterns2="$2"

    # Simple glob matching: check if any pattern from p1 matches any from p2
    # Use bash filename expansion or simple substring matching
    local p1 p2

    IFS=',' read -ra p1_arr <<< "$patterns1"
    IFS=',' read -ra p2_arr <<< "$patterns2"

    for p1 in "${p1_arr[@]}"; do
        p1="${p1// /}"  # trim spaces
        [[ -z "$p1" ]] && continue

        for p2 in "${p2_arr[@]}"; do
            p2="${p2// /}"  # trim spaces
            [[ -z "$p2" ]] && continue

            # Simple substring overlap check: if removing glob chars, do they share directory structure?
            local p1_base="${p1%/*}"  # get directory part
            local p2_base="${p2%/*}"

            # Check if patterns refer to same or overlapping directory trees
            if [[ "$p1_base" == "$p2_base" ]] || [[ "$p1_base" == "$p2"* ]] || [[ "$p2_base" == "$p1"* ]]; then
                return 0
            fi

            # Also check if exact patterns match
            if [[ "$p1" == "$p2" ]]; then
                return 0
            fi
        done
    done

    return 1
}

# clean: remove stale discoveries (older than TTL)
clean_discoveries() {
    local ttl="${1:-$DISCOVERY_TTL_SECS}"

    [[ ! -f "$DISCOVERIES_FILE" ]] && {
        info "No discoveries to clean"
        return 0
    }

    local now
    now=$(now_epoch)
    local cutoff=$((now - ttl))

    local tmp_file
    tmp_file=$(mktemp)
    local removed_count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ts_epoch
        ts_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || echo "0")

        if [[ "$ts_epoch" -ge "$cutoff" ]]; then
            echo "$line" >> "$tmp_file"
        else
            ((removed_count++))
        fi
    done < "$DISCOVERIES_FILE"

    # Atomic replace
    [[ -s "$tmp_file" ]] && mv "$tmp_file" "$DISCOVERIES_FILE" || rm -f "$tmp_file"

    if [[ "$removed_count" -gt 0 ]]; then
        success "Cleaned ${removed_count} stale discoveries (older than ${ttl}s)"
    else
        info "No stale discoveries to clean"
    fi
}

# status: show discovery channel stats
show_status() {
    info "Discovery Channel Status"
    echo ""

    local total=0
    local oldest=""
    local newest=""

    if [[ -f "$DISCOVERIES_FILE" ]]; then
        total=$(wc -l < "$DISCOVERIES_FILE")

        # Get oldest and newest timestamps
        oldest=$(jq -s 'min_by(.ts_epoch) | .ts' "$DISCOVERIES_FILE" 2>/dev/null || echo "N/A")
        newest=$(jq -s 'max_by(.ts_epoch) | .ts' "$DISCOVERIES_FILE" 2>/dev/null || echo "N/A")
    fi

    echo -e "  ${CYAN}Total discoveries:${RESET} ${total}"
    echo -e "  ${CYAN}Oldest:${RESET} ${oldest}"
    echo -e "  ${CYAN}Newest:${RESET} ${newest}"
    echo ""

    # Count by category
    if [[ -f "$DISCOVERIES_FILE" ]]; then
        echo -e "  ${CYAN}By category:${RESET}"
        jq -s 'group_by(.category) | map({category: .[0].category, count: length}) | .[]' \
            "$DISCOVERIES_FILE" 2>/dev/null | \
            jq -r '"    \(.category): \(.count)"' 2>/dev/null | sort || true
    fi

    echo ""
    echo -e "  ${CYAN}Storage:${RESET} ${DISCOVERIES_FILE}"
    [[ -f "$DISCOVERIES_FILE" ]] && echo -e "  ${CYAN}Size:${RESET} $(du -h "$DISCOVERIES_FILE" | cut -f1)"
}

# show_help: display usage
show_help() {
    echo -e "${CYAN}${BOLD}shipwright discovery${RESET} — Cross-Pipeline Real-Time Learning"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright discovery${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}broadcast${RESET} <category> <patterns> <text> [resolution]"
    echo -e "    Write a new discovery event to the shared channel"
    echo ""
    echo -e "  ${CYAN}query${RESET} <patterns> [limit]"
    echo -e "    Find discoveries relevant to file patterns"
    echo ""
    echo -e "  ${CYAN}inject${RESET} <patterns>"
    echo -e "    Inject new discoveries for this pipeline (tracks seen set)"
    echo ""
    echo -e "  ${CYAN}clean${RESET} [ttl-seconds]"
    echo -e "    Remove stale discoveries (default: 86400s = 24h)"
    echo ""
    echo -e "  ${CYAN}status${RESET}"
    echo -e "    Show discovery channel statistics and health"
    echo ""
    echo -e "  ${CYAN}help${RESET}"
    echo -e "    Show this help message"
    echo ""
    echo -e "${BOLD}ENVIRONMENT${RESET}"
    echo -e "  ${DIM}SHIPWRIGHT_PIPELINE_ID${RESET}      Current pipeline ID (auto-tracked in seen set)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright discovery broadcast \"auth-fix\" \"src/auth/*.ts\" \"JWT validation failure resolved\" \"Added claim verification\"${RESET}"
    echo -e "  ${DIM}shipwright discovery query \"src/**/*.js,src/**/*.ts\" 5${RESET}"
    echo -e "  ${DIM}shipwright discovery inject \"src/api/**\" 2>&1 | xargs -I {} echo \"Learning: {}\"${RESET}"
    echo -e "  ${DIM}shipwright discovery clean 172800${RESET}              # Remove discoveries older than 48h"
    echo -e "  ${DIM}shipwright discovery status${RESET}"
}

# ─── Main ────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        broadcast)
            [[ $# -lt 3 ]] && {
                error "broadcast requires: category, patterns, text [, resolution]"
                exit 1
            }
            broadcast_discovery "$1" "$2" "$3" "${4:-}"
            ;;
        query)
            [[ $# -lt 1 ]] && {
                error "query requires: patterns [limit]"
                exit 1
            }
            query_discoveries "$1" "${2:-10}"
            ;;
        inject)
            [[ $# -lt 1 ]] && {
                error "inject requires: patterns"
                exit 1
            }
            inject_discoveries "$1"
            ;;
        clean)
            clean_discoveries "${1:-$DISCOVERY_TTL_SECS}"
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
