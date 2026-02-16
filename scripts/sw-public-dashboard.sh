#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright public-dashboard — Public real-time pipeline progress          ║
# ║  Shareable URLs · Self-contained HTML · Privacy controls                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.2"
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

# ─── Paths ──────────────────────────────────────────────────────────────────
PUB_DASH_DIR="${HOME}/.shipwright/public-dashboard"
SHARE_LINKS_FILE="${PUB_DASH_DIR}/share-links.json"
SHARE_CONFIG_FILE="${PUB_DASH_DIR}/config.json"

# ─── Initialization ──────────────────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "$PUB_DASH_DIR"
    [[ -f "$SHARE_LINKS_FILE" ]] || echo '{"links":[]}' > "$SHARE_LINKS_FILE"
    [[ -f "$SHARE_CONFIG_FILE" ]] || echo '{"privacy":"stages_only","expiry_hours":24,"custom_domain":"","branding":""}' > "$SHARE_CONFIG_FILE"
}

# ─── Sanitize Functions ──────────────────────────────────────────────────────
sanitize_for_privacy() {
    local input="$1"
    local privacy_level="${2:-stages_only}"

    case "$privacy_level" in
        public)
            # Full details
            echo "$input"
            ;;
        anonymized)
            # Hide paths and tokens
            echo "$input" | sed -E \
                -e 's|/Users/[^/]+|/home/user|g' \
                -e 's/(ghp_|sk_live_)[A-Za-z0-9_-]+/[REDACTED_TOKEN]/g' \
                -e 's/(CLAUDECODE|GITHUB_TOKEN)=[^ ]*/[REDACTED_ENV]/g' \
                -e 's/@[^ ]*\.com/@redacted.com/g'
            ;;
        stages_only)
            # Only stage names and status
            echo "$input" | sed -E \
                -e 's|"description":"[^"]*"|"description":""|g' \
                -e 's|"logs":"[^"]*"|"logs":""|g' \
                -e 's|"output":"[^"]*"|"output":""|g' \
                -e 's|/Users/[^/]+|/home/user|g'
            ;;
    esac
}

# ─── Gather Current Pipeline State ──────────────────────────────────────────
gather_pipeline_state() {
    local privacy="${1:-stages_only}"

    local state_file="${REPO_DIR}/.claude/pipeline-state.md"
    local daemon_state="${HOME}/.shipwright/daemon-state.json"
    local pipeline_artifacts="${REPO_DIR}/.claude/pipeline-artifacts"

    local pipeline_data='{
        "status":"unknown",
        "stages":[],
        "agents":[],
        "events":[],
        "updated_at":"'"$(now_iso)"'"
    }'

    # Read daemon state
    if [[ -f "$daemon_state" ]]; then
        local active_jobs queued_count
        active_jobs=$(jq -c '.active_jobs // []' "$daemon_state" 2>/dev/null || echo "[]")
        queued_count=$(jq 'length' <<<"$active_jobs" 2>/dev/null || echo "0")

        if [[ "$queued_count" -gt 0 ]]; then
            pipeline_data=$(jq --argjson jobs "$active_jobs" '.agents = $jobs' <<<"$pipeline_data")
        fi
    fi

    # Read recent events (last 50)
    if [[ -f "$EVENTS_FILE" ]]; then
        local events
        events=$(tail -50 "$EVENTS_FILE" | jq -c -s '.' 2>/dev/null || echo "[]")
        pipeline_data=$(jq --argjson events "$events" '.events = $events' <<<"$pipeline_data")
    fi

    # Read pipeline artifacts if available
    if [[ -d "$pipeline_artifacts" ]]; then
        local stage_count
        stage_count=$(find "$pipeline_artifacts" -name "*.md" -o -name "*.json" | wc -l || echo "0")
        pipeline_data=$(jq --arg count "$stage_count" '.artifact_count = $count' <<<"$pipeline_data")
    fi

    # Sanitize based on privacy level
    sanitize_for_privacy "$pipeline_data" "$privacy"
}

# ─── Generate Token ─────────────────────────────────────────────────────────
generate_token() {
    # Create a read-only token (32 hex chars)
    if command -v openssl &>/dev/null; then
        openssl rand -hex 16
    else
        # Fallback to simple pseudo-random
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' '
    fi
}

# ─── Generate Self-Contained HTML ──────────────────────────────────────────
generate_html() {
    local data_json="$1"
    local title="${2:-Shipwright Pipeline Progress}"
    local privacy="${3:-stages_only}"

    # Escape JSON for embedding in HTML
    local json_escaped
    json_escaped=$(echo "$data_json" | sed 's/"/\\"/g' | tr '\n' ' ')

    cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>TITLE_PLACEHOLDER</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #0a1428 0%, #1a2332 100%);
            color: #e0e0e0;
            padding: 20px;
            min-height: 100vh;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 30px;
            padding-bottom: 20px;
            border-bottom: 2px solid #00d4ff;
        }
        h1 { color: #00d4ff; font-size: 28px; }
        .meta {
            font-size: 12px;
            color: #7c3aed;
            display: flex;
            gap: 20px;
        }
        .meta-item { display: flex; flex-direction: column; }
        .meta-label { color: #999; text-transform: uppercase; }
        .meta-value { color: #00d4ff; font-weight: bold; }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .card {
            background: rgba(30, 30, 40, 0.8);
            border: 1px solid #333;
            border-radius: 8px;
            padding: 20px;
            backdrop-filter: blur(10px);
            transition: all 0.3s ease;
        }
        .card:hover { border-color: #00d4ff; box-shadow: 0 0 20px rgba(0, 212, 255, 0.2); }
        .card-title {
            color: #00d4ff;
            font-size: 14px;
            font-weight: bold;
            text-transform: uppercase;
            margin-bottom: 15px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: bold;
        }
        .badge-success { background: rgba(74, 222, 128, 0.2); color: #4ade80; }
        .badge-warning { background: rgba(250, 204, 21, 0.2); color: #f8cc15; }
        .badge-error { background: rgba(248, 113, 113, 0.2); color: #f87171; }
        .badge-info { background: rgba(0, 212, 255, 0.2); color: #00d4ff; }
        .progress-bar {
            width: 100%;
            height: 6px;
            background: #222;
            border-radius: 3px;
            overflow: hidden;
            margin-bottom: 10px;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #00d4ff, #7c3aed);
            width: 0%;
            transition: width 0.3s ease;
        }
        .list-item {
            padding: 10px 0;
            border-bottom: 1px solid #222;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 13px;
        }
        .list-item:last-child { border-bottom: none; }
        .timestamp {
            color: #666;
            font-size: 11px;
            font-family: 'Monaco', 'Courier New', monospace;
        }
        .footer {
            text-align: center;
            padding: 20px;
            color: #666;
            font-size: 12px;
            border-top: 1px solid #333;
        }
        .footer a { color: #00d4ff; text-decoration: none; }
        .footer a:hover { text-decoration: underline; }
        @media (prefers-reduced-motion: reduce) {
            * { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div>
                <h1>⚓ TITLE_PLACEHOLDER</h1>
            </div>
            <div class="meta">
                <div class="meta-item">
                    <span class="meta-label">Updated</span>
                    <span class="meta-value" id="updated-time">—</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Privacy</span>
                    <span class="meta-value">PRIVACY_PLACEHOLDER</span>
                </div>
            </div>
        </header>

        <div class="grid" id="dashboard">
            <div class="card">
                <div class="card-title">📊 Pipeline Status</div>
                <div id="pipeline-status">
                    <div class="list-item">
                        <span>Overall</span>
                        <span class="badge badge-info" id="overall-status">Loading...</span>
                    </div>
                    <div class="list-item">
                        <span>Active Agents</span>
                        <span id="agent-count">—</span>
                    </div>
                    <div class="list-item">
                        <span>Completed Events</span>
                        <span id="event-count">—</span>
                    </div>
                </div>
            </div>

            <div class="card">
                <div class="card-title">⚙️ Artifacts</div>
                <div id="artifacts-info">
                    <div class="list-item">
                        <span>Stage Files</span>
                        <span id="artifact-count">—</span>
                    </div>
                    <div style="padding: 10px 0; font-size: 12px; color: #999;">
                        Stage outputs and checkpoints available in pipeline artifacts
                    </div>
                </div>
            </div>

            <div class="card">
                <div class="card-title">📝 Recent Events</div>
                <div id="events-list" style="max-height: 300px; overflow-y: auto;">
                    <div style="color: #666; font-size: 12px;">Loading events...</div>
                </div>
            </div>
        </div>

        <div class="footer">
            <p>Generated by <a href="https://github.com/sethdford/shipwright">Shipwright</a> v1.13.0</p>
            <p style="margin-top: 8px; color: #555;">Dashboard auto-refreshes every 30s when served from dashboard server</p>
            <p style="margin-top: 8px;" id="footer-timestamp">Generated: —</p>
        </div>
    </div>

    <script>
        const pipelineData = {DATA_PLACEHOLDER};

        function formatTime(isoString) {
            if (!isoString) return '—';
            const date = new Date(isoString);
            return date.toLocaleTimeString();
        }

        function renderDashboard() {
            if (!pipelineData) return;

            document.getElementById('updated-time').textContent = formatTime(pipelineData.updated_at);
            document.getElementById('footer-timestamp').textContent = 'Generated: ' + new Date().toLocaleString();

            // Pipeline status
            const agents = pipelineData.agents || [];
            document.getElementById('agent-count').textContent = agents.length + ' running';

            const events = pipelineData.events || [];
            document.getElementById('event-count').textContent = events.length + ' total';

            const artifactCount = pipelineData.artifact_count || 0;
            document.getElementById('artifact-count').textContent = artifactCount + ' files';

            // Render events
            const eventsList = document.getElementById('events-list');
            if (events.length === 0) {
                eventsList.innerHTML = '<div style="color: #666; font-size: 12px;">No events recorded</div>';
            } else {
                eventsList.innerHTML = events
                    .slice(-10)
                    .reverse()
                    .map(e => {
                        const eventType = (e.type || 'unknown').toUpperCase();
                        const time = formatTime(e.ts);
                        return '<div class="list-item"><span>' + eventType + '</span><span class="timestamp">' + time + '</span></div>';
                    })
                    .join('');
            }
        }

        // Render on page load
        document.addEventListener('DOMContentLoaded', renderDashboard);

        // Auto-refresh every 30 seconds if this is served from a server
        if (window.location.protocol.startsWith('http')) {
            setInterval(function() {
                fetch(window.location.href)
                    .then(r => r.text())
                    .then(html => {
                        const parser = new DOMParser();
                        const newDoc = parser.parseFromString(html, 'text/html');
                        const newScript = newDoc.querySelector('script');
                        if (newScript) {
                            eval(newScript.textContent);
                            renderDashboard();
                        }
                    })
                    .catch(e => console.log('Auto-refresh failed:', e));
            }, 30000);
        }
    </script>
</body>
</html>
EOF
}

# ─── Export Command ─────────────────────────────────────────────────────────
cmd_export() {
    local output_file="${1:-${PUB_DASH_DIR}/dashboard.html}"
    local title="${2:-Shipwright Pipeline Progress}"
    local privacy="${3:-stages_only}"

    ensure_dirs

    info "Gathering pipeline state (privacy: $privacy)..."
    local state_data
    state_data=$(gather_pipeline_state "$privacy")

    info "Generating HTML export..."
    local html
    html=$(generate_html "$state_data" "$title" "$privacy")

    # Replace placeholders
    html="${html//TITLE_PLACEHOLDER/$title}"
    html="${html//PRIVACY_PLACEHOLDER/$privacy}"
    html="${html//\{DATA_PLACEHOLDER\}/$state_data}"

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" EXIT
    echo "$html" > "$tmp_file"
    mv "$tmp_file" "$output_file"

    emit_event "public_dashboard_export" "privacy=$privacy" "path=$output_file"

    success "Dashboard exported to: $output_file"
    echo "  Size: $(du -h "$output_file" | cut -f1)"
    echo "  Privacy: $privacy"
}

# ─── Share Command ──────────────────────────────────────────────────────────
cmd_share() {
    local expiry_hours="${1:-24}"
    local privacy="${2:-stages_only}"

    ensure_dirs

    info "Creating share link (expires in ${expiry_hours}h)..."
    local token
    token=$(generate_token)
    local expires_at
    expires_at=$(($(now_epoch) + expiry_hours * 3600))

    local link_entry
    link_entry=$(jq -n \
        --arg token "$token" \
        --arg privacy "$privacy" \
        --arg created "$(now_iso)" \
        --arg expires "$(date -u -d "@$expires_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v +${expiry_hours}H +%Y-%m-%dT%H:%M:%SZ)" \
        '{token:$token, privacy:$privacy, created:$created, expires:$expires, view_count:0, last_viewed:null}')

    # Append to share links file (atomic)
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" EXIT
    jq ".links += [$link_entry]" "$SHARE_LINKS_FILE" > "$tmp_file"
    mv "$tmp_file" "$SHARE_LINKS_FILE"

    emit_event "public_dashboard_share" "token=$token" "privacy=$privacy" "expires_hours=$expiry_hours"

    success "Share link created!"
    echo "  Token: $token"
    echo "  Privacy: $privacy"
    echo "  Expires: $(date -u -d "@$expires_at" +%Y-%m-%d\ %H:%M:%S 2>/dev/null || date -u -v +${expiry_hours}H +%Y-%m-%d\ %H:%M:%S)"
    echo ""
    echo "  Share URL: https://your-domain.com/public-dashboard/$token"
    echo "  or embed:  <iframe src=\"https://your-domain.com/public-dashboard/$token\"></iframe>"
}

# ─── Revoke Command ─────────────────────────────────────────────────────────
cmd_revoke() {
    local token="$1"

    [[ -z "$token" ]] && error "Token required" && return 1

    ensure_dirs

    info "Revoking share link: $token"

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" EXIT

    if jq ".links |= map(select(.token != \"$token\"))" "$SHARE_LINKS_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$SHARE_LINKS_FILE"
        emit_event "public_dashboard_revoke" "token=$token"
        success "Share link revoked"
    else
        error "Failed to revoke link"
        return 1
    fi
}

# ─── List Command ───────────────────────────────────────────────────────────
cmd_list() {
    ensure_dirs

    local now_epoch_val
    now_epoch_val=$(now_epoch)

    info "Active share links:"
    echo ""

    if ! jq empty "$SHARE_LINKS_FILE" 2>/dev/null; then
        warn "No share links found"
        return 0
    fi

    local active_count=0
    jq -r '.links[] |
        if (.expires | fromdateiso8601) > '$now_epoch_val' then
            .token + "|" + .privacy + "|" + .expires + "|" + (.view_count | tostring)
        else
            empty
        end' "$SHARE_LINKS_FILE" | while IFS='|' read -r token privacy expires views; do
        active_count=$((active_count + 1))
        printf "  %s... | Privacy: %-12s | Expires: %s | Views: %s\n" "${token:0:8}" "$privacy" "$expires" "$views"
    done

    local expired_count
    expired_count=$(jq "[.links[] | select((.expires | fromdateiso8601) <= $now_epoch_val)] | length" "$SHARE_LINKS_FILE" 2>/dev/null || echo "0")

    if [[ "$expired_count" -gt 0 ]]; then
        echo ""
        warn "$expired_count expired link(s) — run 'shipwright public-dashboard cleanup' to remove"
    fi
}

# ─── Config Command ─────────────────────────────────────────────────────────
cmd_config() {
    local key="${1:-}"
    local value="${2:-}"

    ensure_dirs

    if [[ -z "$key" ]]; then
        info "Current config:"
        jq '.' "$SHARE_CONFIG_FILE"
        return 0
    fi

    case "$key" in
        privacy)
            [[ -z "$value" ]] && error "Value required for privacy" && return 1
            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" EXIT
            jq ".privacy = \"$value\"" "$SHARE_CONFIG_FILE" > "$tmp_file"
            mv "$tmp_file" "$SHARE_CONFIG_FILE"
            success "Privacy set to: $value"
            ;;
        expiry)
            [[ -z "$value" ]] && error "Value required for expiry (hours)" && return 1
            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" EXIT
            jq ".expiry_hours = $value" "$SHARE_CONFIG_FILE" > "$tmp_file"
            mv "$tmp_file" "$SHARE_CONFIG_FILE"
            success "Default expiry set to: ${value}h"
            ;;
        domain)
            [[ -z "$value" ]] && error "Value required for domain" && return 1
            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" EXIT
            jq ".custom_domain = \"$value\"" "$SHARE_CONFIG_FILE" > "$tmp_file"
            mv "$tmp_file" "$SHARE_CONFIG_FILE"
            success "Custom domain set to: $value"
            ;;
        *)
            error "Unknown config key: $key"
            return 1
            ;;
    esac
}

# ─── Embed Command ──────────────────────────────────────────────────────────
cmd_embed() {
    local token="$1"
    local format="${2:-iframe}"

    [[ -z "$token" ]] && error "Token required" && return 1

    ensure_dirs

    local domain
    domain=$(jq -r '.custom_domain // "your-domain.com"' "$SHARE_CONFIG_FILE")
    local url="https://${domain}/public-dashboard/${token}"

    case "$format" in
        iframe)
            cat <<EOF
<!-- Shipwright Public Dashboard Embed -->
<iframe
  src="$url"
  style="width: 100%; height: 600px; border: 1px solid #ddd; border-radius: 8px;"
  title="Pipeline Progress"
  sandbox="allow-same-origin"
></iframe>
EOF
            ;;
        badge)
            cat <<EOF
<!-- Shipwright Public Dashboard Badge -->
<a href="$url" style="display: inline-block;">
  <img
    alt="Pipeline Status"
    src="$url/badge"
    style="max-width: 200px;"
  />
</a>
EOF
            ;;
        markdown)
            cat <<EOF
<!-- Shipwright Public Dashboard -->
[![Pipeline Status]($url/badge)]($url)

[View Full Dashboard]($url)
EOF
            ;;
        link)
            echo "$url"
            ;;
        *)
            error "Unknown format: $format (iframe, badge, markdown, link)"
            return 1
            ;;
    esac
}

# ─── Cleanup Command ────────────────────────────────────────────────────────
cmd_cleanup() {
    ensure_dirs

    local now_epoch_val
    now_epoch_val=$(now_epoch)

    local before_count after_count
    before_count=$(jq '.links | length' "$SHARE_LINKS_FILE" 2>/dev/null || echo "0")

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" EXIT

    jq ".links |= map(select((.expires | fromdateiso8601) > $now_epoch_val))" "$SHARE_LINKS_FILE" > "$tmp_file"
    mv "$tmp_file" "$SHARE_LINKS_FILE"

    after_count=$(jq '.links | length' "$SHARE_LINKS_FILE" 2>/dev/null || echo "0")
    local removed=$((before_count - after_count))

    if [[ "$removed" -gt 0 ]]; then
        success "Cleaned up $removed expired link(s)"
    else
        info "No expired links to clean up"
    fi
}

# ─── Help ────────────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
${CYAN}${BOLD}shipwright public-dashboard${RESET} — Public real-time pipeline progress

${BOLD}USAGE${RESET}
  ${CYAN}shipwright public-dashboard${RESET} <command> [options]
  ${CYAN}shipwright share${RESET} [--expires 24h] [--privacy anonymized]

${BOLD}COMMANDS${RESET}
  ${CYAN}export${RESET} [file] [title] [privacy]
      Generate self-contained HTML dashboard file
      File: output path (default: ~/.shipwright/public-dashboard/dashboard.html)
      Title: page title (default: "Shipwright Pipeline Progress")
      Privacy: stages_only, anonymized, or public (default: stages_only)

  ${CYAN}share${RESET} [expiry_hours] [privacy_level]
      Create a shareable link for real-time dashboard
      Expiry: hours until link expires (default: 24)
      Privacy: stages_only, anonymized, or public

  ${CYAN}revoke${RESET} <token>
      Revoke a share link (invalidate the token)

  ${CYAN}list${RESET}
      List all active share links

  ${CYAN}config${RESET} [key] [value]
      View or modify dashboard configuration
      Keys: privacy, expiry, domain

  ${CYAN}embed${RESET} <token> [format]
      Generate embed code (iframe, badge, markdown, link)

  ${CYAN}cleanup${RESET}
      Remove expired share links

  ${CYAN}help${RESET}
      Show this help message

${BOLD}EXAMPLES${RESET}
  # Export static HTML
  ${DIM}shipwright public-dashboard export${RESET}
  ${DIM}shipwright public-dashboard export dashboard.html "My Pipeline"${RESET}

  # Create shareable link (requires dashboard server)
  ${DIM}shipwright public-dashboard share 48 anonymized${RESET}

  # Generate embed code for README
  ${DIM}shipwright public-dashboard embed abc123def456 markdown${RESET}

  # Configure default privacy level
  ${DIM}shipwright public-dashboard config privacy anonymized${RESET}
  ${DIM}shipwright public-dashboard config domain app.example.com${RESET}

${BOLD}PRIVACY LEVELS${RESET}
  ${CYAN}stages_only${RESET}
      Only stage names and generic status info (most private)

  ${CYAN}anonymized${RESET}
      Full details with paths and tokens redacted

  ${CYAN}public${RESET}
      All details including paths and environment (least private)

${BOLD}OUTPUT${RESET}
  Generated HTML files are completely self-contained:
  - No external resources (all CSS/JS embedded)
  - ~50 KB gzipped
  - Works offline
  - Safe to share

${BOLD}SHARE LINKS${RESET}
  Share links require a running dashboard server to serve the public endpoint.
  By default, requires dashboard to serve at: https://your-domain.com/public-dashboard/<token>

${DIM}Docs: https://sethdford.github.io/shipwright${RESET}
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        export)
            shift
            cmd_export "$@"
            ;;
        share)
            shift
            cmd_share "$@"
            ;;
        revoke)
            shift
            cmd_revoke "$@"
            ;;
        list)
            cmd_list
            ;;
        config)
            shift
            cmd_config "$@"
            ;;
        embed)
            shift
            cmd_embed "$@"
            ;;
        cleanup)
            cmd_cleanup
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
