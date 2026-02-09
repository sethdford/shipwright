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
echo -e "${CYAN}║${RESET}  ${BOLD}Shipwright${RESET}                                               ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}  ${DIM}Interactive installer for Claude Code agent teams${RESET}         ${CYAN}║${RESET}"
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
    warn "tmux $TMUX_VERSION (3.2+ recommended — display-popup, set-hook unavailable)"
  fi
else
  warn "tmux not found"
  if ask "Install tmux now?"; then
    if [[ "$(uname)" == "Darwin" ]]; then
      if command -v brew &>/dev/null; then
        run "Install tmux via Homebrew" "brew install tmux"
        success "Installed tmux"
      else
        error "Homebrew not found — install tmux manually: brew install tmux"
        PREREQ_OK=false
      fi
    elif command -v apt-get &>/dev/null; then
      run "Install tmux via apt" "sudo apt-get install -y tmux"
      success "Installed tmux"
    elif command -v dnf &>/dev/null; then
      run "Install tmux via dnf" "sudo dnf install -y tmux"
      success "Installed tmux"
    elif command -v pacman &>/dev/null; then
      run "Install tmux via pacman" "sudo pacman -S --noconfirm tmux"
      success "Installed tmux"
    else
      error "Could not detect package manager — install tmux manually"
      PREREQ_OK=false
    fi
  else
    error "tmux is required — install with: brew install tmux"
    PREREQ_OK=false
  fi
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

# jq
if command -v jq &>/dev/null; then
  success "jq $(jq --version 2>/dev/null | tr -d 'jq-')"
else
  error "jq not found — install with: brew install jq"
  PREREQ_OK=false
fi

# Bash version
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
if [[ "$BASH_MAJOR" -ge 4 ]]; then
  success "bash $BASH_VERSION"
else
  warn "bash $BASH_VERSION (4.0+ recommended — associative arrays, globstar unavailable)"
fi

# gh CLI (optional but recommended)
if command -v gh &>/dev/null; then
  GH_VERSION="$(gh --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  success "gh CLI $GH_VERSION"
  # Check gh authentication
  if gh auth status &>/dev/null; then
    success "gh authenticated"
  else
    warn "gh CLI installed but not authenticated — run: gh auth login"
    warn "  (needed for daemon, pipeline PR creation, and issue management)"
  fi
else
  warn "gh CLI not found — install with: brew install gh"
  warn "  (needed for daemon, pipeline PR creation, and issue management)"
fi

if ! $PREREQ_OK; then
  echo ""
  error "Missing prerequisites. Install them and re-run this script."
  exit 1
fi

echo ""
success "All prerequisites met"

# ═════════════════════════════════════════════════════════════════════════════
# CREATE EXPECTED DIRECTORIES
# ═════════════════════════════════════════════════════════════════════════════
header "Creating directories"

for dir in \
  "$HOME/.claude" \
  "$HOME/.claude/hooks" \
  "$HOME/.claude-teams" \
  "$HOME/.shipwright" \
  "$HOME/.shipwright/templates" \
  "$HOME/.shipwright/pipelines"; do
  if [[ ! -d "$dir" ]]; then
    run "Create $dir" "mkdir -p '$dir'"
  fi
done
success "All directories ready"

# ═════════════════════════════════════════════════════════════════════════════
# TMUX CONFIGURATION
# ═════════════════════════════════════════════════════════════════════════════
header "tmux configuration"

INSTALL_FULL_TMUX=false
INSTALL_OVERLAY_ONLY=false

if [[ -f "$HOME/.tmux.conf" ]]; then
  info "Found existing ~/.tmux.conf"
  echo ""
  echo -e "  ${BOLD}1)${RESET} Install full tmux config ${DIM}(backs up existing with timestamp)${RESET}"
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
    TMUX_BACKUP="$HOME/.tmux.conf.bak.$(date +%Y%m%d-%H%M%S)"
    run "Back up ~/.tmux.conf → $TMUX_BACKUP" \
      "cp '$HOME/.tmux.conf' '$TMUX_BACKUP'"
    success "Backed up existing tmux config → $TMUX_BACKUP"
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
    # Strip JSONC comments and ensure hooks paths are correct
    run "Install settings.json (comments stripped, hooks enabled)" \
      "sed '/^[[:space:]]*\/\//d' '$SCRIPT_DIR/claude-code/settings.json.template' > '$HOME/.claude/settings.json'"
    # Validate the resulting JSON
    if command -v jq &>/dev/null && [[ -f "$HOME/.claude/settings.json" ]] && ! $DRY_RUN; then
      if jq -e . "$HOME/.claude/settings.json" >/dev/null 2>&1; then
        success "Installed Claude Code settings (validated)"
      else
        warn "settings.json has invalid JSON — check for syntax errors"
      fi
    else
      success "Installed Claude Code settings"
    fi
    INSTALLED+=("settings.json")
  else
    run "Copy settings template for reference" \
      "cp '$SCRIPT_DIR/claude-code/settings.json.template' '$HOME/.claude/settings.json.template'"
    info "Template saved to ~/.claude/settings.json.template"
    INSTALLED+=("settings.json.template (reference)")
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# CLAUDE.md — AGENT INSTRUCTIONS
# ═════════════════════════════════════════════════════════════════════════════
header "Agent instructions (CLAUDE.md)"

CLAUDE_MD_SRC="$SCRIPT_DIR/claude-code/CLAUDE.md.shipwright"
GLOBAL_CLAUDE_MD="$HOME/.claude/CLAUDE.md"

if [[ -f "$CLAUDE_MD_SRC" ]]; then
  if [[ -f "$GLOBAL_CLAUDE_MD" ]] && grep -q "Shipwright" "$GLOBAL_CLAUDE_MD" 2>/dev/null; then
    success "~/.claude/CLAUDE.md already contains Shipwright instructions"
  elif [[ -f "$GLOBAL_CLAUDE_MD" ]]; then
    info "Found existing ~/.claude/CLAUDE.md"
    echo ""
    echo -e "  ${BOLD}1)${RESET} Append Shipwright section ${DIM}(keeps your existing instructions)${RESET}"
    echo -e "  ${BOLD}2)${RESET} Skip"
    echo ""
    echo -en "${PURPLE}?${RESET} Choose [1/2]: "
    read -r claude_md_choice
    case "$claude_md_choice" in
      1)
        run "Append Shipwright instructions to ~/.claude/CLAUDE.md" \
          "{ echo ''; echo '---'; echo ''; cat '$CLAUDE_MD_SRC'; } >> '$GLOBAL_CLAUDE_MD'"
        success "Appended Shipwright instructions to ~/.claude/CLAUDE.md"
        INSTALLED+=("CLAUDE.md (appended)")
        ;;
      *) info "Skipping CLAUDE.md" ;;
    esac
  else
    if ask "Install Shipwright agent instructions to ~/.claude/CLAUDE.md?"; then
      run "Create ~/.claude/ directory" \
        "mkdir -p '$HOME/.claude'"
      run "Install CLAUDE.md" \
        "cp '$CLAUDE_MD_SRC' '$GLOBAL_CLAUDE_MD'"
      success "Installed ~/.claude/CLAUDE.md"
      INSTALLED+=("CLAUDE.md")
    fi
  fi
else
  warn "CLAUDE.md template not found — skipping"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SHIPWRIGHT CLI SCRIPTS
# ═════════════════════════════════════════════════════════════════════════════
header "Shipwright CLI"

BIN_DIR="$HOME/.local/bin"

if ask "Install Shipwright CLI to $BIN_DIR?"; then
  run "Create $BIN_DIR directory" \
    "mkdir -p '$BIN_DIR'"

  if [[ -f "$SCRIPT_DIR/scripts/cct" ]]; then
    # Install router + all subcommand scripts
    run "Install cct → $BIN_DIR/cct" \
      "cp '$SCRIPT_DIR/scripts/cct' '$BIN_DIR/cct' && chmod +x '$BIN_DIR/cct'"
    INSTALLED+=("cct")

    # Create shipwright and sw aliases
    run "Create shipwright symlink" \
      "ln -sf '$BIN_DIR/cct' '$BIN_DIR/shipwright'"
    run "Create sw symlink" \
      "ln -sf '$BIN_DIR/cct' '$BIN_DIR/sw'"
    INSTALLED+=("shipwright (symlink)")
    INSTALLED+=("sw (symlink)")

    for sub in cct-session.sh cct-status.sh cct-cleanup.sh cct-upgrade.sh cct-doctor.sh cct-logs.sh cct-ps.sh cct-templates.sh cct-loop.sh cct-pipeline.sh cct-pipeline-test.sh cct-worktree.sh cct-init.sh cct-prep.sh cct-prep-test.sh cct-daemon.sh cct-daemon-test.sh cct-reaper.sh cct-memory.sh cct-memory-test.sh cct-cost.sh cct-fleet.sh cct-fleet-test.sh cct-fix.sh cct-fix-test.sh cct-dashboard.sh cct-tracker.sh cct-tracker-linear.sh cct-tracker-jira.sh cct-heartbeat.sh cct-checkpoint.sh cct-remote.sh cct-linear.sh cct-jira.sh; do
      if [[ -f "$SCRIPT_DIR/scripts/$sub" ]]; then
        run "Install $sub → $BIN_DIR/$sub" \
          "cp '$SCRIPT_DIR/scripts/$sub' '$BIN_DIR/$sub' && chmod +x '$BIN_DIR/$sub'"
        INSTALLED+=("$sub")
      fi
    done

    # Install dashboard
    if [[ -d "$SCRIPT_DIR/dashboard" ]]; then
      local DASH_DEST="$HOME/.local/share/shipwright/dashboard"
      run "Create dashboard directory" \
        "mkdir -p '$DASH_DEST'"
      for f in "$SCRIPT_DIR"/dashboard/*.ts; do
        [[ -f "$f" ]] || continue
        local_name="$(basename "$f")"
        run "Install $local_name → $DASH_DEST/$local_name" \
          "cp '$f' '$DASH_DEST/$local_name'"
      done
      if [[ -d "$SCRIPT_DIR/dashboard/public" ]]; then
        run "Create dashboard/public directory" \
          "mkdir -p '$DASH_DEST/public'"
        for f in "$SCRIPT_DIR"/dashboard/public/*; do
          [[ -f "$f" ]] || continue
          local_name="$(basename "$f")"
          run "Install $local_name → $DASH_DEST/public/$local_name" \
            "cp '$f' '$DASH_DEST/public/$local_name'"
        done
      fi
      INSTALLED+=("dashboard")
    fi

    # Install terminal adapters
    if [[ -d "$SCRIPT_DIR/scripts/adapters" ]]; then
      run "Create $BIN_DIR/adapters directory" \
        "mkdir -p '$BIN_DIR/adapters'"
      for adapter in "$SCRIPT_DIR"/scripts/adapters/*.sh; do
        local_name="$(basename "$adapter")"
        run "Install adapter $local_name" \
          "cp '$adapter' '$BIN_DIR/adapters/$local_name' && chmod +x '$BIN_DIR/adapters/$local_name'"
      done
    fi

    # Install team templates
    if [[ -d "$SCRIPT_DIR/tmux/templates" ]]; then
      run "Create ~/.claude-teams/templates directory" \
        "mkdir -p '$HOME/.claude-teams/templates'"
      run "Create ~/.shipwright/templates directory" \
        "mkdir -p '$HOME/.shipwright/templates'"
      for tpl in "$SCRIPT_DIR"/tmux/templates/*.json; do
        local_name="$(basename "$tpl")"
        run "Install template $local_name" \
          "cp '$tpl' '$HOME/.claude-teams/templates/$local_name'"
        run "Install template $local_name → ~/.shipwright/templates/" \
          "cp '$tpl' '$HOME/.shipwright/templates/$local_name'"
      done
      # Validate installed team templates
      if command -v jq &>/dev/null && ! $DRY_RUN; then
        for tpl_file in "$HOME/.claude-teams/templates"/*.json; do
          [[ -f "$tpl_file" ]] || continue
          if ! jq -e . "$tpl_file" >/dev/null 2>&1; then
            warn "Invalid JSON: $(basename "$tpl_file")"
          fi
        done
      fi
      INSTALLED+=("templates")
    fi

    # Install pipeline templates
    if [[ -d "$SCRIPT_DIR/templates/pipelines" ]]; then
      run "Create ~/.claude-teams/pipelines directory" \
        "mkdir -p '$HOME/.claude-teams/pipelines'"
      run "Create ~/.shipwright/pipelines directory" \
        "mkdir -p '$HOME/.shipwright/pipelines'"
      for ptpl in "$SCRIPT_DIR"/templates/pipelines/*.json; do
        local_name="$(basename "$ptpl")"
        run "Install pipeline template $local_name" \
          "cp '$ptpl' '$HOME/.claude-teams/pipelines/$local_name'"
        run "Install pipeline template $local_name → ~/.shipwright/pipelines/" \
          "cp '$ptpl' '$HOME/.shipwright/pipelines/$local_name'"
      done
      # Validate installed pipeline templates
      if command -v jq &>/dev/null && ! $DRY_RUN; then
        for ptpl_file in "$HOME/.claude-teams/pipelines"/*.json; do
          [[ -f "$ptpl_file" ]] || continue
          if ! jq -e . "$ptpl_file" >/dev/null 2>&1; then
            warn "Invalid JSON: $(basename "$ptpl_file")"
          fi
        done
      fi
      INSTALLED+=("pipeline-templates")
    fi

    # Install definition-of-done template
    if [[ -f "$SCRIPT_DIR/docs/definition-of-done.example.md" ]]; then
      run "Install definition-of-done template" \
        "cp '$SCRIPT_DIR/docs/definition-of-done.example.md' '$HOME/.claude-teams/templates/definition-of-done.example.md'"
      INSTALLED+=("definition-of-done.example.md")
    fi

    success "Installed Shipwright CLI (router + subcommands + adapters + templates)"
  else
    warn "scripts/cct not found — skipping (may not be built yet)"
  fi

  # Check if ~/.local/bin is in PATH and fix if needed
  if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    echo ""
    warn "$BIN_DIR is not in your PATH"

    # Detect the user's shell rc file
    SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
    case "$SHELL_NAME" in
      zsh)  RC_FILE="$HOME/.zshrc" ;;
      bash)
        if [[ -f "$HOME/.bash_profile" ]]; then
          RC_FILE="$HOME/.bash_profile"
        else
          RC_FILE="$HOME/.bashrc"
        fi
        ;;
      *)    RC_FILE="$HOME/.profile" ;;
    esac

    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
    MARKER="# Added by Shipwright"

    if [[ -f "$RC_FILE" ]] && grep -qF "$MARKER" "$RC_FILE" 2>/dev/null; then
      info "PATH entry already in $RC_FILE (Shipwright marker found)"
    elif ask "Add $BIN_DIR to PATH in $RC_FILE?"; then
      run "Add PATH to $RC_FILE" \
        "printf '\n%s\n%s\n' '$MARKER' '$PATH_LINE' >> '$RC_FILE'"
      success "Added $BIN_DIR to PATH in $RC_FILE"
      echo ""
      info "Run: ${BOLD}source $RC_FILE${RESET}  (or restart your shell)"
    else
      info "Add this to your shell profile ($RC_FILE):"
      echo ""
      echo -e "  ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
      echo ""
    fi
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# HOOKS
# ═════════════════════════════════════════════════════════════════════════════
header "Quality gate hooks"

if ask "Install quality gate hooks to ~/.claude/hooks/?"; then
  run "Create ~/.claude/hooks/ directory" \
    "mkdir -p '$HOME/.claude/hooks'"

  for hook in teammate-idle.sh task-completed.sh notify-idle.sh pre-compact-save.sh; do
    if [[ -f "$SCRIPT_DIR/claude-code/hooks/$hook" ]]; then
      run "Install $hook hook" \
        "cp '$SCRIPT_DIR/claude-code/hooks/$hook' '$HOME/.claude/hooks/$hook' && chmod +x '$HOME/.claude/hooks/$hook'"
      INSTALLED+=("$hook")
    fi
  done

  success "Installed hooks to ~/.claude/hooks/"

  echo ""
  info "Wire up hooks in ~/.claude/settings.json (see settings.json.template for examples)"
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
# UPGRADE MANIFEST
# ═════════════════════════════════════════════════════════════════════════════
if [[ ${#INSTALLED[@]} -gt 0 ]] && ! $DRY_RUN; then
  header "Upgrade manifest"

  MANIFEST_DIR="$HOME/.claude-teams"
  MANIFEST="$MANIFEST_DIR/manifest.json"
  mkdir -p "$MANIFEST_DIR"

  # Checksum helper (macOS md5 vs linux md5sum)
  _cksum() {
    if command -v md5 &>/dev/null; then
      md5 -q "$1" 2>/dev/null
    else
      md5sum "$1" 2>/dev/null | awk '{print $1}'
    fi
  }

  # Build file entries — only for files that actually got installed
  BIN_DIR="$HOME/.local/bin"
  MANIFEST_ENTRIES=""
  _add_entry() {
    local key="$1" src="$2" dest="$3" protected="${4:-false}" executable="${5:-false}"
    [[ -f "$dest" ]] || return 0
    local cksum
    cksum="$(_cksum "$dest")"
    if [[ -n "$MANIFEST_ENTRIES" ]]; then MANIFEST_ENTRIES+=","; fi
    MANIFEST_ENTRIES+="$(printf '\n    "%s": {\n' "$key")"
    if [[ -n "$src" ]]; then
      MANIFEST_ENTRIES+="$(printf '      "src": "%s",\n' "$src")"
    fi
    MANIFEST_ENTRIES+="$(printf '      "dest": "%s",\n' "$dest")"
    MANIFEST_ENTRIES+="$(printf '      "checksum": "%s",\n' "$cksum")"
    MANIFEST_ENTRIES+="$(printf '      "protected": %s,\n' "$protected")"
    MANIFEST_ENTRIES+="$(printf '      "executable": %s\n' "$executable")"
    MANIFEST_ENTRIES+="$(printf '    }')"
  }

  # Check each installed item and add to manifest
  for item in "${INSTALLED[@]}"; do
    case "$item" in
      "tmux.conf")
        _add_entry "tmux.conf" "tmux/tmux.conf" "$HOME/.tmux.conf" false false ;;
      "claude-teams-overlay.conf")
        _add_entry "claude-teams-overlay.conf" "tmux/claude-teams-overlay.conf" "$HOME/.tmux/claude-teams-overlay.conf" false false ;;
      "settings.json")
        _add_entry "settings.json" "" "$HOME/.claude/settings.json" true false ;;
      "settings.json.template"*)
        _add_entry "settings.json.template" "claude-code/settings.json.template" "$HOME/.claude/settings.json.template" false false ;;
      "cct")
        _add_entry "cct" "scripts/cct" "$BIN_DIR/cct" false true ;;
      "shipwright (symlink)")
        _add_entry "shipwright" "" "$BIN_DIR/shipwright" false true ;;
      "sw (symlink)")
        _add_entry "sw" "" "$BIN_DIR/sw" false true ;;
      "cct-session.sh")
        _add_entry "cct-session.sh" "scripts/cct-session.sh" "$BIN_DIR/cct-session.sh" false true ;;
      "cct-status.sh")
        _add_entry "cct-status.sh" "scripts/cct-status.sh" "$BIN_DIR/cct-status.sh" false true ;;
      "cct-cleanup.sh")
        _add_entry "cct-cleanup.sh" "scripts/cct-cleanup.sh" "$BIN_DIR/cct-cleanup.sh" false true ;;
      "cct-upgrade.sh")
        _add_entry "cct-upgrade.sh" "scripts/cct-upgrade.sh" "$BIN_DIR/cct-upgrade.sh" false true ;;
      "cct-doctor.sh")
        _add_entry "cct-doctor.sh" "scripts/cct-doctor.sh" "$BIN_DIR/cct-doctor.sh" false true ;;
      "cct-logs.sh")
        _add_entry "cct-logs.sh" "scripts/cct-logs.sh" "$BIN_DIR/cct-logs.sh" false true ;;
      "cct-ps.sh")
        _add_entry "cct-ps.sh" "scripts/cct-ps.sh" "$BIN_DIR/cct-ps.sh" false true ;;
      "cct-templates.sh")
        _add_entry "cct-templates.sh" "scripts/cct-templates.sh" "$BIN_DIR/cct-templates.sh" false true ;;
      "cct-loop.sh")
        _add_entry "cct-loop.sh" "scripts/cct-loop.sh" "$BIN_DIR/cct-loop.sh" false true ;;
      "cct-worktree.sh")
        _add_entry "cct-worktree.sh" "scripts/cct-worktree.sh" "$BIN_DIR/cct-worktree.sh" false true ;;
      "cct-init.sh")
        _add_entry "cct-init.sh" "scripts/cct-init.sh" "$BIN_DIR/cct-init.sh" false true ;;
      "cct-prep.sh")
        _add_entry "cct-prep.sh" "scripts/cct-prep.sh" "$BIN_DIR/cct-prep.sh" false true ;;
      "cct-daemon.sh")
        _add_entry "cct-daemon.sh" "scripts/cct-daemon.sh" "$BIN_DIR/cct-daemon.sh" false true ;;
      "cct-dashboard.sh")
        _add_entry "cct-dashboard.sh" "scripts/cct-dashboard.sh" "$BIN_DIR/cct-dashboard.sh" false true ;;
      "cct-pipeline.sh")
        _add_entry "cct-pipeline.sh" "scripts/cct-pipeline.sh" "$BIN_DIR/cct-pipeline.sh" false true ;;
      "cct-reaper.sh")
        _add_entry "cct-reaper.sh" "scripts/cct-reaper.sh" "$BIN_DIR/cct-reaper.sh" false true ;;
      "cct-memory.sh")
        _add_entry "cct-memory.sh" "scripts/cct-memory.sh" "$BIN_DIR/cct-memory.sh" false true ;;
      "cct-cost.sh")
        _add_entry "cct-cost.sh" "scripts/cct-cost.sh" "$BIN_DIR/cct-cost.sh" false true ;;
      "cct-fleet.sh")
        _add_entry "cct-fleet.sh" "scripts/cct-fleet.sh" "$BIN_DIR/cct-fleet.sh" false true ;;
      "cct-fix.sh")
        _add_entry "cct-fix.sh" "scripts/cct-fix.sh" "$BIN_DIR/cct-fix.sh" false true ;;
      "cct-tracker.sh")
        _add_entry "cct-tracker.sh" "scripts/cct-tracker.sh" "$BIN_DIR/cct-tracker.sh" false true ;;
      "cct-tracker-linear.sh")
        _add_entry "cct-tracker-linear.sh" "scripts/cct-tracker-linear.sh" "$BIN_DIR/cct-tracker-linear.sh" false true ;;
      "cct-tracker-jira.sh")
        _add_entry "cct-tracker-jira.sh" "scripts/cct-tracker-jira.sh" "$BIN_DIR/cct-tracker-jira.sh" false true ;;
      "cct-heartbeat.sh")
        _add_entry "cct-heartbeat.sh" "scripts/cct-heartbeat.sh" "$BIN_DIR/cct-heartbeat.sh" false true ;;
      "cct-checkpoint.sh")
        _add_entry "cct-checkpoint.sh" "scripts/cct-checkpoint.sh" "$BIN_DIR/cct-checkpoint.sh" false true ;;
      "cct-remote.sh")
        _add_entry "cct-remote.sh" "scripts/cct-remote.sh" "$BIN_DIR/cct-remote.sh" false true ;;
      "cct-linear.sh")
        _add_entry "cct-linear.sh" "scripts/cct-linear.sh" "$BIN_DIR/cct-linear.sh" false true ;;
      "cct-jira.sh")
        _add_entry "cct-jira.sh" "scripts/cct-jira.sh" "$BIN_DIR/cct-jira.sh" false true ;;

      "teammate-idle.sh")
        _add_entry "teammate-idle.sh" "claude-code/hooks/teammate-idle.sh" "$HOME/.claude/hooks/teammate-idle.sh" false true ;;
      "task-completed.sh")
        _add_entry "task-completed.sh" "claude-code/hooks/task-completed.sh" "$HOME/.claude/hooks/task-completed.sh" false true ;;
      "notify-idle.sh")
        _add_entry "notify-idle.sh" "claude-code/hooks/notify-idle.sh" "$HOME/.claude/hooks/notify-idle.sh" false true ;;
      "pre-compact-save.sh")
        _add_entry "pre-compact-save.sh" "claude-code/hooks/pre-compact-save.sh" "$HOME/.claude/hooks/pre-compact-save.sh" false true ;;
      "templates")
        # Add individual template entries
        for tpl_file in "$HOME/.claude-teams/templates"/*.json; do
          [[ -f "$tpl_file" ]] || continue
          local_name="$(basename "$tpl_file")"
          _add_entry "$local_name" "tmux/templates/$local_name" "$tpl_file" false false
        done
        ;;
      "definition-of-done.example.md")
        _add_entry "definition-of-done.example.md" "docs/definition-of-done.example.md" "$HOME/.claude-teams/templates/definition-of-done.example.md" false false ;;
      "CLAUDE.md"|"CLAUDE.md (appended)")
        _add_entry "CLAUDE.md" "claude-code/CLAUDE.md.shipwright" "$HOME/.claude/CLAUDE.md" true false ;;
    esac
  done

  # Write the manifest
  cat > "$MANIFEST" <<MANIFEST_EOF
{
  "schema": 1,
  "version": "1.1.0",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo_path": "$SCRIPT_DIR",
  "files": {$MANIFEST_ENTRIES
  }
}
MANIFEST_EOF

  success "Upgrade manifest written to $MANIFEST"
  info "Future updates: ${DIM}git pull && shipwright upgrade --apply${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}Shipwright installed${RESET}                                      ${CYAN}║${RESET}"
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
echo -e "  ${DIM}3.${RESET} Launch Shipwright:     ${BOLD}shipwright help${RESET}  ${DIM}(or: sw, cct)${RESET}"
echo -e "  ${DIM}4.${RESET} Tab completions:       ${BOLD}shipwright completions install${RESET}"
echo ""

if $DRY_RUN; then
  warn "This was a dry run — no changes were made"
  echo ""
fi
