#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct upgrade — Detect and apply updates from the repo                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$HOME/.claude-teams"
MANIFEST="$MANIFEST_DIR/manifest.json"

# ─── Colors ────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
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

# ─── Parse flags ───────────────────────────────────────────────────────────
APPLY=false
REPO_OVERRIDE=""

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --repo-path)  shift_next=true ;;
        --repo-path=*) REPO_OVERRIDE="${arg#--repo-path=}" ;;
        *)
            if [[ "${shift_next:-}" == "true" ]]; then
                REPO_OVERRIDE="$arg"
                shift_next=false
            fi
            ;;
    esac
done

# ─── Locate repo ──────────────────────────────────────────────────────────
find_repo() {
    # 1. Explicit override
    if [[ -n "$REPO_OVERRIDE" ]]; then
        echo "$REPO_OVERRIDE"
        return
    fi

    # 2. Environment variable
    if [[ -n "${CCT_REPO_PATH:-}" ]]; then
        echo "$CCT_REPO_PATH"
        return
    fi

    # 3. Walk up from script dir
    local dir="$SCRIPT_DIR"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/install.sh" && -d "$dir/scripts" && -f "$dir/scripts/cct" ]]; then
            echo "$dir"
            return
        fi
        dir="$(dirname "$dir")"
    done

    # 4. Check manifest for stored repo_path
    if [[ -f "$MANIFEST" ]]; then
        local stored
        stored="$(jq -r '.repo_path // ""' "$MANIFEST" 2>/dev/null || true)"
        if [[ -n "$stored" && -d "$stored" ]]; then
            echo "$stored"
            return
        fi
    fi

    return 1
}

REPO_PATH="$(find_repo)" || {
    error "Cannot locate the Shipwright repo."
    echo ""
    echo -e "  Try one of:"
    echo -e "    ${DIM}export CCT_REPO_PATH=/path/to/shipwright${RESET}"
    echo -e "    ${DIM}shipwright upgrade --repo-path /path/to/shipwright${RESET}"
    exit 1
}

# ─── File registry ─────────────────────────────────────────────────────────
# Each entry: "key|src_relative|dest_absolute|protected|executable"
BIN_DIR="$HOME/.local/bin"

FILES=(
    "tmux.conf|tmux/tmux.conf|$HOME/.tmux.conf|false|false"
    "claude-teams-overlay.conf|tmux/claude-teams-overlay.conf|$HOME/.tmux/claude-teams-overlay.conf|false|false"
    "settings.json.template|claude-code/settings.json.template|$HOME/.claude/settings.json.template|false|false"
    "settings.json||$HOME/.claude/settings.json|true|false"
    "cct|scripts/cct|$BIN_DIR/cct|false|true"
    "cct-session.sh|scripts/cct-session.sh|$BIN_DIR/cct-session.sh|false|true"
    "cct-status.sh|scripts/cct-status.sh|$BIN_DIR/cct-status.sh|false|true"
    "cct-cleanup.sh|scripts/cct-cleanup.sh|$BIN_DIR/cct-cleanup.sh|false|true"
    "cct-upgrade.sh|scripts/cct-upgrade.sh|$BIN_DIR/cct-upgrade.sh|false|true"
    "cct-doctor.sh|scripts/cct-doctor.sh|$BIN_DIR/cct-doctor.sh|false|true"
    "cct-logs.sh|scripts/cct-logs.sh|$BIN_DIR/cct-logs.sh|false|true"
    "cct-ps.sh|scripts/cct-ps.sh|$BIN_DIR/cct-ps.sh|false|true"
    "cct-templates.sh|scripts/cct-templates.sh|$BIN_DIR/cct-templates.sh|false|true"
    "cct-loop.sh|scripts/cct-loop.sh|$BIN_DIR/cct-loop.sh|false|true"
    "cct-pipeline.sh|scripts/cct-pipeline.sh|$BIN_DIR/cct-pipeline.sh|false|true"
    "cct-pipeline-test.sh|scripts/cct-pipeline-test.sh|$BIN_DIR/cct-pipeline-test.sh|false|true"
    "cct-worktree.sh|scripts/cct-worktree.sh|$BIN_DIR/cct-worktree.sh|false|true"
    "cct-init.sh|scripts/cct-init.sh|$BIN_DIR/cct-init.sh|false|true"
    "cct-prep.sh|scripts/cct-prep.sh|$BIN_DIR/cct-prep.sh|false|true"
    "cct-daemon.sh|scripts/cct-daemon.sh|$BIN_DIR/cct-daemon.sh|false|true"
    "cct-daemon-test.sh|scripts/cct-daemon-test.sh|$BIN_DIR/cct-daemon-test.sh|false|true"
    "cct-prep-test.sh|scripts/cct-prep-test.sh|$BIN_DIR/cct-prep-test.sh|false|true"
    "cct-memory.sh|scripts/cct-memory.sh|$BIN_DIR/cct-memory.sh|false|true"
    "cct-memory-test.sh|scripts/cct-memory-test.sh|$BIN_DIR/cct-memory-test.sh|false|true"
    "cct-cost.sh|scripts/cct-cost.sh|$BIN_DIR/cct-cost.sh|false|true"
    "cct-fleet.sh|scripts/cct-fleet.sh|$BIN_DIR/cct-fleet.sh|false|true"
    "cct-fleet-test.sh|scripts/cct-fleet-test.sh|$BIN_DIR/cct-fleet-test.sh|false|true"
    "cct-fix.sh|scripts/cct-fix.sh|$BIN_DIR/cct-fix.sh|false|true"
    "cct-fix-test.sh|scripts/cct-fix-test.sh|$BIN_DIR/cct-fix-test.sh|false|true"
    "cct-reaper.sh|scripts/cct-reaper.sh|$BIN_DIR/cct-reaper.sh|false|true"
    "CLAUDE.md.shipwright|claude-code/CLAUDE.md.shipwright|$HOME/.claude/CLAUDE.md|true|false"
    "teammate-idle.sh|claude-code/hooks/teammate-idle.sh|$HOME/.claude/hooks/teammate-idle.sh|false|true"
    "task-completed.sh|claude-code/hooks/task-completed.sh|$HOME/.claude/hooks/task-completed.sh|false|true"
    "notify-idle.sh|claude-code/hooks/notify-idle.sh|$HOME/.claude/hooks/notify-idle.sh|false|true"
    "pre-compact-save.sh|claude-code/hooks/pre-compact-save.sh|$HOME/.claude/hooks/pre-compact-save.sh|false|true"
    "feature-dev.json|tmux/templates/feature-dev.json|$HOME/.claude-teams/templates/feature-dev.json|false|false"
    "code-review.json|tmux/templates/code-review.json|$HOME/.claude-teams/templates/code-review.json|false|false"
    "refactor.json|tmux/templates/refactor.json|$HOME/.claude-teams/templates/refactor.json|false|false"
    "exploration.json|tmux/templates/exploration.json|$HOME/.claude-teams/templates/exploration.json|false|false"
    "bug-fix.json|tmux/templates/bug-fix.json|$HOME/.claude-teams/templates/bug-fix.json|false|false"
    "testing.json|tmux/templates/testing.json|$HOME/.claude-teams/templates/testing.json|false|false"
    "full-stack.json|tmux/templates/full-stack.json|$HOME/.claude-teams/templates/full-stack.json|false|false"
    "security-audit.json|tmux/templates/security-audit.json|$HOME/.claude-teams/templates/security-audit.json|false|false"
    "migration.json|tmux/templates/migration.json|$HOME/.claude-teams/templates/migration.json|false|false"
    "documentation.json|tmux/templates/documentation.json|$HOME/.claude-teams/templates/documentation.json|false|false"
    "devops.json|tmux/templates/devops.json|$HOME/.claude-teams/templates/devops.json|false|false"
    "architecture.json|tmux/templates/architecture.json|$HOME/.claude-teams/templates/architecture.json|false|false"
    "definition-of-done.example.md|docs/definition-of-done.example.md|$HOME/.claude-teams/templates/definition-of-done.example.md|false|false"
    "pipeline-standard.json|templates/pipelines/standard.json|$HOME/.claude-teams/pipelines/standard.json|false|false"
    "pipeline-fast.json|templates/pipelines/fast.json|$HOME/.claude-teams/pipelines/fast.json|false|false"
    "pipeline-full.json|templates/pipelines/full.json|$HOME/.claude-teams/pipelines/full.json|false|false"
    "pipeline-hotfix.json|templates/pipelines/hotfix.json|$HOME/.claude-teams/pipelines/hotfix.json|false|false"
    "pipeline-autonomous.json|templates/pipelines/autonomous.json|$HOME/.claude-teams/pipelines/autonomous.json|false|false"
    "pipeline-cost-aware.json|templates/pipelines/cost-aware.json|$HOME/.claude-teams/pipelines/cost-aware.json|false|false"
    "pipeline-enterprise.json|templates/pipelines/enterprise.json|$HOME/.claude-teams/pipelines/enterprise.json|false|false"
    "pipeline-deployed.json|templates/pipelines/deployed.json|$HOME/.claude-teams/pipelines/deployed.json|false|false"
)

# ─── Checksum helper ──────────────────────────────────────────────────────
file_checksum() {
    local file="$1"
    if [[ -f "$file" ]]; then
        md5 -q "$file" 2>/dev/null || md5sum "$file" 2>/dev/null | awk '{print $1}'
    else
        echo ""
    fi
}

# ─── Manifest helpers ─────────────────────────────────────────────────────
read_manifest_checksum() {
    local key="$1"
    if [[ ! -f "$MANIFEST" ]]; then
        echo ""
        return
    fi
    jq -r ".files[\"$key\"].checksum // \"\"" "$MANIFEST" 2>/dev/null || echo ""
}

write_manifest() {
    mkdir -p "$MANIFEST_DIR"
    local json='{\n  "schema": 1,\n  "version": "1.1.0",\n  "installed_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",\n  "repo_path": "'"$REPO_PATH"'",\n  "files": {'
    local first=true

    for entry in "${FILES[@]}"; do
        IFS='|' read -r key src dest protected executable <<< "$entry"
        # Only include files that exist at dest
        if [[ ! -f "$dest" ]]; then
            continue
        fi
        local cksum
        cksum="$(file_checksum "$dest")"

        if ! $first; then json+=','; fi
        first=false

        json+='\n    "'"$key"'": {'
        if [[ -n "$src" ]]; then
            json+='\n      "src": "'"$src"'",'
        fi
        json+='\n      "dest": "'"$dest"'",'
        json+='\n      "checksum": "'"$cksum"'",'
        json+='\n      "protected": '"$protected"','
        json+='\n      "executable": '"$executable"
        json+='\n    }'
    done

    json+='\n  }\n}'
    echo -e "$json" > "$MANIFEST"
}

# ─── Bootstrap manifest if missing ────────────────────────────────────────
bootstrap_manifest() {
    echo ""
    warn "No upgrade manifest found at $MANIFEST"
    info "Bootstrapping from currently installed files..."
    echo ""

    local found=0
    for entry in "${FILES[@]}"; do
        IFS='|' read -r key _ dest _ _ <<< "$entry"
        if [[ -f "$dest" ]]; then
            echo -e "  ${GREEN}✓${RESET} ${DIM}$key${RESET}  →  $dest"
            ((found++))
        fi
    done

    echo ""
    if [[ $found -eq 0 ]]; then
        error "No installed files found. Run install.sh first."
        exit 1
    fi

    info "Found $found installed files. Writing manifest..."
    write_manifest
    success "Manifest created at $MANIFEST"
    echo ""
}

# ─── Main logic ────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v1.3.0${RESET} — ${BOLD}$(if $APPLY; then echo "Applying Upgrade"; else echo "Upgrade Check"; fi)${RESET}"
echo -e "${CYAN}═══════════════════════════════════════════════${RESET}"
echo ""
echo -e "Comparing installed files against repo at:"
echo -e "  ${DIM}$REPO_PATH${RESET}"

# Bootstrap if needed
if [[ ! -f "$MANIFEST" ]]; then
    bootstrap_manifest
fi

# ─── Diff detection ───────────────────────────────────────────────────────
declare -a UPGRADEABLE=()
declare -a UP_TO_DATE=()
declare -a CONFLICTS=()
declare -a MISSING=()
declare -a PROTECTED=()

for entry in "${FILES[@]}"; do
    IFS='|' read -r key src dest protected executable <<< "$entry"

    # Protected files — never auto-upgrade
    if [[ "$protected" == "true" ]]; then
        PROTECTED+=("$key|$dest")
        continue
    fi

    # No source in repo means it's user-only (shouldn't happen for non-protected, but guard)
    if [[ -z "$src" ]]; then
        continue
    fi

    local_src="$REPO_PATH/$src"

    # Source file missing from repo (shouldn't happen unless repo is incomplete)
    if [[ ! -f "$local_src" ]]; then
        continue
    fi

    repo_hash="$(file_checksum "$local_src")"
    manifest_hash="$(read_manifest_checksum "$key")"
    installed_hash="$(file_checksum "$dest")"

    if [[ -z "$installed_hash" ]]; then
        # File missing on disk
        MISSING+=("$key|$src|$dest|$executable")
    elif [[ "$repo_hash" == "$manifest_hash" ]]; then
        # Repo hasn't changed since last install/upgrade
        UP_TO_DATE+=("$key")
    elif [[ "$installed_hash" == "$manifest_hash" ]]; then
        # Repo changed, user hasn't touched it → safe to upgrade
        UPGRADEABLE+=("$key|$src|$dest|$executable")
    else
        # Both repo and user changed → conflict
        CONFLICTS+=("$key|$src|$dest")
    fi
done

# ─── Display results ──────────────────────────────────────────────────────
echo ""

if [[ ${#UPGRADEABLE[@]} -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}UPGRADEABLE${RESET} ${DIM}(repo has newer version):${RESET}"
    for item in "${UPGRADEABLE[@]}"; do
        IFS='|' read -r key src dest _ <<< "$item"
        printf "  ${GREEN}✓${RESET} %-28s ${DIM}%s → %s${RESET}\n" "$key" "$src" "$dest"
    done
    echo ""
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}MISSING${RESET} ${DIM}(not found on disk — will reinstall):${RESET}"
    for item in "${MISSING[@]}"; do
        IFS='|' read -r key src dest _ <<< "$item"
        printf "  ${YELLOW}?${RESET} %-28s ${DIM}%s → %s${RESET}\n" "$key" "$src" "$dest"
    done
    echo ""
fi

if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    echo -e "${RED}${BOLD}CONFLICTS${RESET} ${DIM}(both repo and local file changed — skipped):${RESET}"
    for item in "${CONFLICTS[@]}"; do
        IFS='|' read -r key src dest <<< "$item"
        printf "  ${RED}!${RESET} %-28s ${DIM}review manually: diff %s %s${RESET}\n" "$key" "$REPO_PATH/$src" "$dest"
    done
    echo ""
fi

if [[ ${#UP_TO_DATE[@]} -gt 0 ]]; then
    echo -e "${DIM}UP TO DATE:${RESET}"
    for key in "${UP_TO_DATE[@]}"; do
        echo -e "  ${DIM}○ $key${RESET}"
    done
    echo ""
fi

if [[ ${#PROTECTED[@]} -gt 0 ]]; then
    echo -e "${PURPLE}${BOLD}PROTECTED${RESET} ${DIM}(never auto-upgraded):${RESET}"
    for item in "${PROTECTED[@]}"; do
        IFS='|' read -r key dest <<< "$item"
        echo -e "  ${PURPLE}✗${RESET} ${key}  ${DIM}— user config, review template for new options${RESET}"
    done
    echo ""
fi

# ─── Summary ──────────────────────────────────────────────────────────────
total_actionable=$(( ${#UPGRADEABLE[@]} + ${#MISSING[@]} ))
echo -e "${BOLD}SUMMARY:${RESET} ${GREEN}$total_actionable upgradeable${RESET}, ${#UP_TO_DATE[@]} up to date, ${#CONFLICTS[@]} conflicts, ${#PROTECTED[@]} protected"
echo ""

if [[ $total_actionable -eq 0 && ${#CONFLICTS[@]} -eq 0 ]]; then
    success "Everything is up to date!"
    exit 0
fi

# ─── Apply ────────────────────────────────────────────────────────────────
if ! $APPLY; then
    if [[ $total_actionable -gt 0 ]]; then
        echo -e "Run with ${BOLD}--apply${RESET} to upgrade:"
        echo -e "  ${DIM}shipwright upgrade --apply${RESET}"
        echo ""
    fi
    if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
        warn "Conflicting files must be resolved manually."
    fi
    exit 0
fi

# Apply upgrades
CCT_SELF_UPGRADED=false

echo -e "${BOLD}Applying...${RESET}"
echo ""

apply_file() {
    local key="$1" src="$2" dest="$3" executable="$4"
    local src_full="$REPO_PATH/$src"

    # Create parent directory if needed
    local dest_dir
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir"

    # Backup existing file
    if [[ -f "$dest" ]]; then
        cp "$dest" "${dest}.pre-upgrade.bak"
        echo -e "  ${DIM}Backed up: $dest → ${dest}.pre-upgrade.bak${RESET}"
    fi

    # Copy new version
    cp "$src_full" "$dest"
    if [[ "$executable" == "true" ]]; then
        chmod +x "$dest"
    fi

    echo -e "  ${GREEN}✓${RESET} Updated: ${BOLD}$key${RESET}"
}

# Process upgradeable files
if [[ ${#UPGRADEABLE[@]} -gt 0 ]]; then
    for item in "${UPGRADEABLE[@]}"; do
        IFS='|' read -r key src dest executable <<< "$item"
        apply_file "$key" "$src" "$dest" "$executable"
        if [[ "$key" == cct* ]]; then
            CCT_SELF_UPGRADED=true
        fi
    done
fi

# Process missing files (reinstall)
if [[ ${#MISSING[@]} -gt 0 ]]; then
    for item in "${MISSING[@]}"; do
        IFS='|' read -r key src dest executable <<< "$item"
        apply_file "$key" "$src" "$dest" "$executable"
    done
fi

echo ""

# Rebuild manifest with current checksums for all installed files
write_manifest
success "Manifest updated: $MANIFEST"

# Self-upgrade warning
if $CCT_SELF_UPGRADED; then
    echo ""
    echo -e "${YELLOW}${BOLD}⚠${RESET}  The Shipwright CLI itself was upgraded."
    echo -e "   Your current command completed, but re-run to use the new version."
fi
echo ""

# Tip for tmux users
if [[ ${#UPGRADEABLE[@]} -gt 0 ]] && printf '%s\n' "${UPGRADEABLE[@]}" | grep -q "tmux\|overlay"; then
    info "Tip: Reload tmux config with: ${DIM}prefix + r${RESET}"
    echo ""
fi
