#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright init — Complete setup for Shipwright + Claude Code Teams    ║
# ║                                                                          ║
# ║  Installs: tmux config, overlay, team & pipeline templates, Claude Code ║
# ║  settings (with agent teams enabled), quality gate hooks, CLAUDE.md     ║
# ║  agent instructions (global + per-repo). Runs doctor at the end.       ║
# ║                                                                          ║
# ║  --deploy  Detect platform and generate deployed.json template          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
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

# ─── Flag parsing ───────────────────────────────────────────────────────────
DEPLOY_SETUP=false
DEPLOY_PLATFORM=""
SKIP_CLAUDE_MD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy)
            DEPLOY_SETUP=true
            shift
            ;;
        --platform)
            DEPLOY_PLATFORM="${2:-}"
            [[ -z "$DEPLOY_PLATFORM" ]] && { error "Missing value for --platform"; exit 1; }
            shift 2
            ;;
        --no-claude-md)
            SKIP_CLAUDE_MD=true
            shift
            ;;
        --help|-h)
            echo "Usage: shipwright init [--deploy] [--platform vercel|fly|railway|docker] [--no-claude-md]"
            echo ""
            echo "Options:"
            echo "  --deploy             Detect deploy platform and generate deployed.json"
            echo "  --platform PLATFORM  Skip detection, use specified platform"
            echo "  --no-claude-md       Skip creating .claude/CLAUDE.md"
            echo "  --help, -h           Show this help"
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            shift
            ;;
    esac
done

echo ""
echo -e "${CYAN}${BOLD}shipwright init${RESET} — Complete setup"
echo -e "${DIM}══════════════════════════════════════════${RESET}"
echo ""

# ─── tmux.conf ────────────────────────────────────────────────────────────────
TOOK_FULL_TMUX_CONF=false
if [[ -f "$REPO_DIR/tmux/tmux.conf" ]]; then
    if [[ -f "$HOME/.tmux.conf" ]]; then
        cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak"
        warn "Backed up existing ~/.tmux.conf → ~/.tmux.conf.bak"
        read -rp "$(echo -e "${CYAN}${BOLD}▸${RESET} Overwrite ~/.tmux.conf with the Shipwright config? [Y/n] ")" tmux_confirm
        if [[ -z "$tmux_confirm" || "$(echo "$tmux_confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
            cp "$REPO_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
            success "Installed ~/.tmux.conf"
            TOOK_FULL_TMUX_CONF=true
        else
            info "Kept existing ~/.tmux.conf"
        fi
    else
        cp "$REPO_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
        success "Installed ~/.tmux.conf"
        TOOK_FULL_TMUX_CONF=true
    fi
else
    warn "tmux.conf not found in package — skipping"
fi

# ─── Overlay ──────────────────────────────────────────────────────────────────
if [[ -f "$REPO_DIR/tmux/claude-teams-overlay.conf" ]]; then
    mkdir -p "$HOME/.tmux"
    cp "$REPO_DIR/tmux/claude-teams-overlay.conf" "$HOME/.tmux/claude-teams-overlay.conf"
    success "Installed ~/.tmux/claude-teams-overlay.conf"
else
    warn "Overlay not found in package — skipping"
fi

# ─── Overlay injection ───────────────────────────────────────────────────────
# If user kept their own tmux.conf, ensure it sources the overlay
if [[ "$TOOK_FULL_TMUX_CONF" == "false" && -f "$HOME/.tmux.conf" ]]; then
    if ! grep -q "claude-teams-overlay" "$HOME/.tmux.conf" 2>/dev/null; then
        read -rp "$(echo -e "${CYAN}${BOLD}▸${RESET} Add Shipwright overlay source to ~/.tmux.conf? [Y/n] ")" overlay_confirm
        if [[ -z "$overlay_confirm" || "$(echo "$overlay_confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
            {
                echo ""
                echo "# Shipwright agent overlay"
                echo "source-file -q ~/.tmux/claude-teams-overlay.conf"
            } >> "$HOME/.tmux.conf"
            success "Appended overlay source to ~/.tmux.conf"
        else
            info "Skipped overlay injection. Add manually:"
            echo -e "    ${DIM}source-file -q ~/.tmux/claude-teams-overlay.conf${RESET}"
        fi
    fi
fi

# ─── Reload tmux config if inside tmux ─────────────────────────────────────
if [[ -n "${TMUX:-}" ]]; then
    tmux source-file "$HOME/.tmux.conf" 2>/dev/null && \
        success "Reloaded tmux config (mouse, terminal overrides active)" || true
fi

# ─── Team Templates ──────────────────────────────────────────────────────────
SHIPWRIGHT_DIR="$HOME/.shipwright"
TEMPLATES_SRC="$REPO_DIR/tmux/templates"
if [[ -d "$TEMPLATES_SRC" ]]; then
    mkdir -p "$SHIPWRIGHT_DIR/templates"
    for tpl in "$TEMPLATES_SRC"/*.json; do
        [[ -f "$tpl" ]] || continue
        cp "$tpl" "$SHIPWRIGHT_DIR/templates/$(basename "$tpl")"
    done
    # Also install to legacy path for backward compatibility
    mkdir -p "$HOME/.claude-teams/templates"
    for tpl in "$TEMPLATES_SRC"/*.json; do
        [[ -f "$tpl" ]] || continue
        cp "$tpl" "$HOME/.claude-teams/templates/$(basename "$tpl")"
    done
    tpl_count=$(find "$SHIPWRIGHT_DIR/templates" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    success "Installed ${tpl_count} team templates → ~/.shipwright/templates/"
fi

# ─── Pipeline Templates ──────────────────────────────────────────────────────
PIPELINES_SRC="$REPO_DIR/templates/pipelines"
if [[ -d "$PIPELINES_SRC" ]]; then
    mkdir -p "$SHIPWRIGHT_DIR/pipelines"
    for tpl in "$PIPELINES_SRC"/*.json; do
        [[ -f "$tpl" ]] || continue
        cp "$tpl" "$SHIPWRIGHT_DIR/pipelines/$(basename "$tpl")"
    done
    pip_count=$(find "$SHIPWRIGHT_DIR/pipelines" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    success "Installed ${pip_count} pipeline templates → ~/.shipwright/pipelines/"
fi

# ─── Claude Code Settings ────────────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
SETTINGS_TEMPLATE="$REPO_DIR/claude-code/settings.json.template"

mkdir -p "$CLAUDE_DIR"

if [[ -f "$SETTINGS_FILE" ]]; then
    # Settings exists — check for agent teams env var
    if grep -q 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' "$SETTINGS_FILE" 2>/dev/null; then
        success "Agent teams already enabled in settings.json"
    else
        # Try to add using jq
        if jq -e '.env' "$SETTINGS_FILE" &>/dev/null 2>&1; then
            tmp=$(mktemp)
            jq '.env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
            success "Enabled agent teams in existing settings.json"
        elif jq -e '.' "$SETTINGS_FILE" &>/dev/null 2>&1; then
            tmp=$(mktemp)
            jq '. + {"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
            success "Added agent teams env to settings.json"
        else
            warn "Could not auto-configure settings.json (JSONC detected)"
            echo -e "    ${DIM}Add to ~/.claude/settings.json:${RESET}"
            echo -e "    ${DIM}\"env\": { \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\" }${RESET}"
        fi
    fi
elif [[ -f "$SETTINGS_TEMPLATE" ]]; then
    cp "$SETTINGS_TEMPLATE" "$SETTINGS_FILE"
    success "Installed ~/.claude/settings.json (with agent teams enabled)"
else
    # Create minimal settings.json with agent teams
    cat > "$SETTINGS_FILE" << 'SETTINGS_EOF'
{
  "hooks": {},
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY": "5",
    "CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE": "70",
    "CLAUDE_CODE_SUBAGENT_MODEL": "haiku"
  }
}
SETTINGS_EOF
    success "Created ~/.claude/settings.json with agent teams enabled"
fi

# ─── Hooks ────────────────────────────────────────────────────────────────────
HOOKS_SRC="$REPO_DIR/claude-code/hooks"
if [[ -d "$HOOKS_SRC" ]]; then
    mkdir -p "$CLAUDE_DIR/hooks"
    hook_count=0
    for hook in "$HOOKS_SRC"/*.sh; do
        [[ -f "$hook" ]] || continue
        dest="$CLAUDE_DIR/hooks/$(basename "$hook")"
        if [[ ! -f "$dest" ]]; then
            cp "$hook" "$dest"
            chmod +x "$dest"
            hook_count=$((hook_count + 1))
        fi
    done
    if [[ $hook_count -gt 0 ]]; then
        success "Installed ${hook_count} quality gate hooks → ~/.claude/hooks/"
    else
        info "Hooks already installed — skipping"
    fi
fi

# ─── CLAUDE.md — Global agent instructions ────────────────────────────────────
CLAUDE_MD_SRC="$REPO_DIR/claude-code/CLAUDE.md.shipwright"
GLOBAL_CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"

if [[ "$SKIP_CLAUDE_MD" == "false" && -f "$CLAUDE_MD_SRC" ]]; then
    if [[ -f "$GLOBAL_CLAUDE_MD" ]]; then
        if grep -q "Shipwright" "$GLOBAL_CLAUDE_MD" 2>/dev/null; then
            info "~/.claude/CLAUDE.md already contains Shipwright instructions"
        else
            { echo ""; echo "---"; echo ""; cat "$CLAUDE_MD_SRC"; } >> "$GLOBAL_CLAUDE_MD"
            success "Appended Shipwright instructions to ~/.claude/CLAUDE.md"
        fi
    else
        cp "$CLAUDE_MD_SRC" "$GLOBAL_CLAUDE_MD"
        success "Installed ~/.claude/CLAUDE.md"
    fi
fi

# ─── CLAUDE.md — Per-repo agent instructions ─────────────────────────────────
LOCAL_CLAUDE_MD=".claude/CLAUDE.md"

if [[ "$SKIP_CLAUDE_MD" == "false" && -f "$CLAUDE_MD_SRC" ]]; then
    if [[ -f "$LOCAL_CLAUDE_MD" ]]; then
        if grep -q "Shipwright" "$LOCAL_CLAUDE_MD" 2>/dev/null; then
            info ".claude/CLAUDE.md already contains Shipwright instructions"
        else
            { echo ""; echo "---"; echo ""; cat "$CLAUDE_MD_SRC"; } >> "$LOCAL_CLAUDE_MD"
            success "Appended Shipwright instructions to ${LOCAL_CLAUDE_MD}"
        fi
    else
        mkdir -p ".claude"
        cp "$CLAUDE_MD_SRC" "$LOCAL_CLAUDE_MD"
        success "Created ${LOCAL_CLAUDE_MD} with Shipwright agent instructions"
    fi
fi

# ─── Reload tmux if inside a session ──────────────────────────────────────────
if [[ -n "${TMUX:-}" ]]; then
    tmux source-file "$HOME/.tmux.conf" 2>/dev/null && \
        success "Reloaded tmux config" || \
        warn "Could not reload tmux config (reload manually with prefix + r)"
fi

# ─── Validation ───────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}Running doctor...${RESET}"
echo ""
"$SCRIPT_DIR/cct-doctor.sh" || true

echo ""
echo -e "${BOLD}Quick start:${RESET}"
if [[ -z "${TMUX:-}" ]]; then
    echo -e "  ${DIM}1.${RESET} tmux new -s dev"
    echo -e "  ${DIM}2.${RESET} shipwright session my-feature --template feature-dev"
else
    echo -e "  ${DIM}1.${RESET} shipwright session my-feature --template feature-dev"
fi
echo ""

# ─── Deploy setup (--deploy) ─────────────────────────────────────────────────
[[ "$DEPLOY_SETUP" == "false" ]] && exit 0

echo -e "${CYAN}${BOLD}Deploy Setup${RESET}"
echo -e "${DIM}══════════════════════════════════════════${RESET}"
echo ""

# Platform detection
detect_deploy_platform() {
    local detected=""

    for adapter_file in "$ADAPTERS_DIR"/*-deploy.sh; do
        [[ -f "$adapter_file" ]] || continue
        # Source the adapter in a subshell to get detection
        if ( source "$adapter_file" && detect_platform ); then
            local name
            name=$(basename "$adapter_file" | sed 's/-deploy\.sh$//')
            if [[ -n "$detected" ]]; then
                detected="$detected $name"
            else
                detected="$name"
            fi
        fi
    done

    echo "$detected"
}

if [[ -n "$DEPLOY_PLATFORM" ]]; then
    # User specified --platform, validate it
    if [[ ! -f "$ADAPTERS_DIR/${DEPLOY_PLATFORM}-deploy.sh" ]]; then
        error "Unknown platform: $DEPLOY_PLATFORM"
        echo -e "  Available: vercel, fly, railway, docker"
        exit 1
    fi
    info "Using specified platform: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
else
    info "Detecting deploy platform..."
    detected=$(detect_deploy_platform)

    if [[ -z "$detected" ]]; then
        warn "No platform detected in current directory"
        echo ""
        echo -e "  Supported platforms:"
        echo -e "    ${CYAN}vercel${RESET}   — vercel.json or .vercel/"
        echo -e "    ${CYAN}fly${RESET}      — fly.toml"
        echo -e "    ${CYAN}railway${RESET}  — railway.toml or .railway/"
        echo -e "    ${CYAN}docker${RESET}   — Dockerfile or docker-compose.yml"
        echo ""
        echo -e "  Specify manually: ${DIM}shipwright init --deploy --platform vercel${RESET}"
        exit 1
    fi

    # If multiple platforms detected, use the first and warn
    platform_count=$(echo "$detected" | wc -w | tr -d ' ')
    DEPLOY_PLATFORM=$(echo "$detected" | awk '{print $1}')

    if [[ "$platform_count" -gt 1 ]]; then
        warn "Multiple platforms detected: ${BOLD}${detected}${RESET}"
        info "Using: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
        echo -e "  ${DIM}Override with: shipwright init --deploy --platform <name>${RESET}"
        echo ""
    else
        success "Detected platform: ${BOLD}${DEPLOY_PLATFORM}${RESET}"
    fi

    # Confirm with user
    read -rp "$(echo -e "${CYAN}${BOLD}▸${RESET} Configure deploy for ${BOLD}${DEPLOY_PLATFORM}${RESET}? [Y/n] ")" confirm
    if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "n" ]]; then
        info "Aborted. Use --platform to specify manually."
        exit 0
    fi
fi

# Source the adapter to get command values
ADAPTER_FILE="$ADAPTERS_DIR/${DEPLOY_PLATFORM}-deploy.sh"
source "$ADAPTER_FILE"

staging_cmd=$(get_staging_cmd)
production_cmd=$(get_production_cmd)
rollback_cmd=$(get_rollback_cmd)
health_url=$(get_health_url)
smoke_cmd=$(get_smoke_cmd)

# Generate deployed.json from template
TEMPLATE_SRC="$REPO_DIR/templates/pipelines/deployed.json"
TEMPLATE_DST=".claude/pipeline-templates/deployed.json"

if [[ ! -f "$TEMPLATE_SRC" ]]; then
    error "Template not found: $TEMPLATE_SRC"
    exit 1
fi

mkdir -p ".claude/pipeline-templates"

# Use jq to properly fill in the template values
jq --arg staging "$staging_cmd" \
   --arg production "$production_cmd" \
   --arg rollback "$rollback_cmd" \
   --arg health "$health_url" \
   --arg smoke "$smoke_cmd" \
   --arg platform "$DEPLOY_PLATFORM" \
   '
   .name = "deployed-" + $platform |
   .description = "Autonomous pipeline with " + $platform + " deploy — generated by shipwright init --deploy" |
   (.stages[] | select(.id == "deploy") | .config) |= {
       staging_cmd: $staging,
       production_cmd: $production,
       rollback_cmd: $rollback
   } |
   (.stages[] | select(.id == "validate") | .config) |= {
       smoke_cmd: $smoke,
       health_url: $health,
       close_issue: true
   } |
   (.stages[] | select(.id == "monitor") | .config) |= (
       .health_url = $health |
       .rollback_cmd = $rollback
   )
   ' "$TEMPLATE_SRC" > "$TEMPLATE_DST"

success "Generated ${BOLD}${TEMPLATE_DST}${RESET}"

echo ""
echo -e "${BOLD}Deploy configured for ${DEPLOY_PLATFORM}!${RESET}"
echo ""
echo -e "${BOLD}Commands configured:${RESET}"
echo -e "  ${DIM}staging:${RESET}    $staging_cmd"
echo -e "  ${DIM}production:${RESET} $production_cmd"
echo -e "  ${DIM}rollback:${RESET}   $rollback_cmd"
if [[ -n "$health_url" ]]; then
    echo -e "  ${DIM}health:${RESET}     $health_url"
fi
echo ""
echo -e "${BOLD}Usage:${RESET}"
echo -e "  ${DIM}shipwright pipeline start --issue 42 --template .claude/pipeline-templates/deployed.json${RESET}"
echo ""
echo -e "${DIM}Edit ${TEMPLATE_DST} to customize deploy commands, gates, or thresholds.${RESET}"
echo ""
