#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-widgets.sh — Embeddable Status Widgets                               ║
# ║                                                                          ║
# ║  Generate badges, Slack messages, markdown blocks, and JSON exports      ║
# ║  for embedding Shipwright status in external dashboards and README       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
_COMPAT="$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/compat.sh
[[ -f "$_COMPAT" ]] && source "$_COMPAT"

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

# ─── Configuration ─────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.shipwright"
CONFIG_FILE="${CONFIG_DIR}/widgets-config.json"
EVENTS_FILE="${CONFIG_DIR}/events.jsonl"
PIPELINE_STATE="${REPO_DIR}/.claude/pipeline-state.md"
COSTS_FILE="${CONFIG_DIR}/costs.json"

# ─── Helpers ───────────────────────────────────────────────────────────────

# Safely extract numeric values
_safe_num() {
    local val="${1:-0}"
    if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        echo "$val"
    else
        echo "0"
    fi
}

# Safely extract string values from JSON
_safe_str() {
    local val="${1:-unknown}"
    echo "$val" | sed 's/"/\\"/g'
}

# Get current pipeline status
_get_pipeline_status() {
    if [[ ! -f "$PIPELINE_STATE" ]]; then
        echo "unknown"
        return
    fi

    # Try to extract status from pipeline state markdown
    if grep -qi "status.*passing" "$PIPELINE_STATE" 2>/dev/null; then
        echo "passing"
    elif grep -qi "status.*failing" "$PIPELINE_STATE" 2>/dev/null; then
        echo "failing"
    elif grep -qi "status.*running" "$PIPELINE_STATE" 2>/dev/null; then
        echo "running"
    else
        echo "unknown"
    fi
}

# Get test pass rate
_get_test_stats() {
    if [[ ! -f "$EVENTS_FILE" ]]; then
        echo "0"
        return
    fi

    # Count test-related events
    local pass_count
    pass_count=$(grep -i "test.*passed" "$EVENTS_FILE" 2>/dev/null | wc -l || echo "0")
    pass_count=$(_safe_num "$pass_count")

    echo "$pass_count"
}

# Get current version
_get_version() {
    if [[ -f "$REPO_DIR/package.json" ]]; then
        jq -r '.version // "unknown"' "$REPO_DIR/package.json" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get health score (0-100)
_get_health_score() {
    if [[ ! -f "$EVENTS_FILE" ]]; then
        echo "50"
        return
    fi

    # Simple health calculation: recent successful stages vs failed
    local recent_events
    recent_events=$(tail -n 100 "$EVENTS_FILE" 2>/dev/null || true)

    local success_count
    success_count=$(echo "$recent_events" | grep -i "stage.*completed" | wc -l || echo "0")
    success_count=$(_safe_num "$success_count")

    local fail_count
    fail_count=$(echo "$recent_events" | grep -i "stage.*failed" | wc -l || echo "0")
    fail_count=$(_safe_num "$fail_count")

    local total=$((success_count + fail_count))
    if [[ $total -eq 0 ]]; then
        echo "50"
    else
        awk "BEGIN {printf \"%.0f\", ($success_count / $total) * 100}"
    fi
}

# ─── Badge Generation (shields.io) ─────────────────────────────────────────

badge_pipeline() {
    local status
    status=$(_get_pipeline_status)

    local color
    case "$status" in
        passing) color="brightgreen" ;;
        failing) color="red" ;;
        running) color="blue" ;;
        *) color="lightgrey" ;;
    esac

    echo "https://img.shields.io/badge/pipeline-${status}-${color}"
}

badge_tests() {
    local count
    count=$(_get_test_stats)

    echo "https://img.shields.io/badge/tests-${count}%2B%20passing-brightgreen"
}

badge_version() {
    local version
    version=$(_get_version)

    # URL-encode dots as %2E
    version="${version//./%2E}"
    echo "https://img.shields.io/badge/version-v${version}-blue"
}

badge_health() {
    local score
    score=$(_get_health_score)

    local color
    if [[ $score -ge 80 ]]; then
        color="brightgreen"
    elif [[ $score -ge 60 ]]; then
        color="yellow"
    else
        color="red"
    fi

    echo "https://img.shields.io/badge/health-${score}%25-${color}"
}

# ─── Command: badge ──────────────────────────────────────────────────────────

cmd_badge() {
    local type="${1:-pipeline}"

    case "$type" in
        pipeline)
            badge_pipeline
            ;;
        tests)
            badge_tests
            ;;
        version)
            badge_version
            ;;
        health)
            badge_health
            ;;
        all)
            echo "Pipeline:  $(badge_pipeline)"
            echo "Tests:     $(badge_tests)"
            echo "Version:   $(badge_version)"
            echo "Health:    $(badge_health)"
            ;;
        *)
            error "Unknown badge type: $type"
            echo "  Valid: pipeline, tests, version, health, all"
            exit 1
            ;;
    esac
}

# ─── Command: slack ───────────────────────────────────────────────────────────

cmd_slack() {
    local webhook_url=""
    local channel=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --webhook)
                webhook_url="$2"
                shift 2
                ;;
            --channel)
                channel="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Try to load webhook from config if not provided
    if [[ -z "$webhook_url" ]] && [[ -f "$CONFIG_FILE" ]]; then
        webhook_url=$(jq -r '.slack.webhook_url // empty' "$CONFIG_FILE" 2>/dev/null || true)
    fi

    if [[ -z "$webhook_url" ]]; then
        error "No webhook URL provided. Use --webhook or configure in $CONFIG_FILE"
        exit 1
    fi

    # Gather status data
    local status
    status=$(_get_pipeline_status)
    local tests
    tests=$(_get_test_stats)
    local health
    health=$(_get_health_score)

    # Determine color based on status
    local color
    case "$status" in
        passing) color="#4ade80" ;;
        failing) color="#f87171" ;;
        running) color="#60a5fa" ;;
        *) color="#9ca3af" ;;
    esac

    # Build Slack message
    local message_json
    message_json=$(jq -n \
        --arg channel "$channel" \
        --arg status "$status" \
        --arg tests "$tests" \
        --arg health "$health" \
        --arg color "$color" \
        '{
            channel: $channel,
            attachments: [
                {
                    color: $color,
                    title: "Shipwright Pipeline Status",
                    fields: [
                        {title: "Status", value: $status, short: true},
                        {title: "Tests Passing", value: $tests, short: true},
                        {title: "Health Score", value: ($health + "%"), short: true},
                        {title: "Updated", value: "'$(now_iso)'", short: true}
                    ],
                    footer: "Shipwright Status Widget",
                    ts: '$(date +%s)'
                }
            ]
        }' | sed 's/"channel":""/"channel": null/' \
    )

    # Send to webhook
    if command -v curl &>/dev/null; then
        response=$(curl -s -X POST "$webhook_url" \
            -H 'Content-Type: application/json' \
            -d "$message_json" 2>&1)

        if echo "$response" | grep -qi "ok"; then
            success "Slack message sent"
        else
            warn "Slack response: $response"
        fi
    else
        error "curl is required for Slack integration"
        exit 1
    fi
}

# ─── Command: markdown ──────────────────────────────────────────────────────

cmd_markdown() {
    local pipeline_badge
    local tests_badge
    local version_badge
    local health_badge

    pipeline_badge=$(badge_pipeline)
    tests_badge=$(badge_tests)
    version_badge=$(badge_version)
    health_badge=$(badge_health)

    cat <<EOF
<!-- Shipwright Status Widgets -->

## Status Badges

[![Pipeline](${pipeline_badge})](./PIPELINE.md)
[![Tests](${tests_badge})](./TEST_RESULTS.md)
[![Version](${version_badge})](./CHANGELOG.md)
[![Health](${health_badge})](./HEALTH.md)

### Pipeline Status
- **Current Status**: $(_get_pipeline_status)
- **Tests Passing**: $(_get_test_stats)+
- **Health Score**: $(_get_health_score)%
- **Last Updated**: $(now_iso)

### Getting Started
To add these badges to your README.md:

\`\`\`markdown
[![Pipeline](${pipeline_badge})](./PIPELINE.md)
[![Tests](${tests_badge})](./TEST_RESULTS.md)
[![Version](${version_badge})](./CHANGELOG.md)
[![Health](${health_badge})](./HEALTH.md)
\`\`\`

---
Generated by [Shipwright]($(_sw_github_url))
EOF
}

# ─── Command: json ──────────────────────────────────────────────────────────

cmd_json() {
    local pipeline_status
    local test_stats
    local health_score
    local version

    pipeline_status=$(_get_pipeline_status)
    test_stats=$(_get_test_stats)
    health_score=$(_get_health_score)
    version=$(_get_version)

    # Extract last deploy time from events if available
    local last_deploy="unknown"
    if [[ -f "$EVENTS_FILE" ]]; then
        last_deploy=$(grep -i "deploy.*completed" "$EVENTS_FILE" | tail -1 | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")
    fi

    # Build JSON status
    jq -n \
        --arg timestamp "$(now_iso)" \
        --arg status "$pipeline_status" \
        --arg tests "$test_stats" \
        --argjson health "$health_score" \
        --arg version "$version" \
        --arg last_deploy "$last_deploy" \
        --arg pipeline_badge "$(badge_pipeline)" \
        --arg tests_badge "$(badge_tests)" \
        --arg version_badge "$(badge_version)" \
        --arg health_badge "$(badge_health)" \
        '{
            timestamp: $timestamp,
            pipeline: {
                status: $status,
                tests_passing: ($tests | tonumber),
                health_score: $health,
                last_deploy: $last_deploy
            },
            version: $version,
            badges: {
                pipeline: $pipeline_badge,
                tests: $tests_badge,
                version: $version_badge,
                health: $health_badge
            }
        }'
}

# ─── Command: notify ──────────────────────────────────────────────────────────

cmd_notify() {
    local notify_on="${1:-always}"
    local status
    status=$(_get_pipeline_status)

    case "$notify_on" in
        success)
            if [[ "$status" == "passing" ]]; then
                success "Pipeline is passing!"
            fi
            ;;
        failure)
            if [[ "$status" == "failing" ]]; then
                error "Pipeline is failing!"
                exit 1
            fi
            ;;
        always)
            info "Pipeline status: $status"
            ;;
        *)
            error "Unknown notify type: $notify_on"
            exit 1
            ;;
    esac
}

# ─── Command: help ───────────────────────────────────────────────────────────

cmd_help() {
    cat <<EOF
${CYAN}${BOLD}shipwright widgets${RESET} — Embeddable Status Widgets

${BOLD}USAGE${RESET}
  shipwright widgets <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}badge${RESET} [type]              Generate shields.io badge URLs
                            Types: pipeline, tests, version, health, all
  ${CYAN}slack${RESET} [options]            Send pipeline status to Slack
                            --webhook URL  Slack webhook URL
                            --channel #ch  (optional) channel override
  ${CYAN}markdown${RESET}                    Generate markdown status block for README
  ${CYAN}json${RESET}                        Export current status as JSON
  ${CYAN}notify${RESET} [type]              Send notifications based on status
                            Types: success, failure, always
  ${CYAN}help${RESET}                       Show this help message

${BOLD}EXAMPLES${RESET}
  # Generate pipeline badge URL
  shipwright widgets badge pipeline

  # Get all badges
  shipwright widgets badge all

  # Send Slack notification
  shipwright widgets slack --webhook https://hooks.slack.com/... --channel #ops

  # Generate markdown block for README
  shipwright widgets markdown > STATUS.md

  # Get JSON status for dashboards
  shipwright widgets json | jq

  # Notify if pipeline is passing
  shipwright widgets notify success

${BOLD}CONFIGURATION${RESET}
  Slack webhooks can be stored in: ${CONFIG_FILE}

  Example:
  {
    "slack": {
      "webhook_url": "https://hooks.slack.com/services/..."
    }
  }

${BOLD}INTEGRATION${RESET}
  Use in CI/CD pipelines:
    - GitHub Actions: Add badge URLs to job summaries
    - README.md: Embed markdown status block
    - External dashboards: Query JSON endpoint
    - Slack: Post status updates on workflow completion

EOF
}

# ─── Main ──────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        badge)
            cmd_badge "$@"
            ;;
        slack)
            cmd_slack "$@"
            ;;
        markdown)
            cmd_markdown "$@"
            ;;
        json)
            cmd_json "$@"
            ;;
        notify)
            cmd_notify "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        version|--version|-v)
            echo "Shipwright widgets v${VERSION}"
            ;;
        *)
            error "Unknown command: $cmd"
            echo "  Try: shipwright widgets help"
            exit 1
            ;;
    esac
}

# ─── Guard: allow sourcing ────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
