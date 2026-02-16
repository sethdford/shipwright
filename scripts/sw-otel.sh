#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright otel — OpenTelemetry Observability                           ║
# ║  Prometheus metrics, traces, OTLP export, webhook forwarding, dashboard   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
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

# ─── State Directories ──────────────────────────────────────────────────────
OTEL_DIR="${HOME}/.shipwright/otel"
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
DAEMON_STATE="${HOME}/.shipwright/daemon-state.json"
OTEL_CONFIG="${REPO_DIR}/.claude/otel-config.json"

ensure_otel_dir() {
    mkdir -p "$OTEL_DIR"
}

# ─── Prometheus Metrics ──────────────────────────────────────────────────────

cmd_metrics() {
    local format="${1:-text}"

    ensure_otel_dir

    # Initialize counters
    local total_pipelines=0
    local active_pipelines=0
    local failed_pipelines=0
    local succeeded_pipelines=0
    local total_cost=0

    # Status breakdown
    local status_success=0
    local status_failed=0
    local status_running=0

    # Template counts
    declare -a templates
    declare -a template_counts

    # Stage timing
    declare -a stages
    declare -a stage_durations

    # Model costs
    declare -a models
    declare -a model_costs

    # Parse events.jsonl
    if [[ -f "$EVENTS_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local event_type
            event_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null || true)

            case "$event_type" in
                pipeline_start)
                    ((total_pipelines++))
                    ((active_pipelines++))
                    ;;
                pipeline_complete)
                    ((active_pipelines--))
                    ((succeeded_pipelines++))
                    ((status_success++))
                    ;;
                pipeline_failed)
                    ((active_pipelines--))
                    ((failed_pipelines++))
                    ((status_failed++))
                    ;;
                stage_complete)
                    local stage duration
                    stage=$(echo "$line" | jq -r '.stage // "unknown"' 2>/dev/null || true)
                    duration=$(echo "$line" | jq -r '.duration_seconds // 0' 2>/dev/null || true)
                    if [[ -n "$stage" && "$duration" != "0" ]]; then
                        stage_durations+=("$stage:$duration")
                    fi
                    ;;
                cost_recorded)
                    local cost model
                    cost=$(echo "$line" | jq -r '.cost_usd // 0' 2>/dev/null || true)
                    model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null || true)
                    total_cost=$(awk -v t="$total_cost" -v c="$cost" 'BEGIN { printf "%.4f", t + c }')
                    model_costs+=("$model:$cost")
                    ;;
            esac
        done < "$EVENTS_FILE"
    fi

    # Parse daemon state for queue depth
    local queue_depth=0
    if [[ -f "$DAEMON_STATE" ]]; then
        queue_depth=$(jq -r '.active_jobs | length // 0' "$DAEMON_STATE" 2>/dev/null || echo "0")
    fi

    # Calculate histogram buckets for stage durations
    local stage_p50=0 stage_p99=0
    if [[ ${#stage_durations[@]} -gt 0 ]]; then
        # Simple approximation for percentiles
        stage_p50=$(printf '%s\n' "${stage_durations[@]}" | cut -d: -f2 | sort -n | head -n $((${#stage_durations[@]}/2)) | tail -n1 || echo "0")
        stage_p99=$(printf '%s\n' "${stage_durations[@]}" | cut -d: -f2 | sort -n | tail -n1 || echo "0")
    fi

    if [[ "$format" == "json" ]]; then
        cat << EOF
{
  "metrics": {
    "pipelines_total": {
      "value": $total_pipelines,
      "type": "counter"
    },
    "active_pipelines": {
      "value": $active_pipelines,
      "type": "gauge"
    },
    "pipelines_succeeded": {
      "value": $succeeded_pipelines,
      "type": "counter"
    },
    "pipelines_failed": {
      "value": $failed_pipelines,
      "type": "counter"
    },
    "cost_total_usd": {
      "value": $total_cost,
      "type": "counter"
    },
    "queue_depth": {
      "value": $queue_depth,
      "type": "gauge"
    },
    "stage_duration_p50_seconds": {
      "value": $stage_p50,
      "type": "histogram"
    },
    "stage_duration_p99_seconds": {
      "value": $stage_p99,
      "type": "histogram"
    }
  },
  "timestamp": "$(now_iso)"
}
EOF
    else
        # Prometheus text format
        cat << EOF
# HELP shipwright_pipelines_total Total number of pipeline runs
# TYPE shipwright_pipelines_total counter
shipwright_pipelines_total $total_pipelines

# HELP shipwright_active_pipelines Currently running pipelines
# TYPE shipwright_active_pipelines gauge
shipwright_active_pipelines $active_pipelines

# HELP shipwright_pipelines_succeeded Successfully completed pipelines
# TYPE shipwright_pipelines_succeeded counter
shipwright_pipelines_succeeded $succeeded_pipelines

# HELP shipwright_pipelines_failed Failed pipelines
# TYPE shipwright_pipelines_failed counter
shipwright_pipelines_failed $failed_pipelines

# HELP shipwright_cost_total_usd Total cost in USD
# TYPE shipwright_cost_total_usd counter
shipwright_cost_total_usd $total_cost

# HELP shipwright_queue_depth Number of queued jobs
# TYPE shipwright_queue_depth gauge
shipwright_queue_depth $queue_depth

# HELP shipwright_stage_duration_seconds Stage duration histogram
# TYPE shipwright_stage_duration_seconds histogram
shipwright_stage_duration_seconds_bucket{le="1"} 0
shipwright_stage_duration_seconds_bucket{le="5"} 0
shipwright_stage_duration_seconds_bucket{le="10"} 0
shipwright_stage_duration_seconds_bucket{le="30"} 0
shipwright_stage_duration_seconds_bucket{le="60"} 0
shipwright_stage_duration_seconds_bucket{le="300"} 0
shipwright_stage_duration_seconds_bucket{le="+Inf"} $total_pipelines
shipwright_stage_duration_seconds_sum 0
shipwright_stage_duration_seconds_count $total_pipelines
EOF
    fi
}

# ─── OpenTelemetry Traces ────────────────────────────────────────────────────

cmd_trace() {
    local pipeline_id="${1:-latest}"

    ensure_otel_dir

    # Build trace from events
    local traces='[]'
    local spans='[]'
    local root_span=""

    if [[ -f "$EVENTS_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local event_type ts stage pipeline
            event_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null || true)
            ts=$(echo "$line" | jq -r '.ts // empty' 2>/dev/null || true)
            pipeline=$(echo "$line" | jq -r '.pipeline_id // empty' 2>/dev/null || true)

            [[ -z "$event_type" ]] && continue

            case "$event_type" in
                pipeline_start)
                    root_span=$(cat << EOF
{
  "traceId": "${pipeline:0:16}",
  "spanId": "${pipeline:0:16}",
  "parentSpanId": "",
  "name": "pipeline",
  "kind": "SPAN_KIND_INTERNAL",
  "startTime": "${ts}",
  "endTime": "",
  "status": {
    "code": "STATUS_CODE_UNSET",
    "message": ""
  },
  "attributes": {
    "pipeline.id": "$pipeline",
    "pipeline.status": "running"
  },
  "events": []
}
EOF
                    )
                    ;;
                stage_start)
                    stage=$(echo "$line" | jq -r '.stage // "unknown"' 2>/dev/null || true)
                    local span_id="${stage:0:8}$(printf '%08x' $((RANDOM * 256 + RANDOM)))"
                    spans=$(echo "$spans" | jq --arg span_id "$span_id" --arg stage "$stage" --arg ts "$ts" \
                        '. += [{
                            "traceId": "'${pipeline:0:16}'",
                            "spanId": "'$span_id'",
                            "parentSpanId": "'${root_span:0:16}'",
                            "name": "stage_'$stage'",
                            "kind": "SPAN_KIND_INTERNAL",
                            "startTime": "'$ts'",
                            "attributes": { "stage.name": "'$stage'" }
                        }]')
                    ;;
            esac
        done < "$EVENTS_FILE"
    fi

    # Output OTel trace JSON
    cat << EOF
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": {
          "service.name": "shipwright",
          "service.version": "$VERSION"
        }
      },
      "scopeSpans": [
        {
          "scope": {
            "name": "shipwright-tracer",
            "version": "$VERSION"
          },
          "spans": $spans
        }
      ]
    }
  ],
  "exportedAt": "$(now_iso)"
}
EOF
}

# ─── OTLP Export ────────────────────────────────────────────────────────────

cmd_export() {
    local format="${1:-prometheus}"

    ensure_otel_dir

    local endpoint="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}"
    local auth_header=""

    if [[ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]]; then
        auth_header="-H '${OTEL_EXPORTER_OTLP_HEADERS}'"
    fi

    info "Exporting $format metrics to $endpoint"

    local payload
    if [[ "$format" == "trace" ]]; then
        payload=$(cmd_trace)
        local response
        response=$(curl -s -X POST \
            "$endpoint/v1/traces" \
            -H "Content-Type: application/json" \
            $auth_header \
            -d "$payload" 2>&1 || echo "{\"error\": \"export failed\"}")

        if echo "$response" | jq . >/dev/null 2>&1; then
            success "Traces exported successfully"
        else
            error "Failed to export traces: $response"
            return 1
        fi
    else
        payload=$(cmd_metrics text)
        local response
        response=$(curl -s -X POST \
            "$endpoint/metrics" \
            -H "Content-Type: text/plain" \
            $auth_header \
            --data-binary "$payload" 2>&1 || echo "error")

        if [[ "$response" == "200" ]] || [[ "$response" == "" ]]; then
            success "Metrics exported successfully"
        else
            error "Failed to export metrics: $response"
            return 1
        fi
    fi

    # Record export event
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"otel_export\",\"format\":\"$format\",\"endpoint\":\"$endpoint\"}" \
        >> "${HOME}/.shipwright/events.jsonl"
}

# ─── Webhook Forwarding ──────────────────────────────────────────────────────

cmd_webhook() {
    local action="${1:-send}"
    local webhook_url="${OTEL_WEBHOOK_URL:-}"

    if [[ -z "$webhook_url" ]]; then
        error "OTEL_WEBHOOK_URL environment variable not set"
        return 1
    fi

    if [[ "$action" == "send" ]]; then
        info "Forwarding events to webhook: $webhook_url"

        # Get latest unforwarded events
        local payload
        payload=$(cmd_metrics json)

        local max_retries=3
        local retry=0
        local backoff=1

        while [[ $retry -lt $max_retries ]]; do
            local response
            response=$(curl -s -w "\n%{http_code}" -X POST \
                "$webhook_url" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>&1 || echo "000")

            local http_code
            http_code=$(echo "$response" | tail -n1)

            if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]] || [[ "$http_code" == "204" ]]; then
                success "Webhook delivered (HTTP $http_code)"
                echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"webhook_sent\",\"url\":\"$webhook_url\",\"http_code\":$http_code}" \
                    >> "${HOME}/.shipwright/events.jsonl"
                return 0
            fi

            ((retry++))
            if [[ $retry -lt $max_retries ]]; then
                warn "Webhook failed (HTTP $http_code), retrying in ${backoff}s..."
                sleep "$backoff"
                backoff=$((backoff * 2))
            fi
        done

        error "Webhook delivery failed after $max_retries attempts"
        return 1
    elif [[ "$action" == "config" ]]; then
        info "Webhook configuration:"
        echo "  URL: $webhook_url"
        echo "  Status: enabled"
    else
        error "Unknown webhook action: $action"
        return 1
    fi
}

# ─── Dashboard Metrics ───────────────────────────────────────────────────────

cmd_dashboard() {
    ensure_otel_dir

    # Aggregate metrics for dashboard
    local metrics
    metrics=$(cmd_metrics json)

    # Enhance with additional dashboard fields
    echo "$metrics" | jq '
    .dashboard = {
      "pipelines": {
        "total": .metrics.pipelines_total.value,
        "active": .metrics.active_pipelines.value,
        "success_rate": ((.metrics.pipelines_succeeded.value / (.metrics.pipelines_total.value + 0.001)) * 100 | floor)
      },
      "costs": {
        "total_usd": .metrics.cost_total_usd.value,
        "daily_avg": (.metrics.cost_total_usd.value / 30)
      },
      "queue": {
        "depth": .metrics.queue_depth.value
      }
    }
    '
}

# ─── Observability Report ───────────────────────────────────────────────────

cmd_report() {
    ensure_otel_dir

    info "Shipwright Observability Health Report"
    echo ""

    # Event volume
    local event_count=0
    local export_count=0
    local webhook_count=0
    local last_event_ts=""

    if [[ -f "$EVENTS_FILE" ]]; then
        event_count=$(wc -l < "$EVENTS_FILE" || echo "0")
        export_count=$(grep -c '"type":"otel_export"' "$EVENTS_FILE" 2>/dev/null || echo "0")
        webhook_count=$(grep -c '"type":"webhook_sent"' "$EVENTS_FILE" 2>/dev/null || echo "0")
        last_event_ts=$(tail -n1 "$EVENTS_FILE" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")
    fi

    echo -e "${BOLD}Events:${RESET}"
    echo "  Total events: $event_count"
    echo "  OTLP exports: $export_count"
    echo "  Webhook sends: $webhook_count"
    echo "  Last event: $last_event_ts"
    echo ""

    # Metrics summary
    local metrics
    metrics=$(cmd_metrics json)

    local active_pipelines succeeded failed cost
    active_pipelines=$(echo "$metrics" | jq -r '.metrics.active_pipelines.value')
    succeeded=$(echo "$metrics" | jq -r '.metrics.pipelines_succeeded.value')
    failed=$(echo "$metrics" | jq -r '.metrics.pipelines_failed.value')
    cost=$(echo "$metrics" | jq -r '.metrics.cost_total_usd.value')

    echo -e "${BOLD}Pipeline Metrics:${RESET}"
    echo "  Active: $active_pipelines"
    echo "  Succeeded: $succeeded"
    echo "  Failed: $failed"
    echo "  Total cost: \$$(printf '%.2f' "$cost")"
    echo ""

    # Export health
    local export_success_rate=0
    if [[ $export_count -gt 0 ]]; then
        export_success_rate=$((succeeded * 100 / (succeeded + failed + 1)))
    fi

    echo -e "${BOLD}Export Health:${RESET}"
    echo "  Success rate: ${export_success_rate}%"
    echo "  Configuration: $(test -f "$OTEL_CONFIG" && echo "present" || echo "not found")"

    # Recommendations
    echo ""
    echo -e "${BOLD}${CYAN}Recommendations:${RESET}"
    if [[ $active_pipelines -gt 10 ]]; then
        echo "  ⚠ High queue depth ($active_pipelines) — consider scaling"
    fi
    if [[ $export_count -eq 0 ]]; then
        echo "  ⚠ No exports configured — set OTEL_EXPORTER_OTLP_ENDPOINT"
    fi
    if [[ $webhook_count -eq 0 ]]; then
        echo "  ℹ No webhooks configured — set OTEL_WEBHOOK_URL for event forwarding"
    fi
}

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
    cat << EOF
${BOLD}${CYAN}shipwright otel${RESET} — OpenTelemetry Observability

${BOLD}USAGE${RESET}
  ${CYAN}shipwright otel${RESET} <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  ${CYAN}metrics${RESET} [format]         Prometheus-format metrics (text or json)
  ${CYAN}trace${RESET} [pipeline-id]      OpenTelemetry trace for a pipeline run
  ${CYAN}export${RESET} [format]          Export metrics/traces to OTLP endpoint
  ${CYAN}webhook${RESET} <action>         Webhook operations (send, config)
  ${CYAN}dashboard${RESET}                Dashboard-ready JSON metrics
  ${CYAN}report${RESET}                   Observability health report
  ${CYAN}help${RESET}                     Show this help message

${BOLD}FORMATS${RESET}
  ${DIM}prometheus, text${RESET}         Prometheus text format (default)
  ${DIM}json${RESET}                     JSON format
  ${DIM}trace${RESET}                    OpenTelemetry trace format

${BOLD}ENVIRONMENT VARIABLES${RESET}
  ${DIM}OTEL_EXPORTER_OTLP_ENDPOINT${RESET}  OTLP collector endpoint (default: http://localhost:4318)
  ${DIM}OTEL_EXPORTER_OTLP_HEADERS${RESET}   Authorization header for OTLP
  ${DIM}OTEL_WEBHOOK_URL${RESET}             Webhook endpoint for event forwarding

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright otel metrics${RESET}                          # Show Prometheus metrics
  ${DIM}shipwright otel metrics json${RESET}                     # JSON format
  ${DIM}shipwright otel export prometheus${RESET}                # Export to OTLP endpoint
  ${DIM}OTEL_WEBHOOK_URL=https://api.example.com shipwright otel webhook send${RESET}
  ${DIM}shipwright otel report${RESET}                           # Health status

EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        metrics)
            cmd_metrics "$@"
            ;;
        trace)
            cmd_trace "$@"
            ;;
        export)
            cmd_export "$@"
            ;;
        webhook)
            cmd_webhook "$@"
            ;;
        dashboard)
            cmd_dashboard "$@"
            ;;
        report)
            cmd_report "$@"
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
