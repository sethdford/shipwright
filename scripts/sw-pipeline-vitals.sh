#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright vitals — Pipeline Vitals Engine                              ║
# ║  Real-time health scoring · Adaptive limits · Budget trajectory          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
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

# ─── Constants ──────────────────────────────────────────────────────────────
PROGRESS_DIR="${HOME}/.shipwright/progress"
COST_DIR="${HOME}/.shipwright"
COST_FILE="${COST_DIR}/costs.json"
BUDGET_FILE="${COST_DIR}/budget.json"
OPTIMIZATION_DIR="${HOME}/.shipwright/optimization"

# Signal weights for health score (configurable via env vars)
WEIGHT_MOMENTUM="${VITALS_WEIGHT_MOMENTUM:-35}"
WEIGHT_CONVERGENCE="${VITALS_WEIGHT_CONVERGENCE:-30}"
WEIGHT_BUDGET="${VITALS_WEIGHT_BUDGET:-20}"
WEIGHT_ERROR_MATURITY="${VITALS_WEIGHT_ERROR_MATURITY:-15}"

# ─── Helper: safe numeric extraction ────────────────────────────────────────
_safe_num() {
    local val="${1:-0}"
    if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        echo "$val"
    else
        echo "0"
    fi
}

# ─── Momentum Score ─────────────────────────────────────────────────────────
# Compares current snapshot to previous snapshots to detect forward progress
_compute_momentum() {
    local progress_file="$1"
    local current_stage="${2:-unknown}"
    local current_iteration="${3:-0}"
    local current_diff="${4:-0}"

    # No history — assume neutral
    if [[ ! -f "$progress_file" ]]; then
        echo "50"
        return
    fi

    local snapshots_count
    snapshots_count=$(jq '.snapshots | length' "$progress_file" 2>/dev/null || echo "0")
    snapshots_count=$(_safe_num "$snapshots_count")

    if [[ "$snapshots_count" -lt 2 ]]; then
        # If we have 1 snapshot, check if stage advanced from intake
        if [[ "$snapshots_count" -eq 1 ]]; then
            local last_stage
            last_stage=$(jq -r '.snapshots[-1].stage // ""' "$progress_file" 2>/dev/null || echo "")
            if [[ -n "$last_stage" && "$last_stage" != "intake" && "$last_stage" != "unknown" ]]; then
                echo "60"
                return
            fi
        fi
        echo "50"
        return
    fi

    # Get last 3 snapshots for comparison
    local score=50

    local prev_stage prev_iteration prev_diff no_progress_count
    prev_stage=$(jq -r '.snapshots[-1].stage // "unknown"' "$progress_file" 2>/dev/null || echo "unknown")
    prev_iteration=$(jq -r '.snapshots[-1].iteration // 0' "$progress_file" 2>/dev/null || echo "0")
    prev_iteration=$(_safe_num "$prev_iteration")
    prev_diff=$(jq -r '.snapshots[-1].diff_lines // 0' "$progress_file" 2>/dev/null || echo "0")
    prev_diff=$(_safe_num "$prev_diff")
    no_progress_count=$(jq -r '.no_progress_count // 0' "$progress_file" 2>/dev/null || echo "0")
    no_progress_count=$(_safe_num "$no_progress_count")

    # Stage advancement: +30 points
    if [[ "$current_stage" != "$prev_stage" && "$current_stage" != "unknown" ]]; then
        score=$((score + 30))
    fi

    # Iteration progress: +10 points per increment
    current_iteration=$(_safe_num "$current_iteration")
    local iter_delta=$((current_iteration - prev_iteration))
    if [[ "$iter_delta" -gt 0 ]]; then
        local iter_bonus=$((iter_delta * 10))
        [[ "$iter_bonus" -gt 30 ]] && iter_bonus=30
        score=$((score + iter_bonus))
    fi

    # Diff growth: +5 points per 50 new lines
    current_diff=$(_safe_num "$current_diff")
    local diff_delta=$((current_diff - prev_diff))
    if [[ "$diff_delta" -gt 0 ]]; then
        local diff_bonus=$(( (diff_delta / 50) * 5 ))
        [[ "$diff_bonus" -gt 20 ]] && diff_bonus=20
        score=$((score + diff_bonus))
    fi

    # No change penalty: -20 per stagnant check
    if [[ "$no_progress_count" -gt 0 ]]; then
        local stagnant_penalty=$((no_progress_count * 20))
        score=$((score - stagnant_penalty))
    fi

    # Clamp to 0-100
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100

    echo "$score"
}

# ─── Convergence Score ──────────────────────────────────────────────────────
# Tracks error/issue counts trend across cycles
_compute_convergence() {
    local error_log="$1"
    local progress_file="$2"

    # No error log — assume perfect convergence
    if [[ ! -f "$error_log" ]]; then
        echo "100"
        return
    fi

    local total_errors
    total_errors=$(wc -l < "$error_log" 2>/dev/null | tr -d ' ' || echo "0")
    total_errors=$(_safe_num "$total_errors")

    if [[ "$total_errors" -eq 0 ]]; then
        echo "100"
        return
    fi

    # Compare error counts across snapshots to detect trend
    if [[ -f "$progress_file" ]]; then
        local snapshots_count
        snapshots_count=$(jq '.snapshots | length' "$progress_file" 2>/dev/null || echo "0")
        snapshots_count=$(_safe_num "$snapshots_count")

        if [[ "$snapshots_count" -ge 2 ]]; then
            # Count errors with non-empty signatures in snapshots
            local early_errors late_errors
            early_errors=$(jq '[.snapshots[:($snapshots_count/2 | floor)] | .[] | select(.last_error != "")] | length' \
                --argjson snapshots_count "$snapshots_count" "$progress_file" 2>/dev/null || echo "0")
            early_errors=$(_safe_num "$early_errors")
            late_errors=$(jq '[.snapshots[($snapshots_count/2 | floor):] | .[] | select(.last_error != "")] | length' \
                --argjson snapshots_count "$snapshots_count" "$progress_file" 2>/dev/null || echo "0")
            late_errors=$(_safe_num "$late_errors")

            if [[ "$early_errors" -gt 0 ]]; then
                local reduction_pct=$(( (early_errors - late_errors) * 100 / early_errors ))
                if [[ "$reduction_pct" -gt 50 ]]; then
                    echo "100"
                    return
                elif [[ "$reduction_pct" -gt 0 ]]; then
                    echo "75"
                    return
                elif [[ "$reduction_pct" -eq 0 ]]; then
                    echo "40"
                    return
                fi
            fi
        fi
    fi

    # Fallback: decreasing = good, based on recent no_progress_count
    if [[ -f "$progress_file" ]]; then
        local no_prog
        no_prog=$(jq -r '.no_progress_count // 0' "$progress_file" 2>/dev/null || echo "0")
        no_prog=$(_safe_num "$no_prog")
        if [[ "$no_prog" -ge 3 ]]; then
            echo "10"
            return
        fi
    fi

    echo "40"
}

# ─── Budget Score ───────────────────────────────────────────────────────────
# Calculates budget health based on remaining vs burn rate
_compute_budget() {
    local cost_file="${COST_FILE}"
    local budget_file="${BUDGET_FILE}"

    # Check if budget is enabled
    if [[ ! -f "$budget_file" ]]; then
        echo "100"
        return
    fi

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled' "$budget_file" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$budget_file" 2>/dev/null || echo "0")

    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        echo "100"
        return
    fi

    # Calculate today's spending
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null \
        || date -u -d "$today_start" +%s 2>/dev/null || echo "0")

    local today_spent="0"
    if [[ -f "$cost_file" ]]; then
        today_spent=$(jq --argjson cutoff "$today_epoch" \
            '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
            "$cost_file" 2>/dev/null || echo "0")
    fi
    today_spent=$(_safe_num "$today_spent")
    budget_usd=$(_safe_num "$budget_usd")

    if [[ "$budget_usd" == "0" ]]; then
        echo "100"
        return
    fi

    # Score = remaining / budget * 100
    local remaining_pct
    remaining_pct=$(awk -v budget="$budget_usd" -v spent="$today_spent" \
        'BEGIN { if (budget > 0) printf "%.0f", ((budget - spent) / budget) * 100; else print 100 }')
    remaining_pct=$(_safe_num "$remaining_pct")

    [[ "$remaining_pct" -lt 0 ]] && remaining_pct=0
    [[ "$remaining_pct" -gt 100 ]] && remaining_pct=100

    echo "$remaining_pct"
}

# ─── Error Maturity Score ───────────────────────────────────────────────────
# High unique/total ratio = new problems = lower score
# Low unique/total ratio = same issues = depends on convergence
_compute_error_maturity() {
    local error_log="$1"

    if [[ ! -f "$error_log" ]]; then
        echo "80"
        return
    fi

    local total_errors
    total_errors=$(wc -l < "$error_log" 2>/dev/null | tr -d ' ' || echo "0")
    total_errors=$(_safe_num "$total_errors")

    if [[ "$total_errors" -eq 0 ]]; then
        echo "80"
        return
    fi

    # Count unique error signatures
    local unique_errors
    unique_errors=$(jq -r '.signature // "unknown"' "$error_log" 2>/dev/null | sort -u | wc -l | tr -d ' ' || echo "0")
    unique_errors=$(_safe_num "$unique_errors")

    if [[ "$unique_errors" -eq 0 ]]; then
        echo "80"
        return
    fi

    # Ratio: unique / total. Low ratio = same issues repeating
    # High ratio (>0.8) = lots of different errors = unstable (score 20)
    # Medium ratio (0.4-0.8) = some variety (score 50)
    # Low ratio (<0.4) = stuck on same issues (score 60, mature but stuck)
    local ratio_pct=$(( unique_errors * 100 / total_errors ))

    if [[ "$ratio_pct" -gt 80 ]]; then
        echo "20"
    elif [[ "$ratio_pct" -gt 40 ]]; then
        echo "50"
    else
        echo "60"
    fi
}

# ─── File Locking Helpers ──────────────────────────────────────────────────
_vitals_acquire_lock() {
    local lockfile="$1.lock"
    local fd=200
    eval "exec $fd>\"$lockfile\""
    flock -w 5 "$fd" || { warn "Vitals lock timeout"; return 1; }
}
_vitals_release_lock() {
    local fd=200
    flock -u "$fd" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# pipeline_emit_progress_snapshot
# Records a point-in-time snapshot for progress tracking
# Args: <issue_num> <stage> <iteration> <diff_lines> <files_changed> <last_error>
# Side effect: writes to ~/.shipwright/progress/issue-<N>.json
# ═══════════════════════════════════════════════════════════════════════════
pipeline_emit_progress_snapshot() {
    local issue_num="${1:-}"
    local stage="${2:-unknown}"
    local iteration="${3:-0}"
    local diff_lines="${4:-0}"
    local files_changed="${5:-0}"
    local last_error="${6:-}"

    [[ -z "$issue_num" ]] && return 0

    mkdir -p "$PROGRESS_DIR"
    local progress_file="${PROGRESS_DIR}/issue-${issue_num}.json"

    # Acquire lock
    _vitals_acquire_lock "$progress_file" || return 1

    # Build new snapshot entry
    local snapshot_json
    snapshot_json=$(jq -n \
        --arg stage "$stage" \
        --argjson iteration "$(_safe_num "$iteration")" \
        --argjson diff_lines "$(_safe_num "$diff_lines")" \
        --argjson files_changed "$(_safe_num "$files_changed")" \
        --arg last_error "$last_error" \
        --arg ts "$(now_iso)" \
        '{
            stage: $stage,
            iteration: $iteration,
            diff_lines: $diff_lines,
            files_changed: $files_changed,
            last_error: $last_error,
            ts: $ts
        }')

    # Initialize file if missing
    if [[ ! -f "$progress_file" ]]; then
        echo '{"snapshots":[],"no_progress_count":0}' > "$progress_file"
    fi

    # Determine if progress was made (stage or iteration advanced)
    local prev_stage prev_iteration no_progress_count
    prev_stage=$(jq -r '.snapshots[-1].stage // ""' "$progress_file" 2>/dev/null || echo "")
    prev_iteration=$(jq -r '.snapshots[-1].iteration // -1' "$progress_file" 2>/dev/null || echo "-1")
    prev_iteration=$(_safe_num "$prev_iteration")
    no_progress_count=$(jq -r '.no_progress_count // 0' "$progress_file" 2>/dev/null || echo "0")
    no_progress_count=$(_safe_num "$no_progress_count")

    local cur_iter_num
    cur_iter_num=$(_safe_num "$iteration")

    if [[ "$stage" != "$prev_stage" || "$cur_iter_num" -gt "$prev_iteration" ]]; then
        no_progress_count=0
    else
        no_progress_count=$((no_progress_count + 1))
    fi

    # Append snapshot, cap at 20 entries, update no_progress_count
    local tmp_pf="${progress_file}.tmp.$$"
    jq --argjson snap "$snapshot_json" \
       --argjson npc "$no_progress_count" \
       '.snapshots += [$snap] | .snapshots = .snapshots[-20:] | .no_progress_count = $npc' \
       "$progress_file" > "$tmp_pf" 2>/dev/null && mv "$tmp_pf" "$progress_file" || {
        rm -f "$tmp_pf"
        _vitals_release_lock
        return 1
    }

    _vitals_release_lock

    emit_event "vitals.snapshot" \
        "issue=$issue_num" \
        "stage=$stage" \
        "iteration=$iteration" \
        "diff_lines=$diff_lines" \
        "no_progress=$no_progress_count"
}

# ═══════════════════════════════════════════════════════════════════════════
# pipeline_compute_vitals
# Main entry: computes composite health score from 4 weighted signals
# Args: [pipeline_state_file] [artifacts_dir] [issue_number]
# Output: JSON to stdout
# ═══════════════════════════════════════════════════════════════════════════
pipeline_compute_vitals() {
    local state_file="${1:-${PIPELINE_STATE:-${REPO_DIR}/.claude/pipeline-state.md}}"
    local artifacts_dir="${2:-${REPO_DIR}/.claude/pipeline-artifacts}"
    local issue_num="${3:-}"

    # ── Read current pipeline state ──
    local current_stage="unknown" current_iteration=0 elapsed="0s"
    if [[ -f "$state_file" ]]; then
        current_stage=$(grep -m1 '^current_stage:' "$state_file" 2>/dev/null | sed 's/^current_stage: *//' || echo "unknown")
        [[ -z "$current_stage" ]] && current_stage="unknown"

        local stage_progress
        stage_progress=$(grep -m1 '^stage_progress:' "$state_file" 2>/dev/null | sed 's/^stage_progress: *//' || echo "")
        if [[ "$stage_progress" =~ iteration\ ([0-9]+) ]]; then
            current_iteration="${BASH_REMATCH[1]}"
        fi

        elapsed=$(grep -m1 '^elapsed:' "$state_file" 2>/dev/null | sed 's/^elapsed: *//' || echo "0s")
    fi

    # ── Detect issue number if not provided ──
    if [[ -z "$issue_num" && -f "$state_file" ]]; then
        issue_num=$(grep -m1 '^issue:' "$state_file" 2>/dev/null | sed 's/^issue: *//' | tr -d '"' || echo "")
    fi

    # ── Determine progress file ──
    local progress_file=""
    if [[ -n "$issue_num" ]]; then
        progress_file="${PROGRESS_DIR}/issue-${issue_num}.json"
    fi

    # ── Error log ──
    local error_log="${artifacts_dir}/error-log.jsonl"

    # ── Get diff stats from git ──
    local current_diff=0
    current_diff=$(cd "$REPO_DIR" && git diff --stat 2>/dev/null | tail -1 | grep -o '[0-9]* insertion' | grep -o '[0-9]*' || echo "0")
    [[ -z "$current_diff" ]] && current_diff=0

    # ── Compute individual signals ──
    local momentum convergence budget_score error_maturity
    momentum=$(_compute_momentum "${progress_file}" "$current_stage" "$current_iteration" "$current_diff")
    convergence=$(_compute_convergence "$error_log" "$progress_file")
    budget_score=$(_compute_budget)
    error_maturity=$(_compute_error_maturity "$error_log")

    # ── Weighted composite score ──
    local health_score=$(( (momentum * WEIGHT_MOMENTUM + convergence * WEIGHT_CONVERGENCE + budget_score * WEIGHT_BUDGET + error_maturity * WEIGHT_ERROR_MATURITY) / 100 ))
    [[ "$health_score" -lt 0 ]] && health_score=0
    [[ "$health_score" -gt 100 ]] && health_score=100

    # ── Previous score for trajectory ──
    local prev_score=""
    if [[ -n "$progress_file" && -f "$progress_file" ]]; then
        prev_score=$(jq -r '.last_health_score // ""' "$progress_file" 2>/dev/null || echo "")
    fi

    # ── Verdict ──
    local verdict
    verdict=$(pipeline_health_verdict "$health_score" "$prev_score")

    # ── Recommended action ──
    local recommended_action="continue"
    case "$verdict" in
        continue) recommended_action="continue" ;;
        warn)     recommended_action="extend patience, monitor closely" ;;
        intervene) recommended_action="prepare intervention, consider reducing scope" ;;
        abort)    recommended_action="abort pipeline, escalate to human" ;;
    esac

    # ── Store health score in progress file for trajectory tracking ──
    if [[ -n "$progress_file" && -f "$progress_file" ]]; then
        if _vitals_acquire_lock "$progress_file" 2>/dev/null; then
            local tmp_pf="${progress_file}.tmp.$$"
            jq --argjson score "$health_score" '.last_health_score = $score' \
                "$progress_file" > "$tmp_pf" 2>/dev/null && mv "$tmp_pf" "$progress_file" || rm -f "$tmp_pf"
            _vitals_release_lock
        fi
    fi

    # ── Budget details ──
    local remaining_budget="unlimited" today_spent="0.00"
    if [[ -f "$BUDGET_FILE" ]]; then
        local be
        be=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
        if [[ "$be" == "true" ]]; then
            local bu
            bu=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")
            local today_start
            today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
            local today_epoch
            today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null \
                || date -u -d "$today_start" +%s 2>/dev/null || echo "0")
            if [[ -f "$COST_FILE" ]]; then
                today_spent=$(jq --argjson cutoff "$today_epoch" \
                    '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
                    "$COST_FILE" 2>/dev/null || echo "0")
            fi
            remaining_budget=$(awk -v b="$bu" -v s="$today_spent" 'BEGIN { printf "%.2f", b - s }')
        fi
    fi

    # ── Error counts ──
    local total_errors=0 unique_errors=0
    if [[ -f "$error_log" ]]; then
        total_errors=$(wc -l < "$error_log" 2>/dev/null | tr -d ' ' || echo "0")
        unique_errors=$(jq -r '.signature // "unknown"' "$error_log" 2>/dev/null | sort -u | wc -l | tr -d ' ' || echo "0")
    fi

    # ── Output JSON ──
    jq -n \
        --argjson health_score "$health_score" \
        --arg verdict "$verdict" \
        --arg recommended_action "$recommended_action" \
        --argjson momentum "$momentum" \
        --argjson convergence "$convergence" \
        --argjson budget_score "$budget_score" \
        --argjson error_maturity "$error_maturity" \
        --arg current_stage "$current_stage" \
        --argjson current_iteration "$current_iteration" \
        --arg elapsed "$elapsed" \
        --arg prev_score "${prev_score:-}" \
        --arg remaining_budget "$remaining_budget" \
        --arg today_spent "$today_spent" \
        --argjson total_errors "$total_errors" \
        --argjson unique_errors "$unique_errors" \
        --arg issue "${issue_num:-}" \
        --arg ts "$(now_iso)" \
        '{
            health_score: $health_score,
            verdict: $verdict,
            recommended_action: $recommended_action,
            signals: {
                momentum: $momentum,
                convergence: $convergence,
                budget: $budget_score,
                error_maturity: $error_maturity
            },
            pipeline: {
                stage: $current_stage,
                iteration: $current_iteration,
                elapsed: $elapsed,
                issue: $issue
            },
            budget: {
                remaining: $remaining_budget,
                today_spent: $today_spent
            },
            errors: {
                total: $total_errors,
                unique: $unique_errors
            },
            prev_score: (if $prev_score == "" then null else ($prev_score | tonumber) end),
            ts: $ts
        }'
}

# ═══════════════════════════════════════════════════════════════════════════
# pipeline_health_verdict
# Maps health score to action, considering trajectory
# Args: current_score [previous_score]
# Output: continue | warn | intervene | abort
# ═══════════════════════════════════════════════════════════════════════════
pipeline_health_verdict() {
    local current_score="${1:-50}"
    local prev_score="${2:-}"

    current_score=$(_safe_num "$current_score")

    # Determine trajectory
    local trajectory="stable"
    if [[ -n "$prev_score" && "$prev_score" != "" ]]; then
        prev_score=$(_safe_num "$prev_score")
        if [[ "$current_score" -gt "$prev_score" ]]; then
            trajectory="improving"
        elif [[ "$current_score" -lt "$prev_score" ]]; then
            trajectory="declining"
        fi
    fi

    # Score-based verdict with trajectory adjustment
    if [[ "$current_score" -ge 70 ]]; then
        echo "continue"
    elif [[ "$current_score" -ge 50 ]]; then
        # Sluggish zone: extend patience if improving
        if [[ "$trajectory" == "improving" ]]; then
            echo "continue"
        else
            echo "warn"
        fi
    elif [[ "$current_score" -ge 30 ]]; then
        # Stalling zone: escalate faster if declining
        if [[ "$trajectory" == "declining" ]]; then
            echo "intervene"
        elif [[ "$trajectory" == "improving" ]]; then
            echo "warn"
        else
            echo "intervene"
        fi
    else
        # Critical zone
        echo "abort"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# pipeline_adaptive_limit
# Determines cycle limit dynamically based on vitals + learned model
# Args: loop_type (build_test|compound_quality) [vitals_json]
# Output: integer cycle limit
# ═══════════════════════════════════════════════════════════════════════════
pipeline_adaptive_limit() {
    local loop_type="${1:-build_test}"
    local vitals_json="${2:-}"

    # Start with learned iteration model
    local model_file="${OPTIMIZATION_DIR}/iteration-model.json"
    local base_limit=5

    if [[ -f "$model_file" ]]; then
        local learned
        learned=$(jq -r --arg ctx "$loop_type" '.[$ctx].recommended_cycles // 0' "$model_file" 2>/dev/null || echo "0")
        learned=$(_safe_num "$learned")
        if [[ "$learned" -gt 0 ]]; then
            base_limit="$learned"
        fi
    fi

    # Get template max (hard ceiling = 2x template max)
    local hard_ceiling=$((base_limit * 2))
    [[ "$hard_ceiling" -lt 4 ]] && hard_ceiling=4

    # If no vitals provided, return base
    if [[ -z "$vitals_json" ]]; then
        echo "$base_limit"
        return
    fi

    # Extract vitals signals
    local health convergence budget_s
    health=$(echo "$vitals_json" | jq -r '.health_score // 50' 2>/dev/null || echo "50")
    health=$(_safe_num "$health")
    convergence=$(echo "$vitals_json" | jq -r '.signals.convergence // 50' 2>/dev/null || echo "50")
    convergence=$(_safe_num "$convergence")
    budget_s=$(echo "$vitals_json" | jq -r '.signals.budget // 100' 2>/dev/null || echo "100")
    budget_s=$(_safe_num "$budget_s")

    local limit="$base_limit"

    # Health > 70 + convergence > 60: allow +1 beyond model
    if [[ "$health" -gt 70 && "$convergence" -gt 60 ]]; then
        limit=$((base_limit + 1))
    fi

    # Health < 40: cap at current cycle (don't extend)
    if [[ "$health" -lt 40 ]]; then
        # Keep base_limit, don't extend
        limit="$base_limit"
    fi

    # Budget score < 30: hard stop at minimum
    if [[ "$budget_s" -lt 30 ]]; then
        limit=1
    fi

    # Never exceed hard ceiling
    [[ "$limit" -gt "$hard_ceiling" ]] && limit="$hard_ceiling"
    [[ "$limit" -lt 1 ]] && limit=1

    echo "$limit"
}

# ═══════════════════════════════════════════════════════════════════════════
# pipeline_budget_trajectory
# Predicts if pipeline can afford to finish
# Output: ok | warn | stop
# ═══════════════════════════════════════════════════════════════════════════
pipeline_budget_trajectory() {
    local state_file="${1:-${PIPELINE_STATE:-${REPO_DIR}/.claude/pipeline-state.md}}"

    # Check if budget is enabled
    if [[ ! -f "$BUDGET_FILE" ]]; then
        echo "ok"
        return
    fi

    local budget_enabled
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    if [[ "$budget_enabled" != "true" ]]; then
        echo "ok"
        return
    fi

    # Get remaining budget
    local budget_usd today_spent remaining_budget
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")
    budget_usd=$(_safe_num "$budget_usd")

    if [[ "$budget_usd" == "0" ]]; then
        echo "ok"
        return
    fi

    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null \
        || date -u -d "$today_start" +%s 2>/dev/null || echo "0")

    today_spent="0"
    if [[ -f "$COST_FILE" ]]; then
        today_spent=$(jq --argjson cutoff "$today_epoch" \
            '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
            "$COST_FILE" 2>/dev/null || echo "0")
    fi
    today_spent=$(_safe_num "$today_spent")

    remaining_budget=$(awk -v b="$budget_usd" -v s="$today_spent" 'BEGIN { printf "%.2f", b - s }')

    # Calculate average cost per stage from events
    local avg_cost_per_stage="0"
    if [[ -f "$EVENTS_FILE" ]]; then
        avg_cost_per_stage=$(grep '"type":"cost.record"' "$EVENTS_FILE" 2>/dev/null \
            | jq -r '.cost_usd // 0' 2>/dev/null \
            | awk '{ sum += $1; count++ } END { if (count > 0) printf "%.2f", sum/count; else print "0.50" }' \
            || echo "0.50")
    fi
    avg_cost_per_stage=$(_safe_num "$avg_cost_per_stage")
    # Default to 0.50 if no data
    if awk -v c="$avg_cost_per_stage" 'BEGIN { exit !(c <= 0) }'; then
        avg_cost_per_stage="0.50"
    fi

    # Count remaining stages
    local remaining_stages=6
    if [[ -f "$state_file" ]]; then
        local current_stage
        current_stage=$(grep -m1 '^current_stage:' "$state_file" 2>/dev/null | sed 's/^current_stage: *//' || echo "")
        case "$current_stage" in
            intake)             remaining_stages=11 ;;
            plan)               remaining_stages=10 ;;
            design)             remaining_stages=9 ;;
            build)              remaining_stages=8 ;;
            test)               remaining_stages=7 ;;
            review)             remaining_stages=6 ;;
            compound_quality)   remaining_stages=5 ;;
            pr)                 remaining_stages=4 ;;
            merge)              remaining_stages=3 ;;
            deploy)             remaining_stages=2 ;;
            validate)           remaining_stages=1 ;;
            monitor)            remaining_stages=0 ;;
        esac
    fi

    # Predict: can we afford to finish?
    local needed
    needed=$(awk -v avg="$avg_cost_per_stage" -v stages="$remaining_stages" -v factor="1.5" \
        'BEGIN { printf "%.2f", avg * stages * factor }')

    local can_afford
    can_afford=$(awk -v rem="$remaining_budget" -v need="$needed" 'BEGIN { print (rem >= need) ? "yes" : "no" }')

    local min_threshold
    min_threshold=$(awk -v avg="$avg_cost_per_stage" 'BEGIN { printf "%.2f", avg * 2 }')

    local above_min
    above_min=$(awk -v rem="$remaining_budget" -v min="$min_threshold" 'BEGIN { print (rem >= min) ? "yes" : "no" }')

    if [[ "$above_min" == "no" ]]; then
        echo "stop"
    elif [[ "$can_afford" == "no" ]]; then
        echo "warn"
    else
        echo "ok"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# vitals_dashboard
# CLI output for `shipwright vitals`
# ═══════════════════════════════════════════════════════════════════════════
vitals_dashboard() {
    local state_file="${1:-${PIPELINE_STATE:-${REPO_DIR}/.claude/pipeline-state.md}}"
    local artifacts_dir="${2:-${REPO_DIR}/.claude/pipeline-artifacts}"
    local issue_num="${3:-}"

    # Compute vitals
    local vitals
    vitals=$(pipeline_compute_vitals "$state_file" "$artifacts_dir" "$issue_num")

    # Extract fields
    local health_score verdict recommended_action
    health_score=$(echo "$vitals" | jq -r '.health_score')
    verdict=$(echo "$vitals" | jq -r '.verdict')
    recommended_action=$(echo "$vitals" | jq -r '.recommended_action')

    local momentum convergence budget_s error_maturity
    momentum=$(echo "$vitals" | jq -r '.signals.momentum')
    convergence=$(echo "$vitals" | jq -r '.signals.convergence')
    budget_s=$(echo "$vitals" | jq -r '.signals.budget')
    error_maturity=$(echo "$vitals" | jq -r '.signals.error_maturity')

    local stage iteration elapsed issue_display
    stage=$(echo "$vitals" | jq -r '.pipeline.stage')
    iteration=$(echo "$vitals" | jq -r '.pipeline.iteration')
    elapsed=$(echo "$vitals" | jq -r '.pipeline.elapsed')
    issue_display=$(echo "$vitals" | jq -r '.pipeline.issue')

    local remaining_budget today_spent
    remaining_budget=$(echo "$vitals" | jq -r '.budget.remaining')
    today_spent=$(echo "$vitals" | jq -r '.budget.today_spent')

    local total_errors unique_errors
    total_errors=$(echo "$vitals" | jq -r '.errors.total')
    unique_errors=$(echo "$vitals" | jq -r '.errors.unique')

    local prev_score
    prev_score=$(echo "$vitals" | jq -r '.prev_score // "none"')

    # ── Color for health score ──
    local score_color="$GREEN"
    if [[ "$health_score" -lt 30 ]]; then
        score_color="$RED"
    elif [[ "$health_score" -lt 50 ]]; then
        score_color="$YELLOW"
    elif [[ "$health_score" -lt 70 ]]; then
        score_color="$BLUE"
    fi

    # ── Verdict label ──
    local verdict_label
    case "$verdict" in
        continue)  verdict_label="${GREEN}healthy${RESET}" ;;
        warn)      verdict_label="${YELLOW}sluggish${RESET}" ;;
        intervene) verdict_label="${RED}stalling${RESET}" ;;
        abort)     verdict_label="${RED}${BOLD}critical${RESET}" ;;
        *)         verdict_label="${DIM}unknown${RESET}" ;;
    esac

    # ── Header ──
    echo ""
    local title="Pipeline Vitals"
    if [[ -n "$issue_display" && "$issue_display" != "" ]]; then
        title="Pipeline Vitals — issue #${issue_display}"
    fi
    echo -e "${CYAN}${BOLD}  ${title}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    # ── Health Score ──
    printf "  ${BOLD}Health Score:${RESET}     ${score_color}${BOLD}%d${RESET}/100  (%b)\n" "$health_score" "$verdict_label"

    # ── Signal details ──
    local m_desc c_desc b_desc e_desc

    # Momentum description
    if [[ "$momentum" -ge 70 ]]; then
        m_desc="advancing"
    elif [[ "$momentum" -ge 40 ]]; then
        m_desc="steady"
    else
        m_desc="stagnant"
    fi
    if [[ "$stage" != "unknown" ]]; then
        m_desc="${m_desc} (${stage})"
    fi

    # Convergence description
    if [[ "$convergence" -ge 70 ]]; then
        c_desc="issues decreasing"
    elif [[ "$convergence" -ge 40 ]]; then
        c_desc="flat"
    else
        c_desc="issues increasing"
    fi

    # Budget description
    if [[ "$remaining_budget" == "unlimited" ]]; then
        b_desc="no budget set"
    else
        b_desc="\$${remaining_budget} remaining (\$${today_spent} burned)"
    fi

    # Error maturity description
    e_desc="${unique_errors} unique / ${total_errors} total"

    printf "    ${DIM}Momentum:${RESET}      %3d  ${DIM}%s${RESET}\n" "$momentum" "$m_desc"
    printf "    ${DIM}Convergence:${RESET}   %3d  ${DIM}%s${RESET}\n" "$convergence" "$c_desc"
    printf "    ${DIM}Budget:${RESET}        %3d  ${DIM}%s${RESET}\n" "$budget_s" "$b_desc"
    printf "    ${DIM}Error Maturity:${RESET}%3d  ${DIM}%s${RESET}\n" "$error_maturity" "$e_desc"
    echo ""

    # ── Trajectory ──
    if [[ "$prev_score" != "none" && "$prev_score" != "null" ]]; then
        local trajectory_label trajectory_color
        prev_score=$(_safe_num "$prev_score")
        if [[ "$health_score" -gt "$prev_score" ]]; then
            trajectory_label="improving"
            trajectory_color="$GREEN"
        elif [[ "$health_score" -lt "$prev_score" ]]; then
            trajectory_label="declining"
            trajectory_color="$RED"
        else
            trajectory_label="stable"
            trajectory_color="$DIM"
        fi
        printf "  ${BOLD}Trajectory:${RESET}      ${trajectory_color}%s${RESET} ${DIM}(was %d → %d)${RESET}\n" \
            "$trajectory_label" "$prev_score" "$health_score"
    fi

    printf "  ${BOLD}Recommendation:${RESET}  %s\n" "$recommended_action"
    echo ""

    # ── Active pipeline info ──
    if [[ "$stage" != "unknown" ]]; then
        printf "  ${DIM}Active: stage=%s iter=%d elapsed=%s${RESET}\n" "$stage" "$iteration" "$elapsed"
        echo ""
    fi

    # ── Budget trajectory ──
    local bt
    bt=$(pipeline_budget_trajectory "$state_file")
    if [[ "$bt" == "warn" ]]; then
        echo -e "  ${YELLOW}${BOLD}⚠${RESET} ${YELLOW}Budget trajectory: may not have enough to finish${RESET}"
        echo ""
    elif [[ "$bt" == "stop" ]]; then
        echo -e "  ${RED}${BOLD}✗${RESET} ${RED}Budget trajectory: insufficient funds to continue${RESET}"
        echo ""
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# pipeline_check_health_gate
# Returns 0 if health is above threshold, 1 if below
# Args: [state_file] [artifacts_dir] [issue_number]
# ═══════════════════════════════════════════════════════════════════════════
pipeline_check_health_gate() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"
    local issue="${3:-}"
    local threshold="${VITALS_GATE_THRESHOLD:-40}"

    local vitals_json
    vitals_json=$(pipeline_compute_vitals "$state_file" "$artifacts_dir" "$issue" 2>/dev/null) || return 0

    local health
    health=$(echo "$vitals_json" | jq -r '.health_score // 50' 2>/dev/null) || health=50
    health=$(_safe_num "$health")

    if [[ "$health" -lt "$threshold" ]]; then
        warn "Health gate: score ${health} < threshold ${threshold}"
        return 1
    fi
    return 0
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Pipeline Vitals${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright vitals [options]"
    echo ""
    echo -e "  ${BOLD}OPTIONS${RESET}"
    echo -e "    ${CYAN}--issue${RESET} <N>           Issue number to check"
    echo -e "    ${CYAN}--state${RESET} <path>        Pipeline state file (default: .claude/pipeline-state.md)"
    echo -e "    ${CYAN}--artifacts${RESET} <path>    Artifacts directory (default: .claude/pipeline-artifacts)"
    echo -e "    ${CYAN}--json${RESET}                Output raw JSON instead of dashboard"
    echo -e "    ${CYAN}--score${RESET}               Output only the health score (0-100)"
    echo -e "    ${CYAN}--verdict${RESET}             Output only the verdict"
    echo -e "    ${CYAN}--budget${RESET}              Output only budget trajectory (ok/warn/stop)"
    echo -e "    ${CYAN}--help${RESET}                Show this help"
    echo ""
    echo -e "  ${BOLD}SIGNALS${RESET}  ${DIM}(weighted composite)${RESET}"
    echo -e "    ${DIM}Momentum     (35%)  Stage advancement, iteration progress, diff growth${RESET}"
    echo -e "    ${DIM}Convergence  (30%)  Error count trend across cycles${RESET}"
    echo -e "    ${DIM}Budget       (20%)  Remaining budget vs burn rate${RESET}"
    echo -e "    ${DIM}Error Maturity(15%) Unique errors vs total errors${RESET}"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}shipwright vitals${RESET}                    # Dashboard view"
    echo -e "    ${DIM}shipwright vitals --issue 42${RESET}         # Check specific issue"
    echo -e "    ${DIM}shipwright vitals --json${RESET}             # Machine-readable output"
    echo -e "    ${DIM}shipwright vitals --score${RESET}            # Just the number"
    echo ""
}

# ─── CLI Entry Point ────────────────────────────────────────────────────────
main() {
    local issue_num="" state_file="" artifacts_dir="" output_mode="dashboard"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue|-i)
                issue_num="$2"
                shift 2
                ;;
            --state)
                state_file="$2"
                shift 2
                ;;
            --artifacts)
                artifacts_dir="$2"
                shift 2
                ;;
            --json)
                output_mode="json"
                shift
                ;;
            --score)
                output_mode="score"
                shift
                ;;
            --verdict)
                output_mode="verdict"
                shift
                ;;
            --budget)
                output_mode="budget"
                shift
                ;;
            --help|-h|help)
                show_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                return 1
                ;;
        esac
    done

    # Defaults
    state_file="${state_file:-${PIPELINE_STATE:-${REPO_DIR}/.claude/pipeline-state.md}}"
    artifacts_dir="${artifacts_dir:-${REPO_DIR}/.claude/pipeline-artifacts}"

    case "$output_mode" in
        dashboard)
            vitals_dashboard "$state_file" "$artifacts_dir" "$issue_num"
            ;;
        json)
            pipeline_compute_vitals "$state_file" "$artifacts_dir" "$issue_num"
            ;;
        score)
            local vitals
            vitals=$(pipeline_compute_vitals "$state_file" "$artifacts_dir" "$issue_num")
            echo "$vitals" | jq -r '.health_score'
            ;;
        verdict)
            local vitals
            vitals=$(pipeline_compute_vitals "$state_file" "$artifacts_dir" "$issue_num")
            echo "$vitals" | jq -r '.verdict'
            ;;
        budget)
            pipeline_budget_trajectory "$state_file"
            ;;
    esac
}

# Only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
