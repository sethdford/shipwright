#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Build Release Artifacts                                   ║
# ║  Creates platform tarballs and checksums for GitHub Releases            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.9.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

# ─── Colors ────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Read version from package.json ───────────────────────────────────────
if command -v jq &>/dev/null && [[ -f "$REPO_ROOT/package.json" ]]; then
    VERSION="$(jq -r .version "$REPO_ROOT/package.json")"
fi

echo ""
echo -e "${CYAN}${BOLD}  ⚓ Shipwright Release Builder  v${VERSION}${RESET}"
echo ""

# ─── Prepare dist directory ───────────────────────────────────────────────
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ─── Collect files into staging area ──────────────────────────────────────
STAGING="$DIST_DIR/staging"
mkdir -p "$STAGING"

cp -R "$REPO_ROOT/scripts" "$STAGING/"
cp -R "$REPO_ROOT/templates" "$STAGING/"
cp -R "$REPO_ROOT/tmux" "$STAGING/"
cp -R "$REPO_ROOT/claude-code" "$STAGING/"
[[ -d "$REPO_ROOT/completions" ]] && cp -R "$REPO_ROOT/completions" "$STAGING/"
[[ -d "$REPO_ROOT/docs" ]] && cp -R "$REPO_ROOT/docs" "$STAGING/"

# Include repo-level agent definitions and hooks
mkdir -p "$STAGING/.claude"
[[ -d "$REPO_ROOT/.claude/agents" ]] && cp -R "$REPO_ROOT/.claude/agents" "$STAGING/.claude/"
[[ -d "$REPO_ROOT/.claude/hooks" ]] && cp -R "$REPO_ROOT/.claude/hooks" "$STAGING/.claude/"
cp "$REPO_ROOT/LICENSE" "$STAGING/"
cp "$REPO_ROOT/README.md" "$STAGING/"
cp "$REPO_ROOT/package.json" "$STAGING/"

# Remove test scripts from release
rm -f "$STAGING"/scripts/*-test.sh

# Make scripts executable
chmod +x "$STAGING"/scripts/*

# ─── Build platform tarballs ──────────────────────────────────────────────
PLATFORMS=(
    "darwin-arm64"
    "darwin-x86_64"
    "linux-x86_64"
)

for platform in "${PLATFORMS[@]}"; do
    tarball="shipwright-${platform}.tar.gz"
    info "Building ${BOLD}${tarball}${RESET}"
    tar -czf "$DIST_DIR/$tarball" -C "$STAGING" .
    success "Created ${tarball}"
done

# ─── Generate checksums ──────────────────────────────────────────────────
info "Generating checksums..."
cd "$DIST_DIR"
shasum -a 256 shipwright-*.tar.gz > checksums.txt
success "Created checksums.txt"
cd "$REPO_ROOT"

# ─── Cleanup staging ──────────────────────────────────────────────────────
rm -rf "$STAGING"

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
success "Release artifacts ready in ${BOLD}dist/${RESET}"
echo ""
for f in "$DIST_DIR"/*; do
    local_size="$(wc -c < "$f" | tr -d ' ')"
    echo -e "  ${DIM}$(basename "$f")${RESET}  ${DIM}(${local_size} bytes)${RESET}"
done
echo ""
