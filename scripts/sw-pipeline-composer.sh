#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline composer — Dynamic Pipeline Composition            ║
# ║  AI-driven stage selection · Conditional insertion · Model routing      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.1"
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

# ─── Source intelligence engine ─────────────────────────────────────────────
INTELLIGENCE_AVAILABLE=false
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
    INTELLIGENCE_AVAILABLE=true
fi

# ─── Default template directory ─────────────────────────────────────────────
TEMPLATES_DIR="${REPO_DIR}/templates/pipelines"
ARTIFACTS_DIR=".claude/pipeline-artifacts"

# ─── GitHub CI History ─────────────────────────────────────────────────────

_composer_github_ci_history() {
    type _gh_detect_repo &>/dev/null 2>&1 || { echo "{}"; return 0; }
    _gh_detect_repo 2>/dev/null || { echo "{}"; return 0; }

    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && { echo "{}"; return 0; }

    if type gh_actions_runs &>/dev/null 2>&1; then
        local runs
        runs=$(gh_actions_runs "$owner" "$repo" "" 20 2>/dev/null || echo "[]")
        local avg_duration p90_duration
        avg_duration=$(echo "$runs" | jq '[.[] | .duration_seconds // 0] | if length > 0 then add / length | floor else 0 end' 2>/dev/null || echo "0")
        p90_duration=$(echo "$runs" | jq '[.[] | .duration_seconds // 0] | sort | if length > 0 then .[length * 9 / 10 | floor] else 0 end' 2>/dev/null || echo "0")
        jq -n --argjson avg "${avg_duration:-0}" --argjson p90 "${p90_duration:-0}" \
            '{avg_ci_duration: $avg, p90_ci_duration: $p90}'
    else
        echo "{}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE COMPOSITION
# ═══════════════════════════════════════════════════════════════════════════════

# Create a composed pipeline from intelligence analysis
# Args: issue_analysis_json repo_context budget_json
composer_create_pipeline() {
    local issue_analysis="${1:-}"
    local repo_context="${2:-}"
    local budget_json="${3:-}"

    local output_dir="${ARTIFACTS_DIR}"
    local output_file="${output_dir}/composed-pipeline.json"

    mkdir -p "$output_dir"

    # Enrich with GitHub CI history if available
    local ci_history
    ci_history=$(_composer_github_ci_history 2>/dev/null || echo "{}")
    local p90_timeout=0
    p90_timeout=$(echo "$ci_history" | jq -r '.p90_ci_duration // 0' 2>/dev/null || echo "0")
    if [[ "${p90_timeout:-0}" -gt 0 ]]; then
        # Include CI history in repo context for the composer
        if [[ -n "$repo_context" ]]; then
            repo_context=$(echo "$repo_context" | jq --argjson ci "$ci_history" '. + {ci_history: $ci}' 2>/dev/null || echo "$repo_context")
        else
            repo_context="$ci_history"
        fi
        info "CI history: p90 duration=${p90_timeout}s — using for timeout tuning" >&2
    fi

    # Try intelligence-driven composition
    if [[ "$INTELLIGENCE_AVAILABLE" == "true" ]] && \
       [[ -n "$issue_analysis" ]] && \
       type intelligence_compose_pipeline &>/dev/null; then

        info "Composing pipeline with intelligence engine..." >&2

        local composed=""
        composed=$(intelligence_compose_pipeline "$issue_analysis" "$repo_context" "$budget_json" 2>/dev/null) || true

        if [[ -n "$composed" ]] && echo "$composed" | jq -e '.stages' &>/dev/null; then
            # Validate the composed pipeline
            if echo "$composed" | composer_validate_pipeline; then
                # Atomic write
                local tmp_file
                tmp_file=$(mktemp "${output_file}.XXXXXX")
                echo "$composed" | jq '.' > "$tmp_file"
                mv "$tmp_file" "$output_file"

                local stage_count
                stage_count=$(echo "$composed" | jq '.stages | length')
                success "Composed pipeline: ${stage_count} stages" >&2

                emit_event "composer.created" \
                    "stages=${stage_count}" \
                    "source=intelligence" \
                    "output=${output_file}"

                echo "$output_file"
                return 0
            else
                warn "Intelligence pipeline failed validation, falling back to template" >&2
            fi
        else
            warn "Intelligence composition returned invalid JSON, falling back to template" >&2
        fi
    fi

    # Fallback: use static template
    local fallback_template="${TEMPLATES_DIR}/standard.json"
    if [[ -f "$fallback_template" ]]; then
        info "Using fallback template: standard" >&2
        local tmp_file
        tmp_file=$(mktemp "${output_file}.XXXXXX")
        cp "$fallback_template" "$tmp_file"
        mv "$tmp_file" "$output_file"

        emit_event "composer.created" \
            "stages=$(jq '.stages | length' "$output_file")" \
            "source=fallback" \
            "output=${output_file}"

        echo "$output_file"
        return 0
    fi

    error "No templates available for fallback" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONDITIONAL STAGE INSERTION
# ═══════════════════════════════════════════════════════════════════════════════

# Insert a stage into the pipeline after a specified stage
# Args: pipeline_json after_stage new_stage_config
# pipeline_json can be a file path or JSON string
composer_insert_conditional_stage() {
    local pipeline_input="${1:-}"
    local after_stage="${2:-}"
    local new_stage_config="${3:-}"

    if [[ -z "$pipeline_input" || -z "$after_stage" || -z "$new_stage_config" ]]; then
        error "Usage: composer insert <pipeline_json> <after_stage> <new_stage_config>"
        return 1
    fi

    # Read pipeline JSON (file path or inline)
    local pipeline_json
    if [[ -f "$pipeline_input" ]]; then
        pipeline_json=$(cat "$pipeline_input")
    else
        pipeline_json="$pipeline_input"
    fi

    # Find index of after_stage
    local idx
    idx=$(echo "$pipeline_json" | jq --arg s "$after_stage" \
        '[.stages[].id] | to_entries | map(select(.value == $s)) | .[0].key // -1')

    if [[ "$idx" == "-1" || "$idx" == "null" ]]; then
        error "Stage '${after_stage}' not found in pipeline"
        return 1
    fi

    # Insert new stage after the found index
    local insert_pos=$((idx + 1))
    local result
    result=$(echo "$pipeline_json" | jq --argjson pos "$insert_pos" --argjson stage "$new_stage_config" \
        '.stages = (.stages[:$pos] + [$stage] + .stages[$pos:])')

    local new_id
    new_id=$(echo "$new_stage_config" | jq -r '.id // "unknown"')

    emit_event "composer.stage_inserted" \
        "new_stage=${new_id}" \
        "after=${after_stage}" \
        "position=${insert_pos}"

    echo "$result"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MODEL DOWNGRADE
# ═══════════════════════════════════════════════════════════════════════════════

# Downgrade models for remaining stages to save budget
# Args: pipeline_json from_stage
composer_downgrade_models() {
    local pipeline_input="${1:-}"
    local from_stage="${2:-}"

    if [[ -z "$pipeline_input" || -z "$from_stage" ]]; then
        error "Usage: composer downgrade <pipeline_json> <from_stage>"
        return 1
    fi

    # Read pipeline JSON (file path or inline)
    local pipeline_json
    if [[ -f "$pipeline_input" ]]; then
        pipeline_json=$(cat "$pipeline_input")
    else
        pipeline_json="$pipeline_input"
    fi

    # Find index of from_stage
    local idx
    idx=$(echo "$pipeline_json" | jq --arg s "$from_stage" \
        '[.stages[].id] | to_entries | map(select(.value == $s)) | .[0].key // -1')

    if [[ "$idx" == "-1" || "$idx" == "null" ]]; then
        error "Stage '${from_stage}' not found in pipeline"
        return 1
    fi

    # Downgrade model in config for all stages from idx onwards
    local result
    result=$(echo "$pipeline_json" | jq --argjson idx "$idx" '
        .stages = [.stages | to_entries[] |
            if .key >= $idx then
                .value.config.model = "sonnet"
            else . end | .value
        ] |
        if .defaults.model then .defaults.model = "sonnet" else . end
    ')

    local total_stages
    total_stages=$(echo "$pipeline_json" | jq '.stages | length')
    local downgraded=$((total_stages - idx))

    emit_event "composer.models_downgraded" \
        "from_stage=${from_stage}" \
        "stages_affected=${downgraded}" \
        "target_model=sonnet"

    echo "$result"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ITERATION ESTIMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Estimate build loop iterations needed
# Args: issue_analysis_json historical_data
composer_estimate_iterations() {
    local issue_analysis="${1:-}"
    local historical_data="${2:-}"

    local default_iterations=20

    # Try intelligence-based estimation
    if [[ "$INTELLIGENCE_AVAILABLE" == "true" ]] && \
       [[ -n "$issue_analysis" ]] && \
       type intelligence_estimate_iterations &>/dev/null; then

        local estimate=""
        estimate=$(intelligence_estimate_iterations "$issue_analysis" "$historical_data" 2>/dev/null) || true

        if [[ -n "$estimate" ]] && [[ "$estimate" =~ ^[0-9]+$ ]] && \
           [[ "$estimate" -ge 1 ]] && [[ "$estimate" -le 50 ]]; then
            echo "$estimate"
            return 0
        fi
    fi

    # Fallback: use complexity from analysis if available
    if [[ -n "$issue_analysis" ]]; then
        local complexity=""
        complexity=$(echo "$issue_analysis" | jq -r '.complexity // empty' 2>/dev/null) || true

        case "${complexity}" in
            trivial)  echo 5;  return 0 ;;
            low)      echo 10; return 0 ;;
            medium)   echo 15; return 0 ;;
            high)     echo 25; return 0 ;;
            critical) echo 35; return 0 ;;
        esac
    fi

    echo "$default_iterations"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

# Validate a pipeline JSON structure
# Reads from stdin or file/string argument
composer_validate_pipeline() {
    local pipeline_input="${1:-}"
    local pipeline_json

    if [[ -n "$pipeline_input" ]]; then
        if [[ -f "$pipeline_input" ]]; then
            pipeline_json=$(cat "$pipeline_input")
        else
            pipeline_json="$pipeline_input"
        fi
    else
        pipeline_json=$(cat)
    fi

    # Check: stages array exists
    if ! echo "$pipeline_json" | jq -e '.stages' &>/dev/null; then
        error "Validation failed: missing 'stages' array"
        return 1
    fi

    # Check: each stage has an id field
    local missing_ids
    missing_ids=$(echo "$pipeline_json" | jq '[.stages[] | select(.id == null or .id == "")] | length')
    if [[ "$missing_ids" -gt 0 ]]; then
        error "Validation failed: ${missing_ids} stage(s) missing 'id' field"
        return 1
    fi

    # Check: stage ordering constraints
    # intake must come before build, build before test, test before pr
    local stage_ids
    stage_ids=$(echo "$pipeline_json" | jq -r '[.stages[] | select(.enabled != false) | .id] | join(",")')

    # Helper: check ordering of two stages (only if both are present and enabled)
    _check_order() {
        local before="$1"
        local after="$2"
        local ids="$stage_ids"

        # Only check if both stages are in the enabled list
        local has_before=false
        local has_after=false
        local before_pos=-1
        local after_pos=-1
        local pos=0

        local IFS=","
        for sid in $ids; do
            if [[ "$sid" == "$before" ]]; then
                has_before=true
                before_pos=$pos
            fi
            if [[ "$sid" == "$after" ]]; then
                has_after=true
                after_pos=$pos
            fi
            pos=$((pos + 1))
        done

        if [[ "$has_before" == "true" && "$has_after" == "true" ]]; then
            if [[ "$before_pos" -ge "$after_pos" ]]; then
                error "Validation failed: '${before}' must come before '${after}'"
                return 1
            fi
        fi
        return 0
    }

    _check_order "intake" "build" || return 1
    _check_order "build" "test"   || return 1
    _check_order "test" "pr"      || return 1
    _check_order "plan" "build"   || return 1
    _check_order "review" "pr"    || return 1

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    echo -e "${CYAN}${BOLD}shipwright pipeline-composer${RESET} — Dynamic pipeline composition"
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo "  sw-pipeline-composer.sh <command> [args...]"
    echo ""
    echo -e "${BOLD}Commands:${RESET}"
    echo "  create   <analysis> [repo_ctx] [budget]  Compose pipeline from analysis"
    echo "  insert   <pipeline> <after> <stage>       Insert stage after specified stage"
    echo "  downgrade <pipeline> <from_stage>         Downgrade models from stage onwards"
    echo "  estimate <analysis> [history]              Estimate build iterations"
    echo "  validate <pipeline>                        Validate pipeline structure"
    echo "  help                                       Show this help"
    echo ""
}

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        create)    composer_create_pipeline "$@" ;;
        insert)    composer_insert_conditional_stage "$@" ;;
        downgrade) composer_downgrade_models "$@" ;;
        estimate)  composer_estimate_iterations "$@" ;;
        validate)  composer_validate_pipeline "$@" ;;
        help|--help|-h) show_help ;;
        *)  error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
