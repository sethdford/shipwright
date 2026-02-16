#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-checks — Native GitHub Checks API Integration       ║
# ║  Check runs per stage · Annotations · PR timeline integration          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Artifacts Directory ─────────────────────────────────────────────────────
ARTIFACTS_DIR="${REPO_DIR}/.claude/pipeline-artifacts"

# ─── Session Cache for API Availability ───────────────────────────────────────
_GH_CHECKS_AVAILABLE=""

# ─── Auto-detect owner/repo from git remote ──────────────────────────────────
_gh_detect_repo() {
    local remote_url
    remote_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -z "$remote_url" ]]; then
        echo ""
        return 1
    fi
    # Handle SSH (git@github.com:owner/repo.git) and HTTPS (https://github.com/owner/repo.git)
    local owner_repo
    owner_repo=$(echo "$remote_url" | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##')
    echo "$owner_repo"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHECKS API FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Check if Checks API is accessible ────────────────────────────────────────
_gh_checks_available() {
    # Return cached result if available
    if [[ "$_GH_CHECKS_AVAILABLE" == "yes" ]]; then
        return 0
    elif [[ "$_GH_CHECKS_AVAILABLE" == "no" ]]; then
        return 1
    fi

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        _GH_CHECKS_AVAILABLE="no"
        return 1
    fi

    local owner="${1:-}"
    local repo="${2:-}"

    if [[ -z "$owner" || -z "$repo" ]]; then
        local detected
        detected=$(_gh_detect_repo || true)
        if [[ -n "$detected" ]]; then
            owner="${detected%%/*}"
            repo="${detected##*/}"
        fi
    fi

    if [[ -z "$owner" || -z "$repo" ]]; then
        _GH_CHECKS_AVAILABLE="no"
        return 1
    fi

    local result=0
    gh api "repos/${owner}/${repo}/commits/HEAD/check-runs?per_page=1" --silent 2>/dev/null || result=$?

    if [[ "$result" -eq 0 ]]; then
        _GH_CHECKS_AVAILABLE="yes"
        return 0
    else
        _GH_CHECKS_AVAILABLE="no"
        return 1
    fi
}

# ─── Create a check run ──────────────────────────────────────────────────────
gh_checks_create_run() {
    local owner="${1:-}"
    local repo="${2:-}"
    local head_sha="${3:-}"
    local name="${4:-}"
    local status="${5:-in_progress}"
    local details_url="${6:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" || -z "$head_sha" || -z "$name" ]]; then
        error "Usage: gh_checks_create_run <owner> <repo> <sha> <name> [status] [details_url]"
        return 1
    fi

    local body
    body=$(jq -n \
        --arg sha "$head_sha" \
        --arg name "$name" \
        --arg status "$status" \
        --arg started_at "$(now_iso)" \
        --arg details_url "$details_url" \
        '{
            head_sha: $sha,
            name: $name,
            status: $status,
            started_at: $started_at
        } + (if $details_url != "" then {details_url: $details_url} else {} end)')

    local response=""
    local result=0
    response=$(gh api "repos/${owner}/${repo}/check-runs" \
        --method POST \
        --input - <<< "$body" 2>/dev/null) || result=$?

    if [[ "$result" -ne 0 ]]; then
        warn "Failed to create check run '${name}' (API returned ${result})" >&2
        echo ""
        return 0
    fi

    local run_id
    run_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null || true)

    if [[ -n "$run_id" && "$run_id" != "null" ]]; then
        emit_event "checks.create" "run_id=$run_id" "name=$name" "status=$status"
        echo "$run_id"
    else
        warn "Check run created but no ID returned" >&2
        echo ""
    fi
}

# ─── Update a check run ──────────────────────────────────────────────────────
gh_checks_update_run() {
    local owner="${1:-}"
    local repo="${2:-}"
    local run_id="${3:-}"
    local status="${4:-}"
    local conclusion="${5:-}"
    local output_title="${6:-}"
    local output_summary="${7:-}"
    local output_text="${8:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    # Skip silently if run_id is empty
    if [[ -z "$run_id" ]]; then
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" ]]; then
        error "Usage: gh_checks_update_run <owner> <repo> <run_id> <status> [conclusion] [title] [summary] [text]"
        return 1
    fi

    local body
    body=$(jq -n \
        --arg status "$status" \
        --arg conclusion "$conclusion" \
        --arg completed_at "$(now_iso)" \
        --arg title "$output_title" \
        --arg summary "$output_summary" \
        --arg text "$output_text" \
        '{status: $status}
        + (if $conclusion != "" then {conclusion: $conclusion, completed_at: $completed_at} else {} end)
        + (if $title != "" then {output: (
            {title: $title, summary: (if $summary != "" then $summary else "No summary" end)}
            + (if $text != "" then {text: $text} else {} end)
        )} else {} end)')

    local result=0
    gh api "repos/${owner}/${repo}/check-runs/${run_id}" \
        --method PATCH \
        --input - <<< "$body" --silent 2>/dev/null || result=$?

    if [[ "$result" -ne 0 ]]; then
        warn "Failed to update check run ${run_id}"
    else
        emit_event "checks.update" "run_id=$run_id" "status=$status" "conclusion=$conclusion"
    fi
}

# ─── Add annotations to a check run ──────────────────────────────────────────
gh_checks_annotate() {
    local owner="${1:-}"
    local repo="${2:-}"
    local run_id="${3:-}"
    local annotations_json="${4:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    if [[ -z "$run_id" ]]; then
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" || -z "$annotations_json" ]]; then
        error "Usage: gh_checks_annotate <owner> <repo> <run_id> <annotations_json>"
        return 1
    fi

    # GitHub limits: max 50 annotations per request
    local total
    total=$(echo "$annotations_json" | jq 'length' 2>/dev/null || echo "0")

    local offset=0
    while [[ "$offset" -lt "$total" ]]; do
        local batch
        batch=$(echo "$annotations_json" | jq --argjson s "$offset" --argjson e 50 '.[$s:$s+$e]' 2>/dev/null)

        local body
        body=$(jq -n \
            --argjson annotations "$batch" \
            '{
                output: {
                    title: "Shipwright Annotations",
                    summary: "Pipeline analysis annotations",
                    annotations: $annotations
                }
            }')

        local result=0
        gh api "repos/${owner}/${repo}/check-runs/${run_id}" \
            --method PATCH \
            --input - <<< "$body" --silent 2>/dev/null || result=$?

        if [[ "$result" -ne 0 ]]; then
            warn "Failed to add annotations batch at offset ${offset}"
        fi

        offset=$((offset + 50))
    done

    emit_event "checks.annotate" "run_id=$run_id" "count=$total"
}

# ─── List check runs for a commit ─────────────────────────────────────────────
gh_checks_list_runs() {
    local owner="${1:-}"
    local repo="${2:-}"
    local head_sha="${3:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        echo "[]"
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" || -z "$head_sha" ]]; then
        error "Usage: gh_checks_list_runs <owner> <repo> <sha>"
        return 1
    fi

    local response=""
    local result=0
    response=$(gh api "repos/${owner}/${repo}/commits/${head_sha}/check-runs" 2>/dev/null) || result=$?

    if [[ "$result" -ne 0 ]]; then
        warn "Failed to list check runs for ${head_sha}" >&2
        echo "[]"
        return 0
    fi

    echo "$response" | jq '[.check_runs[] | {id, name, status, conclusion, started_at, completed_at}]' 2>/dev/null || echo "[]"
}

# ─── Complete a check run (convenience) ───────────────────────────────────────
gh_checks_complete() {
    local owner="${1:-}"
    local repo="${2:-}"
    local run_id="${3:-}"
    local conclusion="${4:-success}"
    local summary="${5:-}"

    if [[ -z "$run_id" ]]; then
        return 0
    fi

    gh_checks_update_run "$owner" "$repo" "$run_id" "completed" "$conclusion" \
        "Shipwright: ${conclusion}" "${summary:-Stage completed with ${conclusion}}" ""

    emit_event "checks.complete" "run_id=$run_id" "conclusion=$conclusion"
}

# ─── Create check runs for all pipeline stages ───────────────────────────────
gh_checks_pipeline_start() {
    local owner="${1:-}"
    local repo="${2:-}"
    local head_sha="${3:-}"
    local stages_json="${4:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        echo "{}"
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" || -z "$head_sha" || -z "$stages_json" ]]; then
        error "Usage: gh_checks_pipeline_start <owner> <repo> <sha> <stages_json>"
        return 1
    fi

    mkdir -p "$ARTIFACTS_DIR"

    local run_ids="{}"
    local stage=""
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue

        local run_id
        run_id=$(gh_checks_create_run "$owner" "$repo" "$head_sha" "shipwright/${stage}" "queued" "")

        if [[ -n "$run_id" ]]; then
            run_ids=$(echo "$run_ids" | jq --arg stage "$stage" --arg id "$run_id" '. + {($stage): $id}')
        fi
    done < <(echo "$stages_json" | jq -r '.[]' 2>/dev/null)

    # Store run IDs atomically
    local tmp_file
    tmp_file=$(mktemp "${ARTIFACTS_DIR}/check-run-ids.XXXXXX")
    echo "$run_ids" > "$tmp_file"
    mv "$tmp_file" "${ARTIFACTS_DIR}/check-run-ids.json"

    emit_event "checks.pipeline_start" "stages=$(echo "$stages_json" | jq -r 'length')"
    echo "$run_ids"
}

# ─── Update a pipeline stage check run ────────────────────────────────────────
gh_checks_stage_update() {
    local stage_name="${1:-}"
    local status="${2:-}"
    local conclusion="${3:-}"
    local summary="${4:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    local ids_file="${ARTIFACTS_DIR}/check-run-ids.json"
    if [[ ! -f "$ids_file" ]]; then
        warn "No check-run-ids.json found — skipping stage update"
        return 0
    fi

    local run_id
    run_id=$(jq -r --arg s "$stage_name" '.[$s] // empty' "$ids_file" 2>/dev/null || true)

    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        warn "No check run ID found for stage '${stage_name}'"
        return 0
    fi

    # Detect owner/repo
    local detected
    detected=$(_gh_detect_repo || true)
    if [[ -z "$detected" ]]; then
        warn "Could not detect owner/repo — skipping stage update"
        return 0
    fi

    local owner="${detected%%/*}"
    local repo="${detected##*/}"

    gh_checks_update_run "$owner" "$repo" "$run_id" "$status" "$conclusion" \
        "Shipwright: ${stage_name}" "${summary:-Stage ${stage_name}: ${status}}" ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI INTERFACE
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright github-checks${RESET} — Native GitHub Checks API Integration"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright checks <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}list${RESET} <sha>                 List check runs for a commit"
    echo -e "  ${CYAN}create${RESET} <sha> <name>        Create a new check run"
    echo -e "  ${CYAN}help${RESET}                       Show this help"
    echo ""
    echo -e "${BOLD}FUNCTIONS (for sourcing)${RESET}"
    echo -e "  ${DIM}gh_checks_create_run       Create a check run${RESET}"
    echo -e "  ${DIM}gh_checks_update_run       Update check run status/conclusion${RESET}"
    echo -e "  ${DIM}gh_checks_annotate         Add annotations to a check run${RESET}"
    echo -e "  ${DIM}gh_checks_list_runs        List check runs for a commit${RESET}"
    echo -e "  ${DIM}gh_checks_complete         Mark a check run as completed${RESET}"
    echo -e "  ${DIM}gh_checks_pipeline_start   Create runs for all pipeline stages${RESET}"
    echo -e "  ${DIM}gh_checks_stage_update     Update a stage's check run${RESET}"
    echo ""
    echo -e "${DIM}Version ${VERSION}${RESET}"
}

_checks_list_cli() {
    local sha="${1:-HEAD}"

    local detected
    detected=$(_gh_detect_repo || true)
    if [[ -z "$detected" ]]; then
        error "Could not detect owner/repo from git remote"
        exit 1
    fi

    local owner="${detected%%/*}"
    local repo="${detected##*/}"

    info "Listing check runs for ${sha}..."
    local runs
    runs=$(gh_checks_list_runs "$owner" "$repo" "$sha")

    local count
    count=$(echo "$runs" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        info "No check runs found"
        return 0
    fi

    echo ""
    echo -e "${BOLD}Check Runs (${count})${RESET}"
    echo ""

    echo "$runs" | jq -r '.[] | "  \(.name)\t\(.status)\t\(.conclusion // "-")"' 2>/dev/null || true
    echo ""
}

_checks_create_cli() {
    local sha="${1:-}"
    local name="${2:-}"

    if [[ -z "$sha" || -z "$name" ]]; then
        error "Usage: shipwright checks create <sha> <name>"
        exit 1
    fi

    local detected
    detected=$(_gh_detect_repo || true)
    if [[ -z "$detected" ]]; then
        error "Could not detect owner/repo from git remote"
        exit 1
    fi

    local owner="${detected%%/*}"
    local repo="${detected##*/}"

    info "Creating check run '${name}'..."
    local run_id
    run_id=$(gh_checks_create_run "$owner" "$repo" "$sha" "$name" "in_progress")

    if [[ -n "$run_id" ]]; then
        success "Created check run: ${run_id}"
    else
        error "Failed to create check run"
        exit 1
    fi
}

main() {
    case "${1:-help}" in
        list)   shift; _checks_list_cli "$@" ;;
        create) shift; _checks_create_cli "$@" ;;
        help|--help|-h) show_help ;;
        *)      error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
