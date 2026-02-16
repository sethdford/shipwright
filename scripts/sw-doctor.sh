#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-doctor.sh — Validate Shipwright setup                       ║
# ║                                                                          ║
# ║  Checks prerequisites, installed files, PATH, and common issues.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.1.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
_COMPAT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compat.sh"
# shellcheck source=lib/compat.sh
[[ -f "$_COMPAT" ]] && source "$_COMPAT"

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*"; }

PASS=0
WARN=0
FAIL=0

check_pass() { success "$*"; PASS=$((PASS + 1)); }
check_warn() { warn "$*"; WARN=$((WARN + 1)); }
check_fail() { error "$*"; FAIL=$((FAIL + 1)); }

# ─── Header ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}  Shipwright — Doctor${RESET}"
echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 1. Prerequisites
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  PREREQUISITES${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# tmux
if command -v tmux &>/dev/null; then
    TMUX_VERSION="$(tmux -V | grep -oE '[0-9]+\.[0-9a-z]+')"
    TMUX_MAJOR="$(echo "$TMUX_VERSION" | cut -d. -f1)"
    TMUX_MINOR="$(echo "$TMUX_VERSION" | cut -d. -f2 | tr -dc '0-9')"
    if [[ "$TMUX_MAJOR" -ge 3 && "$TMUX_MINOR" -ge 3 ]] || [[ "$TMUX_MAJOR" -ge 4 ]]; then
        check_pass "tmux ${TMUX_VERSION} (all features: passthrough, popups, extended-keys)"
    elif [[ "$TMUX_MAJOR" -ge 3 && "$TMUX_MINOR" -ge 2 ]]; then
        check_warn "tmux ${TMUX_VERSION} — 3.3+ recommended for allow-passthrough"
    else
        check_warn "tmux ${TMUX_VERSION} — 3.2+ required, 3.3+ recommended"
    fi
else
    check_fail "tmux not installed"
    echo -e "    ${DIM}brew install tmux  (macOS)${RESET}"
    echo -e "    ${DIM}sudo apt install tmux  (Ubuntu/Debian)${RESET}"
fi

# TPM (Tmux Plugin Manager)
if [[ -d "$HOME/.tmux/plugins/tpm" ]]; then
    check_pass "TPM installed"
else
    check_warn "TPM not installed — run: shipwright tmux install"
fi

# jq
if command -v jq &>/dev/null; then
    check_pass "jq $(jq --version 2>&1 | tr -d 'jq-')"
else
    check_fail "jq not installed — required for template parsing"
    echo -e "    ${DIM}brew install jq${RESET}  (macOS)"
    echo -e "    ${DIM}sudo apt install jq${RESET}  (Ubuntu/Debian)"
fi

# Claude Code CLI
if command -v claude &>/dev/null; then
    check_pass "Claude Code CLI found"
else
    check_fail "Claude Code CLI not found"
    echo -e "    ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
fi

# Node.js
if command -v node &>/dev/null; then
    NODE_VERSION="$(node -v | tr -d 'v')"
    NODE_MAJOR="$(echo "$NODE_VERSION" | cut -d. -f1)"
    if [[ "$NODE_MAJOR" -ge 20 ]]; then
        check_pass "Node.js ${NODE_VERSION}"
    else
        check_warn "Node.js ${NODE_VERSION} — 20+ recommended"
    fi
else
    check_fail "Node.js not found"
fi

# Git
if command -v git &>/dev/null; then
    check_pass "git $(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
else
    check_fail "git not found"
fi

# Bash version
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
BASH_MINOR="${BASH_VERSINFO[1]:-0}"
if [[ "$BASH_MAJOR" -ge 5 ]]; then
    check_pass "bash ${BASH_VERSION}"
elif [[ "$BASH_MAJOR" -ge 4 ]]; then
    check_pass "bash ${BASH_VERSION}"
else
    check_warn "bash ${BASH_VERSION} — 4.0+ required for associative arrays"
    echo -e "    ${DIM}brew install bash  (macOS ships 3.2)${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. Installed Files
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  INSTALLED FILES${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# tmux overlay
if [[ -f "$HOME/.tmux/shipwright-overlay.conf" ]]; then
    check_pass "Overlay: ~/.tmux/shipwright-overlay.conf"
else
    check_fail "Overlay not found: ~/.tmux/shipwright-overlay.conf"
    echo -e "    ${DIM}Re-run install.sh to install it${RESET}"
fi

# Overlay sourced in tmux.conf
if [[ -f "$HOME/.tmux.conf" ]]; then
    if grep -q "shipwright-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
        check_pass "Overlay sourced in ~/.tmux.conf"
    else
        check_warn "Overlay not sourced in ~/.tmux.conf"
        echo -e "    ${DIM}Add: source-file -q ~/.tmux/shipwright-overlay.conf${RESET}"
    fi
else
    check_warn "No ~/.tmux.conf found"
fi

# Claude settings
if [[ -f "$HOME/.claude/settings.json" ]]; then
    check_pass "Settings: ~/.claude/settings.json"
else
    check_warn "No ~/.claude/settings.json"
    echo -e "    ${DIM}Copy from settings.json.template${RESET}"
fi

# Hooks directory
HOOKS_DIR="$HOME/.claude/hooks"
if [[ -d "$HOOKS_DIR" ]]; then
    hook_count=0
    non_exec=0
    while IFS= read -r hook; do
        [[ -z "$hook" ]] && continue
        hook_count=$((hook_count + 1))
        if [[ ! -x "$hook" ]]; then
            non_exec=$((non_exec + 1))
        fi
    done < <(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)

    if [[ $hook_count -gt 0 && $non_exec -eq 0 ]]; then
        check_pass "Hooks: ${hook_count} scripts, all executable"
    elif [[ $hook_count -gt 0 && $non_exec -gt 0 ]]; then
        check_warn "Hooks: ${non_exec}/${hook_count} scripts not executable"
        echo -e "    ${DIM}chmod +x ~/.claude/hooks/*.sh${RESET}"
    else
        check_warn "Hooks dir exists but no .sh scripts found"
    fi
else
    check_warn "No hooks directory at ~/.claude/hooks/"
fi

# Hook wiring validation — check hooks are configured in settings.json
if [[ -d "$HOOKS_DIR" && -f "$HOME/.claude/settings.json" ]] && jq -e '.' "$HOME/.claude/settings.json" &>/dev/null; then
    wired=0 unwired=0 hook_total_check=0
    # Colon-separated pairs: filename:EventName (Bash 3.2 compatible)
    for pair in \
        "teammate-idle.sh:TeammateIdle" \
        "task-completed.sh:TaskCompleted" \
        "notify-idle.sh:Notification" \
        "pre-compact-save.sh:PreCompact" \
        "session-start.sh:SessionStart"; do
        hfile="" hevent=""
        IFS=':' read -r hfile hevent <<< "$pair"
        # Only check hooks that are actually installed
        [[ -f "$HOOKS_DIR/$hfile" ]] || continue
        hook_total_check=$((hook_total_check + 1))
        if jq -e ".hooks.${hevent}" "$HOME/.claude/settings.json" &>/dev/null; then
            wired=$((wired + 1))
        else
            unwired=$((unwired + 1))
            check_warn "Hook ${hfile} not wired to ${hevent} event in settings.json"
        fi
    done
    if [[ $hook_total_check -gt 0 && $unwired -eq 0 ]]; then
        check_pass "Hooks wired in settings.json: ${wired}/${hook_total_check}"
    elif [[ $unwired -gt 0 ]]; then
        echo -e "    ${DIM}Run: shipwright init  to wire hooks${RESET}"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. Agent Teams
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  AGENT TEAMS${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# Agent teams env var in settings.json
SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
    if grep -q 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' "$SETTINGS_FILE" 2>/dev/null; then
        check_pass "Agent teams enabled in settings.json"
    else
        check_fail "Agent teams NOT enabled in settings.json"
        echo -e "    ${DIM}Run: shipwright init${RESET}"
        echo -e "    ${DIM}Or add to ~/.claude/settings.json:${RESET}"
        echo -e "    ${DIM}\"env\": { \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\" }${RESET}"
    fi
else
    check_fail "No ~/.claude/settings.json — agent teams not configured"
    echo -e "    ${DIM}Run: shipwright init${RESET}"
fi

# CLAUDE.md with Shipwright instructions
GLOBAL_CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [[ -f "$GLOBAL_CLAUDE_MD" ]]; then
    if grep -q "Shipwright" "$GLOBAL_CLAUDE_MD" 2>/dev/null; then
        check_pass "CLAUDE.md contains Shipwright instructions"
    else
        check_warn "CLAUDE.md exists but missing Shipwright instructions"
        echo -e "    ${DIM}Run: shipwright init${RESET}"
    fi
else
    check_warn "No ~/.claude/CLAUDE.md — agents won't know Shipwright commands"
    echo -e "    ${DIM}Run: shipwright init${RESET}"
fi

# Team templates
TEMPLATES_DIR="$HOME/.shipwright/templates"
if [[ -d "$TEMPLATES_DIR" ]]; then
    tpl_count=0
    while IFS= read -r f; do
        [[ -n "$f" ]] && tpl_count=$((tpl_count + 1))
    done < <(find "$TEMPLATES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
    if [[ $tpl_count -gt 0 ]]; then
        check_pass "Team templates: ${tpl_count} installed"
    else
        check_warn "Template dir exists but no .json files found"
    fi
else
    check_warn "No team templates at ~/.shipwright/templates/"
    echo -e "    ${DIM}Run: shipwright init${RESET}"
fi

# Pipeline templates
PIPELINES_DIR="$HOME/.shipwright/pipelines"
if [[ -d "$PIPELINES_DIR" ]]; then
    pip_count=0
    while IFS= read -r f; do
        [[ -n "$f" ]] && pip_count=$((pip_count + 1))
    done < <(find "$PIPELINES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
    if [[ $pip_count -gt 0 ]]; then
        check_pass "Pipeline templates: ${pip_count} installed"
    else
        check_warn "Pipeline dir exists but no .json files found"
    fi
else
    check_warn "No pipeline templates at ~/.shipwright/pipelines/"
    echo -e "    ${DIM}Run: shipwright init${RESET}"
fi

# GitHub CLI
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
        GH_USER="$(gh api user -q .login 2>/dev/null || echo "authenticated")"
        check_pass "GitHub CLI: ${GH_USER}"
    else
        check_warn "GitHub CLI installed but not authenticated"
        echo -e "    ${DIM}gh auth login${RESET}"
    fi
else
    check_warn "GitHub CLI (gh) not installed — daemon/pipeline need it for PRs and issues"
    echo -e "    ${DIM}brew install gh${RESET}  (macOS)"
    echo -e "    ${DIM}sudo apt install gh${RESET}  (Ubuntu/Debian)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. PATH & CLI
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  PATH & CLI${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

BIN_DIR="$HOME/.local/bin"

if echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    check_pass "${BIN_DIR} is in PATH"
else
    check_warn "${BIN_DIR} is NOT in PATH"
    echo -e "    ${DIM}Add to ~/.zshrc or ~/.bashrc:${RESET}"
    echo -e "    ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
fi

# Check sw subcommands are installed alongside the router
if command -v sw &>/dev/null; then
    SW_DIR="$(dirname "$(command -v sw)")"
    check_pass "shipwright router found at ${SW_DIR}/sw"

    missing_subs=()
    for sub in sw-session.sh sw-status.sh sw-cleanup.sh; do
        if [[ ! -x "${SW_DIR}/${sub}" ]]; then
            missing_subs+=("$sub")
        fi
    done

    if [[ ${#missing_subs[@]} -eq 0 ]]; then
        check_pass "All core subcommands installed"
    else
        check_warn "Missing subcommands: ${missing_subs[*]}"
        echo -e "    ${DIM}Re-run install.sh or shipwright upgrade --apply${RESET}"
    fi
else
    check_fail "shipwright command not found in PATH"
    echo -e "    ${DIM}Re-run install.sh to install the CLI${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 5. Pane Display
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  PANE DISPLAY${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# Check overlay file exists
if [[ -f "$HOME/.tmux/shipwright-overlay.conf" ]]; then
    # Check for set-hook color enforcement
    if grep -q "set-hook.*after-split-window" "$HOME/.tmux/shipwright-overlay.conf" 2>/dev/null; then
        check_pass "Overlay has color hooks (set-hook)"
    else
        check_warn "Overlay missing color hooks — new panes may flash white"
        echo -e "    ${DIM}Run: shipwright upgrade --apply  or  shipwright init${RESET}"
    fi
else
    check_fail "Overlay not found — pane display features unavailable"
fi

# Check if set-hook commands are active in tmux
if [[ -n "${TMUX:-}" ]]; then
    if tmux show-hooks -g 2>/dev/null | grep -q "after-split-window"; then
        check_pass "set-hook commands active in tmux"
    else
        check_warn "set-hook commands not active — reload config: prefix + r"
    fi

    # Check default-terminal
    TMUX_TERM="$(tmux show-option -gv default-terminal 2>/dev/null || echo "unknown")"
    if [[ "$TMUX_TERM" == *"256color"* ]]; then
        check_pass "default-terminal: $TMUX_TERM"
    else
        check_warn "default-terminal: $TMUX_TERM — 256color variant recommended"
        echo -e "    ${DIM}set -g default-terminal 'tmux-256color'${RESET}"
    fi

    # Check pane border includes cyan accent
    BORDER_FMT="$(tmux show-option -gv pane-border-format 2>/dev/null || echo "")"
    if echo "$BORDER_FMT" | grep -q "#00d4ff"; then
        check_pass "Pane border format includes cyan accent"
    else
        check_warn "Pane border format missing cyan accent — overlay may not be loaded"
    fi
    # Check Claude Code compatibility settings
    PASSTHROUGH="$(tmux show-option -gv allow-passthrough 2>/dev/null || echo "off")"
    if [[ "$PASSTHROUGH" == "on" ]]; then
        check_pass "allow-passthrough: on (DEC 2026 synchronized output)"
    else
        check_warn "allow-passthrough: ${PASSTHROUGH} — Claude Code may flicker"
        echo -e "    ${DIM}Fix: shipwright tmux fix${RESET}"
    fi

    EXTKEYS="$(tmux show-option -gv extended-keys 2>/dev/null || echo "off")"
    if [[ "$EXTKEYS" == "on" ]]; then
        check_pass "extended-keys: on"
    else
        check_warn "extended-keys: ${EXTKEYS} — some TUI key combos may not work"
    fi

    HIST_LIMIT="$(tmux show-option -gv history-limit 2>/dev/null || echo "2000")"
    if [[ "$HIST_LIMIT" -ge 100000 ]]; then
        check_pass "history-limit: ${HIST_LIMIT}"
    else
        check_warn "history-limit: ${HIST_LIMIT} — 250000+ recommended for Claude Code"
        echo -e "    ${DIM}Fix: shipwright tmux fix${RESET}"
    fi
else
    info "Not in tmux session — skipping runtime display checks"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 6. Orphaned Sessions
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  ORPHAN CHECK${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

orphaned_teams=0
TEAMS_DIR="$HOME/.claude/teams"
if [[ -d "$TEAMS_DIR" ]]; then
    while IFS= read -r team_dir; do
        [[ -z "$team_dir" ]] && continue
        team_name="$(basename "$team_dir")"
        config_file="${team_dir}/config.json"
        if [[ ! -f "$config_file" ]]; then
            orphaned_teams=$((orphaned_teams + 1))
            check_warn "Orphaned team dir: ${team_name} (no config.json)"
        fi
    done < <(find "$TEAMS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

if [[ $orphaned_teams -eq 0 ]]; then
    check_pass "No orphaned team sessions"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 7. Environment & Resources
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  ENVIRONMENT${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# Expected directories
EXPECTED_DIRS=(
    "$HOME/.claude"
    "$HOME/.claude/hooks"
    "$HOME/.shipwright"
    "$HOME/.shipwright"
)
missing_dirs=0
for dir in "${EXPECTED_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        check_pass "Directory: ${dir/#$HOME/\~}"
    else
        check_warn "Missing directory: ${dir/#$HOME/\~}"
        echo -e "    ${DIM}mkdir -p \"$dir\"${RESET}"
        missing_dirs=$((missing_dirs + 1))
    fi
done

# JSON validation for templates
if command -v jq &>/dev/null; then
    json_errors=0
    json_total=0
    for tpl_dir in "$HOME/.shipwright/templates" "$HOME/.shipwright/pipelines"; do
        if [[ -d "$tpl_dir" ]]; then
            while IFS= read -r json_file; do
                [[ -z "$json_file" ]] && continue
                json_total=$((json_total + 1))
                if ! jq -e . "$json_file" &>/dev/null; then
                    check_fail "Invalid JSON: ${json_file/#$HOME/\~}"
                    json_errors=$((json_errors + 1))
                fi
            done < <(find "$tpl_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
        fi
    done
    if [[ $json_total -gt 0 && $json_errors -eq 0 ]]; then
        check_pass "Template JSON: ${json_total} files valid"
    elif [[ $json_total -eq 0 ]]; then
        check_warn "No template JSON files found to validate"
    fi
fi

# Terminal 256-color support
TERM_VAR="${TERM:-}"
if [[ "$TERM_VAR" == *"256color"* || "$TERM_VAR" == "xterm-kitty" || "$TERM_VAR" == "tmux-256color" ]]; then
    check_pass "TERM=$TERM_VAR (256 colors)"
elif [[ -z "$TERM_VAR" ]]; then
    check_warn "TERM not set — colors may not display correctly"
else
    check_warn "TERM=$TERM_VAR — 256color variant recommended for full theme support"
    echo -e "    ${DIM}export TERM=xterm-256color${RESET}"
fi

# Disk space check (warn if < 1GB free)
if [[ "$(uname)" == "Darwin" ]]; then
    FREE_GB="$(df -g "$HOME" 2>/dev/null | awk 'NR==2{print $4}')" || FREE_GB=""
else
    # Linux: df -BG gives output in GB
    FREE_GB="$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')" || FREE_GB=""
fi
if [[ -n "$FREE_GB" && "$FREE_GB" =~ ^[0-9]+$ ]]; then
    if [[ "$FREE_GB" -ge 5 ]]; then
        check_pass "Disk space: ${FREE_GB}GB free"
    elif [[ "$FREE_GB" -ge 1 ]]; then
        check_warn "Disk space: ${FREE_GB}GB free — getting low"
    else
        check_fail "Disk space: ${FREE_GB}GB free — less than 1GB available"
        echo -e "    ${DIM}Free up disk space to avoid pipeline failures${RESET}"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 8. Terminal Compatibility
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  TERMINAL${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

TERM_PROGRAM="${TERM_PROGRAM:-unknown}"

case "$TERM_PROGRAM" in
    iTerm.app|iTerm2)
        check_pass "iTerm2 — full support (true color, SGR mouse, focus events)"
        # Verify mouse reporting is actually enabled in iTerm2 profile
        ITERM_MOUSE="$(defaults read com.googlecode.iterm2 "New Bookmarks" 2>/dev/null | grep '"Mouse Reporting"' | head -1 | grep -oE '[0-9]+' || echo "unknown")"
        if [[ "$ITERM_MOUSE" == "0" ]]; then
            check_fail "iTerm2 mouse reporting is DISABLED — tmux cannot receive mouse clicks"
            echo -e "    ${DIM}Fix: iTerm2 → Preferences → Profiles → Terminal → enable 'Report mouse clicks & drags'${RESET}"
            echo -e "    ${DIM}Or run: ${CYAN}/usr/libexec/PlistBuddy -c \"Set ':New Bookmarks:0:Mouse Reporting' 1\" ~/Library/Preferences/com.googlecode.iterm2.plist${RESET}"
        elif [[ "$ITERM_MOUSE" == "1" ]]; then
            check_pass "iTerm2 mouse reporting: enabled"
        fi
        ;;
    Apple_Terminal)
        check_warn "Terminal.app — limited support"
        echo -e "    ${DIM}No true color (256 colors only), no SGR extended mouse.${RESET}"
        echo -e "    ${DIM}Mouse clicking works, but wide terminals (>223 cols) may mistrack.${RESET}"
        echo -e "    ${DIM}Recommended: use iTerm2 or WezTerm for best experience.${RESET}"
        ;;
    WezTerm)
        check_pass "WezTerm — full support (true color, SGR mouse, focus events)"
        ;;
    tmux)
        # Detect parent terminal when nested inside tmux
        PARENT_TERM="${LC_TERMINAL:-unknown}"
        check_pass "Running inside tmux — parent terminal: ${PARENT_TERM}"
        # Check iTerm2 mouse reporting even when nested inside tmux
        if [[ "$PARENT_TERM" == *iTerm* ]]; then
            ITERM_MOUSE="$(defaults read com.googlecode.iterm2 "New Bookmarks" 2>/dev/null | grep '"Mouse Reporting"' | head -1 | grep -oE '[0-9]+' || echo "unknown")"
            if [[ "$ITERM_MOUSE" == "0" ]]; then
                check_fail "iTerm2 mouse reporting is DISABLED — tmux cannot receive mouse clicks"
                echo -e "    ${DIM}Fix: iTerm2 → Preferences → Profiles → Terminal → enable 'Report mouse clicks & drags'${RESET}"
                echo -e "    ${DIM}Or run: ${CYAN}shipwright init${RESET} (auto-fixes this)${RESET}"
            elif [[ "$ITERM_MOUSE" == "1" ]]; then
                check_pass "iTerm2 mouse reporting: enabled"
            fi
        fi
        ;;
    vscode)
        check_warn "VS Code integrated terminal"
        echo -e "    ${DIM}Some pane border features may not render correctly.${RESET}"
        echo -e "    ${DIM}Consider running tmux in an external terminal.${RESET}"
        ;;
    Ghostty)
        check_pass "Ghostty — full support (true color, SGR mouse)"
        ;;
    Alacritty)
        check_pass "Alacritty — full support (true color, SGR mouse)"
        ;;
    kitty)
        check_pass "kitty — full support (true color, extended keyboard)"
        ;;
    *)
        info "Terminal: ${TERM_PROGRAM}"
        ;;
esac

# Check mouse window clicking (tmux 3.4+ changed the default)
if command -v tmux &>/dev/null && [[ -n "${TMUX:-}" ]]; then
    MOUSE_BIND="$(tmux list-keys 2>/dev/null | grep 'MouseDown1Status' | head -1 || true)"
    if echo "$MOUSE_BIND" | grep -q 'select-window'; then
        check_pass "Mouse window click: select-window (correct)"
    elif echo "$MOUSE_BIND" | grep -q 'switch-client'; then
        check_fail "Mouse window click: switch-client (broken — clicking windows won't work)"
        echo -e "    ${DIM}Fix: add to tmux.conf: bind -T root MouseDown1Status select-window -t =${RESET}"
        echo -e "    ${DIM}Or run: shipwright init${RESET}"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 9. Issue Tracker
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  ISSUE TRACKER${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

TRACKER_CONFIG="${HOME}/.shipwright/tracker-config.json"
if [[ -f "$TRACKER_CONFIG" ]]; then
    TRACKER_PROVIDER=$(jq -r '.provider // "none"' "$TRACKER_CONFIG" 2>/dev/null || echo "none")
    if [[ "$TRACKER_PROVIDER" != "none" && -n "$TRACKER_PROVIDER" ]]; then
        check_pass "Tracker provider: ${TRACKER_PROVIDER}"
        # Validate provider-specific config
        case "$TRACKER_PROVIDER" in
            linear)
                LINEAR_KEY=$(jq -r '.linear.api_key // empty' "$TRACKER_CONFIG" 2>/dev/null || true)
                if [[ -n "$LINEAR_KEY" ]]; then
                    check_pass "Linear API key: configured"
                else
                    check_warn "Linear API key: not set — set via shipwright tracker init or LINEAR_API_KEY env var"
                fi
                ;;
            jira)
                JIRA_URL=$(jq -r '.jira.base_url // empty' "$TRACKER_CONFIG" 2>/dev/null || true)
                JIRA_TOKEN=$(jq -r '.jira.api_token // empty' "$TRACKER_CONFIG" 2>/dev/null || true)
                if [[ -n "$JIRA_URL" && -n "$JIRA_TOKEN" ]]; then
                    check_pass "Jira: configured (${JIRA_URL})"
                else
                    check_warn "Jira: incomplete config — run shipwright jira init"
                fi
                ;;
        esac
    else
        info "  No tracker configured ${DIM}(optional — run shipwright tracker init)${RESET}"
    fi
else
    info "  No tracker configured ${DIM}(optional — run shipwright tracker init)${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 10. Agent Heartbeats & Checkpoints
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  HEARTBEATS & CHECKPOINTS${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

HEARTBEAT_DIR="$HOME/.shipwright/heartbeats"
if [[ -d "$HEARTBEAT_DIR" ]]; then
    check_pass "Heartbeat directory: ${HEARTBEAT_DIR/#$HOME/\~}"
    # Check permissions
    if [[ -w "$HEARTBEAT_DIR" ]]; then
        check_pass "Heartbeat directory: writable"
    else
        check_fail "Heartbeat directory: not writable"
    fi

    # Count active/stale heartbeats
    hb_active=0
    hb_stale=0
    for hb_file in "${HEARTBEAT_DIR}"/*.json; do
        [[ -f "$hb_file" ]] || continue
        hb_updated=$(jq -r '.updated_at // ""' "$hb_file" 2>/dev/null || true)
        if [[ -n "$hb_updated" && "$hb_updated" != "null" ]]; then
            hb_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb_updated" +%s 2>/dev/null || echo 0)
            if [[ "$hb_epoch" -gt 0 ]]; then
                now_e=$(date +%s)
                hb_age=$((now_e - hb_epoch))
                if [[ "$hb_age" -ge 120 ]]; then
                    hb_stale=$((hb_stale + 1))
                else
                    hb_active=$((hb_active + 1))
                fi
            fi
        fi
    done
    if [[ $hb_active -gt 0 ]]; then
        check_pass "Active heartbeats: ${hb_active}"
    fi
    if [[ $hb_stale -gt 0 ]]; then
        check_warn "Stale heartbeats: ${hb_stale} (>120s old)"
        echo -e "    ${DIM}Clean up with: shipwright heartbeat clear <job-id>${RESET}"
    fi
else
    info "  No heartbeat directory ${DIM}(created automatically when agents run)${RESET}"
fi

# Checkpoint directory
CHECKPOINT_DIR=".claude/pipeline-artifacts/checkpoints"
if [[ -d "$CHECKPOINT_DIR" ]]; then
    cp_count=0
    for cp_file in "${CHECKPOINT_DIR}"/*-checkpoint.json; do
        [[ -f "$cp_file" ]] || continue
        cp_count=$((cp_count + 1))
    done
    if [[ $cp_count -gt 0 ]]; then
        check_pass "Checkpoints: ${cp_count} saved"
    else
        check_pass "Checkpoint directory exists (no checkpoints saved)"
    fi
else
    info "  No checkpoint directory ${DIM}(created on first checkpoint save)${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 11. Remote Machines
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  REMOTE MACHINES${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

MACHINES_FILE="$HOME/.shipwright/machines.json"
if [[ -f "$MACHINES_FILE" ]]; then
    machine_count=$(jq '.machines | length' "$MACHINES_FILE" 2>/dev/null || echo 0)
    if [[ "$machine_count" -gt 0 ]]; then
        check_pass "Registered machines: ${machine_count}"
        # Check SSH connectivity (quick check, 5s timeout per machine)
        if command -v ssh &>/dev/null; then
            while IFS= read -r machine; do
                [[ -z "$machine" ]] && continue
                m_name=$(echo "$machine" | jq -r '.name // ""')
                m_host=$(echo "$machine" | jq -r '.host // ""')
                m_user=$(echo "$machine" | jq -r '.user // ""')
                m_port=$(echo "$machine" | jq -r '.port // 22')

                if [[ -n "$m_host" ]]; then
                    ssh_target="${m_user:+${m_user}@}${m_host}"
                    if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$m_port" "$ssh_target" true 2>/dev/null; then
                        check_pass "SSH: ${m_name} (${ssh_target}) reachable"
                    else
                        check_warn "SSH: ${m_name} (${ssh_target}) unreachable"
                        echo -e "    ${DIM}Check SSH key and connectivity: ssh -p ${m_port} ${ssh_target}${RESET}"
                    fi
                fi
            done < <(jq -c '.machines[]' "$MACHINES_FILE" 2>/dev/null)
        fi
    else
        info "  No machines registered ${DIM}(add with: shipwright remote add)${RESET}"
    fi
else
    info "  No remote machines ${DIM}(optional — run shipwright remote add)${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 12. Team Connectivity
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  TEAM CONNECTIVITY${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# Check connect process
CONNECT_PID_FILE="$HOME/.shipwright/connect.pid"
if [[ -f "$CONNECT_PID_FILE" ]]; then
    CONNECT_PID=$(cat "$CONNECT_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$CONNECT_PID" ]]; then
        if kill -0 "$CONNECT_PID" 2>/dev/null; then
            check_pass "Connect process: running (PID ${CONNECT_PID})"
        else
            check_warn "Connect process: PID file exists but process not running"
            echo -e "    ${DIM}Clean up with: rm ${CONNECT_PID_FILE}${RESET}"
        fi
    else
        check_warn "Connect PID file exists but is empty"
    fi
else
    info "  Team connect not configured ${DIM}(optional)${RESET}"
fi

# Check team config
TEAM_CONFIG="$HOME/.shipwright/team-config.json"
if [[ -f "$TEAM_CONFIG" ]]; then
    if jq -e . "$TEAM_CONFIG" &>/dev/null; then
        check_pass "Team config: valid JSON"

        # Check dashboard_url field
        DASHBOARD_URL=$(jq -r '.dashboard_url // empty' "$TEAM_CONFIG" 2>/dev/null || true)
        if [[ -n "$DASHBOARD_URL" ]]; then
            check_pass "Dashboard URL: configured"

            # Try to reach dashboard with 3s timeout
            if command -v curl &>/dev/null; then
                if curl -s -m 3 "${DASHBOARD_URL}/api/health" &>/dev/null; then
                    check_pass "Dashboard reachable: ${DASHBOARD_URL}"
                else
                    check_warn "Dashboard unreachable: ${DASHBOARD_URL}"
                    echo -e "    ${DIM}Check if dashboard service is running or URL is correct${RESET}"
                fi
            else
                info "  curl not found — skipping dashboard health check"
            fi
        else
            check_warn "Team config: missing dashboard_url field"
        fi
    else
        check_fail "Team config: invalid JSON"
        echo -e "    ${DIM}Fix JSON syntax in ${TEAM_CONFIG}${RESET}"
    fi
else
    info "  Team config not found ${DIM}(optional — run shipwright init)${RESET}"
fi

# Check developer registry
DEVELOPER_REGISTRY="$HOME/.shipwright/developer-registry.json"
if [[ -f "$DEVELOPER_REGISTRY" ]]; then
    if jq -e . "$DEVELOPER_REGISTRY" &>/dev/null; then
        check_pass "Developer registry: exists and valid"
    else
        check_fail "Developer registry: invalid JSON"
        echo -e "    ${DIM}Fix JSON syntax in ${DEVELOPER_REGISTRY}${RESET}"
    fi
else
    info "  Developer registry not found ${DIM}(optional)${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 13. GitHub Integration
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  GITHUB INTEGRATION${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null 2>&1; then
        check_pass "gh CLI authenticated"

        # Check required scopes
        gh_scopes=""
        gh_scopes=$(gh auth status 2>&1 | grep -i "token scopes" || echo "")
        if [[ -n "$gh_scopes" ]]; then
            if echo "$gh_scopes" | grep -qi "repo"; then
                check_pass "Token has 'repo' scope"
            else
                check_warn "'repo' scope not detected — some features may not work"
                echo -e "    ${DIM}Fix: gh auth refresh -s repo${RESET}"
            fi
            if echo "$gh_scopes" | grep -qi "read:org"; then
                check_pass "Token has 'read:org' scope"
            else
                check_warn "'read:org' scope not detected — org data may be unavailable"
                echo -e "    ${DIM}Fix: gh auth refresh -s read:org${RESET}"
            fi
        fi

        # Check GraphQL endpoint
        if gh api graphql -f query='{viewer{login}}' &>/dev/null 2>&1; then
            check_pass "GraphQL API accessible"
        else
            check_warn "GraphQL API not accessible — intelligence enrichment will use fallbacks"
        fi

        # Check code scanning API
        dr_repo_owner=""
        dr_repo_name=""
        dr_repo_owner=$(git remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+)/[^/]+(\.git)?$#\1#' || echo "")
        dr_repo_name=$(git remote get-url origin 2>/dev/null | sed -E 's#.*/([^/]+)(\.git)?$#\1#' || echo "")
        if [[ -n "$dr_repo_owner" && -n "$dr_repo_name" ]]; then
            if gh api "repos/$dr_repo_owner/$dr_repo_name/code-scanning/alerts?per_page=1" &>/dev/null 2>&1; then
                check_pass "Code scanning API accessible"
            else
                info "  Code scanning API not available ${DIM}(may need GitHub Advanced Security)${RESET}"
            fi
        fi

        # Check CODEOWNERS file
        if [[ -f "CODEOWNERS" || -f ".github/CODEOWNERS" || -f "docs/CODEOWNERS" ]]; then
            check_pass "CODEOWNERS file found"
        else
            info "  No CODEOWNERS file ${DIM}(reviewer selection will use contributor data)${RESET}"
        fi

        # Check GitHub modules installed
        _DOCTOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$_DOCTOR_SCRIPT_DIR/sw-github-graphql.sh" ]]; then
            check_pass "GitHub GraphQL module installed"
        else
            info "  GitHub GraphQL module not found ${DIM}(scripts/sw-github-graphql.sh)${RESET}"
        fi
        if [[ -f "$_DOCTOR_SCRIPT_DIR/sw-github-checks.sh" ]]; then
            check_pass "GitHub Checks module installed"
        else
            info "  GitHub Checks module not found ${DIM}(scripts/sw-github-checks.sh)${RESET}"
        fi
        if [[ -f "$_DOCTOR_SCRIPT_DIR/sw-github-deploy.sh" ]]; then
            check_pass "GitHub Deploy module installed"
        else
            info "  GitHub Deploy module not found ${DIM}(scripts/sw-github-deploy.sh)${RESET}"
        fi
    else
        check_warn "gh CLI not authenticated — run: ${DIM}gh auth login${RESET}"
    fi
else
    check_warn "gh CLI not installed — GitHub integration disabled"
    echo -e "    ${DIM}Install: brew install gh (macOS) or see https://cli.github.com${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 14. Dashboard & Dependencies
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  DASHBOARD & DEPENDENCIES${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# Bun runtime
if command -v bun &>/dev/null; then
    bun_ver="$(bun --version 2>/dev/null || echo "unknown")"
    check_pass "bun $bun_ver"
else
    check_warn "bun not found — required for shipwright dashboard"
    echo -e "    ${DIM}Install: curl -fsSL https://bun.sh/install | bash${RESET}"
fi

# Dashboard files — check multiple locations
_DOCTOR_SCRIPT_DIR="${_DOCTOR_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
_DOCTOR_REPO_DIR="$(cd "$_DOCTOR_SCRIPT_DIR/.." 2>/dev/null && pwd 2>/dev/null || echo "")"
_DASHBOARD_DIR=""

if [[ -n "$_DOCTOR_REPO_DIR" && -f "$_DOCTOR_REPO_DIR/dashboard/server.ts" ]]; then
    _DASHBOARD_DIR="$_DOCTOR_REPO_DIR/dashboard"
elif [[ -f "$HOME/.local/share/shipwright/dashboard/server.ts" ]]; then
    _DASHBOARD_DIR="$HOME/.local/share/shipwright/dashboard"
fi

if [[ -n "$_DASHBOARD_DIR" ]]; then
    check_pass "Dashboard server found: ${DIM}$_DASHBOARD_DIR/server.ts${RESET}"
    if [[ -f "$_DASHBOARD_DIR/public/index.html" ]]; then
        check_pass "Dashboard frontend found"
    else
        check_warn "Dashboard public/index.html not found"
    fi
else
    check_warn "Dashboard files not found"
    echo -e "    ${DIM}Expected: dashboard/server.ts in repo or ~/.local/share/shipwright/dashboard/${RESET}"
fi

# Port 3000 availability
if command -v lsof &>/dev/null; then
    if lsof -i :3000 -sTCP:LISTEN &>/dev/null 2>&1; then
        dr_port_proc="$(lsof -i :3000 -sTCP:LISTEN -t 2>/dev/null | head -1 || echo "unknown")"
        check_warn "Port 3000 in use (PID: $dr_port_proc) — dashboard may need a different port"
        echo -e "    ${DIM}Use: shipwright dashboard start --port 3001${RESET}"
    else
        check_pass "Port 3000 available"
    fi
elif command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ':3000 '; then
        check_warn "Port 3000 in use — dashboard may need a different port"
    else
        check_pass "Port 3000 available"
    fi
else
    info "  Port check skipped ${DIM}(lsof/ss not found)${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 15. Database Health
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${PURPLE}${BOLD}  DATABASE HEALTH${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

if command -v sqlite3 &>/dev/null; then
    _sqlite_ver="$(sqlite3 --version 2>/dev/null | cut -d' ' -f1 || echo "unknown")"
    check_pass "sqlite3 ${_sqlite_ver}"

    _db_file="${HOME}/.shipwright/shipwright.db"
    if [[ -f "$_db_file" ]]; then
        check_pass "Database exists: ${DIM}${_db_file}${RESET}"

        # Check WAL mode
        _wal_mode=$(sqlite3 "$_db_file" "PRAGMA journal_mode;" 2>/dev/null || echo "unknown")
        if [[ "$_wal_mode" == "wal" ]]; then
            check_pass "WAL mode enabled"
        else
            check_warn "WAL mode not enabled (current: ${_wal_mode})"
        fi

        # Check schema version
        _schema_ver=$(sqlite3 "$_db_file" "SELECT MAX(version) FROM _schema;" 2>/dev/null || echo "0")
        if [[ "${_schema_ver:-0}" -ge 2 ]]; then
            check_pass "Schema version: ${_schema_ver}"
        else
            check_warn "Schema version ${_schema_ver:-0} — expected >= 2. Run: shipwright db init"
        fi

        # Check file size
        _db_size=$(ls -l "$_db_file" 2>/dev/null | awk '{print $5}')
        _db_size_mb=$(awk -v s="${_db_size:-0}" 'BEGIN { printf "%.1f", s / 1048576 }')
        check_pass "Database size: ${_db_size_mb} MB"

        # Check table counts
        _event_count=$(sqlite3 "$_db_file" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
        _run_count=$(sqlite3 "$_db_file" "SELECT COUNT(*) FROM pipeline_runs;" 2>/dev/null || echo "0")
        info "  Tables: events=${_event_count} pipeline_runs=${_run_count}"
    else
        check_warn "Database not initialized — run: shipwright db init"
    fi
else
    check_warn "sqlite3 not installed — DB features disabled"
    echo -e "    ${DIM}Install: brew install sqlite (macOS) or apt install sqlite3 (Linux)${RESET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

TOTAL=$((PASS + WARN + FAIL))

echo -e "  ${GREEN}${BOLD}${PASS}${RESET} passed  ${YELLOW}${BOLD}${WARN}${RESET} warnings  ${RED}${BOLD}${FAIL}${RESET} failed  ${DIM}(${TOTAL} checks)${RESET}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    error "Some checks failed. Fix the issues above and re-run ${CYAN}shipwright doctor${RESET}"
elif [[ $WARN -gt 0 ]]; then
    warn "Setup mostly OK, but there are warnings above"
else
    success "Everything looks good!"
fi
echo ""
