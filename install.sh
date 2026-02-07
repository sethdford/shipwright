#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║          Claude Code Teams + tmux — Interactive Installer                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ─── Colors (matching the theme) ────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
BLUE='\033[38;2;0;102;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;34;197;94m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;239;68;68m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── State ──────────────────────────────────────────────────────────────────
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED=()

# ─── Parse args ─────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      echo "Usage: ./install.sh [--dry-run]"
      echo ""
      echo "  --dry-run   Preview actions without making changes"
      exit 0
      ;;
  esac
done

# ─── Helpers ────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}●${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
warn()    { echo -e "${YELLOW}!${RESET} $1"; }
error()   { echo -e "${RED}✗${RESET} $1"; }
dry()     { echo -e "${DIM}[dry-run]${RESET} $1"; }
header()  { echo -e "\n${BOLD}${BLUE}═══${RESET} ${BOLD}$1${RESET} ${BLUE}═══${RESET}"; }

ask() {
  local prompt="$1" default="${2:-y}"
  if [[ "$default" == "y" ]]; then
    echo -en "${PURPLE}?${RESET} $prompt ${DIM}[Y/n]${RESET} "
  else
    echo -en "${PURPLE}?${RESET} $prompt ${DIM}[y/N]${RESET} "
  fi
  read -r answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

run() {
  if $DRY_RUN; then
    dry "$1"
  else
    eval "$2"
  fi
}

# ─── Banner ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}Claude Code Teams + tmux${RESET}                                ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}  ${DIM}Interactive installer${RESET}                                    ${CYAN}║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""

if $DRY_RUN; then
  warn "Dry-run mode — no changes will be made"
  echo ""
fi

# ═════════════════════════════════════════════════════════════════════════════
# PREREQUISITE CHECKS
# ═════════════════════════════════════════════════════════════════════════════
header "Checking prerequisites"

PREREQ_OK=true

# tmux
if command -v tmux &>/dev/null; then
  TMUX_VERSION="$(tmux -V | grep -oE '[0-9]+\.[0-9a-z]+')"
  TMUX_MAJOR="$(echo "$TMUX_VERSION" | cut -d. -f1)"
  TMUX_MINOR="$(echo "$TMUX_VERSION" | cut -d. -f2 | tr -dc '0-9')"
  if [[ "$TMUX_MAJOR" -ge 3 && "$TMUX_MINOR" -ge 2 ]] || [[ "$TMUX_MAJOR" -ge 4 ]]; then
    success "tmux $TMUX_VERSION"
  else
    warn "tmux $TMUX_VERSION (3.2+ recommended)"
  fi
else
  error "tmux not found — install with: brew install tmux"
  PREREQ_OK=false
fi

# Claude Code CLI
if command -v claude &>/dev/null; then
  success "Claude Code CLI"
else
  error "Claude Code CLI not found — install with: npm install -g @anthropic-ai/claude-code"
  PREREQ_OK=false
fi

# Git
if command -v git &>/dev/null; then
  success "git $(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
else
  error "git not found"
  PREREQ_OK=false
fi

# Node.js
if command -v node &>/dev/null; then
  NODE_VERSION="$(node -v | tr -d 'v')"
  NODE_MAJOR="$(echo "$NODE_VERSION" | cut -d. -f1)"
  if [[ "$NODE_MAJOR" -ge 20 ]]; then
    success "Node.js $NODE_VERSION"
  else
    warn "Node.js $NODE_VERSION (20+ recommended)"
  fi
else
  error "Node.js not found — install from https://nodejs.org/"
  PREREQ_OK=false
fi

if ! $PREREQ_OK; then
  echo ""
  error "Missing prerequisites. Install them and re-run this script."
  exit 1
fi

echo ""
success "All prerequisites met"

# ═════════════════════════════════════════════════════════════════════════════
# TMUX CONFIGURATION
# ═════════════════════════════════════════════════════════════════════════════
header "tmux configuration"

INSTALL_FULL_TMUX=false
INSTALL_OVERLAY_ONLY=false

if [[ -f "$HOME/.tmux.conf" ]]; then
  info "Found existing ~/.tmux.conf"
  echo ""
  echo -e "  ${BOLD}1)${RESET} Install full tmux config ${DIM}(backs up existing to ~/.tmux.conf.bak)${RESET}"
  echo -e "  ${BOLD}2)${RESET} Install overlay only ${DIM}(adds agent pane features to your existing config)${RESET}"
  echo -e "  ${BOLD}3)${RESET} Skip tmux config"
  echo ""
  echo -en "${PURPLE}?${RESET} Choose [1/2/3]: "
  read -r choice
  case "$choice" in
    1) INSTALL_FULL_TMUX=true ;;
    2) INSTALL_OVERLAY_ONLY=true ;;
    *) info "Skipping tmux config" ;;
  esac
else
  if ask "Install full tmux config?"; then
    INSTALL_FULL_TMUX=true
  fi
fi

if $INSTALL_FULL_TMUX; then
  # Back up existing config
  if [[ -f "$HOME/.tmux.conf" ]]; then
    run "Back up ~/.tmux.conf → ~/.tmux.conf.bak" \
      "cp '$HOME/.tmux.conf' '$HOME/.tmux.conf.bak'"
    success "Backed up existing tmux config"
  fi

  run "Install tmux.conf → ~/.tmux.conf" \
    "cp '$SCRIPT_DIR/tmux/tmux.conf' '$HOME/.tmux.conf'"
  success "Installed full tmux config"
  INSTALLED+=("tmux.conf")

  # Also install the overlay to ~/.tmux/
  run "Create ~/.tmux/ directory" \
    "mkdir -p '$HOME/.tmux'"
  run "Install overlay → ~/.tmux/claude-teams-overlay.conf" \
    "cp '$SCRIPT_DIR/tmux/claude-teams-overlay.conf' '$HOME/.tmux/claude-teams-overlay.conf'"
  success "Installed teams overlay"
  INSTALLED+=("claude-teams-overlay.conf")
fi

if $INSTALL_OVERLAY_ONLY; then
  run "Create ~/.tmux/ directory" \
    "mkdir -p '$HOME/.tmux'"
  run "Install overlay → ~/.tmux/claude-teams-overlay.conf" \
    "cp '$SCRIPT_DIR/tmux/claude-teams-overlay.conf' '$HOME/.tmux/claude-teams-overlay.conf'"
  success "Installed teams overlay"
  INSTALLED+=("claude-teams-overlay.conf")

  echo ""
  info "Add this line to your ~/.tmux.conf to load the overlay:"
  echo ""
  echo -e "  ${DIM}source-file -q ~/.tmux/claude-teams-overlay.conf${RESET}"
  echo ""
fi

# ═════════════════════════════════════════════════════════════════════════════
# CLAUDE CODE SETTINGS
# ═════════════════════════════════════════════════════════════════════════════
header "Claude Code settings"

if [[ -f "$HOME/.claude/settings.json" ]]; then
  info "Found existing ~/.claude/settings.json — will NOT overwrite"
  info "Template saved to ~/.claude/settings.json.template for reference"
  run "Copy settings template" \
    "cp '$SCRIPT_DIR/claude-code/settings.json.template' '$HOME/.claude/settings.json.template'"
  INSTALLED+=("settings.json.template (reference)")
else
  run "Create ~/.claude/ directory" \
    "mkdir -p '$HOME/.claude'"

  if ask "Install Claude Code settings template as your settings.json?"; then
    # Strip JSONC comments for the actual settings file
    run "Install settings.json (comments stripped)" \
      "sed '/^[[:space:]]*\/\//d' '$SCRIPT_DIR/claude-code/settings.json.template' > '$HOME/.claude/settings.json'"
    success "Installed Claude Code settings"
    INSTALLED+=("settings.json")
  else
    run "Copy settings template for reference" \
      "cp '$SCRIPT_DIR/claude-code/settings.json.template' '$HOME/.claude/settings.json.template'"
    info "Template saved to ~/.claude/settings.json.template"
    INSTALLED+=("settings.json.template (reference)")
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# CCT CLI SCRIPTS
# ═════════════════════════════════════════════════════════════════════════════
header "cct CLI"

BIN_DIR="$HOME/.local/bin"

if ask "Install cct CLI to $BIN_DIR?"; then
  run "Create $BIN_DIR directory" \
    "mkdir -p '$BIN_DIR'"

  if [[ -f "$SCRIPT_DIR/scripts/cct" ]]; then
    run "Install cct → $BIN_DIR/cct" \
      "cp '$SCRIPT_DIR/scripts/cct' '$BIN_DIR/cct' && chmod +x '$BIN_DIR/cct'"
    success "Installed cct CLI"
    INSTALLED+=("cct")
  else
    warn "scripts/cct not found — skipping (may not be built yet)"
  fi

  # Check if ~/.local/bin is in PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    echo ""
    warn "$BIN_DIR is not in your PATH"
    info "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo ""
    echo -e "  ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
    echo ""
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# HOOKS
# ═════════════════════════════════════════════════════════════════════════════
header "Quality gate hooks"

if ask "Install quality gate hooks to ~/.claude/hooks/?"; then
  run "Create ~/.claude/hooks/ directory" \
    "mkdir -p '$HOME/.claude/hooks'"
  run "Install teammate-idle.sh hook" \
    "cp '$SCRIPT_DIR/claude-code/hooks/teammate-idle.sh' '$HOME/.claude/hooks/teammate-idle.sh' && chmod +x '$HOME/.claude/hooks/teammate-idle.sh'"
  success "Installed teammate-idle.sh hook"
  INSTALLED+=("teammate-idle.sh")

  echo ""
  info "Wire up hooks in ~/.claude/settings.json:"
  echo ""
  echo -e "  ${DIM}\"hooks\": {"
  echo -e "    \"teammate-idle\": {"
  echo -e "      \"command\": \"~/.claude/hooks/teammate-idle.sh\","
  echo -e "      \"timeout\": 30000"
  echo -e "    }"
  echo -e "  }${RESET}"
  echo ""
fi

# ═════════════════════════════════════════════════════════════════════════════
# TPM (Tmux Plugin Manager)
# ═════════════════════════════════════════════════════════════════════════════
header "Tmux Plugin Manager (TPM)"

if [[ -d "$HOME/.tmux/plugins/tpm" ]]; then
  success "TPM already installed"
else
  if ask "Install TPM (tmux plugin manager)?"; then
    run "Clone TPM to ~/.tmux/plugins/tpm" \
      "git clone https://github.com/tmux-plugins/tpm '$HOME/.tmux/plugins/tpm'"
    success "Installed TPM"
    INSTALLED+=("TPM")
    info "Press prefix + I inside tmux to install plugins"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}Installation complete${RESET}                                    ${CYAN}║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ ${#INSTALLED[@]} -eq 0 ]]; then
  info "Nothing was installed"
else
  info "Installed:"
  for item in "${INSTALLED[@]}"; do
    echo -e "  ${GREEN}✓${RESET} $item"
  done
fi

echo ""
info "Next steps:"
echo -e "  ${DIM}1.${RESET} Start a tmux session:  ${BOLD}tmux new -s dev${RESET}"
echo -e "  ${DIM}2.${RESET} Install tmux plugins:  ${BOLD}prefix + I${RESET}"
echo -e "  ${DIM}3.${RESET} Launch Claude Code:    ${BOLD}claude${RESET}"
echo ""

if $DRY_RUN; then
  warn "This was a dry run — no changes were made"
  echo ""
fi
