#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright memory — Persistent Learning & Context System                     ║
# ║  Captures learnings · Injects context · Searches memory · Tracks metrics║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

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
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Database (for dual-write memory to DB) ───────────────────────────────────
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"

# ─── Intelligence Engine (optional) ──────────────────────────────────────────
# shellcheck source=sw-intelligence.sh
[[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]] && source "$SCRIPT_DIR/sw-intelligence.sh"

# ─── Memory Effectiveness Tracker ──────────────────────────────────────────
# shellcheck source=lib/memory-effectiveness.sh
[[ -f "$SCRIPT_DIR/lib/memory-effectiveness.sh" ]] && source "$SCRIPT_DIR/lib/memory-effectiveness.sh"

# ─── Memory modules (load order matters: common → capture → query → aggregate → admin)
_MEMORY_LIB_DIR="$SCRIPT_DIR/lib"
for _mem_mod in memory-common memory-capture memory-query memory-aggregate memory-admin; do
    if [[ ! -f "$_MEMORY_LIB_DIR/${_mem_mod}.sh" ]]; then
        echo "ERROR: shipwright memory: missing module lib/${_mem_mod}.sh — reinstall or run 'shipwright upgrade --apply'" >&2
        return 1 2>/dev/null || exit 1
    fi
    # shellcheck source=/dev/null
    source "$_MEMORY_LIB_DIR/${_mem_mod}.sh"
done
unset _mem_mod

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright memory${RESET} ${DIM}v${VERSION}${RESET} — Persistent Learning & Context System"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright memory${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show${RESET}               Display memory for current repo"
    echo -e "  ${CYAN}show${RESET} --global       Display cross-repo learnings"
    echo -e "  ${CYAN}search${RESET} <keyword>    Search memory for keyword"
    echo -e "  ${CYAN}search${RESET} --semantic <query>  Semantic search via memory_embeddings"
    echo -e "  ${CYAN}forget${RESET} --all         Clear memory for current repo"
    echo -e "  ${CYAN}export${RESET}              Export memory as JSON"
    echo -e "  ${CYAN}import${RESET} <file>        Import memory from JSON"
    echo -e "  ${CYAN}stats${RESET}               Show memory size, age, hit rate"
    echo ""
    echo -e "${BOLD}PIPELINE INTEGRATION${RESET}"
    echo -e "  ${CYAN}capture${RESET} <state> <artifacts>    Capture pipeline learnings"
    echo -e "  ${CYAN}inject${RESET} <stage_id>              Inject context for a stage"
    echo -e "  ${CYAN}pattern${RESET} <type> [data]           Record a codebase pattern"
    echo -e "  ${CYAN}metric${RESET} <name> <value>           Update a performance baseline"
    echo -e "  ${CYAN}decision${RESET} <type> <summary>       Record a design decision"
    echo -e "  ${CYAN}analyze-failure${RESET} <log> <stage>    Analyze failure root cause via AI"
    echo -e "  ${CYAN}fix-outcome${RESET} <pattern> <applied> <resolved>  Record fix effectiveness"
    echo -e "  ${CYAN}ab-report${RESET}                      Compare control vs treatment in A/B tests"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright memory show${RESET}                            # View repo memory"
    echo -e "  ${DIM}shipwright memory show --global${RESET}                   # View cross-repo learnings"
    echo -e "  ${DIM}shipwright memory search \"auth\"${RESET}                   # Find auth-related memories"
    echo -e "  ${DIM}shipwright memory export > backup.json${RESET}            # Export memory"
    echo -e "  ${DIM}shipwright memory import backup.json${RESET}              # Import memory"
    echo -e "  ${DIM}shipwright memory capture .claude/pipeline-state.md .claude/pipeline-artifacts${RESET}"
    echo -e "  ${DIM}shipwright memory inject build${RESET}                    # Get context for build stage"
}

# ─── Command Router ─────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    SUBCOMMAND="${1:-help}"
    shift 2>/dev/null || true

    case "$SUBCOMMAND" in
        show)
            memory_show "$@"
            ;;
        search)
            memory_search "$@"
            ;;
        forget)
            memory_forget "$@"
            ;;
        export)
            memory_export
            ;;
        import)
            memory_import "$@"
            ;;
        stats)
            memory_stats
            ;;
        capture)
            memory_capture_pipeline "$@"
            ;;
        inject)
            memory_inject_context "$@"
            ;;
        pattern)
            memory_capture_pattern "$@"
            ;;
        get)
            memory_get_baseline "$@"
            ;;
        metric)
            memory_update_metrics "$@"
            ;;
        decision)
            memory_capture_decision "$@"
            ;;
        analyze-failure)
            memory_analyze_failure "$@"
            ;;
        fix-outcome)
            memory_record_fix_outcome "$@"
            ;;
        search-weighted)
            memory_search_weighted "$@"
            ;;
        decay)
            memory_decay_old "$@"
            ;;
        ab-report)
            cmd_memory_ab_report "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${SUBCOMMAND}"
            echo ""
            show_help
            exit 1
            ;;
    esac
fi
