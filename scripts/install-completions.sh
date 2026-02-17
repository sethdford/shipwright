#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Shell completion installer                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPLETIONS_DIR="$(cd "$SCRIPT_DIR/../completions" && pwd)"

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

SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"

case "$SHELL_NAME" in
    bash)
        DEST="${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions}"
        mkdir -p "$DEST"
        cp "$COMPLETIONS_DIR/shipwright.bash" "$DEST/shipwright"
        cp "$COMPLETIONS_DIR/shipwright.bash" "$DEST/sw"
        success "Installed bash completions to $DEST"
        info "Restart your shell or run: ${DIM}source $DEST/shipwright${RESET}"
        ;;
    zsh)
        # Prefer ~/.zfunc if it exists; otherwise create it
        DEST="${HOME}/.zfunc"
        mkdir -p "$DEST"
        cp "$COMPLETIONS_DIR/_shipwright" "$DEST/_shipwright"
        cp "$COMPLETIONS_DIR/_shipwright" "$DEST/_sw"
        success "Installed zsh completions to $DEST"
        if ! echo "$FPATH" | tr ':' '\n' | grep -q "$DEST"; then
            warn "$DEST is not in your fpath"
            info "Add to ~/.zshrc: ${DIM}fpath=(~/.zfunc \$fpath) && autoload -Uz compinit && compinit${RESET}"
        else
            info "Run ${DIM}compinit${RESET} or restart your shell to activate"
        fi
        ;;
    fish)
        DEST="${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions"
        mkdir -p "$DEST"
        cp "$COMPLETIONS_DIR/shipwright.fish" "$DEST/shipwright.fish"
        cp "$COMPLETIONS_DIR/shipwright.fish" "$DEST/sw.fish"
        success "Installed fish completions to $DEST"
        info "Completions are available immediately in new fish shells"
        ;;
    *)
        error "Unsupported shell: $SHELL_NAME"
        info "Manually install completions from: $COMPLETIONS_DIR"
        exit 1
        ;;
esac
