#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fix — Bulk Fix Across Multiple Repos                              ║
# ║  Clone a goal across repos · Run pipelines in parallel · Collect PRs    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.7.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

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

# ─── Defaults ───────────────────────────────────────────────────────────────
FIX_DIR="${HOME}/.claude-teams"
GOAL=""
REPOS=()
REPOS_FROM=""
TEMPLATE="fast"
MODEL=""
MAX_PARALLEL=3
DRY_RUN=false
BRANCH_PREFIX="fix/"

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright fix${RESET} — Bulk fix across multiple repos"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright fix${RESET} \"goal\" [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${DIM}--repos dir1,dir2,...${RESET}     Comma-separated repo paths"
    echo -e "  ${DIM}--repos-from file${RESET}         Read repo paths from file (one per line)"
    echo -e "  ${DIM}--pipeline template${RESET}       Pipeline template (default: fast)"
    echo -e "  ${DIM}--model model${RESET}             Model to use (default: auto)"
    echo -e "  ${DIM}--max-parallel N${RESET}          Max concurrent pipelines (default: 3)"
    echo -e "  ${DIM}--branch-prefix prefix${RESET}    Branch name prefix (default: \"fix/\")"
    echo -e "  ${DIM}--dry-run${RESET}                 Show what would happen without executing"
    echo -e "  ${DIM}--status${RESET}                  Show running fix sessions"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright fix \"Update lodash to 4.17.21\" --repos ~/api,~/web,~/mobile${RESET}"
    echo -e "  ${DIM}shipwright fix \"Fix SQL injection in auth\" --repos ~/api --pipeline fast${RESET}"
    echo -e "  ${DIM}shipwright fix \"Bump Node to 22\" --repos-from repos.txt --pipeline hotfix${RESET}"
    echo -e "  ${DIM}shipwright fix --status${RESET}"
    echo ""
}

# ─── Argument Parsing ───────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repos)
                IFS=',' read -ra REPOS <<< "$2"
                shift 2
                ;;
            --repos-from)
                REPOS_FROM="$2"
                shift 2
                ;;
            --pipeline)
                TEMPLATE="$2"
                shift 2
                ;;
            --model)
                MODEL="$2"
                shift 2
                ;;
            --max-parallel)
                MAX_PARALLEL="$2"
                shift 2
                ;;
            --branch-prefix)
                BRANCH_PREFIX="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --status)
                fix_status
                exit 0
                ;;
            help|--help|-h)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "$GOAL" && ! "$1" =~ ^-- ]]; then
                    GOAL="$1"
                fi
                shift
                ;;
        esac
    done

    # Load repos from file if specified
    if [[ -n "$REPOS_FROM" ]]; then
        if [[ ! -f "$REPOS_FROM" ]]; then
            error "Repos file not found: $REPOS_FROM"
            exit 1
        fi
        while IFS= read -r line; do
            line="${line%%#*}"    # strip comments
            line="${line// /}"    # strip whitespace
            if [[ -n "$line" ]]; then
                REPOS+=("$line")
            fi
        done < "$REPOS_FROM"
    fi
}

# ─── Sanitize Goal for Branch Names ────────────────────────────────────────

sanitize_branch() {
    local raw="$1"
    # Lowercase, replace spaces/special chars with hyphens, truncate
    echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50
}

# ─── Fix Status ─────────────────────────────────────────────────────────────

fix_status() {
    local fix_files
    fix_files=$(find "$FIX_DIR" -name 'fix-*.json' -maxdepth 1 2>/dev/null | sort -r) || true

    if [[ -z "$fix_files" ]]; then
        info "No fix sessions found."
        return
    fi

    echo -e "${CYAN}${BOLD}═══ Fix Sessions ═══${RESET}"
    echo ""

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local goal status repo_count started
        goal=$(jq -r '.goal // "unknown"' "$f" 2>/dev/null) || goal="unknown"
        status=$(jq -r '.status // "unknown"' "$f" 2>/dev/null) || status="unknown"
        repo_count=$(jq -r '.repos | length // 0' "$f" 2>/dev/null) || repo_count=0
        started=$(jq -r '.started // "unknown"' "$f" 2>/dev/null) || started="unknown"

        local status_color="$YELLOW"
        [[ "$status" == "completed" ]] && status_color="$GREEN"
        [[ "$status" == "failed" ]]    && status_color="$RED"

        echo -e "  ${BOLD}${goal}${RESET}"
        echo -e "    Status: ${status_color}${status}${RESET}  |  Repos: ${repo_count}  |  Started: ${DIM}${started}${RESET}"

        # Show per-repo status
        local repo_statuses
        repo_statuses=$(jq -r '.repos[]? | "\(.name)|\(.status // "pending")|\(.pr_url // "-")|\(.duration // "-")"' "$f" 2>/dev/null) || true
        if [[ -n "$repo_statuses" ]]; then
            while IFS='|' read -r rname rstatus rpr rdur; do
                local ricon="⋯"
                [[ "$rstatus" == "pass" ]] && ricon="${GREEN}✓${RESET}"
                [[ "$rstatus" == "fail" ]] && ricon="${RED}✗${RESET}"
                echo -e "      ${ricon} ${rname}  ${DIM}${rstatus}${RESET}  ${DIM}${rpr}${RESET}"
            done <<< "$repo_statuses"
        fi
        echo ""
    done <<< "$fix_files"
}

# ─── Fix Start ──────────────────────────────────────────────────────────────

fix_start() {
    # Validate
    if [[ -z "$GOAL" ]]; then
        error "Goal is required."
        echo -e "  Example: ${DIM}shipwright fix \"Update lodash to 4.17.21\" --repos ~/api,~/web${RESET}"
        exit 1
    fi

    if [[ ${#REPOS[@]} -eq 0 ]]; then
        error "No repos specified. Use --repos or --repos-from."
        exit 1
    fi

    # Validate repos exist
    for repo in "${REPOS[@]}"; do
        local expanded
        expanded=$(eval echo "$repo")
        if [[ ! -d "$expanded" ]]; then
            error "Repo directory not found: $expanded"
            exit 1
        fi
        if [[ ! -d "$expanded/.git" ]]; then
            warn "Not a git repo: $expanded (skipping)"
        fi
    done

    local sanitized
    sanitized=$(sanitize_branch "$GOAL")
    local branch_name="${BRANCH_PREFIX}${sanitized}"
    local session_id="fix-$(date +%s)"
    local state_file="$FIX_DIR/${session_id}.json"
    local log_dir="$FIX_DIR/${session_id}-logs"
    local start_epoch
    start_epoch=$(now_epoch)

    mkdir -p "$FIX_DIR" "$log_dir"

    # ─── Header ─────────────────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Shipwright Fix                                              ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}       $GOAL"
    echo -e "  ${BOLD}Repos:${RESET}      ${#REPOS[@]}"
    echo -e "  ${BOLD}Pipeline:${RESET}   $TEMPLATE"
    echo -e "  ${BOLD}Branch:${RESET}     $branch_name"
    echo -e "  ${BOLD}Parallel:${RESET}   $MAX_PARALLEL"
    [[ -n "$MODEL" ]] && echo -e "  ${BOLD}Model:${RESET}      $MODEL"
    echo ""

    # ─── Dry Run ────────────────────────────────────────────────────────────
    if [[ "$DRY_RUN" == "true" ]]; then
        info "Dry run — would execute:"
        for repo in "${REPOS[@]}"; do
            local expanded
            expanded=$(eval echo "$repo")
            local rname
            rname=$(basename "$expanded")
            echo -e "  ${DIM}cd $expanded && git checkout -b $branch_name${RESET}"
            echo -e "  ${DIM}cct-pipeline.sh start --goal \"$GOAL\" --pipeline $TEMPLATE --skip-gates${RESET}"
            echo ""
        done
        return
    fi

    # Build initial state JSON using jq
    local repos_json="[]"
    for repo in "${REPOS[@]}"; do
        local expanded
        expanded=$(eval echo "$repo")
        local rname
        rname=$(basename "$expanded")
        repos_json=$(echo "$repos_json" | jq --arg name "$rname" --arg path "$expanded" \
            '. + [{"name": $name, "path": $path, "status": "pending", "pr_url": "-", "duration": "-", "pid": 0}]')
    done

    # Atomic write initial state
    local tmp_state
    tmp_state=$(mktemp)
    jq -n \
        --arg goal "$GOAL" \
        --arg branch "$branch_name" \
        --arg template "$TEMPLATE" \
        --arg started "$(now_iso)" \
        --arg session_id "$session_id" \
        --argjson repos "$repos_json" \
        '{goal: $goal, branch: $branch, template: $template, started: $started, session_id: $session_id, status: "running", repos: $repos}' \
        > "$tmp_state"
    mv "$tmp_state" "$state_file"

    emit_event "fix.started" "goal=$GOAL" "repos=${#REPOS[@]}" "template=$TEMPLATE" "session=$session_id"

    # ─── Parallel Execution ─────────────────────────────────────────────────
    local pids=()
    local pid_to_idx=()
    local idx=0

    for repo in "${REPOS[@]}"; do
        local expanded
        expanded=$(eval echo "$repo")
        local rname
        rname=$(basename "$expanded")

        # Throttle: wait for a slot if at max parallel
        while [[ ${#pids[@]} -ge $MAX_PARALLEL ]]; do
            # Wait for any one to finish
            wait -n "${pids[@]}" 2>/dev/null || true
            # Rebuild pids array — remove finished ones
            local new_pids=()
            for p in "${pids[@]}"; do
                if kill -0 "$p" 2>/dev/null; then
                    new_pids+=("$p")
                fi
            done
            pids=("${new_pids[@]}")
        done

        info "Starting: ${BOLD}${rname}${RESET}"

        emit_event "fix.repo.started" "repo=$rname" "session=$session_id"

        # Update state to running
        tmp_state=$(mktemp)
        jq --arg name "$rname" '(.repos[] | select(.name == $name)).status = "running"' "$state_file" > "$tmp_state"
        mv "$tmp_state" "$state_file"

        # Spawn pipeline in subshell
        (
            cd "$expanded"

            # Determine base branch
            local base
            base=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || base="main"

            # Create fix branch
            git checkout -b "$branch_name" "origin/$base" 2>/dev/null || git checkout -b "$branch_name" "$base" 2>/dev/null || true

            # Build pipeline command
            local cmd=("$SCRIPT_DIR/cct-pipeline.sh" start --goal "$GOAL" --pipeline "$TEMPLATE" --skip-gates)
            [[ -n "$MODEL" ]] && cmd+=(--model "$MODEL")

            # Run pipeline
            "${cmd[@]}"
        ) > "$log_dir/${rname}.log" 2>&1 &

        local pid=$!
        pids+=("$pid")

        # Track PID → repo index via temp file (subshell-safe)
        echo "$rname" > "$log_dir/.pid-${pid}"

        idx=$((idx + 1))
    done

    # ─── Wait for All ───────────────────────────────────────────────────────
    info "Waiting for ${#REPOS[@]} pipelines to complete..."
    echo ""

    local success_count=0
    local fail_count=0

    # Wait for remaining PIDs and collect results
    for pid in "${pids[@]}"; do
        local rname=""
        if [[ -f "$log_dir/.pid-${pid}" ]]; then
            rname=$(< "$log_dir/.pid-${pid}")
        fi

        local repo_start
        repo_start=$(now_epoch)

        if wait "$pid" 2>/dev/null; then
            local repo_end
            repo_end=$(now_epoch)
            local repo_dur=$((repo_end - repo_start))

            # Try to extract PR URL from log
            local pr_url="-"
            if [[ -f "$log_dir/${rname}.log" ]]; then
                pr_url=$(grep -oE 'https://github\.com/[^ ]+/pull/[0-9]+' "$log_dir/${rname}.log" 2>/dev/null | tail -1) || pr_url="-"
                [[ -z "$pr_url" ]] && pr_url="-"
            fi

            success "  ${rname}: pass"
            success_count=$((success_count + 1))

            emit_event "fix.repo.completed" "repo=$rname" "status=pass" "pr_url=$pr_url" "session=$session_id"

            # Update state
            tmp_state=$(mktemp)
            jq --arg name "$rname" --arg pr "$pr_url" --arg dur "$(format_duration $repo_dur)" \
                '(.repos[] | select(.name == $name)) |= (.status = "pass" | .pr_url = $pr | .duration = $dur)' \
                "$state_file" > "$tmp_state"
            mv "$tmp_state" "$state_file"
        else
            local repo_end
            repo_end=$(now_epoch)
            local repo_dur=$((repo_end - repo_start))

            error "  ${rname}: fail"
            fail_count=$((fail_count + 1))

            emit_event "fix.repo.completed" "repo=$rname" "status=fail" "session=$session_id"

            tmp_state=$(mktemp)
            jq --arg name "$rname" --arg dur "$(format_duration $repo_dur)" \
                '(.repos[] | select(.name == $name)) |= (.status = "fail" | .duration = $dur)' \
                "$state_file" > "$tmp_state"
            mv "$tmp_state" "$state_file"
        fi
    done

    # ─── Summary ────────────────────────────────────────────────────────────
    local end_epoch
    end_epoch=$(now_epoch)
    local total_dur=$((end_epoch - start_epoch))
    local final_status="completed"
    [[ $fail_count -gt 0 ]] && final_status="partial"
    [[ $success_count -eq 0 ]] && final_status="failed"

    # Update final state
    tmp_state=$(mktemp)
    jq --arg status "$final_status" --arg dur "$(format_duration $total_dur)" \
        '.status = $status | .total_duration = $dur' "$state_file" > "$tmp_state"
    mv "$tmp_state" "$state_file"

    emit_event "fix.completed" "goal=$GOAL" "session=$session_id" \
        "success=$success_count" "fail=$fail_count" "total=${#REPOS[@]}" \
        "duration=$total_dur" "status=$final_status"

    echo ""
    echo -e "${CYAN}${BOLD}═══ Fix Complete: \"${GOAL}\" ═══${RESET}"
    echo ""
    printf "  ${BOLD}%-16s %-10s %-30s %s${RESET}\n" "Repo" "Status" "PR" "Duration"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"

    while IFS='|' read -r rname rstatus rpr rdur; do
        [[ -z "$rname" ]] && continue
        local icon="${YELLOW}⋯${RESET}"
        [[ "$rstatus" == "pass" ]] && icon="${GREEN}✓${RESET}"
        [[ "$rstatus" == "fail" ]] && icon="${RED}✗${RESET}"
        printf "  %-16s ${icon} %-8s %-30s %s\n" "$rname" "$rstatus" "$rpr" "$rdur"
    done < <(jq -r '.repos[] | "\(.name)|\(.status)|\(.pr_url)|\(.duration)"' "$state_file" 2>/dev/null)

    echo ""
    echo -e "  ${BOLD}Success:${RESET} ${success_count}/${#REPOS[@]}  |  ${BOLD}Duration:${RESET} $(format_duration $total_dur) (parallel)"

    if [[ $fail_count -gt 0 ]]; then
        echo ""
        echo -e "  ${DIM}Logs: $log_dir${RESET}"
    fi
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────

parse_args "$@"
fix_start
