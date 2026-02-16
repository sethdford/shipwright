#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw upgrade — Detect and apply updates from the repo                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.1.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$HOME/.shipwright"
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

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
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
        if [[ -f "$dir/install.sh" && -d "$dir/scripts" && -f "$dir/scripts/sw" ]]; then
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
    "shipwright-overlay.conf|tmux/shipwright-overlay.conf|$HOME/.tmux/shipwright-overlay.conf|false|false"
    "settings.json.template|claude-code/settings.json.template|$HOME/.claude/settings.json.template|false|false"
    "settings.json||$HOME/.claude/settings.json|true|false"
    "sw|scripts/sw|$BIN_DIR/sw|false|true"
    "sw-session.sh|scripts/sw-session.sh|$BIN_DIR/sw-session.sh|false|true"
    "sw-status.sh|scripts/sw-status.sh|$BIN_DIR/sw-status.sh|false|true"
    "sw-cleanup.sh|scripts/sw-cleanup.sh|$BIN_DIR/sw-cleanup.sh|false|true"
    "sw-upgrade.sh|scripts/sw-upgrade.sh|$BIN_DIR/sw-upgrade.sh|false|true"
    "sw-doctor.sh|scripts/sw-doctor.sh|$BIN_DIR/sw-doctor.sh|false|true"
    "sw-logs.sh|scripts/sw-logs.sh|$BIN_DIR/sw-logs.sh|false|true"
    "sw-ps.sh|scripts/sw-ps.sh|$BIN_DIR/sw-ps.sh|false|true"
    "sw-templates.sh|scripts/sw-templates.sh|$BIN_DIR/sw-templates.sh|false|true"
    "sw-loop.sh|scripts/sw-loop.sh|$BIN_DIR/sw-loop.sh|false|true"
    "sw-pipeline.sh|scripts/sw-pipeline.sh|$BIN_DIR/sw-pipeline.sh|false|true"
    "sw-pipeline-test.sh|scripts/sw-pipeline-test.sh|$BIN_DIR/sw-pipeline-test.sh|false|true"
    "sw-worktree.sh|scripts/sw-worktree.sh|$BIN_DIR/sw-worktree.sh|false|true"
    "sw-init.sh|scripts/sw-init.sh|$BIN_DIR/sw-init.sh|false|true"
    "sw-setup.sh|scripts/sw-setup.sh|$BIN_DIR/sw-setup.sh|false|true"
    "sw-prep.sh|scripts/sw-prep.sh|$BIN_DIR/sw-prep.sh|false|true"
    "sw-daemon.sh|scripts/sw-daemon.sh|$BIN_DIR/sw-daemon.sh|false|true"
    "sw-daemon-test.sh|scripts/sw-daemon-test.sh|$BIN_DIR/sw-daemon-test.sh|false|true"
    "sw-prep-test.sh|scripts/sw-prep-test.sh|$BIN_DIR/sw-prep-test.sh|false|true"
    "sw-memory.sh|scripts/sw-memory.sh|$BIN_DIR/sw-memory.sh|false|true"
    "sw-memory-test.sh|scripts/sw-memory-test.sh|$BIN_DIR/sw-memory-test.sh|false|true"
    "sw-cost.sh|scripts/sw-cost.sh|$BIN_DIR/sw-cost.sh|false|true"
    "sw-fleet.sh|scripts/sw-fleet.sh|$BIN_DIR/sw-fleet.sh|false|true"
    "sw-fleet-test.sh|scripts/sw-fleet-test.sh|$BIN_DIR/sw-fleet-test.sh|false|true"
    "sw-fix.sh|scripts/sw-fix.sh|$BIN_DIR/sw-fix.sh|false|true"
    "sw-fix-test.sh|scripts/sw-fix-test.sh|$BIN_DIR/sw-fix-test.sh|false|true"
    "sw-reaper.sh|scripts/sw-reaper.sh|$BIN_DIR/sw-reaper.sh|false|true"
    "sw-dashboard.sh|scripts/sw-dashboard.sh|$BIN_DIR/sw-dashboard.sh|false|true"
    "sw-docs.sh|scripts/sw-docs.sh|$BIN_DIR/sw-docs.sh|false|true"
    "sw-tmux.sh|scripts/sw-tmux.sh|$BIN_DIR/sw-tmux.sh|false|true"
    "sw-connect.sh|scripts/sw-connect.sh|$BIN_DIR/sw-connect.sh|false|true"
    "sw-tracker.sh|scripts/sw-tracker.sh|$BIN_DIR/sw-tracker.sh|false|true"
    "sw-linear.sh|scripts/sw-linear.sh|$BIN_DIR/sw-linear.sh|false|true"
    "sw-jira.sh|scripts/sw-jira.sh|$BIN_DIR/sw-jira.sh|false|true"
    "sw-launchd.sh|scripts/sw-launchd.sh|$BIN_DIR/sw-launchd.sh|false|true"
    "sw-checkpoint.sh|scripts/sw-checkpoint.sh|$BIN_DIR/sw-checkpoint.sh|false|true"
    "sw-heartbeat.sh|scripts/sw-heartbeat.sh|$BIN_DIR/sw-heartbeat.sh|false|true"
    "sw-intelligence.sh|scripts/sw-intelligence.sh|$BIN_DIR/sw-intelligence.sh|false|true"
    "sw-pipeline-composer.sh|scripts/sw-pipeline-composer.sh|$BIN_DIR/sw-pipeline-composer.sh|false|true"
    "sw-self-optimize.sh|scripts/sw-self-optimize.sh|$BIN_DIR/sw-self-optimize.sh|false|true"
    "sw-predictive.sh|scripts/sw-predictive.sh|$BIN_DIR/sw-predictive.sh|false|true"
    "sw-adversarial.sh|scripts/sw-adversarial.sh|$BIN_DIR/sw-adversarial.sh|false|true"
    "sw-developer-simulation.sh|scripts/sw-developer-simulation.sh|$BIN_DIR/sw-developer-simulation.sh|false|true"
    "sw-architecture-enforcer.sh|scripts/sw-architecture-enforcer.sh|$BIN_DIR/sw-architecture-enforcer.sh|false|true"
    "sw-patrol-meta.sh|scripts/sw-patrol-meta.sh|$BIN_DIR/sw-patrol-meta.sh|false|true"
    # GitHub API modules
    "sw-github-graphql.sh|scripts/sw-github-graphql.sh|$BIN_DIR/sw-github-graphql.sh|false|true"
    "sw-github-checks.sh|scripts/sw-github-checks.sh|$BIN_DIR/sw-github-checks.sh|false|true"
    "sw-github-deploy.sh|scripts/sw-github-deploy.sh|$BIN_DIR/sw-github-deploy.sh|false|true"
    # Tracker adapters
    "sw-tracker-linear.sh|scripts/sw-tracker-linear.sh|$BIN_DIR/sw-tracker-linear.sh|false|true"
    "sw-tracker-jira.sh|scripts/sw-tracker-jira.sh|$BIN_DIR/sw-tracker-jira.sh|false|true"
    # Test suites
    "sw-connect-test.sh|scripts/sw-connect-test.sh|$BIN_DIR/sw-connect-test.sh|false|true"
    "sw-intelligence-test.sh|scripts/sw-intelligence-test.sh|$BIN_DIR/sw-intelligence-test.sh|false|true"
    "sw-frontier-test.sh|scripts/sw-frontier-test.sh|$BIN_DIR/sw-frontier-test.sh|false|true"
    "sw-self-optimize-test.sh|scripts/sw-self-optimize-test.sh|$BIN_DIR/sw-self-optimize-test.sh|false|true"
    "sw-pipeline-composer-test.sh|scripts/sw-pipeline-composer-test.sh|$BIN_DIR/sw-pipeline-composer-test.sh|false|true"
    "sw-predictive-test.sh|scripts/sw-predictive-test.sh|$BIN_DIR/sw-predictive-test.sh|false|true"
    "sw-heartbeat-test.sh|scripts/sw-heartbeat-test.sh|$BIN_DIR/sw-heartbeat-test.sh|false|true"
    "sw-github-graphql-test.sh|scripts/sw-github-graphql-test.sh|$BIN_DIR/sw-github-graphql-test.sh|false|true"
    "sw-github-checks-test.sh|scripts/sw-github-checks-test.sh|$BIN_DIR/sw-github-checks-test.sh|false|true"
    "sw-github-deploy-test.sh|scripts/sw-github-deploy-test.sh|$BIN_DIR/sw-github-deploy-test.sh|false|true"
    "sw-tracker-test.sh|scripts/sw-tracker-test.sh|$BIN_DIR/sw-tracker-test.sh|false|true"
    "sw-init-test.sh|scripts/sw-init-test.sh|$BIN_DIR/sw-init-test.sh|false|true"
    "sw-session-test.sh|scripts/sw-session-test.sh|$BIN_DIR/sw-session-test.sh|false|true"
    "sw-remote-test.sh|scripts/sw-remote-test.sh|$BIN_DIR/sw-remote-test.sh|false|true"
    # Shared libraries
    "compat.sh|scripts/lib/compat.sh|$BIN_DIR/lib/compat.sh|false|false"
    "CLAUDE.md.shipwright|claude-code/CLAUDE.md.shipwright|$HOME/.claude/CLAUDE.md|true|false"
    "teammate-idle.sh|claude-code/hooks/teammate-idle.sh|$HOME/.claude/hooks/teammate-idle.sh|false|true"
    "task-completed.sh|claude-code/hooks/task-completed.sh|$HOME/.claude/hooks/task-completed.sh|false|true"
    "notify-idle.sh|claude-code/hooks/notify-idle.sh|$HOME/.claude/hooks/notify-idle.sh|false|true"
    "pre-compact-save.sh|claude-code/hooks/pre-compact-save.sh|$HOME/.claude/hooks/pre-compact-save.sh|false|true"
    "feature-dev.json|tmux/templates/feature-dev.json|$HOME/.shipwright/templates/feature-dev.json|false|false"
    "code-review.json|tmux/templates/code-review.json|$HOME/.shipwright/templates/code-review.json|false|false"
    "refactor.json|tmux/templates/refactor.json|$HOME/.shipwright/templates/refactor.json|false|false"
    "exploration.json|tmux/templates/exploration.json|$HOME/.shipwright/templates/exploration.json|false|false"
    "bug-fix.json|tmux/templates/bug-fix.json|$HOME/.shipwright/templates/bug-fix.json|false|false"
    "testing.json|tmux/templates/testing.json|$HOME/.shipwright/templates/testing.json|false|false"
    "full-stack.json|tmux/templates/full-stack.json|$HOME/.shipwright/templates/full-stack.json|false|false"
    "security-audit.json|tmux/templates/security-audit.json|$HOME/.shipwright/templates/security-audit.json|false|false"
    "migration.json|tmux/templates/migration.json|$HOME/.shipwright/templates/migration.json|false|false"
    "documentation.json|tmux/templates/documentation.json|$HOME/.shipwright/templates/documentation.json|false|false"
    "devops.json|tmux/templates/devops.json|$HOME/.shipwright/templates/devops.json|false|false"
    "architecture.json|tmux/templates/architecture.json|$HOME/.shipwright/templates/architecture.json|false|false"
    "definition-of-done.example.md|docs/definition-of-done.example.md|$HOME/.shipwright/templates/definition-of-done.example.md|false|false"
    "pipeline-standard.json|templates/pipelines/standard.json|$HOME/.shipwright/pipelines/standard.json|false|false"
    "pipeline-fast.json|templates/pipelines/fast.json|$HOME/.shipwright/pipelines/fast.json|false|false"
    "pipeline-full.json|templates/pipelines/full.json|$HOME/.shipwright/pipelines/full.json|false|false"
    "pipeline-hotfix.json|templates/pipelines/hotfix.json|$HOME/.shipwright/pipelines/hotfix.json|false|false"
    "pipeline-autonomous.json|templates/pipelines/autonomous.json|$HOME/.shipwright/pipelines/autonomous.json|false|false"
    "pipeline-cost-aware.json|templates/pipelines/cost-aware.json|$HOME/.shipwright/pipelines/cost-aware.json|false|false"
    "pipeline-enterprise.json|templates/pipelines/enterprise.json|$HOME/.shipwright/pipelines/enterprise.json|false|false"
    "pipeline-deployed.json|templates/pipelines/deployed.json|$HOME/.shipwright/pipelines/deployed.json|false|false"
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
SW_SELF_UPGRADED=false

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
        if [[ "$key" == sw* ]]; then
            SW_SELF_UPGRADED=true
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
if $SW_SELF_UPGRADED; then
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
