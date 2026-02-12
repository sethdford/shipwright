#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright setup — One-shot setup: check prerequisites, init, doctor   ║
# ║                                                                          ║
# ║  Guides new users from zero to running: checks tools, installs configs, ║
# ║  injects the tmux overlay, validates everything, and prints a quick     ║
# ║  start guide.                                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.9.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

PASS=0
WARN=0
FAIL=0

check_pass() { success "$*"; PASS=$((PASS + 1)); }
check_warn() { warn "$*"; WARN=$((WARN + 1)); }
check_fail() { error "$*"; FAIL=$((FAIL + 1)); }

# ─── Flag parsing ────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: shipwright setup"
            echo ""
            echo "One-shot guided setup: checks prerequisites, runs init,"
            echo "injects the tmux overlay, validates with doctor, and prints"
            echo "a quick-start guide."
            exit 0
            ;;
    esac
done

# ═════════════════════════════════════════════════════════════════════════════
# Welcome Banner
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║        Shipwright Setup              ║${RESET}"
echo -e "${CYAN}${BOLD}  ║        v${VERSION}                        ║${RESET}"
echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════╝${RESET}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 1. Check Prerequisites
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  PREREQUISITES${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# Detect OS for install instructions
if [[ "$(uname)" == "Darwin" ]]; then
    PKG_MGR="brew install"
else
    PKG_MGR="sudo apt install"
fi

# tmux (>= 3.2)
if command -v tmux &>/dev/null; then
    TMUX_VERSION="$(tmux -V | grep -oE '[0-9]+\.[0-9a-z]+')"
    TMUX_MAJOR="$(echo "$TMUX_VERSION" | cut -d. -f1)"
    TMUX_MINOR="$(echo "$TMUX_VERSION" | cut -d. -f2 | tr -dc '0-9')"
    if [[ "$TMUX_MAJOR" -ge 4 ]] || [[ "$TMUX_MAJOR" -ge 3 && "$TMUX_MINOR" -ge 2 ]]; then
        check_pass "tmux ${TMUX_VERSION}"
    else
        check_warn "tmux ${TMUX_VERSION} — 3.2+ required for pane-border-format"
        echo -e "    ${DIM}${PKG_MGR} tmux${RESET}"
    fi
else
    check_fail "tmux not installed"
    echo -e "    ${DIM}${PKG_MGR} tmux${RESET}"
fi

# jq
if command -v jq &>/dev/null; then
    check_pass "jq $(jq --version 2>&1 | tr -d 'jq-')"
else
    check_fail "jq not installed — required for template parsing"
    echo -e "    ${DIM}${PKG_MGR} jq${RESET}"
fi

# Node.js (>= 20)
if command -v node &>/dev/null; then
    NODE_VERSION="$(node -v | tr -d 'v')"
    NODE_MAJOR="$(echo "$NODE_VERSION" | cut -d. -f1)"
    if [[ "$NODE_MAJOR" -ge 20 ]]; then
        check_pass "Node.js ${NODE_VERSION}"
    else
        check_warn "Node.js ${NODE_VERSION} — 20+ required"
        echo -e "    ${DIM}${PKG_MGR} node${RESET}"
    fi
else
    check_fail "Node.js not found"
    echo -e "    ${DIM}${PKG_MGR} node${RESET}"
fi

# Claude Code CLI
if command -v claude &>/dev/null; then
    check_pass "Claude Code CLI"
else
    check_fail "Claude Code CLI not found"
    echo -e "    ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
fi

# GitHub CLI + auth
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
        GH_USER="$(gh api user -q .login 2>/dev/null || echo "authenticated")"
        check_pass "GitHub CLI: ${GH_USER}"
    else
        check_warn "GitHub CLI installed but not authenticated"
        echo -e "    ${DIM}gh auth login${RESET}"
    fi
else
    check_warn "GitHub CLI (gh) not installed — needed for daemon/pipeline"
    echo -e "    ${DIM}${PKG_MGR} gh${RESET}"
fi

# Bash (>= 4)
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
if [[ "$BASH_MAJOR" -ge 4 ]]; then
    check_pass "bash ${BASH_VERSION}"
else
    check_warn "bash ${BASH_VERSION} — 4.0+ required for associative arrays"
    echo -e "    ${DIM}brew install bash  (macOS ships 3.2)${RESET}"
fi

echo ""

# Bail early if critical prereqs are missing
if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${GREEN}${BOLD}${PASS}${RESET} passed  ${YELLOW}${BOLD}${WARN}${RESET} warnings  ${RED}${BOLD}${FAIL}${RESET} failed"
    echo ""
    error "Fix the failed prerequisites above before continuing."
    echo -e "  ${DIM}Re-run: shipwright setup${RESET}"
    exit 1
fi

echo -e "  ${GREEN}${BOLD}${PASS}${RESET} passed  ${YELLOW}${BOLD}${WARN}${RESET} warnings  ${RED}${BOLD}${FAIL}${RESET} failed"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 2. Run init
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  INITIALIZING${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

"$SCRIPT_DIR/sw-init.sh"

# ═════════════════════════════════════════════════════════════════════════════
# 3. Inject tmux overlay (if not already sourced)
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  TMUX OVERLAY${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

if [[ -f "$HOME/.tmux.conf" ]]; then
    if grep -q "shipwright-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
        success "Overlay already sourced in ~/.tmux.conf"
    else
        echo ""
        echo -e "  Your ${BOLD}~/.tmux.conf${RESET} does not source the Shipwright overlay."
        echo -e "  This adds: pane borders, color hooks, agent keybindings."
        echo ""
        read -rp "$(echo -e "  ${CYAN}${BOLD}▸${RESET} Append overlay source to ~/.tmux.conf? [Y/n] ")" confirm
        if [[ -z "$confirm" || "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
            {
                echo ""
                echo "# Shipwright agent overlay"
                echo "source-file -q ~/.tmux/shipwright-overlay.conf"
            } >> "$HOME/.tmux.conf"
            success "Appended overlay source to ~/.tmux.conf"
        else
            info "Skipped. Add manually if you want overlay features:"
            echo -e "    ${DIM}source-file -q ~/.tmux/shipwright-overlay.conf${RESET}"
        fi
    fi
else
    info "No ~/.tmux.conf found — init should have created one"
fi
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 4. Run doctor
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  VALIDATION${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

"$SCRIPT_DIR/sw-doctor.sh" || true

# ═════════════════════════════════════════════════════════════════════════════
# 5. Quick-start guide
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║  Quick Start                                                ║${RESET}"
echo -e "${CYAN}${BOLD}  ╠══════════════════════════════════════════════════════════════╣${RESET}"
if [[ -z "${TMUX:-}" ]]; then
echo -e "${CYAN}${BOLD}  ║${RESET}  1. Start tmux:   ${DIM}tmux new -s work${RESET}                         ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}  2. Create team:  ${DIM}shipwright session my-feat --template feature-dev${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}  3. Launch Claude: ${DIM}claude${RESET}                                   ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}  4. Use teams:    ${DIM}\"Create a team with 3 agents for this feature\"${RESET} ${CYAN}${BOLD}║${RESET}"
else
echo -e "${CYAN}${BOLD}  ║${RESET}  1. Create team:  ${DIM}shipwright session my-feat --template feature-dev${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}  2. Launch Claude: ${DIM}claude${RESET}                                   ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}  3. Use teams:    ${DIM}\"Create a team with 3 agents for this feature\"${RESET} ${CYAN}${BOLD}║${RESET}"
fi
echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
success "Setup complete! You're ready to go."
echo ""
