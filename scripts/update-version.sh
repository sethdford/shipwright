#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Version Updater                                           ║
# ║  Bumps VERSION= across all scripts and package.json                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

NEW_VERSION="${1:-}"
if [[ -z "$NEW_VERSION" ]]; then
    error "Usage: $0 <version>"
    echo -e "  ${DIM}Example: $0 1.7.0${RESET}"
    exit 1
fi

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid semver: $NEW_VERSION"
    exit 1
fi

COUNT=0

# Update VERSION= in all scripts
while IFS= read -r file; do
    sed_i "s/^VERSION=\"[^\"]*\"/VERSION=\"$NEW_VERSION\"/" "$file"
    success "Updated $(basename "$file")"
    ((COUNT++))
done < <(grep -rl '^VERSION="' "$REPO_ROOT/scripts/" "$REPO_ROOT/install.sh" 2>/dev/null || true)

# Update package.json
PKG="$REPO_ROOT/package.json"
if [[ -f "$PKG" ]]; then
    if command -v jq &>/dev/null; then
        jq --arg v "$NEW_VERSION" '.version = $v' "$PKG" > "$PKG.tmp" && mv "$PKG.tmp" "$PKG"
    else
        sed_i "s/\"version\": \"[^\"]*\"/\"version\": \"$NEW_VERSION\"/" "$PKG"
    fi
    success "Updated package.json"
    ((COUNT++))
fi

echo ""
info "Bumped ${BOLD}$COUNT${RESET} files to ${CYAN}v${NEW_VERSION}${RESET}"
