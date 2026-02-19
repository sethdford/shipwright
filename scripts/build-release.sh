#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Build Release Artifacts                                   ║
# ║  Creates platform tarballs and checksums for GitHub Releases            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

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
# ─── Read version from package.json ───────────────────────────────────────
if command -v jq >/dev/null 2>&1 && [[ -f "$REPO_ROOT/package.json" ]]; then
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
[[ -d "$REPO_ROOT/config" ]] && cp -R "$REPO_ROOT/config" "$STAGING/"

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
