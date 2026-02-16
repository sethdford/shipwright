#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-checkpoint.sh — Save and restore agent state mid-stage             ║
# ║                                                                          ║
# ║  Checkpoints capture enough state to resume a pipeline stage without    ║
# ║  restarting from scratch.                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Checkpoint Directory ───────────────────────────────────────────────────
CHECKPOINT_DIR=".claude/pipeline-artifacts/checkpoints"

ensure_checkpoint_dir() {
    mkdir -p "$CHECKPOINT_DIR"
}

checkpoint_file() {
    local stage="$1"
    echo "${CHECKPOINT_DIR}/${stage}-checkpoint.json"
}

# ─── Save ────────────────────────────────────────────────────────────────────

cmd_save() {
    local stage=""
    local iteration=""
    local git_sha=""
    local files_modified=""
    local tests_passing="false"
    local loop_state=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage)
                stage="${2:-}"
                shift 2
                ;;
            --stage=*)
                stage="${1#--stage=}"
                shift
                ;;
            --iteration)
                iteration="${2:-}"
                shift 2
                ;;
            --iteration=*)
                iteration="${1#--iteration=}"
                shift
                ;;
            --git-sha)
                git_sha="${2:-}"
                shift 2
                ;;
            --git-sha=*)
                git_sha="${1#--git-sha=}"
                shift
                ;;
            --files-modified)
                files_modified="${2:-}"
                shift 2
                ;;
            --files-modified=*)
                files_modified="${1#--files-modified=}"
                shift
                ;;
            --tests-passing)
                tests_passing="true"
                shift
                ;;
            --loop-state)
                loop_state="${2:-}"
                shift 2
                ;;
            --loop-state=*)
                loop_state="${1#--loop-state=}"
                shift
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -z "$stage" ]]; then
        error "Missing required --stage"
        echo ""
        show_help
        return 1
    fi

    # Default git sha from HEAD if not provided
    if [[ -z "$git_sha" ]]; then
        git_sha="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"
    fi

    ensure_checkpoint_dir

    # Build files_modified JSON array from comma-separated string
    local files_json="[]"
    if [[ -n "$files_modified" ]]; then
        files_json="$(echo "$files_modified" | tr ',' '\n' | jq -R . | jq -s .)"
    fi

    # Build checkpoint JSON with jq for proper escaping
    local tmp_file
    tmp_file="$(mktemp)"

    jq -n \
        --arg stage "$stage" \
        --arg iteration "${iteration:-0}" \
        --argjson files_modified "$files_json" \
        --arg tests_passing "$tests_passing" \
        --arg git_sha "$git_sha" \
        --arg loop_state "${loop_state:-}" \
        --arg created_at "$(now_iso)" \
        '{
            stage: $stage,
            iteration: ($iteration | tonumber),
            files_modified: $files_modified,
            tests_passing: ($tests_passing == "true"),
            git_sha: $git_sha,
            loop_state: $loop_state,
            created_at: $created_at
        }' > "$tmp_file"

    # Atomic write
    local target
    target="$(checkpoint_file "$stage")"
    mv "$tmp_file" "$target"

    success "Checkpoint saved for stage ${BOLD}${stage}${RESET} (iteration ${iteration:-0})"
}

# ─── Restore ─────────────────────────────────────────────────────────────────

cmd_restore() {
    local stage=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage)
                stage="${2:-}"
                shift 2
                ;;
            --stage=*)
                stage="${1#--stage=}"
                shift
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -z "$stage" ]]; then
        error "Missing required --stage"
        return 1
    fi

    local target
    target="$(checkpoint_file "$stage")"

    if [[ ! -f "$target" ]]; then
        return 1
    fi

    if ! jq empty "$target" 2>/dev/null; then
        warn "Corrupt checkpoint for stage: $(basename "$target")"
        return 1
    fi

    cat "$target"
    return 0
}

# ─── List ────────────────────────────────────────────────────────────────────

cmd_list() {
    echo ""
    echo -e "${CYAN}${BOLD}  Checkpoints${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    if [[ ! -d "$CHECKPOINT_DIR" ]]; then
        echo -e "  ${DIM}No checkpoints found.${RESET}"
        echo ""
        return 0
    fi

    local count=0
    local file
    for file in "${CHECKPOINT_DIR}"/*-checkpoint.json; do
        # Handle no matches (glob returns literal pattern)
        [[ -f "$file" ]] || continue
        count=$((count + 1))

        local stage iteration git_sha tests_passing loop_state created_at
        stage="$(jq -r '.stage' "$file")"
        iteration="$(jq -r '.iteration' "$file")"
        git_sha="$(jq -r '.git_sha' "$file")"
        tests_passing="$(jq -r '.tests_passing' "$file")"
        loop_state="$(jq -r '.loop_state' "$file")"
        created_at="$(jq -r '.created_at' "$file")"

        # Format tests indicator
        local tests_icon
        if [[ "$tests_passing" == "true" ]]; then
            tests_icon="${GREEN}✓${RESET}"
        else
            tests_icon="${RED}✗${RESET}"
        fi

        # Format loop state
        local state_display=""
        if [[ -n "$loop_state" && "$loop_state" != "null" ]]; then
            state_display=" ${DIM}state:${RESET}${loop_state}"
        fi

        echo -e "  ${CYAN}●${RESET} ${BOLD}${stage}${RESET}  iter:${iteration}  tests:${tests_icon}  ${DIM}sha:${git_sha:0:7}${RESET}${state_display}"
        echo -e "    ${DIM}${created_at}${RESET}"
    done

    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${DIM}No checkpoints found.${RESET}"
    else
        echo ""
        echo -e "  ${DIM}${count} checkpoint(s)${RESET}"
    fi
    echo ""
}

# ─── Clear ───────────────────────────────────────────────────────────────────

cmd_clear() {
    local stage=""
    local clear_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage)
                stage="${2:-}"
                shift 2
                ;;
            --stage=*)
                stage="${1#--stage=}"
                shift
                ;;
            --all)
                clear_all=true
                shift
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ "$clear_all" == "true" ]]; then
        if [[ -d "$CHECKPOINT_DIR" ]]; then
            local count=0
            local file
            for file in "${CHECKPOINT_DIR}"/*-checkpoint.json; do
                [[ -f "$file" ]] || continue
                rm -f "$file"
                count=$((count + 1))
            done
            success "Cleared ${count} checkpoint(s)"
        else
            info "No checkpoints to clear"
        fi
        return 0
    fi

    if [[ -z "$stage" ]]; then
        error "Missing --stage or --all"
        return 1
    fi

    local target
    target="$(checkpoint_file "$stage")"

    if [[ -f "$target" ]]; then
        rm -f "$target"
        success "Cleared checkpoint for stage ${BOLD}${stage}${RESET}"
    else
        warn "No checkpoint found for stage ${BOLD}${stage}${RESET}"
    fi
}

# ─── Expire ──────────────────────────────────────────────────────────────────

cmd_expire() {
    local max_hours=24

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hours)
                max_hours="${2:-24}"
                shift 2
                ;;
            --hours=*)
                max_hours="${1#--hours=}"
                shift
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ ! -d "$CHECKPOINT_DIR" ]]; then
        return 0
    fi

    local max_secs=$((max_hours * 3600))
    local now_e
    now_e=$(date +%s)
    local expired=0

    local file
    for file in "${CHECKPOINT_DIR}"/*-checkpoint.json; do
        [[ -f "$file" ]] || continue

        # Check created_at from checkpoint JSON
        local created_at
        created_at=$(jq -r '.created_at // empty' "$file" 2>/dev/null || true)

        if [[ -n "$created_at" ]]; then
            # Parse ISO date to epoch
            local file_epoch
            file_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null \
                || date -d "$created_at" +%s 2>/dev/null \
                || echo "0")
            if [[ "$file_epoch" -gt 0 && $((now_e - file_epoch)) -gt $max_secs ]]; then
                local stage_name
                stage_name=$(jq -r '.stage // "unknown"' "$file" 2>/dev/null || echo "unknown")
                rm -f "$file"
                expired=$((expired + 1))
                info "Expired: ${stage_name} checkpoint (${max_hours}h+ old)"
            fi
        else
            # Fallback: check file mtime
            local mtime
            mtime=$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo "0")
            if [[ "$mtime" -gt 0 && $((now_e - mtime)) -gt $max_secs ]]; then
                rm -f "$file"
                expired=$((expired + 1))
            fi
        fi
    done

    if [[ "$expired" -gt 0 ]]; then
        success "Expired ${expired} checkpoint(s) older than ${max_hours}h"
    fi
}

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright checkpoint${RESET} ${DIM}v${VERSION}${RESET} — Save and restore agent state mid-stage"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright checkpoint${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}save${RESET}      Save a checkpoint for a stage"
    echo -e "  ${CYAN}restore${RESET}   Restore a checkpoint (prints JSON to stdout)"
    echo -e "  ${CYAN}list${RESET}      Show all available checkpoints"
    echo -e "  ${CYAN}clear${RESET}     Remove checkpoint(s)"
    echo -e "  ${CYAN}expire${RESET}    Remove checkpoints older than N hours"
    echo ""
    echo -e "${BOLD}SAVE OPTIONS${RESET}"
    echo -e "  ${CYAN}--stage${RESET} <name>              Stage name (required)"
    echo -e "  ${CYAN}--iteration${RESET} <n>             Current iteration number"
    echo -e "  ${CYAN}--git-sha${RESET} <sha>             Git commit SHA (default: HEAD)"
    echo -e "  ${CYAN}--files-modified${RESET} \"f1,f2\"    Comma-separated list of modified files"
    echo -e "  ${CYAN}--tests-passing${RESET}             Mark tests as passing"
    echo -e "  ${CYAN}--loop-state${RESET} <state>        Loop state (running, paused, etc.)"
    echo ""
    echo -e "${BOLD}RESTORE OPTIONS${RESET}"
    echo -e "  ${CYAN}--stage${RESET} <name>              Stage to restore (required)"
    echo ""
    echo -e "${BOLD}CLEAR OPTIONS${RESET}"
    echo -e "  ${CYAN}--stage${RESET} <name>              Stage to clear"
    echo -e "  ${CYAN}--all${RESET}                       Clear all checkpoints"
    echo ""
    echo -e "${BOLD}EXPIRE OPTIONS${RESET}"
    echo -e "  ${CYAN}--hours${RESET} <n>                 Max age in hours (default: 24)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright checkpoint save --stage build --iteration 5${RESET}"
    echo -e "  ${DIM}shipwright checkpoint save --stage build --iteration 3 --tests-passing --files-modified \"src/auth.ts,src/middleware.ts\"${RESET}"
    echo -e "  ${DIM}shipwright checkpoint restore --stage build${RESET}"
    echo -e "  ${DIM}shipwright checkpoint list${RESET}"
    echo -e "  ${DIM}shipwright checkpoint clear --stage build${RESET}"
    echo -e "  ${DIM}shipwright checkpoint clear --all${RESET}"
    echo -e "  ${DIM}shipwright checkpoint expire --hours 48${RESET}"
}

# ─── Command Router ─────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        save)       cmd_save "$@" ;;
        restore)    cmd_restore "$@" ;;
        list)       cmd_list ;;
        clear)      cmd_clear "$@" ;;
        expire)     cmd_expire "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
