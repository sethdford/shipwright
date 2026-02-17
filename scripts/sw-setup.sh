#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright setup — Comprehensive onboarding wizard                      ║
# ║                                                                          ║
# ║  Phase 1: Prerequisites Check — validate required tools                 ║
# ║  Phase 2: Repo Analysis — detect language, tests, build                 ║
# ║  Phase 3: Configuration Generation — create .claude/ configs             ║
# ║  Phase 4: Validation — run doctor & show quick start                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.3.0"

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

# Detect OS for install instructions
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "macOS"
    else
        echo "Linux"
    fi
}

get_install_cmd() {
    local os="$1"
    local pkg="$2"
    if [[ "$os" == "macOS" ]]; then
        echo "brew install $pkg"
    else
        echo "sudo apt install $pkg"
    fi
}

# ─── Flag parsing ────────────────────────────────────────────────────────────
SKIP_DAEMON_PROMPT=false
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: shipwright setup [--skip-daemon-prompt]"
            echo ""
            echo "Comprehensive onboarding wizard with four phases:"
            echo ""
            echo "  Phase 1: Check prerequisites (tmux, bash, jq, gh, claude)"
            echo "  Phase 2: Analyze repo (language, framework, tests, build)"
            echo "  Phase 3: Generate .claude/ configuration"
            echo "  Phase 4: Validate setup and show quick start guide"
            echo ""
            echo "Options:"
            echo "  --skip-daemon-prompt  Don't ask about daemon auto-processing"
            exit 0
            ;;
        --skip-daemon-prompt)
            SKIP_DAEMON_PROMPT=true
            ;;
    esac
done

# Detect OS once at startup
OS="$(detect_os)"

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
# PHASE 1: Prerequisites Check
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  PHASE 1: PREREQUISITES${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

# Required tools
REQUIRED_TOOLS=("tmux" "bash" "git" "jq" "gh" "claude")
OPTIONAL_TOOLS=("bun")

# Check required tools
for tool in "${REQUIRED_TOOLS[@]}"; do
    case "$tool" in
        tmux)
            if command -v tmux &>/dev/null; then
                TMUX_VERSION="$(tmux -V | grep -oE '[0-9]+\.[0-9a-z]+')"
                TMUX_MAJOR="$(echo "$TMUX_VERSION" | cut -d. -f1)"
                TMUX_MINOR="$(echo "$TMUX_VERSION" | cut -d. -f2 | tr -dc '0-9')"
                if [[ "$TMUX_MAJOR" -ge 4 ]] || [[ "$TMUX_MAJOR" -ge 3 && "$TMUX_MINOR" -ge 2 ]]; then
                    check_pass "tmux ${TMUX_VERSION}"
                else
                    check_warn "tmux ${TMUX_VERSION} — 3.2+ required"
                    echo -e "    ${DIM}$(get_install_cmd "$OS" tmux)${RESET}"
                fi
            else
                check_fail "tmux not installed"
                echo -e "    ${DIM}$(get_install_cmd "$OS" tmux)${RESET}"
            fi
            ;;
        bash)
            BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
            if [[ "$BASH_MAJOR" -ge 3 ]]; then
                check_pass "bash $BASH_VERSION"
            else
                check_fail "bash $BASH_VERSION — 3.2+ required"
                echo -e "    ${DIM}$(get_install_cmd "$OS" bash)${RESET}"
            fi
            ;;
        git)
            if command -v git &>/dev/null; then
                check_pass "git $(git --version | awk '{print $3}')"
            else
                check_fail "git not installed"
                echo -e "    ${DIM}$(get_install_cmd "$OS" git)${RESET}"
            fi
            ;;
        jq)
            if command -v jq &>/dev/null; then
                check_pass "jq $(jq --version 2>&1 | tr -d 'jq-')"
            else
                check_fail "jq not installed"
                echo -e "    ${DIM}$(get_install_cmd "$OS" jq)${RESET}"
            fi
            ;;
        gh)
            if command -v gh &>/dev/null; then
                if gh auth status &>/dev/null 2>&1; then
                    GH_USER="$(gh api user -q .login 2>/dev/null || echo "authenticated")"
                    check_pass "GitHub CLI: ${GH_USER}"
                else
                    check_warn "GitHub CLI installed but not authenticated"
                    echo -e "    ${DIM}gh auth login${RESET}"
                fi
            else
                check_warn "GitHub CLI (gh) not installed"
                echo -e "    ${DIM}$(get_install_cmd "$OS" gh)${RESET}"
            fi
            ;;
        claude)
            if command -v claude &>/dev/null; then
                check_pass "Claude Code CLI"
            else
                check_fail "Claude Code CLI not found"
                echo -e "    ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
            fi
            ;;
    esac
done

echo ""

# Check optional tools
for tool in "${OPTIONAL_TOOLS[@]}"; do
    case "$tool" in
        bun)
            if command -v bun &>/dev/null; then
                check_pass "Bun (dashboard server)"
            else
                check_warn "Bun not installed (optional — for dashboard)"
                echo -e "    ${DIM}curl -fsSL https://bun.sh/install | bash${RESET}"
            fi
            ;;
    esac
done

echo ""

# Bail early if critical prereqs are missing
if [[ $FAIL -gt 0 ]]; then
    echo -e "  Summary: ${GREEN}${BOLD}${PASS}${RESET} passed  ${YELLOW}${BOLD}${WARN}${RESET} warnings  ${RED}${BOLD}${FAIL}${RESET} failed"
    echo ""
    error "Fix the failed prerequisites above before continuing."
    echo -e "  ${DIM}Re-run: shipwright setup${RESET}"
    exit 1
fi

echo -e "  Summary: ${GREEN}${BOLD}${PASS}${RESET} passed  ${YELLOW}${BOLD}${WARN}${RESET} warnings  ${RED}${BOLD}${FAIL}${RESET} failed"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2: Repo Analysis
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  PHASE 2: REPO ANALYSIS${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

DETECTED_LANGUAGE=""
DETECTED_FRAMEWORK=""
DETECTED_TEST_CMD=""
DETECTED_BUILD_CMD=""

# Detect language and framework
if [[ -f "package.json" ]]; then
    DETECTED_LANGUAGE="Node.js"
    if grep -q '"next"' package.json 2>/dev/null; then
        DETECTED_FRAMEWORK="Next.js"
    elif grep -q '"react"' package.json 2>/dev/null; then
        DETECTED_FRAMEWORK="React"
    elif grep -q '"express"' package.json 2>/dev/null; then
        DETECTED_FRAMEWORK="Express.js"
    elif grep -q '"vue"' package.json 2>/dev/null; then
        DETECTED_FRAMEWORK="Vue.js"
    else
        DETECTED_FRAMEWORK="Node.js (generic)"
    fi

    # Detect test command
    if grep -q '"jest"' package.json 2>/dev/null; then
        DETECTED_TEST_CMD="npm test"
    elif grep -q '"mocha"' package.json 2>/dev/null; then
        DETECTED_TEST_CMD="npm test"
    elif grep -q '"vitest"' package.json 2>/dev/null; then
        DETECTED_TEST_CMD="npm run test"
    fi

    # Detect build command
    if [[ -n "$(grep -o '"build":' package.json 2>/dev/null || true)" ]]; then
        DETECTED_BUILD_CMD="npm run build"
    fi
elif [[ -f "Cargo.toml" ]]; then
    DETECTED_LANGUAGE="Rust"
    DETECTED_FRAMEWORK="Cargo"
    DETECTED_TEST_CMD="cargo test"
    DETECTED_BUILD_CMD="cargo build"
elif [[ -f "go.mod" ]]; then
    DETECTED_LANGUAGE="Go"
    DETECTED_FRAMEWORK="Go"
    DETECTED_TEST_CMD="go test ./..."
    DETECTED_BUILD_CMD="go build"
elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
    DETECTED_LANGUAGE="Python"
    DETECTED_FRAMEWORK="Python"
    if [[ -f "pyproject.toml" ]] && grep -q 'pytest' pyproject.toml 2>/dev/null; then
        DETECTED_TEST_CMD="pytest"
    elif [[ -f "setup.py" ]]; then
        DETECTED_TEST_CMD="python -m pytest"
    fi
    DETECTED_BUILD_CMD="python setup.py build"
fi

# Display detected info
if [[ -n "$DETECTED_LANGUAGE" ]]; then
    info "Detected ${BOLD}${DETECTED_LANGUAGE}${RESET} project"
    [[ -n "$DETECTED_FRAMEWORK" ]] && echo -e "    ${DIM}Framework: ${DETECTED_FRAMEWORK}${RESET}"
    [[ -n "$DETECTED_TEST_CMD" ]] && echo -e "    ${DIM}Test: ${DETECTED_TEST_CMD}${RESET}"
    [[ -n "$DETECTED_BUILD_CMD" ]] && echo -e "    ${DIM}Build: ${DETECTED_BUILD_CMD}${RESET}"
else
    info "Could not auto-detect language (no package.json, Cargo.toml, go.mod, pyproject.toml, or setup.py found)"
fi

# Check for .claude directory
if [[ -d ".claude" ]]; then
    info "Found existing .claude/ directory — will preserve and enhance"
else
    info "Will create .claude/ directory with agent configuration"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3: Configuration Generation
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  PHASE 3: CONFIGURATION GENERATION${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

"$SCRIPT_DIR/sw-init.sh"

# ═════════════════════════════════════════════════════════════════════════════
# Ask about daemon auto-processing
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_DAEMON_PROMPT" == "false" ]]; then
    echo ""
    echo -e "  ${CYAN}${BOLD}Daemon Auto-Processing${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────${RESET}"
    read -rp "$(echo -e "  ${CYAN}${BOLD}▸${RESET} Enable daemon to watch for labeled GitHub issues? [y/N] ")" daemon_confirm
    if [[ "$(echo "$daemon_confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
        success "Daemon auto-processing enabled"
        info "Start with: ${DIM}shipwright daemon start${RESET}"
    else
        info "Daemon auto-processing disabled"
    fi
    echo ""
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4: Validation & Quick Start
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${PURPLE}${BOLD}  PHASE 4: VALIDATION${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

"$SCRIPT_DIR/sw-doctor.sh" || true

# ═════════════════════════════════════════════════════════════════════════════
# Quick Start Guide
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}${BOLD}  ╔════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║  Setup Complete! Quick Start Guide                            ║${RESET}"
echo -e "${CYAN}${BOLD}  ╠════════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}✓${RESET}  Prerequisites checked and tools configured"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}✓${RESET}  .claude/ directory with agent config created"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}✓${RESET}  tmux integration ready"
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${CYAN}${BOLD}→ Try these commands next:${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}"
if [[ -z "${TMUX:-}" ]]; then
echo -e "${CYAN}${BOLD}  ║  ${DIM}1. tmux new -s dev                     # Start tmux session${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${DIM}2. shipwright session work            # Create team session${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${DIM}3. claude                             # Launch Claude Code${RESET} ${CYAN}${BOLD}║${RESET}"
else
echo -e "${CYAN}${BOLD}  ║  ${DIM}1. shipwright session work            # Create team session${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${DIM}2. claude                             # Launch Claude Code${RESET} ${CYAN}${BOLD}║${RESET}"
fi
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${CYAN}${BOLD}→ Or use the autonomous loop:${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}"
if [[ -n "$DETECTED_TEST_CMD" ]]; then
echo -e "${CYAN}${BOLD}  ║  ${DIM}shipwright loop \"fix the failing tests\" --test-cmd \"${DETECTED_TEST_CMD}\"${RESET} ${CYAN}${BOLD}║${RESET}"
else
echo -e "${CYAN}${BOLD}  ║  ${DIM}shipwright loop \"build authentication\" --test-cmd \"npm test\"${RESET} ${CYAN}${BOLD}║${RESET}"
fi
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${CYAN}${BOLD}→ Or start the full delivery pipeline:${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${DIM}shipwright pipeline start --goal \"add user authentication\"${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${CYAN}${BOLD}→ Or watch GitHub for labeled issues:${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  ${DIM}shipwright daemon start               # Watch for GitHub issues${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ║${RESET}"
echo -e "${CYAN}${BOLD}  ║  See more: ${DIM}shipwright --help${RESET} ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}  ╚════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
success "Shipwright v${VERSION} setup complete — you're ready to orchestrate!"
echo ""
