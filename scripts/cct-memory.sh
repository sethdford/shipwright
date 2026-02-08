#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct memory — Persistent Learning & Context System                     ║
# ║  Captures learnings · Injects context · Searches memory · Tracks metrics║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.6.0"
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

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.claude-teams/events.jsonl"

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
    mkdir -p "${HOME}/.claude-teams"
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

    local tmp_file
    tmp_file=$(mktemp)

    if [[ "$existing_idx" != "-1" && "$existing_idx" != "null" ]]; then
        # Update existing entry
        jq --argjson idx "$existing_idx" \
           --arg ts "$(now_iso)" \
           '.failures[$idx].seen_count += 1 | .failures[$idx].last_seen = $ts' \
           "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file"
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
           "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file"
    fi

    emit_event "memory.failure" "stage=${stage}" "pattern=${pattern:0:80}"
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
memory_inject_context() {
    local stage_id="${1:-}"

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
            # Failure patterns to avoid + code conventions
            echo "## Failure Patterns to Avoid"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures | sort_by(-.seen_count) | .[:10][] |
                    "- [\(.stage)] \(.pattern) (seen \(.seen_count)x)" +
                    if .fix != "" then "\n  Fix: \(.fix)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No failures recorded."
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
            # Generic context for any other stage
            echo "## Repository Patterns"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                jq -r 'to_entries | map(select(.key != "known_issues")) | from_entries' \
                    "$mem_dir/patterns.json" 2>/dev/null || true
            fi
            ;;
    esac

    echo ""
    emit_event "memory.inject" "stage=${stage_id}"
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
    echo -e "${CYAN}${BOLD}cct memory${RESET} ${DIM}v${VERSION}${RESET} — Persistent Learning & Context System"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}cct memory${RESET} <command> [options]"
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
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}cct memory show${RESET}                            # View repo memory"
    echo -e "  ${DIM}cct memory show --global${RESET}                   # View cross-repo learnings"
    echo -e "  ${DIM}cct memory search \"auth\"${RESET}                   # Find auth-related memories"
    echo -e "  ${DIM}cct memory export > backup.json${RESET}            # Export memory"
    echo -e "  ${DIM}cct memory import backup.json${RESET}              # Import memory"
    echo -e "  ${DIM}cct memory capture .claude/pipeline-state.md .claude/pipeline-artifacts${RESET}"
    echo -e "  ${DIM}cct memory inject build${RESET}                    # Get context for build stage"
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
    metric)
        memory_update_metrics "$@"
        ;;
    decision)
        memory_capture_decision "$@"
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
