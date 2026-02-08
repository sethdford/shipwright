#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct-doctor.sh — Validate Claude Code Teams setup                       ║
# ║                                                                          ║
# ║  Checks prerequisites, installed files, PATH, and common issues.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

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
echo -e "${CYAN}${BOLD}  Claude Code Teams — Doctor${RESET}"
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
    if [[ "$TMUX_MAJOR" -ge 3 && "$TMUX_MINOR" -ge 2 ]] || [[ "$TMUX_MAJOR" -ge 4 ]]; then
        check_pass "tmux ${TMUX_VERSION}"
    else
        check_warn "tmux ${TMUX_VERSION} — 3.2+ recommended for pane-border-format"
    fi
else
    check_fail "tmux not installed"
    echo -e "    ${DIM}brew install tmux  (macOS)${RESET}"
    echo -e "    ${DIM}sudo apt install tmux  (Ubuntu/Debian)${RESET}"
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
if [[ -f "$HOME/.tmux/claude-teams-overlay.conf" ]]; then
    check_pass "Overlay: ~/.tmux/claude-teams-overlay.conf"
else
    check_fail "Overlay not found: ~/.tmux/claude-teams-overlay.conf"
    echo -e "    ${DIM}Re-run install.sh to install it${RESET}"
fi

# Overlay sourced in tmux.conf
if [[ -f "$HOME/.tmux.conf" ]]; then
    if grep -q "claude-teams-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
        check_pass "Overlay sourced in ~/.tmux.conf"
    else
        check_warn "Overlay not sourced in ~/.tmux.conf"
        echo -e "    ${DIM}Add: source-file -q ~/.tmux/claude-teams-overlay.conf${RESET}"
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

# Check cct subcommands are installed alongside the router
if command -v cct &>/dev/null; then
    CCT_DIR="$(dirname "$(command -v cct)")"
    check_pass "shipwright router found at ${CCT_DIR}/cct"

    missing_subs=()
    for sub in cct-session.sh cct-status.sh cct-cleanup.sh; do
        if [[ ! -x "${CCT_DIR}/${sub}" ]]; then
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
if [[ -f "$HOME/.tmux/claude-teams-overlay.conf" ]]; then
    # Check for set-hook color enforcement
    if grep -q "set-hook.*after-split-window" "$HOME/.tmux/claude-teams-overlay.conf" 2>/dev/null; then
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
    "$HOME/.claude-teams"
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
        check_pass "iTerm2 — full support"
        ;;
    Apple_Terminal)
        check_pass "Terminal.app — supported"
        ;;
    WezTerm)
        check_pass "WezTerm — full support"
        ;;
    tmux)
        check_pass "Running inside tmux (nested)"
        ;;
    vscode)
        check_warn "VS Code integrated terminal"
        echo -e "    ${DIM}Some pane border features may not render correctly.${RESET}"
        echo -e "    ${DIM}Consider running tmux in an external terminal.${RESET}"
        ;;
    Ghostty)
        check_warn "Ghostty — may have tmux rendering quirks"
        echo -e "    ${DIM}If pane borders look wrong, try: set -g default-terminal 'xterm-256color'${RESET}"
        ;;
    *)
        info "Terminal: ${TERM_PROGRAM}"
        ;;
esac

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
