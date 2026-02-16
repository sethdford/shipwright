#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright init — Complete setup for Shipwright + Shipwright    ║
# ║                                                                          ║
# ║  Installs: tmux config, overlay, team & pipeline templates, Claude Code ║
# ║  settings (with agent teams enabled), quality gate hooks, CLAUDE.md     ║
# ║  agent instructions (global + per-repo). Runs doctor at the end.       ║
# ║                                                                          ║
# ║  --deploy  Detect platform and generate deployed.json template          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.1.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Flag parsing ───────────────────────────────────────────────────────────
DEPLOY_SETUP=false
DEPLOY_PLATFORM=""
SKIP_CLAUDE_MD=false
REPAIR_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy)
            DEPLOY_SETUP=true
            shift
            ;;
        --platform)
            DEPLOY_PLATFORM="${2:-}"
            [[ -z "$DEPLOY_PLATFORM" ]] && { error "Missing value for --platform"; exit 1; }
            shift 2
            ;;
        --no-claude-md)
            SKIP_CLAUDE_MD=true
            shift
            ;;
        --repair)
            REPAIR_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: shipwright init [--deploy] [--platform vercel|fly|railway|docker] [--no-claude-md] [--repair]"
            echo ""
            echo "Options:"
            echo "  --deploy             Detect deploy platform and generate deployed.json"
            echo "  --platform PLATFORM  Skip detection, use specified platform"
            echo "  --no-claude-md       Skip creating .claude/CLAUDE.md"
            echo "  --repair             Force clean reinstall of tmux config, plugins, and adapters"
            echo "  --help, -h           Show this help"
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            shift
            ;;
    esac
done

echo ""
echo -e "${CYAN}${BOLD}shipwright init${RESET} — Complete setup"
echo -e "${DIM}══════════════════════════════════════════${RESET}"
echo ""

# ─── tmux.conf ────────────────────────────────────────────────────────────────
TOOK_FULL_TMUX_CONF=false
IS_INTERACTIVE="${INTERACTIVE:-false}"

# --repair: remove stale files first for clean slate
if [[ "$REPAIR_MODE" == "true" ]]; then
    info "Repair mode: cleaning stale tmux artifacts..."
    rm -f "$HOME/.tmux/claude-teams-overlay.conf" 2>/dev/null || true
    rm -f "$HOME/.tmux/claude-teams-overlay.conf.pre-upgrade.bak" 2>/dev/null || true
    # Strip legacy overlay source lines from user's tmux.conf
    if [[ -f "$HOME/.tmux.conf" ]] && grep -q "claude-teams-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
        tmp=$(mktemp)
        grep -v "claude-teams-overlay" "$HOME/.tmux.conf" > "$tmp" && mv "$tmp" "$HOME/.tmux.conf"
        success "Removed legacy claude-teams-overlay references from ~/.tmux.conf"
    fi
fi

if [[ -f "$REPO_DIR/tmux/tmux.conf" ]]; then
    if [[ -f "$HOME/.tmux.conf" ]] && [[ "$REPAIR_MODE" == "false" ]]; then
        cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak"
        warn "Backed up existing ~/.tmux.conf → ~/.tmux.conf.bak"
        if [[ "$IS_INTERACTIVE" == "true" ]]; then
            read -rp "$(echo -e "${CYAN}${BOLD}▸${RESET} Overwrite ~/.tmux.conf with the Shipwright config? [Y/n] ")" tmux_confirm
            if [[ -z "$tmux_confirm" || "$(echo "$tmux_confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
                cp "$REPO_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
                success "Installed ~/.tmux.conf"
                TOOK_FULL_TMUX_CONF=true
            else
                info "Kept existing ~/.tmux.conf"
            fi
        else
            cp "$REPO_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
            success "Installed ~/.tmux.conf"
            TOOK_FULL_TMUX_CONF=true
        fi
    else
        cp "$REPO_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
        success "Installed ~/.tmux.conf"
        TOOK_FULL_TMUX_CONF=true
    fi
else
    warn "tmux.conf not found in package — skipping"
fi

# ─── Overlay ──────────────────────────────────────────────────────────────────
if [[ -f "$REPO_DIR/tmux/shipwright-overlay.conf" ]]; then
    mkdir -p "$HOME/.tmux"
    cp "$REPO_DIR/tmux/shipwright-overlay.conf" "$HOME/.tmux/shipwright-overlay.conf"
    success "Installed ~/.tmux/shipwright-overlay.conf"
else
    warn "Overlay not found in package — skipping"
fi

# ─── Clean up legacy overlay files ───────────────────────────────────────────
# Renamed from claude-teams-overlay.conf → shipwright-overlay.conf in v2.0
if [[ -f "$HOME/.tmux/claude-teams-overlay.conf" ]]; then
    rm -f "$HOME/.tmux/claude-teams-overlay.conf"
    rm -f "$HOME/.tmux/claude-teams-overlay.conf.pre-upgrade.bak" 2>/dev/null || true
    success "Removed legacy claude-teams-overlay.conf"
fi
# Strip any lingering source-file references to the old overlay name
if [[ -f "$HOME/.tmux.conf" ]] && grep -q "claude-teams-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
    tmp=$(mktemp)
    grep -v "claude-teams-overlay" "$HOME/.tmux.conf" > "$tmp" && mv "$tmp" "$HOME/.tmux.conf"
    success "Removed legacy overlay reference from ~/.tmux.conf"
fi

# ─── Overlay injection ───────────────────────────────────────────────────────
# If user kept their own tmux.conf, ensure it sources the overlay
if [[ "$TOOK_FULL_TMUX_CONF" == "false" && -f "$HOME/.tmux.conf" ]]; then
    if ! grep -q "shipwright-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
        if [[ "$IS_INTERACTIVE" == "true" ]]; then
            read -rp "$(echo -e "${CYAN}${BOLD}▸${RESET} Add Shipwright overlay source to ~/.tmux.conf? [Y/n] ")" overlay_confirm
            if [[ -z "$overlay_confirm" || "$(echo "$overlay_confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
                {
                    echo ""
                    echo "# Shipwright agent overlay"
                    echo "source-file -q ~/.tmux/shipwright-overlay.conf"
                } >> "$HOME/.tmux.conf"
                success "Appended overlay source to ~/.tmux.conf"
            else
                info "Skipped overlay injection. Add manually:"
                echo -e "    ${DIM}source-file -q ~/.tmux/shipwright-overlay.conf${RESET}"
            fi
        else
            {
                echo ""
                echo "# Shipwright agent overlay"
                echo "source-file -q ~/.tmux/shipwright-overlay.conf"
            } >> "$HOME/.tmux.conf"
            success "Appended overlay source to ~/.tmux.conf"
        fi
    fi
fi

# ─── TPM (Tmux Plugin Manager) ────────────────────────────────────────────
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]] || [[ "$REPAIR_MODE" == "true" ]]; then
    info "Installing TPM (Tmux Plugin Manager)..."
    rm -rf "$HOME/.tmux/plugins/tpm" 2>/dev/null || true
    if git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" 2>/dev/null; then
        success "TPM installed"
    else
        warn "Could not install TPM — install manually or run: shipwright tmux install"
    fi
else
    success "TPM already installed"
fi

# ─── Install TPM plugins ──────────────────────────────────────────────────
# TPM's install_plugins requires a running tmux server to parse the config.
# When run outside tmux (e.g., fresh OS install), we fall back to cloning
# each plugin directly — the repos are the plugins, no build step needed.
_tmux_plugins_installed=false
if [[ -n "${TMUX:-}" ]] && [[ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]]; then
    info "Installing tmux plugins via TPM..."
    if "$HOME/.tmux/plugins/tpm/bin/install_plugins" 2>/dev/null; then
        success "Plugins installed via TPM"
        _tmux_plugins_installed=true
    fi
fi

if [[ "$_tmux_plugins_installed" == "false" ]]; then
    info "Installing tmux plugins directly (not inside tmux)..."
    _plugin_repos=(
        "tmux-plugins/tmux-sensible"
        "tmux-plugins/tmux-resurrect"
        "tmux-plugins/tmux-continuum"
        "tmux-plugins/tmux-yank"
        "sainnhe/tmux-fzf"
    )
    _plugins_ok=0
    _plugins_fail=0
    for _repo in "${_plugin_repos[@]}"; do
        _name="${_repo##*/}"
        _dest="$HOME/.tmux/plugins/$_name"
        if [[ -d "$_dest" ]] && [[ "$REPAIR_MODE" == "false" ]]; then
            _plugins_ok=$((_plugins_ok + 1))
        else
            rm -rf "$_dest" 2>/dev/null || true
            if git clone "https://github.com/$_repo" "$_dest" 2>/dev/null; then
                _plugins_ok=$((_plugins_ok + 1))
            else
                _plugins_fail=$((_plugins_fail + 1))
            fi
        fi
    done
    if [[ $_plugins_fail -eq 0 ]]; then
        success "Installed ${_plugins_ok} tmux plugins (sensible, resurrect, continuum, yank, fzf)"
    else
        warn "${_plugins_ok} plugins installed, ${_plugins_fail} failed — retry with: shipwright tmux install"
    fi
fi

# ─── tmux Adapter ────────────────────────────────────────────────────────────
# Deploy the tmux adapter (pane ID safety layer) to ~/.shipwright/adapters/
if [[ -f "$SCRIPT_DIR/adapters/tmux-adapter.sh" ]]; then
    mkdir -p "$HOME/.shipwright/adapters"
    cp "$SCRIPT_DIR/adapters/tmux-adapter.sh" "$HOME/.shipwright/adapters/tmux-adapter.sh"
    chmod +x "$HOME/.shipwright/adapters/tmux-adapter.sh"
    success "Installed tmux adapter → ~/.shipwright/adapters/"
fi

# ─── tmux Status Widgets & Role Colors ──────────────────────────────────────
# Deploy scripts called by tmux hooks and #() status-bar widgets
mkdir -p "$HOME/.shipwright/scripts"
for _widget in sw-tmux-status.sh sw-tmux-role-color.sh; do
    if [[ -f "$SCRIPT_DIR/$_widget" ]]; then
        cp "$SCRIPT_DIR/$_widget" "$HOME/.shipwright/scripts/$_widget"
        chmod +x "$HOME/.shipwright/scripts/$_widget"
    fi
done
success "Installed tmux widgets → ~/.shipwright/scripts/"

# ─── Fix iTerm2 mouse reporting if disabled ────────────────────────────────
if [[ "${LC_TERMINAL:-${TERM_PROGRAM:-}}" == *iTerm* ]]; then
    ITERM_MOUSE="$(defaults read com.googlecode.iterm2 "New Bookmarks" 2>/dev/null \
        | grep '"Mouse Reporting"' | head -1 | grep -oE '[0-9]+' || echo "unknown")"
    if [[ "$ITERM_MOUSE" == "0" ]]; then
        warn "iTerm2 mouse reporting is disabled — tmux can't receive mouse clicks"
        /usr/libexec/PlistBuddy -c "Set ':New Bookmarks:0:Mouse Reporting' 1" \
            ~/Library/Preferences/com.googlecode.iterm2.plist 2>/dev/null && \
            success "Enabled iTerm2 mouse reporting (open a new tab to activate)" || \
            warn "Could not auto-fix — enable manually: Preferences → Profiles → Terminal → Report mouse clicks"
    fi
fi

# ─── Verify tmux deployment ──────────────────────────────────────────────────
_verify_fail=0
if [[ ! -f "$HOME/.tmux.conf" ]]; then
    error "VERIFY FAILED: ~/.tmux.conf not found after install"
    _verify_fail=1
elif ! grep -q "allow-passthrough" "$HOME/.tmux.conf" 2>/dev/null; then
    error "VERIFY FAILED: ~/.tmux.conf missing allow-passthrough (Claude Code compat)"
    _verify_fail=1
fi
if [[ ! -f "$HOME/.tmux/shipwright-overlay.conf" ]]; then
    error "VERIFY FAILED: ~/.tmux/shipwright-overlay.conf not found"
    _verify_fail=1
fi
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
    warn "VERIFY: TPM not installed — press prefix + I inside tmux to install"
    _verify_fail=1
fi
if [[ $_verify_fail -eq 0 ]]; then
    success "Verified: tmux config, overlay, TPM, and plugins all deployed"
fi

# ─── Team Templates ──────────────────────────────────────────────────────────
SHIPWRIGHT_DIR="$HOME/.shipwright"
TEMPLATES_SRC="$REPO_DIR/tmux/templates"
if [[ -d "$TEMPLATES_SRC" ]]; then
    mkdir -p "$SHIPWRIGHT_DIR/templates"
    for tpl in "$TEMPLATES_SRC"/*.json; do
        [[ -f "$tpl" ]] || continue
        cp "$tpl" "$SHIPWRIGHT_DIR/templates/$(basename "$tpl")"
    done
    # Also install to legacy path for backward compatibility
    mkdir -p "$HOME/.shipwright/templates"
    for tpl in "$TEMPLATES_SRC"/*.json; do
        [[ -f "$tpl" ]] || continue
        cp "$tpl" "$HOME/.shipwright/templates/$(basename "$tpl")"
    done
    tpl_count=$(find "$SHIPWRIGHT_DIR/templates" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    success "Installed ${tpl_count} team templates → ~/.shipwright/templates/"
fi

# ─── Pipeline Templates ──────────────────────────────────────────────────────
PIPELINES_SRC="$REPO_DIR/templates/pipelines"
if [[ -d "$PIPELINES_SRC" ]]; then
    mkdir -p "$SHIPWRIGHT_DIR/pipelines"
    for tpl in "$PIPELINES_SRC"/*.json; do
        [[ -f "$tpl" ]] || continue
        cp "$tpl" "$SHIPWRIGHT_DIR/pipelines/$(basename "$tpl")"
    done
    pip_count=$(find "$SHIPWRIGHT_DIR/pipelines" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    success "Installed ${pip_count} pipeline templates → ~/.shipwright/pipelines/"
fi

# ─── Shell Completions ────────────────────────────────────────────────────────
# Detect shell type and install completions to the correct location
SHELL_TYPE=""
if [[ -n "${ZSH_VERSION:-}" ]]; then
    SHELL_TYPE="zsh"
elif [[ -n "${BASH_VERSION:-}" ]]; then
    SHELL_TYPE="bash"
else
    # Try to detect from $SHELL env var
    if [[ "$SHELL" == *"zsh"* ]]; then
        SHELL_TYPE="zsh"
    elif [[ "$SHELL" == *"bash"* ]]; then
        SHELL_TYPE="bash"
    fi
fi

COMPLETIONS_SRC="$REPO_DIR/completions"
install_completions=0

if [[ -z "$SHELL_TYPE" ]]; then
    warn "Could not detect shell type — skipping completions installation"
elif [[ "$SHELL_TYPE" == "zsh" ]]; then
    # Install zsh completion to ~/.zsh/completions/
    ZSH_COMPLETION_DIR="$HOME/.zsh/completions"
    if [[ -f "$COMPLETIONS_SRC/_shipwright" ]]; then
        mkdir -p "$ZSH_COMPLETION_DIR"
        cp "$COMPLETIONS_SRC/_shipwright" "$ZSH_COMPLETION_DIR/_shipwright"
        chmod 644 "$ZSH_COMPLETION_DIR/_shipwright"

        # Ensure fpath includes the completions directory
        if [[ -f "$HOME/.zshrc" ]]; then
            if ! grep -q "fpath.*\.zsh/completions" "$HOME/.zshrc" 2>/dev/null; then
                {
                    echo ""
                    echo "# Shipwright shell completions"
                    echo "fpath+=~/.zsh/completions"
                } >> "$HOME/.zshrc"
                info "Added ~/.zsh/completions to fpath in ~/.zshrc"
            fi
        else
            # Create minimal .zshrc with fpath
            {
                echo "# Shipwright shell completions"
                echo "fpath+=~/.zsh/completions"
                echo "autoload -Uz compinit && compinit"
            } > "$HOME/.zshrc"
            info "Created ~/.zshrc with completions"
        fi

        success "Installed zsh completions → ~/.zsh/completions/_shipwright"
        install_completions=1
    fi
elif [[ "$SHELL_TYPE" == "bash" ]]; then
    # Install bash completion to ~/.local/share/bash-completion/completions/ (Linux/macOS)
    BASH_COMPLETION_DIR="$HOME/.local/share/bash-completion/completions"
    if [[ -f "$COMPLETIONS_SRC/shipwright.bash" ]]; then
        mkdir -p "$BASH_COMPLETION_DIR"
        cp "$COMPLETIONS_SRC/shipwright.bash" "$BASH_COMPLETION_DIR/shipwright"
        chmod 644 "$BASH_COMPLETION_DIR/shipwright"

        # Also try to add to .bashrc for systems without bash-completion infrastructure
        if [[ -f "$HOME/.bashrc" ]]; then
            if ! grep -q "bash-completion/completions" "$HOME/.bashrc" 2>/dev/null && \
               ! grep -q "source.*shipwright.bash" "$HOME/.bashrc" 2>/dev/null; then
                {
                    echo ""
                    echo "# Shipwright shell completions"
                    echo "[[ -r $HOME/.local/share/bash-completion/completions/shipwright ]] && source $HOME/.local/share/bash-completion/completions/shipwright"
                } >> "$HOME/.bashrc"
                info "Added completion source to ~/.bashrc"
            fi
        fi

        success "Installed bash completions → ~/.local/share/bash-completion/completions/shipwright"
        install_completions=1
    fi
fi

if [[ $install_completions -eq 1 ]]; then
    echo -e "  ${DIM}Reload your shell config to activate:${RESET}"
    if [[ "$SHELL_TYPE" == "zsh" ]]; then
        echo -e "    ${DIM}source ~/.zshrc${RESET}"
    elif [[ "$SHELL_TYPE" == "bash" ]]; then
        echo -e "    ${DIM}source ~/.bashrc${RESET}"
    fi
fi

# ─── Claude Code Settings ────────────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
SETTINGS_TEMPLATE="$REPO_DIR/claude-code/settings.json.template"

mkdir -p "$CLAUDE_DIR"

if [[ -f "$SETTINGS_FILE" ]]; then
    # Settings exists — check for agent teams env var
    if grep -q 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' "$SETTINGS_FILE" 2>/dev/null; then
        success "Agent teams already enabled in settings.json"
    else
        # Try to add using jq
        if jq -e '.env' "$SETTINGS_FILE" &>/dev/null 2>&1; then
            tmp=$(mktemp)
            jq '.env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
            success "Enabled agent teams in existing settings.json"
        elif jq -e '.' "$SETTINGS_FILE" &>/dev/null 2>&1; then
            tmp=$(mktemp)
            jq '. + {"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
            success "Added agent teams env to settings.json"
        else
            warn "Could not auto-configure settings.json (JSONC detected)"
            echo -e "    ${DIM}Add to ~/.claude/settings.json:${RESET}"
            echo -e "    ${DIM}\"env\": { \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\" }${RESET}"
        fi
    fi
elif [[ -f "$SETTINGS_TEMPLATE" ]]; then
    # Strip JSONC comments (// lines) so jq can parse on subsequent runs
    tmp=$(mktemp)
    sed '/^[[:space:]]*\/\//d' "$SETTINGS_TEMPLATE" > "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
    success "Installed ~/.claude/settings.json (with agent teams enabled)"
else
    # Create minimal settings.json with agent teams
    cat > "$SETTINGS_FILE" << 'SETTINGS_EOF'
{
  "hooks": {},
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY": "5",
    "CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE": "70",
    "CLAUDE_CODE_SUBAGENT_MODEL": "haiku"
  }
}
SETTINGS_EOF
    success "Created ~/.claude/settings.json with agent teams enabled"
fi

# ─── Hooks ────────────────────────────────────────────────────────────────────
HOOKS_SRC="$REPO_DIR/claude-code/hooks"
if [[ -d "$HOOKS_SRC" ]]; then
    mkdir -p "$CLAUDE_DIR/hooks"
    hook_count=0
    for hook in "$HOOKS_SRC"/*.sh; do
        [[ -f "$hook" ]] || continue
        dest="$CLAUDE_DIR/hooks/$(basename "$hook")"
        if [[ ! -f "$dest" ]]; then
            cp "$hook" "$dest"
            chmod +x "$dest"
            hook_count=$((hook_count + 1))
        fi
    done
    if [[ $hook_count -gt 0 ]]; then
        success "Installed ${hook_count} quality gate hooks → ~/.claude/hooks/"
    else
        info "Hooks already installed — skipping"
    fi
fi

# ─── Wire Hooks into settings.json ──────────────────────────────────────────
# Ensure each installed hook has a matching event config in settings.json
if [[ -f "$SETTINGS_FILE" ]] && jq -e '.' "$SETTINGS_FILE" &>/dev/null; then
    hooks_wired=0

    # Ensure .hooks object exists
    if ! jq -e '.hooks' "$SETTINGS_FILE" &>/dev/null; then
        tmp=$(mktemp)
        jq '.hooks = {}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
    fi

    # TeammateIdle
    if [[ -f "$CLAUDE_DIR/hooks/teammate-idle.sh" ]] && ! jq -e '.hooks.TeammateIdle' "$SETTINGS_FILE" &>/dev/null; then
        tmp=$(mktemp)
        jq '.hooks.TeammateIdle = [{"hooks": [{"type": "command", "command": "~/.claude/hooks/teammate-idle.sh", "timeout": 30, "statusMessage": "Running typecheck before idle..."}]}]' \
            "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        hooks_wired=$((hooks_wired + 1))
    fi

    # TaskCompleted
    if [[ -f "$CLAUDE_DIR/hooks/task-completed.sh" ]] && ! jq -e '.hooks.TaskCompleted' "$SETTINGS_FILE" &>/dev/null; then
        tmp=$(mktemp)
        jq '.hooks.TaskCompleted = [{"hooks": [{"type": "command", "command": "~/.claude/hooks/task-completed.sh", "timeout": 60, "statusMessage": "Running quality checks..."}]}]' \
            "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        hooks_wired=$((hooks_wired + 1))
    fi

    # Notification
    if [[ -f "$CLAUDE_DIR/hooks/notify-idle.sh" ]] && ! jq -e '.hooks.Notification' "$SETTINGS_FILE" &>/dev/null; then
        tmp=$(mktemp)
        jq '.hooks.Notification = [{"hooks": [{"type": "command", "command": "~/.claude/hooks/notify-idle.sh", "async": true}]}]' \
            "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        hooks_wired=$((hooks_wired + 1))
    fi

    # PreCompact
    if [[ -f "$CLAUDE_DIR/hooks/pre-compact-save.sh" ]] && ! jq -e '.hooks.PreCompact' "$SETTINGS_FILE" &>/dev/null; then
        tmp=$(mktemp)
        jq '.hooks.PreCompact = [{"matcher": "auto", "hooks": [{"type": "command", "command": "~/.claude/hooks/pre-compact-save.sh", "statusMessage": "Saving context before compaction..."}]}]' \
            "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        hooks_wired=$((hooks_wired + 1))
    fi

    # SessionStart
    if [[ -f "$CLAUDE_DIR/hooks/session-start.sh" ]] && ! jq -e '.hooks.SessionStart' "$SETTINGS_FILE" &>/dev/null; then
        tmp=$(mktemp)
        jq '.hooks.SessionStart = [{"hooks": [{"type": "command", "command": "~/.claude/hooks/session-start.sh", "timeout": 5}]}]' \
            "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        hooks_wired=$((hooks_wired + 1))
    fi

    if [[ $hooks_wired -gt 0 ]]; then
        success "Wired ${hooks_wired} hooks into settings.json"
    fi
fi

# ─── CLAUDE.md — Global agent instructions ────────────────────────────────────
CLAUDE_MD_SRC="$REPO_DIR/claude-code/CLAUDE.md.shipwright"
GLOBAL_CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"

if [[ "$SKIP_CLAUDE_MD" == "false" && -f "$CLAUDE_MD_SRC" ]]; then
    if [[ -f "$GLOBAL_CLAUDE_MD" ]]; then
        if grep -q "Shipwright" "$GLOBAL_CLAUDE_MD" 2>/dev/null; then
            info "~/.claude/CLAUDE.md already contains Shipwright instructions"
        else
            { echo ""; echo "---"; echo ""; cat "$CLAUDE_MD_SRC"; } >> "$GLOBAL_CLAUDE_MD"
            success "Appended Shipwright instructions to ~/.claude/CLAUDE.md"
        fi
    else
        cp "$CLAUDE_MD_SRC" "$GLOBAL_CLAUDE_MD"
        success "Installed ~/.claude/CLAUDE.md"
    fi
fi

# ─── CLAUDE.md — Per-repo agent instructions ─────────────────────────────────
LOCAL_CLAUDE_MD=".claude/CLAUDE.md"

if [[ "$SKIP_CLAUDE_MD" == "false" && -f "$CLAUDE_MD_SRC" ]]; then
    if [[ -f "$LOCAL_CLAUDE_MD" ]]; then
        if grep -q "Shipwright" "$LOCAL_CLAUDE_MD" 2>/dev/null; then
            info ".claude/CLAUDE.md already contains Shipwright instructions"
        else
            { echo ""; echo "---"; echo ""; cat "$CLAUDE_MD_SRC"; } >> "$LOCAL_CLAUDE_MD"
            success "Appended Shipwright instructions to ${LOCAL_CLAUDE_MD}"
        fi
    else
        mkdir -p ".claude"
        cp "$CLAUDE_MD_SRC" "$LOCAL_CLAUDE_MD"
        success "Created ${LOCAL_CLAUDE_MD} with Shipwright agent instructions"
    fi
fi

# ─── Reload tmux if inside a session ──────────────────────────────────────────
if [[ -n "${TMUX:-}" ]]; then
    if tmux source-file "$HOME/.tmux.conf" 2>/dev/null; then
        tmux source-file -q "$HOME/.tmux/shipwright-overlay.conf" 2>/dev/null || true
        success "Reloaded tmux config + overlay"
    else
        warn "Could not reload tmux config (reload manually with prefix + r)"
    fi
fi

# ─── Validation ───────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}Running doctor...${RESET}"
echo ""
"$SCRIPT_DIR/sw-doctor.sh" || true

echo ""
echo -e "${BOLD}Quick start:${RESET}"
if [[ -z "${TMUX:-}" ]]; then
    echo -e "  ${DIM}1.${RESET} tmux new -s dev"
    echo -e "  ${DIM}2.${RESET} shipwright session my-feature --template feature-dev"
else
    echo -e "  ${DIM}1.${RESET} shipwright session my-feature --template feature-dev"
fi
echo ""

# ─── Deploy setup (--deploy) ─────────────────────────────────────────────────
[[ "$DEPLOY_SETUP" == "false" ]] && exit 0

echo -e "${CYAN}${BOLD}Deploy Setup${RESET}"
echo -e "${DIM}══════════════════════════════════════════${RESET}"
echo ""

# Platform detection
detect_deploy_platform() {
    local detected=""

    for adapter_file in "$ADAPTERS_DIR"/*-deploy.sh; do
        [[ -f "$adapter_file" ]] || continue
        # Source the adapter in a subshell to get detection
        if ( source "$adapter_file" && detect_platform ); then
            local name
            name=$(basename "$adapter_file" | sed 's/-deploy\.sh$//')
            if [[ -n "$detected" ]]; then
                detected="$detected $name"
            else
                detected="$name"
            fi
        fi
    done

    echo "$detected"
}

if [[ -n "$DEPLOY_PLATFORM" ]]; then
    # User specified --platform, validate it
    if [[ ! -f "$ADAPTERS_DIR/${DEPLOY_PLATFORM}-deploy.sh" ]]; then
        error "Unknown platform: $DEPLOY_PLATFORM"
        echo -e "  Available: vercel, fly, railway, docker"
        exit 1
    fi
    info "Using specified platform: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
else
    info "Detecting deploy platform..."
    detected=$(detect_deploy_platform)

    if [[ -z "$detected" ]]; then
        warn "No platform detected in current directory"
        echo ""
        echo -e "  Supported platforms:"
        echo -e "    ${CYAN}vercel${RESET}   — vercel.json or .vercel/"
        echo -e "    ${CYAN}fly${RESET}      — fly.toml"
        echo -e "    ${CYAN}railway${RESET}  — railway.toml or .railway/"
        echo -e "    ${CYAN}docker${RESET}   — Dockerfile or docker-compose.yml"
        echo ""
        echo -e "  Specify manually: ${DIM}shipwright init --deploy --platform vercel${RESET}"
        exit 1
    fi

    # If multiple platforms detected, use the first and warn
    platform_count=$(echo "$detected" | wc -w | tr -d ' ')
    DEPLOY_PLATFORM=$(echo "$detected" | awk '{print $1}')

    if [[ "$platform_count" -gt 1 ]]; then
        warn "Multiple platforms detected: ${BOLD}${detected}${RESET}"
        info "Using: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
        echo -e "  ${DIM}Override with: shipwright init --deploy --platform <name>${RESET}"
        echo ""
    else
        success "Detected platform: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
    fi

    # Confirm with user
    read -rp "$(echo -e "${CYAN}${BOLD}▸${RESET} Configure deploy for ${BOLD}${DEPLOY_PLATFORM}${RESET}? [Y/n] ")" confirm
    if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "n" ]]; then
        info "Aborted. Use --platform to specify manually."
        exit 0
    fi
fi

# Source the adapter to get command values
ADAPTER_FILE="$ADAPTERS_DIR/${DEPLOY_PLATFORM}-deploy.sh"
source "$ADAPTER_FILE"

staging_cmd=$(get_staging_cmd)
production_cmd=$(get_production_cmd)
rollback_cmd=$(get_rollback_cmd)
health_url=$(get_health_url)
smoke_cmd=$(get_smoke_cmd)

# Generate deployed.json from template
TEMPLATE_SRC="$REPO_DIR/templates/pipelines/deployed.json"
TEMPLATE_DST=".claude/pipeline-templates/deployed.json"

if [[ ! -f "$TEMPLATE_SRC" ]]; then
    error "Template not found: $TEMPLATE_SRC"
    exit 1
fi

mkdir -p ".claude/pipeline-templates"

# Use jq to properly fill in the template values
jq --arg staging "$staging_cmd" \
   --arg production "$production_cmd" \
   --arg rollback "$rollback_cmd" \
   --arg health "$health_url" \
   --arg smoke "$smoke_cmd" \
   --arg platform "$DEPLOY_PLATFORM" \
   '
   .name = "deployed-" + $platform |
   .description = "Autonomous pipeline with " + $platform + " deploy — generated by shipwright init --deploy" |
   (.stages[] | select(.id == "deploy") | .config) |= {
       staging_cmd: $staging,
       production_cmd: $production,
       rollback_cmd: $rollback
   } |
   (.stages[] | select(.id == "validate") | .config) |= {
       smoke_cmd: $smoke,
       health_url: $health,
       close_issue: true
   } |
   (.stages[] | select(.id == "monitor") | .config) |= (
       .health_url = $health |
       .rollback_cmd = $rollback
   )
   ' "$TEMPLATE_SRC" > "$TEMPLATE_DST"

success "Generated ${BOLD}${TEMPLATE_DST}${RESET}"

echo ""
echo -e "${BOLD}Deploy configured for ${DEPLOY_PLATFORM}!${RESET}"
echo ""
echo -e "${BOLD}Commands configured:${RESET}"
echo -e "  ${DIM}staging:${RESET}    $staging_cmd"
echo -e "  ${DIM}production:${RESET} $production_cmd"
echo -e "  ${DIM}rollback:${RESET}   $rollback_cmd"
if [[ -n "$health_url" ]]; then
    echo -e "  ${DIM}health:${RESET}     $health_url"
fi
echo ""
echo -e "${BOLD}Usage:${RESET}"
echo -e "  ${DIM}shipwright pipeline start --issue 42 --template .claude/pipeline-templates/deployed.json${RESET}"
echo ""
echo -e "${DIM}Edit ${TEMPLATE_DST} to customize deploy commands, gates, or thresholds.${RESET}"
echo ""
