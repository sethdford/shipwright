#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Version Updater                                           ║
# ║  Bumps VERSION= across all scripts and package.json                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# README.md: version badge, TOC anchor, "What's New" heading, release command examples
README="$REPO_ROOT/README.md"
if [[ -f "$README" ]]; then
    # Anchor slug: v2.2.1 -> v221 (remove dots)
    ANCHOR_SLUG="v${NEW_VERSION//./}"
    sed_i "s/badge\/version-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/badge\/version-$NEW_VERSION/" "$README"
    sed_i "s/alt=\"v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\"/alt=\"v$NEW_VERSION\"/" "$README"
    sed_i "s/^- \\[What's New in v[0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*\\](#whats-new-in-v[0-9][0-9]*)$/- [What's New in v$NEW_VERSION](#whats-new-in-$ANCHOR_SLUG)/" "$README"
    sed_i "s/## What's New in v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/## What's New in v$NEW_VERSION/" "$README"
    sed_i "s/shipwright release --version [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/shipwright release --version $NEW_VERSION/g" "$README"
    success "Updated README.md (badge, TOC, What's New, release examples)"
    ((COUNT++))
fi

# .claude/hygiene-report.json if present
HYGIENTE="$REPO_ROOT/.claude/hygiene-report.json"
if [[ -f "$HYGIENTE" ]]; then
    if command -v jq &>/dev/null; then
        jq --arg v "$NEW_VERSION" '.version = $v' "$HYGIENTE" > "$HYGIENTE.tmp" && mv "$HYGIENTE.tmp" "$HYGIENTE"
    else
        sed_i "s/\"version\": \"[^\"]*\"/\"version\": \"$NEW_VERSION\"/" "$HYGIENTE"
    fi
    success "Updated .claude/hygiene-report.json"
    ((COUNT++))
fi

echo ""
info "Bumped ${BOLD}$COUNT${RESET} files to ${CYAN}v${NEW_VERSION}${RESET}"
