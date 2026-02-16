#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-status.sh — Status bar widgets for tmux                        ║
# ║                                                                         ║
# ║  Called by tmux via #() in status-right. Must be FAST (<100ms).         ║
# ║  Reads pipeline state from .claude/pipeline-state.md and heartbeats    ║
# ║  from ~/.shipwright/heartbeats/. Outputs styled tmux format strings.   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ─── Stage colors (match Shipwright brand palette) ────────────────────────
# Each pipeline stage gets a distinct color for instant visual recognition
stage_color() {
    case "${1:-}" in
        intake)             echo "#71717a" ;;  # muted — gathering
        plan)               echo "#7c3aed" ;;  # purple — thinking
        design)             echo "#7c3aed" ;;  # purple — thinking
        build)              echo "#0066ff" ;;  # blue — working
        test)               echo "#facc15" ;;  # yellow — validating
        review)             echo "#f97316" ;;  # orange — scrutinizing
        compound_quality)   echo "#f97316" ;;  # orange — scrutinizing
        pr)                 echo "#00d4ff" ;;  # cyan — shipping
        merge)              echo "#00d4ff" ;;  # cyan — shipping
        deploy)             echo "#4ade80" ;;  # green — deploying
        validate)           echo "#4ade80" ;;  # green — verifying
        monitor)            echo "#4ade80" ;;  # green — watching
        *)                  echo "#71717a" ;;  # muted fallback
    esac
}

# ─── Stage icons ──────────────────────────────────────────────────────────
stage_icon() {
    case "${1:-}" in
        intake)             echo "◇" ;;
        plan)               echo "◆" ;;
        design)             echo "△" ;;
        build)              echo "⚙" ;;
        test)               echo "⚡" ;;
        review)             echo "◎" ;;
        compound_quality)   echo "◎" ;;
        pr)                 echo "↑" ;;
        merge)              echo "⊕" ;;
        deploy)             echo "▲" ;;
        validate)           echo "✦" ;;
        monitor)            echo "◉" ;;
        *)                  echo "·" ;;
    esac
}

# ─── Pipeline stage widget ────────────────────────────────────────────────
# Reads current pipeline stage from state file, outputs tmux format string
pipeline_widget() {
    local state_file=".claude/pipeline-state.md"

    # Try current directory, then walk up to find repo root
    if [[ ! -f "$state_file" ]]; then
        local dir
        dir="$(pwd)"
        while [[ "$dir" != "/" ]]; do
            if [[ -f "$dir/$state_file" ]]; then
                state_file="$dir/$state_file"
                break
            fi
            dir="$(dirname "$dir")"
        done
    fi

    [[ -f "$state_file" ]] || return 0

    # Extract current stage — look for "Stage:" or "## Stage:" pattern
    local stage=""
    stage="$(grep -iE '^\*?\*?(current )?stage:?\*?\*?' "$state_file" 2>/dev/null | head -1 | sed 's/.*: *//' | tr -d '*' | tr '[:upper:]' '[:lower:]' | tr -d ' ')" || true

    [[ -n "$stage" ]] || return 0

    local color icon
    color="$(stage_color "$stage")"
    icon="$(stage_icon "$stage")"
    local label
    label="$(echo "$stage" | tr '[:lower:]' '[:upper:]')"

    # Output: colored badge with icon
    echo "#[fg=#1e1e32,bg=${color},bold] ${icon} ${label} #[fg=${color},bg=#1a1a2e]"
}

# ─── Agent count widget ──────────────────────────────────────────────────
# Shows number of active agents from heartbeat files
agent_widget() {
    local hb_dir="${HOME}/.shipwright/heartbeats"
    [[ -d "$hb_dir" ]] || return 0

    local now count=0
    now="$(date +%s)"

    for hb in "$hb_dir"/*.json; do
        [[ -f "$hb" ]] || continue
        # Heartbeat is alive if updated within last 60 seconds
        local mtime
        if [[ "$(uname)" == "Darwin" ]]; then
            mtime="$(stat -f %m "$hb" 2>/dev/null || echo 0)"
        else
            mtime="$(stat -c %Y "$hb" 2>/dev/null || echo 0)"
        fi
        if (( now - mtime < 60 )); then
            count=$((count + 1))
        fi
    done

    if [[ $count -gt 0 ]]; then
        echo "#[fg=#1e1e32,bg=#7c3aed,bold] λ${count} #[fg=#7c3aed,bg=#1a1a2e]"
    fi
}

# ─── Dispatch ─────────────────────────────────────────────────────────────
case "${1:-pipeline}" in
    pipeline) pipeline_widget ;;
    agents)   agent_widget ;;
    all)
        # Combine both widgets
        local p a
        p="$(pipeline_widget)"
        a="$(agent_widget)"
        echo "${a}${p}"
        ;;
    *)
        echo ""
        ;;
esac
