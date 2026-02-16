#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright worktree — Git worktree management for multi-agent isolation       ║
# ║                                                                          ║
# ║  Each agent gets its own worktree so parallel agents don't clobber       ║
# ║  each other's files. Worktrees live in .worktrees/ relative to root.    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.2.2"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Repo root ─────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    error "Not inside a git repository."
    exit 1
}

WORKTREE_DIR="$REPO_ROOT/.worktrees"

# ─── .gitignore helper ────────────────────────────────────────────────────
ensure_gitignore() {
    local gitignore="$REPO_ROOT/.gitignore"
    if ! grep -q '^\.worktrees/' "$gitignore" 2>/dev/null; then
        echo ".worktrees/" >> "$gitignore"
        info "Added .worktrees/ to .gitignore"
    fi
}

# ─── Commands ──────────────────────────────────────────────────────────────

worktree_create() {
    local name="$1"
    local branch="${2:-loop/$name}"
    local worktree_path="$WORKTREE_DIR/$name"

    if [[ -d "$worktree_path" ]]; then
        warn "Worktree '$name' already exists at $worktree_path"
        return 0
    fi

    ensure_gitignore
    mkdir -p "$WORKTREE_DIR"

    # Create branch from current HEAD if it doesn't exist
    git branch "$branch" HEAD 2>/dev/null || true

    # Create worktree
    git worktree add "$worktree_path" "$branch"

    success "Created worktree: ${BOLD}$name${RESET} → $worktree_path ${DIM}(branch: $branch)${RESET}"
}

worktree_list() {
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        echo -e "  ${DIM}No worktrees found.${RESET}"
        return 0
    fi

    local found=0
    echo ""
    echo -e "${BOLD}AGENT WORKTREES${RESET}"
    echo -e "${DIM}───────────────────────────────────────────────────────────────${RESET}"

    for dir in "$WORKTREE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"
        local branch="loop/$name"
        local main_branch
        main_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

        local ahead behind
        ahead="$(git rev-list "$main_branch".."$branch" --count 2>/dev/null || echo "?")"
        behind="$(git rev-list "$branch".."$main_branch" --count 2>/dev/null || echo "?")"

        local status_str=""
        if [[ "$ahead" != "?" && "$behind" != "?" ]]; then
            if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
                status_str="${GREEN}${ahead} ahead${RESET}, ${YELLOW}${behind} behind${RESET}"
            elif [[ "$ahead" -gt 0 ]]; then
                status_str="${GREEN}${ahead} ahead${RESET}"
            elif [[ "$behind" -gt 0 ]]; then
                status_str="${YELLOW}${behind} behind${RESET}"
            else
                status_str="${DIM}up to date${RESET}"
            fi
        else
            status_str="${DIM}?${RESET}"
        fi

        printf "  ${CYAN}%-16s${RESET} ${PURPLE}%-22s${RESET} %b  ${DIM}.worktrees/%s/${RESET}\n" \
            "$name" "$branch" "$status_str" "$name"
        ((found++))
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${DIM}No worktrees found.${RESET}"
    fi
    echo ""
}

worktree_sync() {
    local name="$1"
    local worktree_path="$WORKTREE_DIR/$name"

    if [[ ! -d "$worktree_path" ]]; then
        error "Worktree '$name' does not exist."
        return 1
    fi

    info "Syncing ${BOLD}$name${RESET} with main..."

    (
        cd "$worktree_path"
        git fetch origin main 2>/dev/null || true
        git merge origin/main --no-edit 2>/dev/null || {
            warn "Merge conflict in $name — resolve manually in $worktree_path"
            return 1
        }
    )

    success "Synced $name with latest main"
}

worktree_sync_all() {
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        warn "No worktrees found."
        return 0
    fi

    local count=0
    local failed=0

    for dir in "$WORKTREE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"
        worktree_sync "$name" || ((failed++))
        ((count++))
    done

    echo ""
    if [[ $failed -gt 0 ]]; then
        warn "Synced $count worktrees, $failed had conflicts"
    else
        success "Synced $count worktrees"
    fi
}

worktree_merge() {
    local name="$1"
    local branch="loop/$name"
    local current_branch
    current_branch="$(git branch --show-current)"

    if ! git rev-parse --verify "$branch" &>/dev/null; then
        error "Branch '$branch' does not exist."
        return 1
    fi

    info "Merging ${BOLD}$branch${RESET} into ${BOLD}$current_branch${RESET}..."

    git merge "$branch" --no-edit || {
        error "Merge conflict merging $branch"
        echo -e "  ${DIM}Resolve conflicts, then run: git merge --continue${RESET}"
        return 1
    }

    success "Merged $branch into $current_branch"
}

worktree_merge_all() {
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        warn "No worktrees found."
        return 0
    fi

    local count=0

    for dir in "$WORKTREE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"

        worktree_merge "$name" || {
            error "Stopping merge-all due to conflict in $name"
            echo -e "  ${DIM}Resolve the conflict, then re-run: shipwright worktree merge-all${RESET}"
            return 1
        }
        ((count++))
    done

    echo ""
    success "Merged $count worktree branches"
}

worktree_remove() {
    local name="$1"
    local worktree_path="$WORKTREE_DIR/$name"
    local branch="loop/$name"

    if [[ -d "$worktree_path" ]]; then
        git worktree remove "$worktree_path" --force 2>/dev/null || {
            warn "Could not cleanly remove worktree $name, forcing..."
            rm -rf "$worktree_path"
            git worktree prune 2>/dev/null || true
        }
    fi

    git branch -D "$branch" 2>/dev/null || true

    success "Removed worktree: ${BOLD}$name${RESET}"
}

worktree_cleanup() {
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        success "Nothing to clean up — no .worktrees/ directory."
        return 0
    fi

    local count=0

    for dir in "$WORKTREE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"
        worktree_remove "$name"
        ((count++))
    done

    # Prune stale worktree references
    git worktree prune

    # Remove .worktrees directory if empty
    rmdir "$WORKTREE_DIR" 2>/dev/null || true

    echo ""
    success "Cleaned up $count worktrees"
}

worktree_status() {
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        echo -e "  ${DIM}No worktrees found.${RESET}"
        return 0
    fi

    local main_branch
    main_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
    local found=0

    echo ""
    echo -e "${BOLD}WORKTREE STATUS${RESET}  ${DIM}(relative to ${main_branch})${RESET}"
    echo -e "${DIM}───────────────────────────────────────────────────────────────${RESET}"

    for dir in "$WORKTREE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"
        local branch="loop/$name"

        local ahead behind
        ahead="$(git rev-list "$main_branch".."$branch" --count 2>/dev/null || echo "?")"
        behind="$(git rev-list "$branch".."$main_branch" --count 2>/dev/null || echo "?")"

        # Check for uncommitted changes in the worktree
        local dirty=""
        if (cd "$dir" && [[ -n "$(git status --porcelain 2>/dev/null)" ]]); then
            dirty=" ${RED}(dirty)${RESET}"
        fi

        printf "  ${CYAN}%-16s${RESET} ${PURPLE}%-22s${RESET} ${GREEN}%s ahead${RESET}, ${YELLOW}%s behind${RESET}%b\n" \
            "$name" "$branch" "$ahead" "$behind" "$dirty"
        ((found++))
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${DIM}No worktrees found.${RESET}"
    fi
    echo ""
}

worktree_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright worktree${RESET} — Git worktree management for multi-agent isolation"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright worktree <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${GREEN}create${RESET} <name> [--branch <branch>]   Create a worktree for an agent"
    echo -e "  ${GREEN}list${RESET}                                  List active agent worktrees"
    echo -e "  ${GREEN}sync${RESET} <name>                           Pull latest main into a worktree"
    echo -e "  ${GREEN}sync-all${RESET}                              Sync all worktrees with main"
    echo -e "  ${GREEN}merge${RESET} <name>                          Merge worktree branch back to main"
    echo -e "  ${GREEN}merge-all${RESET}                             Merge all worktree branches sequentially"
    echo -e "  ${GREEN}remove${RESET} <name>                         Remove a single worktree"
    echo -e "  ${GREEN}cleanup${RESET}                               Remove ALL worktrees and branches"
    echo -e "  ${GREEN}status${RESET}                                Show status of all worktrees"
    echo -e "  ${GREEN}help${RESET}                                  Show this help"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright worktree create agent-1${RESET}            # Create worktree on branch loop/agent-1"
    echo -e "  ${DIM}shipwright worktree create agent-1 --branch feat${RESET}  # Custom branch name"
    echo -e "  ${DIM}shipwright worktree merge-all${RESET}                 # Merge all agent work back to main"
    echo -e "  ${DIM}shipwright worktree cleanup${RESET}                   # Remove all worktrees when done"
    echo ""
    echo -e "${BOLD}DIRECTORY STRUCTURE${RESET}"
    echo -e "  ${DIM}project-root/${RESET}"
    echo -e "  ${DIM}├── .worktrees/           # All agent worktrees${RESET}"
    echo -e "  ${DIM}│   ├── agent-1/          # Full repo copy for agent 1${RESET}"
    echo -e "  ${DIM}│   ├── agent-2/          # Full repo copy for agent 2${RESET}"
    echo -e "  ${DIM}│   └── agent-3/          # Full repo copy for agent 3${RESET}"
    echo -e "  ${DIM}└── .gitignore            # Includes .worktrees/${RESET}"
    echo ""
}

# ─── Main dispatch ─────────────────────────────────────────────────────────

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    create)
        if [[ $# -lt 1 ]]; then
            error "Usage: shipwright worktree create <name> [--branch <branch>]"
            exit 1
        fi
        NAME="$1"
        shift
        BRANCH=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --branch)
                    BRANCH="${2:-}"
                    shift 2 || { error "--branch requires a value"; exit 1; }
                    ;;
                *)
                    error "Unknown option: $1"
                    exit 1
                    ;;
            esac
        done
        if [[ -n "$BRANCH" ]]; then
            worktree_create "$NAME" "$BRANCH"
        else
            worktree_create "$NAME"
        fi
        ;;
    list)
        worktree_list
        ;;
    sync)
        if [[ $# -lt 1 ]]; then
            error "Usage: shipwright worktree sync <name>"
            exit 1
        fi
        worktree_sync "$1"
        ;;
    sync-all)
        worktree_sync_all
        ;;
    merge)
        if [[ $# -lt 1 ]]; then
            error "Usage: shipwright worktree merge <name>"
            exit 1
        fi
        worktree_merge "$1"
        ;;
    merge-all)
        worktree_merge_all
        ;;
    remove)
        if [[ $# -lt 1 ]]; then
            error "Usage: shipwright worktree remove <name>"
            exit 1
        fi
        worktree_remove "$1"
        ;;
    cleanup)
        worktree_cleanup
        ;;
    status)
        worktree_status
        ;;
    help|--help|-h)
        worktree_help
        ;;
    *)
        error "Unknown command: $COMMAND"
        echo -e "  ${DIM}Run 'shipwright worktree help' for usage.${RESET}"
        exit 1
        ;;
esac
