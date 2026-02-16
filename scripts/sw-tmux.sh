#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux.sh — tmux Health & Plugin Management                          ║
# ║                                                                          ║
# ║  Diagnoses tmux + Claude Code compatibility, installs TPM plugins,     ║
# ║  and auto-fixes common issues. Part of the Shipwright CLI.             ║
# ║                                                                          ║
# ║  Usage:                                                                 ║
# ║    shipwright tmux doctor        — Check tmux features + Claude compat ║
# ║    shipwright tmux install       — Install TPM + all plugins           ║
# ║    shipwright tmux fix           — Auto-fix common issues              ║
# ║    shipwright tmux reload        — Reload tmux config                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.2.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

PASS=0
WARN=0
FAIL=0

check_pass() { success "$*"; PASS=$((PASS + 1)); }
check_warn() { warn "$*"; WARN=$((WARN + 1)); }
check_fail() { error "$*"; FAIL=$((FAIL + 1)); }

# ═════════════════════════════════════════════════════════════════════════════
# tmux doctor — Comprehensive tmux + Claude Code compatibility check
# ═════════════════════════════════════════════════════════════════════════════

tmux_doctor() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright — tmux Doctor${RESET}"
    echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    # ─── 1. tmux installed + version ─────────────────────────────────────
    echo -e "${BOLD}1. tmux Version${RESET}"
    if ! command -v tmux &>/dev/null; then
        check_fail "tmux not installed"
        echo -e "    ${DIM}brew install tmux  (macOS)${RESET}"
        echo -e "    ${DIM}sudo apt install tmux  (Ubuntu/Debian)${RESET}"
        echo ""
        echo -e "${RED}${BOLD}Cannot continue without tmux.${RESET}"
        return 1
    fi

    local tmux_version tmux_major tmux_minor
    tmux_version="$(tmux -V | grep -oE '[0-9]+\.[0-9a-z]+')"
    tmux_major="$(echo "$tmux_version" | cut -d. -f1)"
    tmux_minor="$(echo "$tmux_version" | cut -d. -f2 | tr -dc '0-9')"

    if [[ "$tmux_major" -ge 3 && "$tmux_minor" -ge 3 ]] || [[ "$tmux_major" -ge 4 ]]; then
        check_pass "tmux ${tmux_version} (all features supported)"
    elif [[ "$tmux_major" -ge 3 && "$tmux_minor" -ge 2 ]]; then
        check_warn "tmux ${tmux_version} — 3.3+ recommended for popup styling + allow-passthrough"
    else
        check_fail "tmux ${tmux_version} — 3.2+ required for popups, 3.3+ for passthrough"
        echo -e "    ${DIM}brew upgrade tmux${RESET}"
    fi
    echo ""

    # ─── 2. Claude Code compatibility features ──────────────────────────
    echo -e "${BOLD}2. Claude Code Compatibility${RESET}"

    if [[ -n "${TMUX:-}" ]]; then
        # Check allow-passthrough (DEC 2026 synchronized output)
        local passthrough
        passthrough="$(tmux show-option -gv allow-passthrough 2>/dev/null || echo "off")"
        if [[ "$passthrough" == "on" ]]; then
            check_pass "allow-passthrough: on (DEC 2026 synchronized output works)"
        else
            check_fail "allow-passthrough: ${passthrough} — Claude Code will flicker"
            echo -e "    ${DIM}Fix: set -g allow-passthrough on${RESET}"
        fi

        # Check extended-keys
        local extkeys
        extkeys="$(tmux show-option -gv extended-keys 2>/dev/null || echo "off")"
        if [[ "$extkeys" == "on" ]]; then
            check_pass "extended-keys: on (better key handling for TUI apps)"
        else
            check_warn "extended-keys: ${extkeys} — some key combos may not work"
            echo -e "    ${DIM}Fix: set -g extended-keys on${RESET}"
        fi

        # Check escape-time
        local esc_time
        esc_time="$(tmux show-option -gv escape-time 2>/dev/null || echo "500")"
        if [[ "$esc_time" -le 10 ]]; then
            check_pass "escape-time: ${esc_time}ms (no input delay)"
        else
            check_fail "escape-time: ${esc_time}ms — causes input lag in Claude Code"
            echo -e "    ${DIM}Fix: set -sg escape-time 0${RESET}"
        fi

        # Check set-clipboard
        local clipboard
        clipboard="$(tmux show-option -gv set-clipboard 2>/dev/null || echo "off")"
        if [[ "$clipboard" == "on" || "$clipboard" == "external" ]]; then
            check_pass "set-clipboard: ${clipboard} (OSC 52 clipboard works)"
        else
            check_warn "set-clipboard: ${clipboard} — clipboard may not work in SSH"
            echo -e "    ${DIM}Fix: set -g set-clipboard on${RESET}"
        fi

        # Check history-limit
        local hist
        hist="$(tmux show-option -gv history-limit 2>/dev/null || echo "2000")"
        if [[ "$hist" -ge 100000 ]]; then
            check_pass "history-limit: ${hist} (sufficient for Claude Code output)"
        elif [[ "$hist" -ge 50000 ]]; then
            check_warn "history-limit: ${hist} — 250000+ recommended for long agent runs"
        else
            check_fail "history-limit: ${hist} — will overflow during Claude Code streaming"
            echo -e "    ${DIM}Fix: set -g history-limit 250000${RESET}"
        fi

        # Check focus-events
        local focus
        focus="$(tmux show-option -gv focus-events 2>/dev/null || echo "off")"
        if [[ "$focus" == "on" ]]; then
            check_pass "focus-events: on"
        else
            check_warn "focus-events: ${focus} — some TUI features won't work"
        fi

        # Check default-terminal
        local term
        term="$(tmux show-option -gv default-terminal 2>/dev/null || echo "unknown")"
        if [[ "$term" == *"256color"* ]]; then
            check_pass "default-terminal: ${term}"
        else
            check_warn "default-terminal: ${term} — 256color variant recommended"
        fi
    else
        info "Not in tmux session — checking config file instead"
        if [[ -f "$HOME/.tmux.conf" ]]; then
            if grep -q "allow-passthrough" "$HOME/.tmux.conf" 2>/dev/null; then
                check_pass "allow-passthrough found in ~/.tmux.conf"
            else
                check_fail "allow-passthrough not in ~/.tmux.conf — Claude Code will flicker"
            fi
            if grep -q "extended-keys" "$HOME/.tmux.conf" 2>/dev/null; then
                check_pass "extended-keys found in ~/.tmux.conf"
            else
                check_warn "extended-keys not in ~/.tmux.conf"
            fi
        else
            check_fail "No ~/.tmux.conf found"
        fi
    fi
    echo ""

    # ─── 3. Plugin Manager ───────────────────────────────────────────────
    echo -e "${BOLD}3. Plugin Manager (TPM)${RESET}"

    if [[ -d "$HOME/.tmux/plugins/tpm" ]]; then
        check_pass "TPM installed: ~/.tmux/plugins/tpm"
    else
        check_fail "TPM not installed"
        echo -e "    ${DIM}Run: shipwright tmux install${RESET}"
    fi

    # Check individual plugins
    local plugins=("tmux-sensible" "tmux-resurrect" "tmux-continuum" "tmux-yank" "tmux-fzf")
    for plugin in "${plugins[@]}"; do
        local plugin_dir=""
        # tmux-fzf is under sainnhe org
        if [[ "$plugin" == "tmux-fzf" ]]; then
            plugin_dir="$HOME/.tmux/plugins/tmux-fzf"
        else
            plugin_dir="$HOME/.tmux/plugins/${plugin}"
        fi
        if [[ -d "$plugin_dir" ]]; then
            check_pass "Plugin: ${plugin}"
        else
            check_warn "Plugin not installed: ${plugin}"
            echo -e "    ${DIM}Press prefix + I inside tmux to install${RESET}"
        fi
    done
    echo ""

    # ─── 4. Shipwright overlay ───────────────────────────────────────────
    echo -e "${BOLD}4. Shipwright Integration${RESET}"

    if [[ -f "$HOME/.tmux/shipwright-overlay.conf" ]]; then
        check_pass "Overlay: ~/.tmux/shipwright-overlay.conf"
    else
        check_fail "Overlay not found"
        echo -e "    ${DIM}Run: shipwright init${RESET}"
    fi

    if [[ -f "$HOME/.tmux.conf" ]] && grep -q "shipwright-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
        check_pass "Overlay sourced in ~/.tmux.conf"
    else
        check_warn "Overlay not sourced in ~/.tmux.conf"
        echo -e "    ${DIM}Add: source-file -q ~/.tmux/shipwright-overlay.conf${RESET}"
    fi

    if [[ -n "${TMUX:-}" ]]; then
        # Check pane-border-status
        local border_status
        border_status="$(tmux show-option -gv pane-border-status 2>/dev/null || echo "off")"
        if [[ "$border_status" == "top" ]]; then
            check_pass "pane-border-status: top (agent names visible)"
        else
            check_warn "pane-border-status: ${border_status} — agent names won't show"
        fi

        # Check dark theme hooks
        if tmux show-hooks -g 2>/dev/null | grep -q "after-split-window"; then
            check_pass "Dark theme hooks active"
        else
            check_warn "Dark theme hooks not active — new panes may flash white"
        fi

        # Check mouse
        local mouse
        mouse="$(tmux show-option -gv mouse 2>/dev/null || echo "off")"
        if [[ "$mouse" == "on" ]]; then
            check_pass "Mouse: on"
        else
            check_warn "Mouse: off — enable for better agent pane interaction"
        fi
    fi
    echo ""

    # ─── 5. Known Issues ─────────────────────────────────────────────────
    echo -e "${BOLD}5. Known Issues Check${RESET}"

    if [[ -n "${TMUX:-}" ]]; then
        # Check pane-base-index compatibility
        local pbi
        pbi="$(tmux show-window-option -gv pane-base-index 2>/dev/null || echo "0")"
        if [[ "$pbi" != "0" ]]; then
            check_warn "pane-base-index: ${pbi} — Claude Code teammate mode may misaddress panes"
            echo -e "    ${DIM}Shipwright adapter uses pane IDs to work around this${RESET}"
        else
            check_pass "pane-base-index: 0 (Claude Code compatible)"
        fi

        # Check for MouseDown1Status fix
        local mouse_bind
        mouse_bind="$(tmux list-keys 2>/dev/null | grep 'MouseDown1Status' | head -1 || true)"
        if echo "$mouse_bind" | grep -q "select-window"; then
            check_pass "MouseDown1Status: select-window (clicks work correctly)"
        elif [[ -n "$mouse_bind" ]]; then
            check_warn "MouseDown1Status: may switch sessions instead of windows"
            echo -e "    ${DIM}Fix: bind -T root MouseDown1Status select-window -t =${RESET}"
        fi
    fi

    # Check terminal emulator
    local parent_term="${LC_TERMINAL:-${TERM_PROGRAM:-unknown}}"
    case "$parent_term" in
        *Ghostty*|*ghostty*)
            check_pass "Terminal: Ghostty (best Claude Code + tmux compat)"
            ;;
        *iTerm*|*iterm*)
            check_pass "Terminal: iTerm2 (good compat, true color)"
            ;;
        *kitty*)
            check_pass "Terminal: kitty (good compat)"
            ;;
        *WezTerm*|*wezterm*)
            check_pass "Terminal: WezTerm (good compat)"
            ;;
        *Alacritty*|*alacritty*)
            check_pass "Terminal: Alacritty (good compat)"
            ;;
        *Apple_Terminal*|*Terminal*)
            check_warn "Terminal: Apple Terminal — limited color support, no true color"
            echo -e "    ${DIM}Recommend: iTerm2, Ghostty, or WezTerm for full experience${RESET}"
            ;;
        *)
            info "Terminal: ${parent_term}"
            ;;
    esac
    echo ""

    # ─── Summary ─────────────────────────────────────────────────────────
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    echo -e "  ${GREEN}${BOLD}${PASS} passed${RESET}  ${YELLOW}${BOLD}${WARN} warnings${RESET}  ${RED}${BOLD}${FAIL} failed${RESET}"

    if [[ $FAIL -gt 0 ]]; then
        echo ""
        echo -e "  Run ${CYAN}${BOLD}shipwright tmux fix${RESET} to auto-fix issues."
    elif [[ $WARN -gt 0 ]]; then
        echo ""
        echo -e "  ${GREEN}Good shape!${RESET} Warnings are informational."
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}Perfect setup!${RESET} tmux + Claude Code fully optimized."
    fi
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# tmux install — Install TPM and all plugins
# ═════════════════════════════════════════════════════════════════════════════

tmux_install() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright — tmux Plugin Installer${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    # Install TPM if not present
    if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
        info "Installing TPM (Tmux Plugin Manager)..."
        if git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" 2>/dev/null; then
            success "TPM installed"
        else
            error "Failed to clone TPM — check git + network"
            return 1
        fi
    else
        success "TPM already installed"
    fi

    # Install Shipwright tmux.conf if not present
    if [[ -f "$REPO_DIR/tmux/tmux.conf" ]]; then
        if [[ ! -f "$HOME/.tmux.conf" ]]; then
            cp "$REPO_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
            success "Installed ~/.tmux.conf"
        else
            info "~/.tmux.conf exists — run 'shipwright init' to update"
        fi
    fi

    # Install overlay
    if [[ -f "$REPO_DIR/tmux/shipwright-overlay.conf" ]]; then
        mkdir -p "$HOME/.tmux"
        cp "$REPO_DIR/tmux/shipwright-overlay.conf" "$HOME/.tmux/shipwright-overlay.conf"
        success "Installed ~/.tmux/shipwright-overlay.conf"
    fi

    # Trigger TPM plugin install
    if [[ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]]; then
        info "Installing tmux plugins via TPM..."
        "$HOME/.tmux/plugins/tpm/bin/install_plugins" 2>/dev/null && \
            success "All plugins installed" || \
            warn "Some plugins may not have installed — press prefix + I inside tmux"
    else
        warn "TPM install script not found — press prefix + I inside tmux to install plugins"
    fi

    # Reload config if inside tmux
    if [[ -n "${TMUX:-}" ]]; then
        tmux source-file "$HOME/.tmux.conf" 2>/dev/null && \
            success "tmux config reloaded" || true
    fi

    echo ""
    success "tmux setup complete!"
    echo ""
    echo -e "${BOLD}Plugins installed:${RESET}"
    echo -e "  ${CYAN}tmux-sensible${RESET}    — Sensible defaults everyone agrees on"
    echo -e "  ${CYAN}tmux-resurrect${RESET}   — Persist sessions across restarts"
    echo -e "  ${CYAN}tmux-continuum${RESET}   — Auto-save every 15 min, auto-restore"
    echo -e "  ${CYAN}tmux-yank${RESET}        — System clipboard integration (OSC 52)"
    echo -e "  ${CYAN}tmux-fzf${RESET}         — Fuzzy finder for sessions/windows/panes"
    echo ""
    echo -e "${BOLD}Key bindings added:${RESET}"
    echo -e "  ${CYAN}prefix + F${RESET}       — Floating popup terminal"
    echo -e "  ${CYAN}prefix + C-f${RESET}     — FZF session switcher"
    echo -e "  ${CYAN}prefix + T${RESET}       — Launch Shipwright team session"
    echo -e "  ${CYAN}prefix + C-t${RESET}     — Team dashboard popup"
    echo -e "  ${CYAN}prefix + M-d${RESET}     — Full dashboard popup"
    echo -e "  ${CYAN}prefix + M-m${RESET}     — Memory system popup"
    echo -e "  ${CYAN}prefix + R${RESET}       — Reap dead agent panes"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# tmux fix — Auto-fix common tmux + Claude Code issues
# ═════════════════════════════════════════════════════════════════════════════

tmux_fix() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright — tmux Auto-Fix${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    local fixed=0

    if [[ -z "${TMUX:-}" ]]; then
        error "Not inside a tmux session — start tmux first"
        return 1
    fi

    # Fix 1: allow-passthrough
    local passthrough
    passthrough="$(tmux show-option -gv allow-passthrough 2>/dev/null || echo "off")"
    if [[ "$passthrough" != "on" ]]; then
        tmux set -g allow-passthrough on 2>/dev/null
        success "Fixed: allow-passthrough → on (eliminates Claude Code flicker)"
        fixed=$((fixed + 1))
    fi

    # Fix 2: extended-keys
    local extkeys
    extkeys="$(tmux show-option -gv extended-keys 2>/dev/null || echo "off")"
    if [[ "$extkeys" != "on" ]]; then
        tmux set -g extended-keys on 2>/dev/null
        success "Fixed: extended-keys → on"
        fixed=$((fixed + 1))
    fi

    # Fix 3: escape-time
    local esc_time
    esc_time="$(tmux show-option -gv escape-time 2>/dev/null || echo "500")"
    if [[ "$esc_time" -gt 10 ]]; then
        tmux set -sg escape-time 0 2>/dev/null
        success "Fixed: escape-time → 0 (was ${esc_time}ms)"
        fixed=$((fixed + 1))
    fi

    # Fix 4: set-clipboard
    local clipboard
    clipboard="$(tmux show-option -gv set-clipboard 2>/dev/null || echo "off")"
    if [[ "$clipboard" == "off" ]]; then
        tmux set -g set-clipboard on 2>/dev/null
        success "Fixed: set-clipboard → on"
        fixed=$((fixed + 1))
    fi

    # Fix 5: history-limit
    local hist
    hist="$(tmux show-option -gv history-limit 2>/dev/null || echo "2000")"
    if [[ "$hist" -lt 100000 ]]; then
        tmux set -g history-limit 250000 2>/dev/null
        success "Fixed: history-limit → 250000 (was ${hist})"
        fixed=$((fixed + 1))
    fi

    # Fix 6: focus-events
    local focus
    focus="$(tmux show-option -gv focus-events 2>/dev/null || echo "off")"
    if [[ "$focus" != "on" ]]; then
        tmux set -g focus-events on 2>/dev/null
        success "Fixed: focus-events → on"
        fixed=$((fixed + 1))
    fi

    # Fix 7: mouse
    local mouse
    mouse="$(tmux show-option -gv mouse 2>/dev/null || echo "off")"
    if [[ "$mouse" != "on" ]]; then
        tmux set -g mouse on 2>/dev/null
        success "Fixed: mouse → on"
        fixed=$((fixed + 1))
    fi

    # Fix 8: MouseDown1Status
    local mouse_bind
    mouse_bind="$(tmux list-keys 2>/dev/null | grep 'MouseDown1Status' | head -1 || true)"
    if ! echo "$mouse_bind" | grep -q "select-window"; then
        tmux bind -T root MouseDown1Status select-window -t = 2>/dev/null
        success "Fixed: MouseDown1Status → select-window"
        fixed=$((fixed + 1))
    fi

    # Fix 9: dark theme hooks
    if ! tmux show-hooks -g 2>/dev/null | grep -q "after-split-window"; then
        tmux set-hook -g after-split-window "select-pane -P 'bg=#1a1a2e,fg=#e4e4e7'" 2>/dev/null
        tmux set-hook -g after-new-window "select-pane -P 'bg=#1a1a2e,fg=#e4e4e7'" 2>/dev/null
        tmux set-hook -g after-new-session "select-pane -P 'bg=#1a1a2e,fg=#e4e4e7'" 2>/dev/null
        success "Fixed: dark theme hooks installed"
        fixed=$((fixed + 1))
    fi

    # Fix 10: pane-border-status
    local border_status
    border_status="$(tmux show-option -gv pane-border-status 2>/dev/null || echo "off")"
    if [[ "$border_status" != "top" ]]; then
        tmux set -g pane-border-status top 2>/dev/null
        success "Fixed: pane-border-status → top (agent names visible)"
        fixed=$((fixed + 1))
    fi

    echo ""
    if [[ $fixed -eq 0 ]]; then
        success "No fixes needed — tmux is already optimized!"
    else
        success "Applied ${fixed} fixes"
        echo ""
        echo -e "${DIM}These fixes are applied to the running session only.${RESET}"
        echo -e "${DIM}For persistence, update your tmux config:${RESET}"
        echo -e "${DIM}  shipwright init${RESET}"
    fi
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# tmux reload — Reload tmux configuration
# ═════════════════════════════════════════════════════════════════════════════

tmux_reload() {
    if [[ -z "${TMUX:-}" ]]; then
        error "Not inside a tmux session"
        return 1
    fi

    if [[ -f "$HOME/.tmux.conf" ]]; then
        tmux source-file "$HOME/.tmux.conf" 2>/dev/null && \
            success "tmux config reloaded" || \
            error "Failed to reload — check config syntax"
    else
        error "No ~/.tmux.conf found"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Main dispatcher
# ═════════════════════════════════════════════════════════════════════════════

show_help() {
    echo -e "${CYAN}${BOLD}shipwright tmux${RESET} — tmux Health & Plugin Management"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright tmux <command>"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}doctor${RESET}     Check tmux features + Claude Code compatibility"
    echo -e "  ${CYAN}install${RESET}    Install TPM + all plugins"
    echo -e "  ${CYAN}fix${RESET}        Auto-fix common issues in running session"
    echo -e "  ${CYAN}reload${RESET}     Reload tmux configuration"
    echo ""
    echo -e "${BOLD}Claude Code Compatibility${RESET}"
    echo -e "  Shipwright configures tmux for optimal Claude Code TUI compatibility:"
    echo -e "  ${DIM}• allow-passthrough: DEC 2026 synchronized output (no flicker)${RESET}"
    echo -e "  ${DIM}• extended-keys: better key handling for TUI apps${RESET}"
    echo -e "  ${DIM}• escape-time 0: no input delay${RESET}"
    echo -e "  ${DIM}• history-limit 250000: handles Claude Code's high output volume${RESET}"
    echo -e "  ${DIM}• set-clipboard on: native OSC 52 clipboard${RESET}"
    echo -e "  ${DIM}• pane IDs (not indices): fixes teammate pane-base-index bug${RESET}"
    echo ""
    echo -e "${BOLD}Plugins${RESET}"
    echo -e "  ${DIM}tmux-sensible    — Sensible defaults${RESET}"
    echo -e "  ${DIM}tmux-resurrect   — Persist sessions across restarts${RESET}"
    echo -e "  ${DIM}tmux-continuum   — Auto-save + auto-restore${RESET}"
    echo -e "  ${DIM}tmux-yank        — System clipboard (OSC 52)${RESET}"
    echo -e "  ${DIM}tmux-fzf         — Fuzzy finder for sessions/windows/panes${RESET}"
    echo ""
}

case "${1:-}" in
    doctor|check|status)
        tmux_doctor
        ;;
    install|setup)
        tmux_install
        ;;
    fix|repair)
        tmux_fix
        ;;
    reload)
        tmux_reload
        ;;
    --help|-h|help|"")
        show_help
        ;;
    *)
        error "Unknown command: $1"
        echo -e "  Run ${CYAN}shipwright tmux --help${RESET} for usage."
        exit 1
        ;;
esac
