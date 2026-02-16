#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright memory — Persistent Learning & Context System                     ║
# ║  Captures learnings · Injects context · Searches memory · Tracks metrics║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ─── Intelligence Engine (optional) ──────────────────────────────────────────
# shellcheck source=sw-intelligence.sh
[[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]] && source "$SCRIPT_DIR/sw-intelligence.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
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
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Memory Storage Paths ──────────────────────────────────────────────────
MEMORY_ROOT="${HOME}/.shipwright/memory"
GLOBAL_MEMORY="${MEMORY_ROOT}/global.json"

# Get a deterministic hash for the current repo
repo_hash() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    echo -n "$origin" | shasum -a 256 | cut -c1-12
}

repo_name() {
    git config --get remote.origin.url 2>/dev/null \
        | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|' \
        | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|' \
        || echo "local"
}

repo_memory_dir() {
    echo "${MEMORY_ROOT}/$(repo_hash)"
}

ensure_memory_dir() {
    local dir
    dir="$(repo_memory_dir)"
    mkdir -p "$dir"

    # Initialize empty JSON files if they don't exist
    [[ -f "$dir/patterns.json" ]]  || echo '{}' > "$dir/patterns.json"
    [[ -f "$dir/failures.json" ]]  || echo '{"failures":[]}' > "$dir/failures.json"
    [[ -f "$dir/decisions.json" ]] || echo '{"decisions":[]}' > "$dir/decisions.json"
    [[ -f "$dir/metrics.json" ]]   || echo '{"baselines":{}}' > "$dir/metrics.json"

    # Initialize global memory if missing
    mkdir -p "$MEMORY_ROOT"
    [[ -f "$GLOBAL_MEMORY" ]] || echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$GLOBAL_MEMORY"
}

# ─── Memory Capture Functions ──────────────────────────────────────────────

# memory_capture_pipeline <state_file> <artifacts_dir>
# Called after every pipeline completes. Reads state + artifacts → writes learnings.
memory_capture_pipeline() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"

    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        warn "State file not found: ${state_file:-<empty>}"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    local repo
    repo="$(repo_name)"
    local captured_at
    captured_at="$(now_iso)"

    info "Capturing pipeline learnings for ${CYAN}${repo}${RESET}..."

    # Extract pipeline result from state file
    local pipeline_status=""
    pipeline_status=$(sed -n 's/^status: *//p' "$state_file" | head -1)

    local goal=""
    goal=$(sed -n 's/^goal: *"*\([^"]*\)"*/\1/p' "$state_file" | head -1)

    # Capture stage results
    local stages_section=""
    stages_section=$(sed -n '/^stages:/,/^---/p' "$state_file" 2>/dev/null || true)

    # Track which stages passed/failed
    local passed_stages=""
    local failed_stages=""
    if [[ -n "$stages_section" ]]; then
        passed_stages=$(echo "$stages_section" | grep "complete" | sed 's/: *complete//' | tr -d ' ' | tr '\n' ',' | sed 's/,$//' || true)
        failed_stages=$(echo "$stages_section" | grep "failed" | sed 's/: *failed//' | tr -d ' ' | tr '\n' ',' | sed 's/,$//' || true)
    fi

    # Capture test failures if test artifacts exist
    if [[ -n "$artifacts_dir" && -f "$artifacts_dir/test-results.log" ]]; then
        local test_output
        test_output=$(cat "$artifacts_dir/test-results.log" 2>/dev/null || true)
        if echo "$test_output" | grep -qiE "FAIL|ERROR|failed"; then
            memory_capture_failure "test" "$test_output"
        fi
    fi

    # Capture review feedback patterns
    if [[ -n "$artifacts_dir" && -f "$artifacts_dir/review.md" ]]; then
        local review_output
        review_output=$(cat "$artifacts_dir/review.md" 2>/dev/null || true)
        local bug_count warning_count
        bug_count=$(echo "$review_output" | grep -ciE '\*\*\[Bug\]' || true)
        warning_count=$(echo "$review_output" | grep -ciE '\*\*\[Warning\]' || true)

        if [[ "${bug_count:-0}" -gt 0 || "${warning_count:-0}" -gt 0 ]]; then
            # Record review patterns to global memory for cross-repo learning
            local tmp_global
            tmp_global=$(mktemp)
            jq --arg repo "$repo" \
               --arg ts "$captured_at" \
               --argjson bugs "${bug_count:-0}" \
               --argjson warns "${warning_count:-0}" \
               '.cross_repo_learnings += [{
                   repo: $repo,
                   type: "review_feedback",
                   bugs: $bugs,
                   warnings: $warns,
                   captured_at: $ts
               }] | .cross_repo_learnings = (.cross_repo_learnings | .[-50:])' \
               "$GLOBAL_MEMORY" > "$tmp_global" && mv "$tmp_global" "$GLOBAL_MEMORY"
        fi
    fi

    emit_event "memory.capture" \
        "repo=${repo}" \
        "result=${pipeline_status}" \
        "passed_stages=${passed_stages}" \
        "failed_stages=${failed_stages}"

    success "Captured pipeline learnings (status: ${pipeline_status})"
}

# memory_capture_failure <stage> <error_output>
# Captures and deduplicates failure patterns.
memory_capture_failure() {
    local stage="${1:-unknown}"
    local error_output="${2:-}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    # Extract a short pattern from the error (first significant line)
    local pattern=""
    pattern=$(echo "$error_output" \
        | grep -iE "error|fail|cannot|not found|undefined|exception|missing" \
        | head -1 \
        | sed 's/^[[:space:]]*//' \
        | cut -c1-200)

    if [[ -z "$pattern" ]]; then
        pattern=$(echo "$error_output" | head -1 | cut -c1-200)
    fi

    [[ -z "$pattern" ]] && return 0

    # Check for duplicate — increment seen_count if pattern already exists
    local existing_idx
    existing_idx=$(jq --arg pat "$pattern" \
        '[.failures[]] | to_entries | map(select(.value.pattern == $pat)) | .[0].key // -1' \
        "$failures_file" 2>/dev/null || echo "-1")

    (
        if command -v flock &>/dev/null; then
            flock -w 10 200 2>/dev/null || { warn "Memory lock timeout"; return 1; }
        fi
        local tmp_file
        tmp_file=$(mktemp "${failures_file}.tmp.XXXXXX")

        if [[ "$existing_idx" != "-1" && "$existing_idx" != "null" ]]; then
            # Update existing entry
            jq --argjson idx "$existing_idx" \
               --arg ts "$(now_iso)" \
               '.failures[$idx].seen_count += 1 | .failures[$idx].last_seen = $ts' \
               "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file" || rm -f "$tmp_file"
        else
            # Add new failure entry
            jq --arg stage "$stage" \
               --arg pattern "$pattern" \
               --arg ts "$(now_iso)" \
               '.failures += [{
                   stage: $stage,
                   pattern: $pattern,
                   root_cause: "",
                   fix: "",
                   seen_count: 1,
                   last_seen: $ts
               }] | .failures = (.failures | .[-100:])' \
               "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file" || rm -f "$tmp_file"
        fi
    ) 200>"${failures_file}.lock"

    emit_event "memory.failure" "stage=${stage}" "pattern=${pattern:0:80}"
}

# memory_record_fix_outcome <failure_hash_or_pattern> <fix_applied:bool> <fix_resolved:bool>
# Tracks whether suggested fixes actually worked. Builds effectiveness data
# so future memory injection can prioritize high-success-rate fixes.
memory_record_fix_outcome() {
    local pattern_match="${1:-}"
    local fix_applied="${2:-false}"
    local fix_resolved="${3:-false}"

    [[ -z "$pattern_match" ]] && return 1

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    [[ ! -f "$failures_file" ]] && return 1

    # Find matching failure by pattern substring
    local match_idx
    match_idx=$(jq --arg pat "$pattern_match" \
        '[.failures[]] | to_entries | map(select(.value.pattern | contains($pat))) | .[0].key // -1' \
        "$failures_file" 2>/dev/null || echo "-1")

    if [[ "$match_idx" == "-1" || "$match_idx" == "null" ]]; then
        warn "No matching failure found for: ${pattern_match:0:60}"
        return 1
    fi

    # Update fix outcome tracking fields
    local applied_inc=0 resolved_inc=0
    [[ "$fix_applied" == "true" ]] && applied_inc=1
    [[ "$fix_resolved" == "true" ]] && resolved_inc=1

    (
        if command -v flock &>/dev/null; then
            flock -w 10 200 2>/dev/null || { warn "Memory lock timeout"; return 1; }
        fi
        local tmp_file
        tmp_file=$(mktemp "${failures_file}.tmp.XXXXXX")

        jq --argjson idx "$match_idx" \
           --argjson app "$applied_inc" \
           --argjson res "$resolved_inc" \
           --arg ts "$(now_iso)" \
           '.failures[$idx].times_fix_suggested = ((.failures[$idx].times_fix_suggested // 0) + 1) |
            .failures[$idx].times_fix_applied = ((.failures[$idx].times_fix_applied // 0) + $app) |
            .failures[$idx].times_fix_resolved = ((.failures[$idx].times_fix_resolved // 0) + $res) |
            .failures[$idx].fix_effectiveness_rate = (
                if ((.failures[$idx].times_fix_applied // 0) + $app) > 0 then
                    (((.failures[$idx].times_fix_resolved // 0) + $res) * 100 /
                     ((.failures[$idx].times_fix_applied // 0) + $app))
                else 0 end
            ) |
            .failures[$idx].last_outcome_at = $ts' \
           "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file" || rm -f "$tmp_file"
    ) 200>"${failures_file}.lock"

    emit_event "memory.fix_outcome" \
        "pattern=${pattern_match:0:60}" \
        "applied=${fix_applied}" \
        "resolved=${fix_resolved}"
}

# memory_track_fix <error_sig> <success_bool>
# Convenience wrapper for memory_record_fix_outcome
memory_track_fix() {
    local error_sig="${1:-}"
    local success="${2:-false}"
    [[ -z "$error_sig" ]] && return 0
    memory_record_fix_outcome "$error_sig" "true" "$success" 2>/dev/null || true
}

# memory_query_fix_for_error <error_pattern>
# Searches failure memory for known fixes matching the given error pattern.
# Returns JSON with the best fix (highest effectiveness rate) or empty.
memory_query_fix_for_error() {
    local error_pattern="$1"
    [[ -z "$error_pattern" ]] && return 0

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    [[ ! -f "$failures_file" ]] && return 0

    # Search for matching failures with successful fixes
    local matches
    matches=$(jq -r --arg pat "$error_pattern" '
        [.failures[]
        | select(.pattern != null and .pattern != "")
        | select(.pattern | test($pat; "i") // false)
        | select(.fix != null and .fix != "")
        | select((.fix_effectiveness_rate // 0) > 30)
        | {fix, fix_effectiveness_rate, seen_count, category, stage, pattern}]
        | sort_by(-.fix_effectiveness_rate)
        | .[0] // null
    ' "$failures_file" 2>/dev/null) || true

    if [[ -n "$matches" && "$matches" != "null" ]]; then
        echo "$matches"
    fi
}

# memory_closed_loop_inject <error_sig>
# Combines error → memory → fix into injectable text for build retries.
# Returns a one-line summary suitable for goal augmentation.
memory_closed_loop_inject() {
    local error_sig="$1"
    [[ -z "$error_sig" ]] && return 0

    local fix_json
    fix_json=$(memory_query_fix_for_error "$error_sig") || true
    [[ -z "$fix_json" || "$fix_json" == "null" ]] && return 0

    local fix_text success_rate category
    fix_text=$(echo "$fix_json" | jq -r '.fix // ""')
    success_rate=$(echo "$fix_json" | jq -r '.fix_effectiveness_rate // 0')
    category=$(echo "$fix_json" | jq -r '.category // "unknown"')

    [[ -z "$fix_text" ]] && return 0

    echo "[$category, ${success_rate}% success rate] $fix_text"
}

memory_capture_failure_from_log() {
    local artifacts_dir="${1:-}"
    local error_log="${artifacts_dir}/error-log.jsonl"
    [[ ! -f "$error_log" ]] && return 0

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    # Read last 50 entries
    local entries
    entries=$(tail -50 "$error_log" 2>/dev/null) || return 0
    [[ -z "$entries" ]] && return 0

    local captured=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local err_type err_text
        err_type=$(echo "$line" | jq -r '.type // "unknown"' 2>/dev/null) || continue
        err_text=$(echo "$line" | jq -r '.error // ""' 2>/dev/null) || continue
        [[ -z "$err_text" ]] && continue

        # Deduplicate: skip if this exact pattern already exists in failures
        local pattern_short
        pattern_short=$(echo "$err_text" | head -1 | cut -c1-200)
        local already_exists
        already_exists=$(jq --arg pat "$pattern_short" \
            '[.failures[] | select(.pattern == $pat)] | length' \
            "$failures_file" 2>/dev/null || echo "0")
        if [[ "${already_exists:-0}" -gt 0 ]]; then
            continue
        fi

        # Feed into memory_capture_failure with the error type as stage
        memory_capture_failure "$err_type" "$err_text" 2>/dev/null || true
        captured=$((captured + 1))
    done <<< "$entries"

    if [[ "$captured" -gt 0 ]]; then
        emit_event "memory.error_log_processed" "captured=$captured"
    fi
}

# _memory_aggregate_global
# Promotes high-frequency failure patterns to global.json for cross-repo learning
_memory_aggregate_global() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"
    [[ ! -f "$failures_file" ]] && return 0

    local global_file="$GLOBAL_MEMORY"
    [[ ! -f "$global_file" ]] && return 0

    # Find patterns with seen_count >= 3
    local frequent_patterns
    frequent_patterns=$(jq -r '.failures[] | select(.seen_count >= 3) | .pattern' \
        "$failures_file" 2>/dev/null) || return 0
    [[ -z "$frequent_patterns" ]] && return 0

    local promoted=0
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue

        # Check if already in global
        local exists
        exists=$(jq --arg p "$pattern" \
            '[.common_patterns[] | select(.pattern == $p)] | length' \
            "$global_file" 2>/dev/null || echo "0")
        if [[ "${exists:-0}" -gt 0 ]]; then
            continue
        fi

        # Add to global, cap at 100 entries
        local tmp_global
        tmp_global=$(mktemp "${global_file}.tmp.XXXXXX")
        jq --arg p "$pattern" \
           --arg ts "$(now_iso)" \
           --arg cat "general" \
           '.common_patterns += [{pattern: $p, promoted_at: $ts, category: $cat, source: "aggregate"}] |
            .common_patterns = (.common_patterns | .[-100:])' \
           "$global_file" > "$tmp_global" && mv "$tmp_global" "$global_file" || rm -f "$tmp_global"
        promoted=$((promoted + 1))
    done <<< "$frequent_patterns"

    if [[ "$promoted" -gt 0 ]]; then
        emit_event "memory.global_aggregated" "promoted=$promoted"
    fi
}

# memory_finalize_pipeline <state_file> <artifacts_dir>
# Single call that closes multiple feedback loops at pipeline completion
memory_finalize_pipeline() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"
    [[ -z "$state_file" || ! -f "$state_file" ]] && return 0

    # Step 1: Capture pipeline-level learnings
    memory_capture_pipeline "$state_file" "$artifacts_dir" 2>/dev/null || true

    # Step 2: Process error log into failures.json
    memory_capture_failure_from_log "$artifacts_dir" 2>/dev/null || true

    # Step 3: Aggregate high-frequency patterns to global memory
    _memory_aggregate_global 2>/dev/null || true
}

# memory_analyze_failure <log_file> <stage>
# Uses Claude to analyze a pipeline failure and fill in root_cause/fix/category.
memory_analyze_failure() {
    local log_file="${1:-}"
    local stage="${2:-unknown}"

    if [[ -z "$log_file" ]]; then
        warn "No log file specified for failure analysis"
        return 1
    fi

    # Gather log context — use the specific log file if it exists,
    # otherwise glob for any logs in the artifacts directory
    local log_tail=""
    if [[ -f "$log_file" ]]; then
        log_tail=$(tail -200 "$log_file" 2>/dev/null || true)
    else
        # Try to find stage-specific logs in the same directory
        local log_dir
        log_dir=$(dirname "$log_file" 2>/dev/null || echo ".")
        log_tail=$(tail -200 "$log_dir"/*.log 2>/dev/null || true)
    fi

    if [[ -z "$log_tail" ]]; then
        warn "No log content found for analysis"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    # Check that failures.json has at least one entry
    local entry_count
    entry_count=$(jq '.failures | length' "$failures_file" 2>/dev/null || echo "0")
    if [[ "$entry_count" -eq 0 ]]; then
        warn "No failure entries to analyze"
        return 0
    fi

    local last_pattern
    last_pattern=$(jq -r '.failures[-1].pattern // ""' "$failures_file" 2>/dev/null)

    info "Analyzing failure in ${CYAN}${stage}${RESET} stage..."

    # Gather past successful analyses for the same stage/category as examples
    local past_examples=""
    if [[ -f "$failures_file" ]]; then
        past_examples=$(jq -r --arg stg "$stage" \
            '[.failures[] | select(.stage == $stg and .root_cause != "" and .fix != "")] |
             sort_by(-.fix_effectiveness_rate // 0) | .[:2][] |
             "- Pattern: \(.pattern[:80])\n  Root cause: \(.root_cause)\n  Fix: \(.fix)"' \
            "$failures_file" 2>/dev/null || true)
    fi

    # Build valid categories list (from compat.sh if available, else hardcoded)
    local valid_cats="test_failure, build_error, lint_error, timeout, dependency, flaky, config"
    if [[ -n "${SW_ERROR_CATEGORIES:-}" ]]; then
        valid_cats=$(echo "$SW_ERROR_CATEGORIES" | tr ' ' ', ')
    fi

    # Build the analysis prompt
    local prompt
    prompt="Analyze this pipeline failure. The stage was: ${stage}.
The error pattern is: ${last_pattern}

Log output (last 200 lines):
${log_tail}"

    if [[ -n "$past_examples" ]]; then
        prompt="${prompt}

Here are examples of how similar failures were diagnosed in this repo:
${past_examples}"
    fi

    prompt="${prompt}

Return ONLY a JSON object with exactly these fields:
{\"root_cause\": \"one-line root cause\", \"fix\": \"one-line fix suggestion\", \"category\": \"one of: ${valid_cats}\"}

Return JSON only, no markdown fences, no explanation."

    # Call Claude for analysis
    local analysis
    analysis=$(claude -p "$prompt" --model sonnet 2>/dev/null) || {
        warn "Claude analysis failed"
        return 1
    }

    # Extract JSON — strip markdown fences if present
    analysis=$(echo "$analysis" | sed 's/^```json//; s/^```//; s/```$//' | tr -d '\n')

    # Parse the fields
    local root_cause fix category
    root_cause=$(echo "$analysis" | jq -r '.root_cause // ""' 2>/dev/null) || root_cause=""
    fix=$(echo "$analysis" | jq -r '.fix // ""' 2>/dev/null) || fix=""
    category=$(echo "$analysis" | jq -r '.category // "unknown"' 2>/dev/null) || category="unknown"

    if [[ -z "$root_cause" || "$root_cause" == "null" ]]; then
        warn "Could not parse analysis response"
        return 1
    fi

    # Validate category against shared taxonomy (compat.sh) or built-in list
    if type sw_valid_error_category &>/dev/null 2>&1; then
        if ! sw_valid_error_category "$category"; then
            category="unknown"
        fi
    else
        case "$category" in
            test_failure|build_error|lint_error|timeout|dependency|flaky|config) ;;
            *) category="unknown" ;;
        esac
    fi

    # Update the most recent failure entry with root_cause, fix, category
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg rc "$root_cause" \
       --arg fix "$fix" \
       --arg cat "$category" \
       '.failures[-1].root_cause = $rc | .failures[-1].fix = $fix | .failures[-1].category = $cat' \
       "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file"

    emit_event "memory.analyze" "stage=${stage}" "category=${category}"

    success "Failure analyzed: ${PURPLE}[${category}]${RESET} ${root_cause}"
}

# memory_capture_pattern <pattern_type> <pattern_data_json>
# Records codebase patterns (project type, framework, conventions).
memory_capture_pattern() {
    local pattern_type="${1:-}"
    local pattern_data="${2:-}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local patterns_file="$mem_dir/patterns.json"

    local repo
    repo="$(repo_name)"
    local captured_at
    captured_at="$(now_iso)"

    local tmp_file
    tmp_file=$(mktemp)

    case "$pattern_type" in
        project)
            # Detect project attributes
            local proj_type="unknown" framework="" test_runner="" pkg_mgr="" language=""

            if [[ -f "package.json" ]]; then
                proj_type="node"
                pkg_mgr="npm"
                [[ -f "pnpm-lock.yaml" ]] && pkg_mgr="pnpm"
                [[ -f "yarn.lock" ]] && pkg_mgr="yarn"
                [[ -f "bun.lockb" ]] && pkg_mgr="bun"

                framework=$(jq -r '
                    if .dependencies.next then "next"
                    elif .dependencies.express then "express"
                    elif .dependencies.fastify then "fastify"
                    elif .dependencies.react then "react"
                    elif .dependencies.vue then "vue"
                    elif .dependencies.svelte then "svelte"
                    else ""
                    end' package.json 2>/dev/null || echo "")

                test_runner=$(jq -r '
                    if .devDependencies.jest then "jest"
                    elif .devDependencies.vitest then "vitest"
                    elif .devDependencies.mocha then "mocha"
                    else ""
                    end' package.json 2>/dev/null || echo "")

                [[ -f "tsconfig.json" ]] && language="typescript" || language="javascript"
            elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]]; then
                proj_type="python"
                language="python"
                [[ -f "pyproject.toml" ]] && pkg_mgr="poetry" || pkg_mgr="pip"
                test_runner="pytest"
            elif [[ -f "go.mod" ]]; then
                proj_type="go"
                language="go"
                test_runner="go test"
            elif [[ -f "Cargo.toml" ]]; then
                proj_type="rust"
                language="rust"
                test_runner="cargo test"
                pkg_mgr="cargo"
            fi

            local source_dir=""
            [[ -d "src" ]] && source_dir="src/"
            [[ -d "lib" ]] && source_dir="lib/"
            [[ -d "app" ]] && source_dir="app/"

            local test_pattern=""
            if [[ -n "$(find . -maxdepth 3 -name '*.test.ts' 2>/dev/null | head -1)" ]]; then
                test_pattern="*.test.ts"
            elif [[ -n "$(find . -maxdepth 3 -name '*.test.js' 2>/dev/null | head -1)" ]]; then
                test_pattern="*.test.js"
            elif [[ -n "$(find . -maxdepth 3 -name '*_test.go' 2>/dev/null | head -1)" ]]; then
                test_pattern="*_test.go"
            elif [[ -n "$(find . -maxdepth 3 -name 'test_*.py' 2>/dev/null | head -1)" ]]; then
                test_pattern="test_*.py"
            fi

            local import_style="commonjs"
            if [[ -f "package.json" ]]; then
                local pkg_type
                pkg_type=$(jq -r '.type // "commonjs"' package.json 2>/dev/null || echo "commonjs")
                [[ "$pkg_type" == "module" ]] && import_style="esm"
            fi

            jq --arg repo "$repo" \
               --arg ts "$captured_at" \
               --arg type "$proj_type" \
               --arg fw "$framework" \
               --arg tr "$test_runner" \
               --arg pm "$pkg_mgr" \
               --arg lang "$language" \
               --arg sd "$source_dir" \
               --arg tp "$test_pattern" \
               --arg is "$import_style" \
               '. + {
                   repo: $repo,
                   captured_at: $ts,
                   project: {
                       type: $type,
                       framework: $fw,
                       test_runner: $tr,
                       package_manager: $pm,
                       language: $lang
                   },
                   conventions: {
                       source_dir: $sd,
                       test_pattern: $tp,
                       import_style: $is
                   }
               }' "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file"

            emit_event "memory.pattern" "type=project" "proj_type=${proj_type}" "framework=${framework}"
            success "Captured project patterns (${proj_type}/${framework:-none})"
            ;;

        known_issue)
            # pattern_data is the issue description string
            if [[ -n "$pattern_data" ]]; then
                jq --arg issue "$pattern_data" \
                   'if .known_issues then
                        if (.known_issues | index($issue)) then .
                        else .known_issues += [$issue]
                        end
                    else . + {known_issues: [$issue]}
                    end | .known_issues = (.known_issues | .[-50:])' \
                   "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file"
                emit_event "memory.pattern" "type=known_issue"
            fi
            ;;

        *)
            warn "Unknown pattern type: ${pattern_type}"
            return 1
            ;;
    esac
}

# memory_inject_context <stage_id>
# Returns a text block of relevant memory for a given pipeline stage.
# When intelligence engine is available, uses AI-ranked search for better relevance.
memory_inject_context() {
    local stage_id="${1:-}"

    # Try intelligence-ranked search first
    if type intelligence_search_memory &>/dev/null 2>&1; then
        local config="${REPO_DIR:-.}/.claude/daemon-config.json"
        local intel_enabled="false"
        if [[ -f "$config" ]]; then
            intel_enabled=$(jq -r '.intelligence.enabled // false' "$config" 2>/dev/null || echo "false")
        fi
        if [[ "$intel_enabled" == "true" ]]; then
            local ranked_result
            ranked_result=$(intelligence_search_memory "$stage_id stage context" "$(repo_memory_dir)" 5 2>/dev/null || echo "")
            if [[ -n "$ranked_result" ]] && [[ "$ranked_result" != *'"error"'* ]]; then
                echo "$ranked_result"
                return 0
            fi
        fi
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Check that we have memory to inject
    local has_memory=false
    for f in "$mem_dir/patterns.json" "$mem_dir/failures.json" "$mem_dir/decisions.json"; do
        if [[ -f "$f" ]] && [[ "$(wc -c < "$f")" -gt 5 ]]; then
            has_memory=true
            break
        fi
    done

    if [[ "$has_memory" == "false" ]]; then
        echo "# No memory available for this repository yet."
        return 0
    fi

    echo "# Shipwright Memory Context"
    echo "# Injected at: $(now_iso)"
    echo "# Stage: ${stage_id}"
    echo ""

    case "$stage_id" in
        plan|design)
            # Past design decisions + codebase patterns
            echo "## Codebase Patterns"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                local proj_type framework lang
                proj_type=$(jq -r '.project.type // "unknown"' "$mem_dir/patterns.json" 2>/dev/null)
                framework=$(jq -r '.project.framework // ""' "$mem_dir/patterns.json" 2>/dev/null)
                lang=$(jq -r '.project.language // ""' "$mem_dir/patterns.json" 2>/dev/null)
                echo "- Project: ${proj_type} / ${framework:-no framework} / ${lang:-unknown}"

                local src_dir test_pat
                src_dir=$(jq -r '.conventions.source_dir // ""' "$mem_dir/patterns.json" 2>/dev/null)
                test_pat=$(jq -r '.conventions.test_pattern // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$src_dir" ]] && echo "- Source directory: ${src_dir}"
                [[ -n "$test_pat" ]] && echo "- Test file pattern: ${test_pat}"
            fi

            echo ""
            echo "## Past Design Decisions"
            if [[ -f "$mem_dir/decisions.json" ]]; then
                jq -r '.decisions[-5:][] | "- [\(.type // "decision")] \(.summary // .description // "no description")"' \
                    "$mem_dir/decisions.json" 2>/dev/null || echo "- No decisions recorded yet."
            fi

            echo ""
            echo "## Known Issues"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                jq -r '.known_issues // [] | .[] | "- \(.)"' "$mem_dir/patterns.json" 2>/dev/null || true
            fi
            ;;

        build)
            # Failure patterns to avoid — ranked by relevance (recency + effectiveness + frequency)
            echo "## Failure Patterns to Avoid"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r 'now as $now |
                    .failures | map(. +
                        { relevance_score:
                            ((.seen_count // 1) * 1) +
                            (if .fix_effectiveness_rate then (.fix_effectiveness_rate / 10) else 0 end) +
                            (if .last_seen then
                                (($now - ((.last_seen | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) // 0)) |
                                 if . < 86400 then 5
                                 elif . < 604800 then 3
                                 elif . < 2592000 then 1
                                 else 0 end)
                            else 0 end)
                        }
                    ) | sort_by(-.relevance_score) | .[:10][] |
                    "- [\(.stage)] \(.pattern) (seen \(.seen_count)x)" +
                    if .fix != "" then
                        "\n  Fix: \(.fix)" +
                        if .fix_effectiveness_rate then " (effectiveness: \(.fix_effectiveness_rate)%)" else "" end
                    else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No failures recorded."
            fi

            echo ""
            echo "## Known Fixes"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.root_cause != "" and .fix != "" and .stage == "build") |
                    "- [\(.category // "unknown")] \(.root_cause)\n  Fix: \(.fix)" +
                    if .fix_effectiveness_rate then " (effectiveness: \(.fix_effectiveness_rate)%)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No analyzed fixes yet."
            else
                echo "- No analyzed fixes yet."
            fi

            echo ""
            echo "## Code Conventions"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                local import_style
                import_style=$(jq -r '.conventions.import_style // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$import_style" ]] && echo "- Import style: ${import_style}"
                local test_runner
                test_runner=$(jq -r '.project.test_runner // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$test_runner" ]] && echo "- Test runner: ${test_runner}"
            fi
            ;;

        test)
            # Known flaky tests + coverage baselines
            echo "## Known Test Failures"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.stage == "test") |
                    "- \(.pattern) (seen \(.seen_count)x)" +
                    if .fix != "" then "\n  Fix: \(.fix)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No test failures recorded."
            fi

            echo ""
            echo "## Known Fixes"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.root_cause != "" and .fix != "" and .stage == "test") |
                    "- [\(.category // "unknown")] \(.root_cause)\n  Fix: \(.fix)"' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No analyzed fixes yet."
            else
                echo "- No analyzed fixes yet."
            fi

            echo ""
            echo "## Performance Baselines"
            if [[ -f "$mem_dir/metrics.json" ]]; then
                local test_dur coverage
                test_dur=$(jq -r '.baselines.test_duration_s // "not tracked"' "$mem_dir/metrics.json" 2>/dev/null)
                coverage=$(jq -r '.baselines.coverage_pct // "not tracked"' "$mem_dir/metrics.json" 2>/dev/null)
                echo "- Test duration baseline: ${test_dur}s"
                echo "- Coverage baseline: ${coverage}%"
            fi
            ;;

        review|compound_quality)
            # Past review feedback patterns
            echo "## Common Review Feedback"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.stage == "review") |
                    "- \(.pattern)"' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No review patterns recorded."
            fi

            echo ""
            echo "## Cross-Repo Learnings"
            if [[ -f "$GLOBAL_MEMORY" ]]; then
                jq -r '.cross_repo_learnings[-5:][] |
                    "- [\(.repo)] \(.type): \(.bugs // 0) bugs, \(.warnings // 0) warnings"' \
                    "$GLOBAL_MEMORY" 2>/dev/null || true
            fi
            ;;

        *)
            # Generic context for any stage — inject top-K most relevant across all categories
            echo "## Repository Patterns"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                jq -r 'to_entries | map(select(.key != "known_issues")) | from_entries' \
                    "$mem_dir/patterns.json" 2>/dev/null || true
            fi

            # Inject top failures regardless of category (ranked by relevance)
            echo ""
            echo "## Relevant Failure Patterns"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r --arg stg "$stage_id" \
                    '.failures |
                     map(. + { stage_match: (if .stage == $stg then 10 else 0 end) }) |
                     sort_by(-(.seen_count + .stage_match + (.fix_effectiveness_rate // 0) / 10)) |
                     .[:5][] |
                     "- [\(.stage)] \(.pattern[:80]) (seen \(.seen_count)x)" +
                     if .fix != "" then "\n  Fix: \(.fix)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- None recorded."
            fi

            # Inject recent decisions
            echo ""
            echo "## Recent Decisions"
            if [[ -f "$mem_dir/decisions.json" ]]; then
                jq -r '.decisions[-3:][] |
                    "- [\(.type // "decision")] \(.summary // "no description")"' \
                    "$mem_dir/decisions.json" 2>/dev/null || echo "- None recorded."
            fi
            ;;
    esac

    # ── Cross-repo memory injection (global learnings) ──
    if [[ -f "$GLOBAL_MEMORY" ]]; then
        local global_patterns
        global_patterns=$(jq -r --arg stage "$stage_id" '
            .common_patterns // [] | .[] |
            select(.category == $stage or .category == "general" or .category == null) |
            .summary // .description // empty
        ' "$GLOBAL_MEMORY" 2>/dev/null | head -5 || true)

        local cross_repo_learnings
        cross_repo_learnings=$(jq -r '
            .cross_repo_learnings // [] | .[-5:][] |
            "- [\(.repo // "unknown")] \(.type // "learning"): bugs=\(.bugs // 0), warnings=\(.warnings // 0)"
        ' "$GLOBAL_MEMORY" 2>/dev/null | head -5 || true)

        if [[ -n "$global_patterns" || -n "$cross_repo_learnings" ]]; then
            echo ""
            echo "## Cross-Repo Learnings (Global)"
            [[ -n "$global_patterns" ]] && echo "$global_patterns"
            [[ -n "$cross_repo_learnings" ]] && echo "$cross_repo_learnings"
        fi
    fi

    echo ""
    emit_event "memory.inject" "stage=${stage_id}"
}

# memory_get_actionable_failures [threshold]
# Returns JSON array of failure patterns with seen_count >= threshold.
# Used by daemon patrol to detect recurring failures worth fixing.
memory_get_actionable_failures() {
    local threshold="${1:-3}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    if [[ ! -f "$failures_file" ]]; then
        echo "[]"
        return 0
    fi

    jq --argjson t "$threshold" \
        '[.failures[] | select(.seen_count >= $t)] | sort_by(-.seen_count)' \
        "$failures_file" 2>/dev/null || echo "[]"
}

# memory_get_dora_baseline [window_days] [offset_days]
# Calculates DORA metrics for a time window from events.jsonl.
# Returns JSON: {deploy_freq, cycle_time, cfr, mttr, total, grades: {df, ct, cfr, mttr}}
memory_get_dora_baseline() {
    local window_days="${1:-7}"
    local offset_days="${2:-0}"

    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}'
        return 0
    fi

    local now_e
    now_e=$(now_epoch)
    local window_end=$((now_e - offset_days * 86400))
    local window_start=$((window_end - window_days * 86400))

    # Extract pipeline events for the window
    local metrics
    metrics=$(jq -s --argjson start "$window_start" --argjson end "$window_end" '
        [.[] | select(.ts_epoch >= $start and .ts_epoch < $end)] as $events |
        [$events[] | select(.type == "pipeline.completed")] as $completed |
        ($completed | length) as $total |
        [$completed[] | select(.result == "success")] as $successes |
        [$completed[] | select(.result == "failure")] as $failures |
        ($successes | length) as $success_count |
        ($failures | length) as $failure_count |

        # Deploy frequency (per week)
        (if $total > 0 then ($success_count * 7 / '"$window_days"') else 0 end) as $deploy_freq |

        # Cycle time median
        ([$successes[] | .duration_s] | sort |
            if length > 0 then .[length/2 | floor] else 0 end) as $cycle_time |

        # Change failure rate
        (if $total > 0 then ($failure_count / $total * 100) else 0 end) as $cfr |

        # MTTR
        ($completed | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ) as $mttr |

        {
            deploy_freq: ($deploy_freq * 10 | floor / 10),
            cycle_time: $cycle_time,
            cfr: ($cfr * 10 | floor / 10),
            mttr: $mttr,
            total: $total
        }
    ' "$events_file" 2>/dev/null || echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}')

    echo "$metrics"
}

# memory_get_baseline <metric_name>
# Output baseline value for a metric (bundle_size_kb, test_duration_s, coverage_pct, etc.).
# Used by pipeline for regression checks. Outputs nothing if not set.
memory_get_baseline() {
    local metric_name="${1:-}"
    [[ -z "$metric_name" ]] && return 1
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local metrics_file="$mem_dir/metrics.json"
    [[ ! -f "$metrics_file" ]] && return 0
    jq -r --arg m "$metric_name" '.baselines[$m] // empty' "$metrics_file" 2>/dev/null || true
}

# memory_update_metrics <metric_name> <value>
# Track performance baselines and flag regressions.
memory_update_metrics() {
    local metric_name="${1:-}"
    local value="${2:-}"

    [[ -z "$metric_name" || -z "$value" ]] && return 1

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local metrics_file="$mem_dir/metrics.json"

    # Read previous baseline
    local previous
    previous=$(jq -r --arg m "$metric_name" '.baselines[$m] // 0' "$metrics_file" 2>/dev/null || echo "0")

    # Check for regression (>20% increase for duration metrics)
    if [[ "$previous" != "0" && "$previous" != "null" ]]; then
        local threshold
        threshold=$(echo "$previous" | awk '{printf "%.0f", $1 * 1.2}')
        if [[ "${metric_name}" == *"duration"* || "${metric_name}" == *"time"* ]]; then
            if [[ "$(echo "$value $threshold" | awk '{print ($1 > $2)}')" == "1" ]]; then
                warn "Regression detected: ${metric_name} increased from ${previous} to ${value} (>20%)"
                emit_event "memory.regression" "metric=${metric_name}" "previous=${previous}" "current=${value}"
            fi
        fi
    fi

    # Update baseline using atomic write
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg m "$metric_name" \
       --argjson v "$value" \
       --arg ts "$(now_iso)" \
       '.baselines[$m] = $v | .last_updated = $ts' \
       "$metrics_file" > "$tmp_file" && mv "$tmp_file" "$metrics_file"

    emit_event "memory.metric" "metric=${metric_name}" "value=${value}"
}

# memory_capture_decision <type> <summary> <detail>
# Record a design decision / ADR.
memory_capture_decision() {
    local dec_type="${1:-decision}"
    local summary="${2:-}"
    local detail="${3:-}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local decisions_file="$mem_dir/decisions.json"

    local tmp_file
    tmp_file=$(mktemp)
    jq --arg type "$dec_type" \
       --arg summary "$summary" \
       --arg detail "$detail" \
       --arg ts "$(now_iso)" \
       '.decisions += [{
           type: $type,
           summary: $summary,
           detail: $detail,
           recorded_at: $ts
       }] | .decisions = (.decisions | .[-100:])' \
       "$decisions_file" > "$tmp_file" && mv "$tmp_file" "$decisions_file"

    emit_event "memory.decision" "type=${dec_type}" "summary=${summary:0:80}"
    success "Recorded decision: ${summary}"
}

# ─── CLI Display Commands ──────────────────────────────────────────────────

memory_show() {
    local show_global=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) show_global=true; shift ;;
            *)        shift ;;
        esac
    done

    if [[ "$show_global" == "true" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Global Memory ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        if [[ -f "$GLOBAL_MEMORY" ]]; then
            local learning_count
            learning_count=$(jq '.cross_repo_learnings | length' "$GLOBAL_MEMORY" 2>/dev/null || echo 0)
            echo -e "  Cross-repo learnings: ${CYAN}${learning_count}${RESET}"
            echo ""
            if [[ "$learning_count" -gt 0 ]]; then
                jq -r '.cross_repo_learnings[-10:][] |
                    "  \(.repo) — \(.type) (\(.captured_at // "unknown"))"' \
                    "$GLOBAL_MEMORY" 2>/dev/null || true
            fi
        else
            echo -e "  ${DIM}No global memory yet.${RESET}"
        fi
        echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        return 0
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory: ${repo} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # Patterns
    echo -e "${BOLD}  PROJECT${RESET}"
    if [[ -f "$mem_dir/patterns.json" ]]; then
        local proj_type framework lang pkg_mgr test_runner
        proj_type=$(jq -r '.project.type // "unknown"' "$mem_dir/patterns.json" 2>/dev/null)
        framework=$(jq -r '.project.framework // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        lang=$(jq -r '.project.language // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        pkg_mgr=$(jq -r '.project.package_manager // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        test_runner=$(jq -r '.project.test_runner // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        printf "    %-18s %s\n" "Type:" "$proj_type"
        printf "    %-18s %s\n" "Framework:" "$framework"
        printf "    %-18s %s\n" "Language:" "$lang"
        printf "    %-18s %s\n" "Package manager:" "$pkg_mgr"
        printf "    %-18s %s\n" "Test runner:" "$test_runner"
    else
        echo -e "    ${DIM}No patterns captured yet.${RESET}"
    fi
    echo ""

    # Failures
    echo -e "${BOLD}  FAILURE PATTERNS${RESET}"
    if [[ -f "$mem_dir/failures.json" ]]; then
        local failure_count
        failure_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null || echo 0)
        if [[ "$failure_count" -gt 0 ]]; then
            jq -r '.failures | sort_by(-.seen_count) | .[:5][] |
                "    [\(.stage)] \(.pattern[:80]) — seen \(.seen_count)x"' \
                "$mem_dir/failures.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No failures recorded.${RESET}"
        fi
    else
        echo -e "    ${DIM}No failures recorded.${RESET}"
    fi
    echo ""

    # Decisions
    echo -e "${BOLD}  DECISIONS${RESET}"
    if [[ -f "$mem_dir/decisions.json" ]]; then
        local decision_count
        decision_count=$(jq '.decisions | length' "$mem_dir/decisions.json" 2>/dev/null || echo 0)
        if [[ "$decision_count" -gt 0 ]]; then
            jq -r '.decisions[-5:][] |
                "    [\(.type)] \(.summary)"' \
                "$mem_dir/decisions.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No decisions recorded.${RESET}"
        fi
    else
        echo -e "    ${DIM}No decisions recorded.${RESET}"
    fi
    echo ""

    # Metrics
    echo -e "${BOLD}  BASELINES${RESET}"
    if [[ -f "$mem_dir/metrics.json" ]]; then
        local baseline_count
        baseline_count=$(jq '.baselines | length' "$mem_dir/metrics.json" 2>/dev/null || echo 0)
        if [[ "$baseline_count" -gt 0 ]]; then
            jq -r '.baselines | to_entries[] | "    \(.key): \(.value)"' \
                "$mem_dir/metrics.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No baselines tracked yet.${RESET}"
        fi
    else
        echo -e "    ${DIM}No baselines tracked yet.${RESET}"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

memory_search() {
    local keyword="${1:-}"

    if [[ -z "$keyword" ]]; then
        error "Usage: shipwright memory search <keyword>"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory Search: \"${keyword}\" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    local found=0

    # ── Semantic search via intelligence (if available) ──
    if type intelligence_search_memory &>/dev/null 2>&1; then
        local semantic_results
        semantic_results=$(intelligence_search_memory "$keyword" "$mem_dir" 5 2>/dev/null || echo "")
        if [[ -n "$semantic_results" ]] && echo "$semantic_results" | jq -e '.results | length > 0' &>/dev/null; then
            echo -e "  ${BOLD}${CYAN}Semantic Results (AI-ranked):${RESET}"
            local result_count
            result_count=$(echo "$semantic_results" | jq '.results | length')
            local i=0
            while [[ "$i" -lt "$result_count" ]]; do
                local file rel summary
                file=$(echo "$semantic_results" | jq -r ".results[$i].file // \"\"")
                rel=$(echo "$semantic_results" | jq -r ".results[$i].relevance // 0")
                summary=$(echo "$semantic_results" | jq -r ".results[$i].summary // \"\"")
                echo -e "    ${GREEN}●${RESET} [${rel}%] ${BOLD}${file}${RESET} — ${summary}"
                i=$((i + 1))
            done
            echo ""
            found=$((found + 1))

            # Also run grep search below for completeness
            echo -e "  ${DIM}Grep results (supplemental):${RESET}"
            echo ""
        fi
    fi

    # ── Grep-based search (fallback / supplemental) ──

    # Search patterns
    if [[ -f "$mem_dir/patterns.json" ]]; then
        local pattern_matches
        pattern_matches=$(grep -i "$keyword" "$mem_dir/patterns.json" 2>/dev/null || true)
        if [[ -n "$pattern_matches" ]]; then
            echo -e "  ${BOLD}Patterns:${RESET}"
            echo "$pattern_matches" | head -5 | sed 's/^/    /'
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search failures
    if [[ -f "$mem_dir/failures.json" ]]; then
        local failure_matches
        failure_matches=$(jq -r --arg kw "$keyword" \
            '.failures[] | select(.pattern | test($kw; "i")) |
            "    [\(.stage)] \(.pattern[:80]) — seen \(.seen_count)x"' \
            "$mem_dir/failures.json" 2>/dev/null || true)
        if [[ -n "$failure_matches" ]]; then
            echo -e "  ${BOLD}Failures:${RESET}"
            echo "$failure_matches" | head -5
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search decisions
    if [[ -f "$mem_dir/decisions.json" ]]; then
        local decision_matches
        decision_matches=$(jq -r --arg kw "$keyword" \
            '.decisions[] | select((.summary // "") | test($kw; "i")) |
            "    [\(.type)] \(.summary)"' \
            "$mem_dir/decisions.json" 2>/dev/null || true)
        if [[ -n "$decision_matches" ]]; then
            echo -e "  ${BOLD}Decisions:${RESET}"
            echo "$decision_matches" | head -5
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search global memory
    if [[ -f "$GLOBAL_MEMORY" ]]; then
        local global_matches
        global_matches=$(grep -i "$keyword" "$GLOBAL_MEMORY" 2>/dev/null || true)
        if [[ -n "$global_matches" ]]; then
            echo -e "  ${BOLD}Global Memory:${RESET}"
            echo "$global_matches" | head -3 | sed 's/^/    /'
            echo ""
            found=$((found + 1))
        fi
    fi

    if [[ "$found" -eq 0 ]]; then
        echo -e "  ${DIM}No matches found for \"${keyword}\".${RESET}"
    fi

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

memory_forget() {
    local forget_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) forget_all=true; shift ;;
            *)     shift ;;
        esac
    done

    if [[ "$forget_all" == "true" ]]; then
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        if [[ -d "$mem_dir" ]]; then
            rm -rf "$mem_dir"
            success "Cleared all memory for $(repo_name)"
            emit_event "memory.forget" "repo=$(repo_name)" "scope=all"
        else
            warn "No memory found for this repository."
        fi
    else
        error "Usage: shipwright memory forget --all"
        echo -e "  ${DIM}Use --all to confirm clearing memory for this repo.${RESET}"
        return 1
    fi
}

memory_export() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Merge all memory files into a single JSON export
    local export_json
    export_json=$(jq -n \
        --arg repo "$(repo_name)" \
        --arg hash "$(repo_hash)" \
        --arg ts "$(now_iso)" \
        --slurpfile patterns "$mem_dir/patterns.json" \
        --slurpfile failures "$mem_dir/failures.json" \
        --slurpfile decisions "$mem_dir/decisions.json" \
        --slurpfile metrics "$mem_dir/metrics.json" \
        '{
            exported_at: $ts,
            repo: $repo,
            repo_hash: $hash,
            patterns: $patterns[0],
            failures: $failures[0],
            decisions: $decisions[0],
            metrics: $metrics[0]
        }')

    echo "$export_json"
    emit_event "memory.export" "repo=$(repo_name)"
}

memory_import() {
    local import_file="${1:-}"

    if [[ -z "$import_file" || ! -f "$import_file" ]]; then
        error "Usage: shipwright memory import <file.json>"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$import_file" 2>/dev/null; then
        error "Invalid JSON file: $import_file"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Extract and write each section
    local tmp_file
    tmp_file=$(mktemp)

    jq '.patterns // {}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/patterns.json"
    jq '.failures // {"failures":[]}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/failures.json"
    jq '.decisions // {"decisions":[]}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/decisions.json"
    jq '.metrics // {"baselines":{}}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/metrics.json"

    success "Imported memory from ${import_file}"
    emit_event "memory.import" "repo=$(repo_name)" "file=${import_file}"
}

memory_stats() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory Stats: ${repo} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # Size
    local total_size=0
    for f in "$mem_dir"/*.json; do
        if [[ -f "$f" ]]; then
            local fsize
            fsize=$(wc -c < "$f" | tr -d ' ')
            total_size=$((total_size + fsize))
        fi
    done

    local size_human
    if [[ "$total_size" -ge 1048576 ]]; then
        size_human="$(echo "$total_size" | awk '{printf "%.1fMB", $1/1048576}')"
    elif [[ "$total_size" -ge 1024 ]]; then
        size_human="$(echo "$total_size" | awk '{printf "%.1fKB", $1/1024}')"
    else
        size_human="${total_size}B"
    fi

    echo -e "  ${BOLD}Storage${RESET}"
    printf "    %-18s %s\n" "Total size:" "$size_human"
    printf "    %-18s %s\n" "Location:" "$mem_dir"
    echo ""

    # Counts
    local failure_count decision_count baseline_count known_issue_count
    failure_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null || echo 0)
    decision_count=$(jq '.decisions | length' "$mem_dir/decisions.json" 2>/dev/null || echo 0)
    baseline_count=$(jq '.baselines | length' "$mem_dir/metrics.json" 2>/dev/null || echo 0)
    known_issue_count=$(jq '.known_issues // [] | length' "$mem_dir/patterns.json" 2>/dev/null || echo 0)

    echo -e "  ${BOLD}Contents${RESET}"
    printf "    %-18s %s\n" "Failure patterns:" "$failure_count"
    printf "    %-18s %s\n" "Decisions:" "$decision_count"
    printf "    %-18s %s\n" "Baselines:" "$baseline_count"
    printf "    %-18s %s\n" "Known issues:" "$known_issue_count"
    echo ""

    # Age — oldest captured_at
    local captured_at
    captured_at=$(jq -r '.captured_at // ""' "$mem_dir/patterns.json" 2>/dev/null || echo "")
    if [[ -n "$captured_at" && "$captured_at" != "null" ]]; then
        printf "    %-18s %s\n" "First captured:" "$captured_at"
    fi

    # Event-based hit rate
    local inject_count capture_count
    if [[ -f "$EVENTS_FILE" ]]; then
        inject_count=$(grep -c '"memory.inject"' "$EVENTS_FILE" 2>/dev/null || echo 0)
        capture_count=$(grep -c '"memory.capture"' "$EVENTS_FILE" 2>/dev/null || echo 0)
        echo ""
        echo -e "  ${BOLD}Usage${RESET}"
        printf "    %-18s %s\n" "Context injections:" "$inject_count"
        printf "    %-18s %s\n" "Pipeline captures:" "$capture_count"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright memory${RESET} ${DIM}v${VERSION}${RESET} — Persistent Learning & Context System"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright memory${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show${RESET}               Display memory for current repo"
    echo -e "  ${CYAN}show${RESET} --global       Display cross-repo learnings"
    echo -e "  ${CYAN}search${RESET} <keyword>    Search memory for keyword"
    echo -e "  ${CYAN}forget${RESET} --all         Clear memory for current repo"
    echo -e "  ${CYAN}export${RESET}              Export memory as JSON"
    echo -e "  ${CYAN}import${RESET} <file>        Import memory from JSON"
    echo -e "  ${CYAN}stats${RESET}               Show memory size, age, hit rate"
    echo ""
    echo -e "${BOLD}PIPELINE INTEGRATION${RESET}"
    echo -e "  ${CYAN}capture${RESET} <state> <artifacts>    Capture pipeline learnings"
    echo -e "  ${CYAN}inject${RESET} <stage_id>              Inject context for a stage"
    echo -e "  ${CYAN}pattern${RESET} <type> [data]           Record a codebase pattern"
    echo -e "  ${CYAN}metric${RESET} <name> <value>           Update a performance baseline"
    echo -e "  ${CYAN}decision${RESET} <type> <summary>       Record a design decision"
    echo -e "  ${CYAN}analyze-failure${RESET} <log> <stage>    Analyze failure root cause via AI"
    echo -e "  ${CYAN}fix-outcome${RESET} <pattern> <applied> <resolved>  Record fix effectiveness"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright memory show${RESET}                            # View repo memory"
    echo -e "  ${DIM}shipwright memory show --global${RESET}                   # View cross-repo learnings"
    echo -e "  ${DIM}shipwright memory search \"auth\"${RESET}                   # Find auth-related memories"
    echo -e "  ${DIM}shipwright memory export > backup.json${RESET}            # Export memory"
    echo -e "  ${DIM}shipwright memory import backup.json${RESET}              # Import memory"
    echo -e "  ${DIM}shipwright memory capture .claude/pipeline-state.md .claude/pipeline-artifacts${RESET}"
    echo -e "  ${DIM}shipwright memory inject build${RESET}                    # Get context for build stage"
}

# ─── Command Router ─────────────────────────────────────────────────────────

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
    show)
        memory_show "$@"
        ;;
    search)
        memory_search "$@"
        ;;
    forget)
        memory_forget "$@"
        ;;
    export)
        memory_export
        ;;
    import)
        memory_import "$@"
        ;;
    stats)
        memory_stats
        ;;
    capture)
        memory_capture_pipeline "$@"
        ;;
    inject)
        memory_inject_context "$@"
        ;;
    pattern)
        memory_capture_pattern "$@"
        ;;
    get)
        memory_get_baseline "$@"
        ;;
    metric)
        memory_update_metrics "$@"
        ;;
    decision)
        memory_capture_decision "$@"
        ;;
    analyze-failure)
        memory_analyze_failure "$@"
        ;;
    fix-outcome)
        memory_record_fix_outcome "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        error "Unknown command: ${SUBCOMMAND}"
        echo ""
        show_help
        exit 1
        ;;
esac
