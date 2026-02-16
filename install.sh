#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║              Shipwright — One-Command Installer                         ║
# ║                                                                         ║
# ║  Usage:  ./install.sh [--repair] [--deploy] [--no-claude-md]           ║
# ║                                                                         ║
# ║  This is the single entry point. It checks prerequisites, then         ║
# ║  delegates to `shipwright init` which handles everything:              ║
# ║    tmux config + overlay + TPM + plugins                               ║
# ║    CLI symlinks (sw, shipwright, cct) + PATH                           ║
# ║    Claude Code settings + hooks + CLAUDE.md                            ║
# ║    Team & pipeline templates + shell completions                       ║
# ║    iTerm2 fixes + doctor validation                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;34;197;94m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;239;68;68m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Banner ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}Shipwright${RESET}                                               ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}  ${DIM}One-command installer for Claude Code agent teams${RESET}         ${CYAN}║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ─── Help ────────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: ./install.sh [options]"
            echo ""
            echo "Options (passed through to shipwright init):"
            echo "  --repair             Force clean reinstall of tmux config, plugins, and adapters"
            echo "  --deploy             Detect deploy platform and generate pipeline template"
            echo "  --platform PLATFORM  Skip detection, use specified platform (vercel|fly|railway|docker)"
            echo "  --no-claude-md       Skip creating .claude/CLAUDE.md"
            echo "  --help, -h           Show this help"
            echo ""
            echo "One-liner from source:"
            echo "  git clone https://github.com/sethdford/shipwright.git && cd shipwright && ./install.sh"
            echo ""
            echo "Remote install (latest release):"
            echo "  curl -fsSL https://raw.githubusercontent.com/sethdford/shipwright/main/scripts/install-remote.sh | bash"
            exit 0
            ;;
    esac
done

# ─── Prerequisite Check ─────────────────────────────────────────────────────
MISSING=()

if command -v tmux &>/dev/null; then
    echo -e "${GREEN}✓${RESET} tmux $(tmux -V | grep -oE '[0-9]+\.[0-9a-z]+')"
else
    MISSING+=("tmux — brew install tmux")
fi

if command -v git &>/dev/null; then
    echo -e "${GREEN}✓${RESET} git $(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
else
    MISSING+=("git")
fi

if command -v node &>/dev/null; then
    NODE_MAJOR="$(node -v | tr -d 'v' | cut -d. -f1)"
    if [[ "$NODE_MAJOR" -ge 20 ]]; then
        echo -e "${GREEN}✓${RESET} Node.js $(node -v | tr -d 'v')"
    else
        echo -e "${YELLOW}!${RESET} Node.js $(node -v) (20+ recommended)"
    fi
else
    MISSING+=("node — https://nodejs.org")
fi

if command -v jq &>/dev/null; then
    echo -e "${GREEN}✓${RESET} jq $(jq --version 2>/dev/null | tr -d 'jq-')"
else
    MISSING+=("jq — brew install jq")
fi

if command -v claude &>/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; then
    echo -e "${GREEN}✓${RESET} Claude Code CLI"
else
    echo -e "${YELLOW}!${RESET} Claude Code CLI not found (install later: npm i -g @anthropic-ai/claude-code)"
fi

if command -v gh &>/dev/null; then
    echo -e "${GREEN}✓${RESET} gh CLI $(gh --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
else
    echo -e "${YELLOW}!${RESET} gh CLI not found (optional: brew install gh)"
fi

echo ""

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${RED}${BOLD}Missing required tools:${RESET}"
    for m in "${MISSING[@]}"; do
        echo -e "  ${RED}✗${RESET} $m"
    done
    echo ""
    echo -e "Install the above and re-run: ${BOLD}./install.sh${RESET}"
    exit 1
fi

echo -e "${GREEN}✓${RESET} ${BOLD}All prerequisites met${RESET}"
echo ""

# ─── Delegate to shipwright init ─────────────────────────────────────────────
exec "$SCRIPT_DIR/scripts/sw-init.sh" "$@"
