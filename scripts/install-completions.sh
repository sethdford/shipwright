#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Shell completion installer                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPLETIONS_DIR="$(cd "$SCRIPT_DIR/../completions" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"

case "$SHELL_NAME" in
    bash)
        DEST="${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions}"
        mkdir -p "$DEST"
        cp "$COMPLETIONS_DIR/shipwright.bash" "$DEST/shipwright"
        cp "$COMPLETIONS_DIR/shipwright.bash" "$DEST/sw"
        cp "$COMPLETIONS_DIR/shipwright.bash" "$DEST/cct"
        success "Installed bash completions to $DEST"
        info "Restart your shell or run: ${DIM}source $DEST/shipwright${RESET}"
        ;;
    zsh)
        # Prefer ~/.zfunc if it exists; otherwise create it
        DEST="${HOME}/.zfunc"
        mkdir -p "$DEST"
        cp "$COMPLETIONS_DIR/_shipwright" "$DEST/_shipwright"
        cp "$COMPLETIONS_DIR/_shipwright" "$DEST/_sw"
        cp "$COMPLETIONS_DIR/_shipwright" "$DEST/_cct"
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
        cp "$COMPLETIONS_DIR/shipwright.fish" "$DEST/cct.fish"
        success "Installed fish completions to $DEST"
        info "Completions are available immediately in new fish shells"
        ;;
    *)
        error "Unsupported shell: $SHELL_NAME"
        info "Manually install completions from: $COMPLETIONS_DIR"
        exit 1
        ;;
esac
