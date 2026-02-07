#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Remote Installer                                          ║
# ║  curl -fsSL https://raw.githubusercontent.com/.../install-remote.sh | sh ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.6.0"
REPO="sethdford/shipwright"
INSTALL_DIR="${SHIPWRIGHT_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_LIB="${SHIPWRIGHT_INSTALL_LIB:-$HOME/.local/lib/shipwright}"

# ─── Colors ────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Banner ────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║  ⚓ Shipwright Installer  v${VERSION}     ║${RESET}"
echo -e "${CYAN}${BOLD}  ╚═══════════════════════════════════════╝${RESET}"
echo ""

# ─── Detect platform ──────────────────────────────────────────────────────
detect_platform() {
    local os arch

    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *)
            error "Unsupported OS: $(uname -s)"
            echo -e "  ${DIM}Shipwright supports macOS and Linux${RESET}"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64)  arch="x86_64" ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    # Linux arm64 not currently packaged
    if [[ "$os" == "linux" && "$arch" == "arm64" ]]; then
        error "Linux arm64 is not yet supported"
        echo -e "  ${DIM}Please install from source: git clone + ./install.sh${RESET}"
        exit 1
    fi

    echo "${os}-${arch}"
}

# ─── Check dependencies ───────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in curl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

# ─── Download and install ─────────────────────────────────────────────────
install() {
    local platform="$1"
    local tarball="shipwright-${platform}.tar.gz"
    local url="https://github.com/${REPO}/releases/latest/download/${tarball}"
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    info "Detected platform: ${BOLD}${platform}${RESET}"
    info "Downloading ${DIM}${url}${RESET}"

    if ! curl -fsSL "$url" -o "$tmpdir/$tarball"; then
        error "Download failed"
        echo -e "  ${DIM}Check https://github.com/${REPO}/releases for available versions${RESET}"
        exit 1
    fi

    info "Extracting..."
    tar -xzf "$tmpdir/$tarball" -C "$tmpdir"

    # Install library files
    info "Installing to ${BOLD}${INSTALL_LIB}${RESET}"
    mkdir -p "$INSTALL_LIB"
    cp -R "$tmpdir"/scripts "$INSTALL_LIB/"
    cp -R "$tmpdir"/templates "$INSTALL_LIB/"
    cp -R "$tmpdir"/tmux "$INSTALL_LIB/"
    cp -R "$tmpdir"/claude-code "$INSTALL_LIB/"
    [[ -d "$tmpdir/completions" ]] && cp -R "$tmpdir"/completions "$INSTALL_LIB/"
    [[ -d "$tmpdir/docs" ]] && cp -R "$tmpdir"/docs "$INSTALL_LIB/"

    # Make scripts executable
    chmod +x "$INSTALL_LIB"/scripts/*

    # Create symlinks in bin dir
    mkdir -p "$INSTALL_DIR"
    ln -sf "$INSTALL_LIB/scripts/cct" "$INSTALL_DIR/shipwright"
    ln -sf "$INSTALL_LIB/scripts/cct" "$INSTALL_DIR/sw"
    ln -sf "$INSTALL_LIB/scripts/cct" "$INSTALL_DIR/cct"
    success "Created symlinks: ${BOLD}shipwright${RESET}, ${BOLD}sw${RESET}, ${BOLD}cct${RESET}"

    # Install shell completions if available
    if [[ -f "$INSTALL_LIB/scripts/install-completions.sh" ]]; then
        info "Installing shell completions..."
        bash "$INSTALL_LIB/scripts/install-completions.sh" 2>/dev/null || true
    fi

    success "Installed Shipwright v${VERSION}"
}

# ─── Check PATH ────────────────────────────────────────────────────────────
check_path() {
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo ""
        warn "${INSTALL_DIR} is not in your PATH"
        echo ""
        echo -e "  Add it to your shell profile:"
        local shell_name
        shell_name="$(basename "${SHELL:-/bin/bash}")"
        local rc_file
        case "$shell_name" in
            zsh)  rc_file="~/.zshrc" ;;
            bash) rc_file="~/.bashrc" ;;
            fish) rc_file="~/.config/fish/config.fish" ;;
            *)    rc_file="~/.profile" ;;
        esac
        echo -e "  ${DIM}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ${rc_file}${RESET}"
        echo -e "  ${DIM}source ${rc_file}${RESET}"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────────────
main() {
    check_deps
    local platform
    platform="$(detect_platform)"
    install "$platform"
    check_path

    echo ""
    echo -e "${CYAN}${BOLD}  ⚓ Ready to build${RESET}"
    echo ""
    echo -e "  ${DIM}\$${RESET} shipwright doctor     ${DIM}# Verify your setup${RESET}"
    echo -e "  ${DIM}\$${RESET} shipwright session    ${DIM}# Launch an agent team${RESET}"
    echo -e "  ${DIM}\$${RESET} shipwright pipeline   ${DIM}# Run a delivery pipeline${RESET}"
    echo ""
}

main
