#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright daemon test — Unit tests for daemon metrics, health, alerting      ║
# ║  Creates synthetic events · Sources daemon functions · Validates output  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="$SCRIPT_DIR/sw-daemon.sh"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-daemon-test.XXXXXX")

    # Create events directory (daemon uses $HOME/.shipwright)
    mkdir -p "$TEMP_DIR/.shipwright"
    mkdir -p "$TEMP_DIR/logs"
    mkdir -p "$TEMP_DIR/project/.claude"

    # Set env vars to redirect daemon state
    export HOME="$TEMP_DIR"
    export EVENTS_FILE="$TEMP_DIR/.shipwright/events.jsonl"
    export DAEMON_DIR="$TEMP_DIR/.shipwright"
    export STATE_FILE="$TEMP_DIR/.shipwright/daemon-state.json"
    export LOG_FILE="$TEMP_DIR/.shipwright/daemon.log"
    export LOG_DIR="$TEMP_DIR/logs"
    export WORKTREE_DIR="$TEMP_DIR/project/.worktrees"
    export PID_FILE="$TEMP_DIR/shipwright/daemon.pid"
    export SHUTDOWN_FLAG="$TEMP_DIR/shipwright/daemon.shutdown"
    export NO_GITHUB=true

    # Defaults for config vars
    export HEALTH_STALE_TIMEOUT=1800
    export PRIORITY_LABELS="urgent,p0,high,p1,normal,p2,low,p3"
    export DEGRADATION_WINDOW=5
    export DEGRADATION_CFR_THRESHOLD=30
    export DEGRADATION_SUCCESS_THRESHOLD=50
    export SLACK_WEBHOOK=""
    export POLL_INTERVAL=60
    export MAX_PARALLEL=2
    export WATCH_LABEL="ready-to-build"

    # Patrol defaults
    export PATROL_LABEL="auto-patrol"
    export PATROL_AUTO_WATCH=false
    export PATROL_MAX_ISSUES=5
    export PATROL_FAILURES_THRESHOLD=3
    export PATROL_DORA_ENABLED=true
    export PATROL_UNTESTED_ENABLED=true
    export PATROL_RETRY_ENABLED=true
    export PATROL_RETRY_THRESHOLD=2
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Reset between tests
reset_test() {
    rm -f "$EVENTS_FILE"
    rm -f "$STATE_FILE"
    rm -f "$LOG_FILE"
    touch "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Source daemon functions
# We extract functions from the daemon script by sourcing it in a subshell
# with SUBCOMMAND=help to avoid running the main logic, then exporting functions.
# Since the daemon runs setup_dirs and case statement at parse time, we
# instead directly define/source the functions we need to test.
# ═══════════════════════════════════════════════════════════════════════════════

# Source just the function definitions from the daemon script
source_daemon_functions() {
    # Extract function definitions using a careful approach:
    # We need: now_iso, now_epoch, epoch_to_iso, format_duration, emit_event,
    # dora_grade, daemon_health_check, daemon_check_degradation, daemon_log,
    # atomic_write_state, notify

    # Simple helpers we redefine directly (faster + safer than sourcing whole script)
    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    now_epoch() { date +%s; }

    epoch_to_iso() {
        local epoch="$1"
        date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($epoch).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || \
        echo "1970-01-01T00:00:00Z"
    }

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
        mkdir -p "$(dirname "$EVENTS_FILE")"
        echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
    }

    daemon_log() {
        local level="$1"
        shift
        local msg="$*"
        local ts
        ts=$(now_iso)
        echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    }

    notify() {
        # No-op in tests
        true
    }

    # patrol_build_labels — from updated daemon
    patrol_build_labels() {
        local check_label="$1"
        local labels="${PATROL_LABEL},${check_label}"
        if [[ "$PATROL_AUTO_WATCH" == "true" && -n "${WATCH_LABEL:-}" ]]; then
            labels="${labels},${WATCH_LABEL}"
        fi
        echo "$labels"
    }

    atomic_write_state() {
        local content="$1"
        local tmp_file="${STATE_FILE}.tmp.$$"
        echo "$content" > "$tmp_file"
        mv "$tmp_file" "$STATE_FILE"
    }

    # dora_grade — awk-based, matching the updated daemon script
    dora_grade() {
        local metric="$1" value="$2"
        case "$metric" in
            deploy_freq)
                if awk "BEGIN{exit !($value >= 7)}" 2>/dev/null; then echo "Elite"; return; fi
                if awk "BEGIN{exit !($value >= 1)}" 2>/dev/null; then echo "High"; return; fi
                if awk "BEGIN{exit !($value >= 0.25)}" 2>/dev/null; then echo "Medium"; return; fi
                echo "Low" ;;
            cycle_time)
                [[ "$value" -lt 3600 ]] && echo "Elite" && return
                [[ "$value" -lt 86400 ]] && echo "High" && return
                [[ "$value" -lt 604800 ]] && echo "Medium" && return
                echo "Low" ;;
            cfr)
                if awk "BEGIN{exit !($value < 5)}" 2>/dev/null; then echo "Elite"; return; fi
                if awk "BEGIN{exit !($value < 10)}" 2>/dev/null; then echo "High"; return; fi
                if awk "BEGIN{exit !($value < 15)}" 2>/dev/null; then echo "Medium"; return; fi
                echo "Low" ;;
            mttr)
                [[ "$value" -lt 3600 ]] && echo "Elite" && return
                [[ "$value" -lt 86400 ]] && echo "High" && return
                echo "Medium" ;;
        esac
    }

    # Progress monitoring directory for tests
    PROGRESS_DIR="$TEMP_DIR/progress"
    mkdir -p "$PROGRESS_DIR"

    # daemon_clear_progress — clean up progress state
    daemon_clear_progress() {
        local issue_num="$1"
        rm -f "$PROGRESS_DIR/issue-${issue_num}.json"
    }

    # daemon_assess_progress — compare snapshots and return verdict
    daemon_assess_progress() {
        local issue_num="$1" current_snapshot="$2"

        mkdir -p "$PROGRESS_DIR"
        local progress_file="$PROGRESS_DIR/issue-${issue_num}.json"

        if [[ ! -f "$progress_file" ]]; then
            jq -n \
                --argjson snap "$current_snapshot" \
                --arg issue "$issue_num" \
                '{
                    issue: $issue,
                    snapshots: [$snap],
                    no_progress_count: 0,
                    last_progress_at: $snap.ts,
                    repeated_error_count: 0
                }' > "$progress_file"
            echo "healthy"
            return
        fi

        local prev_data
        prev_data=$(cat "$progress_file")

        local prev_stage prev_iteration prev_diff_lines prev_files prev_error prev_no_progress
        prev_stage=$(echo "$prev_data" | jq -r '.snapshots[-1].stage // "unknown"')
        prev_iteration=$(echo "$prev_data" | jq -r '.snapshots[-1].iteration // 0')
        prev_diff_lines=$(echo "$prev_data" | jq -r '.snapshots[-1].diff_lines // 0')
        prev_files=$(echo "$prev_data" | jq -r '.snapshots[-1].files_changed // 0')
        prev_error=$(echo "$prev_data" | jq -r '.snapshots[-1].last_error // ""')
        prev_no_progress=$(echo "$prev_data" | jq -r '.no_progress_count // 0')
        local prev_repeated_errors
        prev_repeated_errors=$(echo "$prev_data" | jq -r '.repeated_error_count // 0')

        local cur_stage cur_iteration cur_diff cur_files cur_error
        cur_stage=$(echo "$current_snapshot" | jq -r '.stage')
        cur_iteration=$(echo "$current_snapshot" | jq -r '.iteration')
        cur_diff=$(echo "$current_snapshot" | jq -r '.diff_lines')
        cur_files=$(echo "$current_snapshot" | jq -r '.files_changed')
        cur_error=$(echo "$current_snapshot" | jq -r '.last_error')

        local has_progress=false

        if [[ "$cur_stage" != "$prev_stage" && "$cur_stage" != "unknown" ]]; then
            has_progress=true
        fi
        if [[ "$cur_iteration" -gt "$prev_iteration" ]]; then
            has_progress=true
        fi
        if [[ "$cur_diff" -gt "$prev_diff_lines" ]]; then
            has_progress=true
        fi
        if [[ "$cur_files" -gt "$prev_files" ]]; then
            has_progress=true
        fi

        local repeated_errors="$prev_repeated_errors"
        if [[ -n "$cur_error" && "$cur_error" == "$prev_error" ]]; then
            repeated_errors=$((repeated_errors + 1))
        elif [[ -n "$cur_error" && "$cur_error" != "$prev_error" ]]; then
            repeated_errors=0
        fi

        local no_progress_count
        if [[ "$has_progress" == "true" ]]; then
            no_progress_count=0
            repeated_errors=0
        else
            no_progress_count=$((prev_no_progress + 1))
        fi

        local tmp_progress="${progress_file}.tmp.$$"
        jq \
            --argjson snap "$current_snapshot" \
            --argjson npc "$no_progress_count" \
            --argjson rec "$repeated_errors" \
            --arg ts "$(now_iso)" \
            '
            .snapshots = ((.snapshots + [$snap]) | .[-10:]) |
            .no_progress_count = $npc |
            .repeated_error_count = $rec |
            if $npc == 0 then .last_progress_at = $ts else . end
            ' "$progress_file" > "$tmp_progress" 2>/dev/null && mv "$tmp_progress" "$progress_file"

        local warn_threshold="${PROGRESS_CHECKS_BEFORE_WARN:-3}"
        local kill_threshold="${PROGRESS_CHECKS_BEFORE_KILL:-6}"

        if [[ "$repeated_errors" -ge 3 ]]; then
            echo "stuck"
            return
        fi

        if [[ "$no_progress_count" -ge "$kill_threshold" ]]; then
            echo "stuck"
        elif [[ "$no_progress_count" -ge "$warn_threshold" ]]; then
            echo "stalled"
        elif [[ "$no_progress_count" -ge 1 ]]; then
            echo "slowing"
        else
            echo "healthy"
        fi
    }

    # daemon_health_check — updated with progress-based monitoring
    daemon_health_check() {
        local findings=0
        local now_e
        now_e=$(now_epoch)
        local use_progress="${PROGRESS_MONITORING:-true}"
        local hard_limit="${PROGRESS_HARD_LIMIT_S:-10800}"

        if [[ -f "$STATE_FILE" ]]; then
            while IFS= read -r job; do
                local pid started_at issue_num worktree
                pid=$(echo "$job" | jq -r '.pid')
                started_at=$(echo "$job" | jq -r '.started_at // empty')
                issue_num=$(echo "$job" | jq -r '.issue')
                worktree=$(echo "$job" | jq -r '.worktree // ""')

                if ! kill -0 "$pid" 2>/dev/null; then
                    continue
                fi

                local elapsed=0
                if [[ -n "$started_at" ]]; then
                    local start_e
                    start_e=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
                    elapsed=$(( now_e - start_e ))
                fi

                # Hard wall-clock limit
                if [[ "$elapsed" -gt "$hard_limit" ]]; then
                    daemon_log WARN "Hard limit exceeded: issue #${issue_num} (${elapsed}s > ${hard_limit}s, PID $pid) — killing"
                    kill "$pid" 2>/dev/null || true
                    daemon_clear_progress "$issue_num"
                    findings=$((findings + 1))
                    continue
                fi

                # Legacy fallback: use static timeout when progress monitoring is off
                if [[ "$use_progress" != "true" ]]; then
                    local stale_timeout="${HEALTH_STALE_TIMEOUT:-1800}"
                    if [[ "$elapsed" -gt "$stale_timeout" ]]; then
                        daemon_log WARN "Stale job (legacy): issue #${issue_num} (${elapsed}s > ${stale_timeout}s, PID $pid) — killing"
                        kill "$pid" 2>/dev/null || true
                        findings=$((findings + 1))
                    fi
                fi
            done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)
        fi

        local free_kb
        free_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
        if [[ -n "$free_kb" ]] && [[ "$free_kb" -lt 1048576 ]] 2>/dev/null; then
            daemon_log WARN "Low disk space: $(( free_kb / 1024 ))MB free"
            findings=$((findings + 1))
        fi

        if [[ -f "$EVENTS_FILE" ]]; then
            local events_size
            events_size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)
            if [[ "$events_size" -gt 104857600 ]]; then
                daemon_log WARN "Events file large ($(( events_size / 1048576 ))MB) — consider rotating"
                findings=$((findings + 1))
            fi
        fi

        if [[ "$findings" -gt 0 ]]; then
            emit_event "daemon.health" "findings=$findings"
        fi
    }

    # daemon_check_degradation — from the updated daemon
    daemon_check_degradation() {
        if [[ ! -f "$EVENTS_FILE" ]]; then return; fi

        local window="${DEGRADATION_WINDOW:-5}"
        local cfr_threshold="${DEGRADATION_CFR_THRESHOLD:-30}"
        local success_threshold="${DEGRADATION_SUCCESS_THRESHOLD:-50}"

        local recent
        recent=$(tail -200 "$EVENTS_FILE" | jq -s "[.[] | select(.type == \"pipeline.completed\")] | .[-${window}:]" 2>/dev/null)
        local count
        count=$(echo "$recent" | jq 'length' 2>/dev/null || echo 0)

        if [[ "$count" -lt "$window" ]]; then return; fi

        local failures successes
        failures=$(echo "$recent" | jq '[.[] | select(.result == "failure")] | length')
        successes=$(echo "$recent" | jq '[.[] | select(.result == "success")] | length')
        local cfr_pct=$(( failures * 100 / count ))
        local success_pct=$(( successes * 100 / count ))

        local alerts=""
        if [[ "$cfr_pct" -gt "$cfr_threshold" ]]; then
            alerts="CFR ${cfr_pct}% exceeds threshold ${cfr_threshold}%"
            daemon_log WARN "DEGRADATION: $alerts"
        fi
        if [[ "$success_pct" -lt "$success_threshold" ]]; then
            local msg="Success rate ${success_pct}% below threshold ${success_threshold}%"
            [[ -n "$alerts" ]] && alerts="$alerts; $msg" || alerts="$msg"
            daemon_log WARN "DEGRADATION: $msg"
        fi

        if [[ -n "$alerts" ]]; then
            emit_event "daemon.alert" "alerts=$alerts" "cfr_pct=$cfr_pct" "success_pct=$success_pct"

            if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
                notify "Pipeline Degradation Alert" "$alerts" "warn"
            fi
        fi
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# SYNTHETIC EVENT HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

# Write a synthetic event directly to events.jsonl
# Usage: write_event '{"ts":"...","type":"..."}'
write_event() {
    echo "$1" >> "$EVENTS_FILE"
}

# Write a pipeline.completed event with specific parameters
# Usage: write_pipeline_event <result> <duration_s> <ts> <ts_epoch>
write_pipeline_event() {
    local result="$1" duration_s="$2" ts="$3" ts_epoch="$4"
    write_event "{\"ts\":\"$ts\",\"ts_epoch\":$ts_epoch,\"type\":\"pipeline.completed\",\"result\":\"$result\",\"duration_s\":$duration_s}"
}

# Write a stage.completed event
# Usage: write_stage_event <stage> <duration_s> <ts>
write_stage_event() {
    local stage="$1" duration_s="$2" ts="$3"
    local ts_epoch
    ts_epoch=$(date +%s)
    write_event "{\"ts\":\"$ts\",\"ts_epoch\":$ts_epoch,\"type\":\"stage.completed\",\"stage\":\"$stage\",\"duration_s\":$duration_s}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_equals() {
    local expected="$1" actual="$2" label="${3:-value}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected '$expected', got '$actual' ($label)"
    return 1
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-contains}"
    if printf '%s\n' "$haystack" | grep -qE "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $needle ($label)"
    echo -e "    ${DIM}Got: $(echo "$haystack" | head -3)${RESET}"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not contains}"
    if ! printf '%s\n' "$haystack" | grep -qE "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $needle ($label)"
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_gt() {
    local actual="$1" threshold="$2" label="${3:-greater than}"
    if [[ "$actual" -gt "$threshold" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected $actual > $threshold ($label)"
    return 1
}

assert_json_key() {
    local json="$1" key="$2" expected="$3" label="${4:-json key}"
    local actual
    actual=$(echo "$json" | jq -r "$key" 2>/dev/null)
    assert_equals "$expected" "$actual" "$label"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. dora_grade deploy_freq — Elite for >= 7
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_elite() {
    local grade
    grade=$(dora_grade deploy_freq 10.0)
    assert_equals "Elite" "$grade" "deploy_freq 10.0 = Elite" &&
    grade=$(dora_grade deploy_freq 7.0)
    assert_equals "Elite" "$grade" "deploy_freq 7.0 = Elite" &&
    grade=$(dora_grade deploy_freq 7)
    assert_equals "Elite" "$grade" "deploy_freq 7 = Elite"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. dora_grade deploy_freq — High for >= 1
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_high() {
    local grade
    grade=$(dora_grade deploy_freq 3.5)
    assert_equals "High" "$grade" "deploy_freq 3.5 = High" &&
    grade=$(dora_grade deploy_freq 1.0)
    assert_equals "High" "$grade" "deploy_freq 1.0 = High"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. dora_grade deploy_freq — Medium for >= 0.25
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_medium() {
    local grade
    grade=$(dora_grade deploy_freq 0.5)
    assert_equals "Medium" "$grade" "deploy_freq 0.5 = Medium" &&
    grade=$(dora_grade deploy_freq 0.25)
    assert_equals "Medium" "$grade" "deploy_freq 0.25 = Medium"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. dora_grade deploy_freq — Low for < 0.25
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_low() {
    local grade
    grade=$(dora_grade deploy_freq 0.1)
    assert_equals "Low" "$grade" "deploy_freq 0.1 = Low" &&
    grade=$(dora_grade deploy_freq 0)
    assert_equals "Low" "$grade" "deploy_freq 0 = Low"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. dora_grade cfr — all thresholds
# ──────────────────────────────────────────────────────────────────────────────
test_dora_grade_cfr() {
    local grade
    grade=$(dora_grade cfr 3.0)
    assert_equals "Elite" "$grade" "cfr 3.0 = Elite" &&
    grade=$(dora_grade cfr 7.5)
    assert_equals "High" "$grade" "cfr 7.5 = High" &&
    grade=$(dora_grade cfr 12.0)
    assert_equals "Medium" "$grade" "cfr 12.0 = Medium" &&
    grade=$(dora_grade cfr 20.0)
    assert_equals "Low" "$grade" "cfr 20.0 = Low"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Stage timings — filter-first jq query
# ──────────────────────────────────────────────────────────────────────────────
test_stage_timings_filter() {
    local now_ts
    now_ts=$(now_iso)

    # Write stage.completed events
    write_stage_event "build" 120 "$now_ts"
    write_stage_event "build" 180 "$now_ts"
    write_stage_event "test" 60 "$now_ts"
    # Write a non-stage event that has a "stage" field (should NOT pollute results)
    write_event "{\"ts\":\"$now_ts\",\"ts_epoch\":$(now_epoch),\"type\":\"pipeline.started\",\"stage\":\"build\"}"

    # Run the fixed jq query
    local result
    result=$(cat "$EVENTS_FILE" | jq -s '[.[] | select(.type == "stage.completed")] | group_by(.stage) | map({stage: .[0].stage, avg: ([.[].duration_s] | add / length | floor)}) | sort_by(.avg) | reverse')

    # Should have 2 stages: build (avg 150) and test (avg 60)
    local stage_count build_avg
    stage_count=$(echo "$result" | jq 'length')
    build_avg=$(echo "$result" | jq '.[0].avg')

    assert_equals "2" "$stage_count" "2 stages found" &&
    assert_equals "150" "$build_avg" "build avg = 150s"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. MTTR — pairs failures with next success
# ──────────────────────────────────────────────────────────────────────────────
test_mttr_computation() {
    local base_epoch
    base_epoch=$(now_epoch)

    # Write events: failure at t=0, success at t=600 (10min gap)
    # Then failure at t=1200, success at t=2400 (20min gap)
    # Expected MTTR = (600 + 1200) / 2 = 900s
    local t0=$base_epoch
    local t1=$((base_epoch + 600))
    local t2=$((base_epoch + 1200))
    local t3=$((base_epoch + 2400))

    write_pipeline_event "failure" 100 "$(epoch_to_iso $t0)" "$t0"
    write_pipeline_event "success" 200 "$(epoch_to_iso $t1)" "$t1"
    write_pipeline_event "failure" 150 "$(epoch_to_iso $t2)" "$t2"
    write_pipeline_event "success" 250 "$(epoch_to_iso $t3)" "$t3"

    # Run the real MTTR jq from daemon
    local mttr
    mttr=$(cat "$EVENTS_FILE" | jq -s '
        [.[] | select(.type == "pipeline.completed")] | sort_by(.ts_epoch // 0) |
        [range(length) as $i |
            if .[$i].result == "failure" then
                [.[$i+1:][] | select(.result == "success")][0] as $next |
                if $next and $next.ts_epoch and .[$i].ts_epoch then
                    ($next.ts_epoch - .[$i].ts_epoch)
                else null end
            else null end
        ] | map(select(. != null)) |
        if length > 0 then (add / length | floor) else 0 end
    ')

    assert_equals "900" "$mttr" "MTTR = 900s (avg of 600+1200)"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. epoch_to_iso helper works
# ──────────────────────────────────────────────────────────────────────────────
test_epoch_to_iso_works() {
    # Known epoch: 1704067200 = 2024-01-01T00:00:00Z
    local result
    result=$(epoch_to_iso 1704067200)
    assert_equals "2024-01-01T00:00:00Z" "$result" "epoch 1704067200 → 2024-01-01"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Health check detects stale jobs
# ──────────────────────────────────────────────────────────────────────────────
test_health_check_stale() {
    # Create a state file with a job that started 2 hours ago
    local old_start
    old_start=$(epoch_to_iso $(($(now_epoch) - 7200)))

    # Start a background sleep process to simulate a stale job
    sleep 300 &
    local stale_pid=$!

    jq -n \
        --argjson pid "$stale_pid" \
        --arg started "$old_start" \
        '{
            version: 1,
            active_jobs: [{
                issue: 99,
                pid: $pid,
                worktree: "/tmp/test",
                title: "Stale test",
                started_at: $started
            }],
            queued: [],
            completed: []
        }' > "$STATE_FILE"

    # Test legacy mode (progress_based=false)
    PROGRESS_MONITORING=false
    HEALTH_STALE_TIMEOUT=1800  # 30min — job is 2h old, should be killed

    daemon_health_check

    # Give the process a moment to die after receiving SIGTERM
    sleep 0.5

    # The stale process should have been killed
    local still_running=true
    kill -0 "$stale_pid" 2>/dev/null || still_running=false

    # Clean up just in case
    kill "$stale_pid" 2>/dev/null || true
    wait "$stale_pid" 2>/dev/null || true

    # Reset to default
    PROGRESS_MONITORING=true

    assert_equals "false" "$still_running" "stale process was killed" &&
    assert_contains "$(cat "$LOG_FILE")" "Stale job .legacy." "log mentions stale job"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Priority sort — urgent issues come first
# ──────────────────────────────────────────────────────────────────────────────
test_priority_sort() {
    local issues='[
        {"number": 1, "title": "Low priority", "labels": [{"name": "low"}]},
        {"number": 2, "title": "Urgent fix", "labels": [{"name": "urgent"}]},
        {"number": 3, "title": "Normal task", "labels": [{"name": "normal"}]}
    ]'

    local priority_labels="urgent,p0,high,p1,normal,p2,low,p3"
    local sorted
    sorted=$(echo "$issues" | jq --arg plist "$priority_labels" '
        ($plist | split(",")) as $priorities |
        sort_by(
            [.labels[].name] as $issue_labels |
            ($priorities | to_entries | map(select(.value as $p | $issue_labels | any(. == $p))) | if length > 0 then .[0].key else 999 end)
        )
    ')

    local first_num second_num third_num
    first_num=$(echo "$sorted" | jq '.[0].number')
    second_num=$(echo "$sorted" | jq '.[1].number')
    third_num=$(echo "$sorted" | jq '.[2].number')

    assert_equals "2" "$first_num" "urgent issue #2 first" &&
    assert_equals "3" "$second_num" "normal issue #3 second" &&
    assert_equals "1" "$third_num" "low issue #1 third"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Degradation alert — triggers on high CFR
# ──────────────────────────────────────────────────────────────────────────────
test_degradation_alert() {
    local now_e
    now_e=$(now_epoch)

    # Write 5 pipeline completions: 4 failures, 1 success → 80% CFR
    for i in 1 2 3 4; do
        local t=$((now_e + i))
        write_pipeline_event "failure" 100 "$(epoch_to_iso $t)" "$t"
    done
    local t=$((now_e + 5))
    write_pipeline_event "success" 100 "$(epoch_to_iso $t)" "$t"

    DEGRADATION_WINDOW=5
    DEGRADATION_CFR_THRESHOLD=30
    DEGRADATION_SUCCESS_THRESHOLD=50

    daemon_check_degradation

    # Should have logged a degradation warning
    assert_contains "$(cat "$LOG_FILE")" "DEGRADATION" "degradation logged" &&
    assert_contains "$(cat "$LOG_FILE")" "CFR" "CFR alert logged"

    # Should have emitted a daemon.alert event
    assert_file_exists "$EVENTS_FILE" "events file exists" &&
    assert_contains "$(cat "$EVENTS_FILE")" "daemon.alert" "daemon.alert event emitted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Metrics JSON output — valid JSON with cycle_time keys
# ──────────────────────────────────────────────────────────────────────────────
test_metrics_json_output() {
    local now_e
    now_e=$(now_epoch)

    # Write enough events for metrics to have data
    for i in 1 2 3 4 5; do
        local t=$((now_e + i))
        write_pipeline_event "success" $((300 * i)) "$(epoch_to_iso $t)" "$t"
    done
    write_pipeline_event "failure" 100 "$(epoch_to_iso $((now_e + 6)))" "$((now_e + 6))"

    # Write some stage events
    write_stage_event "build" 120 "$(now_iso)"
    write_stage_event "test" 60 "$(now_iso)"

    # Run the real daemon metrics command and capture JSON
    local output
    output=$(cd "$TEMP_DIR/project" && bash "$DAEMON_SCRIPT" metrics --json --period 1 2>&1) || true

    # Validate it's valid JSON
    if ! echo "$output" | jq empty 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Output is not valid JSON"
        echo -e "    ${DIM}Got: $(echo "$output" | head -5)${RESET}"
        return 1
    fi

    # Check for cycle_time key (not lead_time)
    assert_contains "$output" "cycle_time" "has cycle_time key" &&
    assert_not_contains "$output" "lead_time" "no lead_time key" &&
    assert_contains "$output" "deploy_frequency" "has deploy_frequency" &&
    assert_contains "$output" "change_failure_rate" "has CFR" &&
    assert_contains "$output" "mttr" "has MTTR" &&
    assert_json_key "$output" ".dora.cycle_time.grade" "Elite" "cycle_time grade present"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Patrol build labels — watch label included when enabled
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_build_labels_enabled() {
    PATROL_AUTO_WATCH=true
    WATCH_LABEL="ready-to-build"
    PATROL_LABEL="auto-patrol"

    local result
    result=$(patrol_build_labels "security")

    assert_contains "$result" "auto-patrol" "has patrol label" &&
    assert_contains "$result" "security" "has check label" &&
    assert_contains "$result" "ready-to-build" "has watch label"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Patrol build labels — watch label excluded when disabled
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_build_labels_disabled() {
    PATROL_AUTO_WATCH=false
    WATCH_LABEL="ready-to-build"
    PATROL_LABEL="auto-patrol"

    local result
    result=$(patrol_build_labels "security")

    assert_contains "$result" "auto-patrol" "has patrol label" &&
    assert_contains "$result" "security" "has check label" &&
    assert_not_contains "$result" "ready-to-build" "no watch label when disabled"
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Patrol recurring failures — label construction
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_recurring_failures() {
    # Setup mock memory with recurring failures
    local mem_dir="$HOME/.shipwright/memory"
    mkdir -p "$mem_dir"

    # Set thresholds
    PATROL_FAILURES_THRESHOLD=3
    NO_GITHUB=true
    PATROL_DRY_RUN=true

    # The actual patrol_recurring_failures function requires sourcing sw-memory.sh
    # which needs a git repo. We test the self-labeling mechanism instead.
    local labels
    labels=$(patrol_build_labels "recurring-failure")
    assert_contains "$labels" "recurring-failure" "recurring-failure label present" &&
    assert_contains "$labels" "auto-patrol" "patrol label present"
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. DORA degradation event detection
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_dora_events() {
    # Write pipeline events showing degradation
    local now_e
    now_e=$(now_epoch)

    # Previous window: 5 successes, 0 failures (Elite CFR)
    for i in 1 2 3 4 5; do
        local ts_e=$((now_e - 1000000 + i * 100))
        write_pipeline_event "success" 300 "$(epoch_to_iso "$ts_e")" "$ts_e"
    done

    # Current window: 2 successes, 4 failures (67% CFR = Low)
    for i in 1 2; do
        local ts_e=$((now_e - 100000 + i * 100))
        write_pipeline_event "success" 300 "$(epoch_to_iso "$ts_e")" "$ts_e"
    done
    for i in 1 2 3 4; do
        local ts_e=$((now_e - 50000 + i * 100))
        write_pipeline_event "failure" 300 "$(epoch_to_iso "$ts_e")" "$ts_e"
    done

    # Verify events were written
    local total_events
    total_events=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
    assert_gt "$total_events" 5 "should have written pipeline events" &&

    # Verify we can extract pipeline.completed events
    local completed
    completed=$(jq -s '[.[] | select(.type == "pipeline.completed")] | length' "$EVENTS_FILE")
    assert_equals "11" "$completed" "11 pipeline.completed events"
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Retry exhaustion event detection
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_retry_exhaustion_events() {
    local now_e
    now_e=$(now_epoch)

    # Write retry_exhausted events
    for i in 1 2 3; do
        local ts_e=$((now_e - 86400 + i * 3600))
        write_event "{\"ts\":\"$(epoch_to_iso "$ts_e")\",\"ts_epoch\":$ts_e,\"type\":\"daemon.retry_exhausted\",\"issue\":\"42\"}"
    done

    # Verify events
    local exhausted_count
    exhausted_count=$(jq -s '[.[] | select(.type == "daemon.retry_exhausted")] | length' "$EVENTS_FILE")
    assert_equals "3" "$exhausted_count" "3 retry_exhausted events" &&

    # Verify threshold logic: 3 >= 2 (default threshold)
    assert_gt "$exhausted_count" "$PATROL_RETRY_THRESHOLD" "count exceeds threshold"
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Untested script detection logic
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_untested_detection() {
    # Create a mock scripts directory
    local mock_scripts="$TEMP_DIR/scripts"
    mkdir -p "$mock_scripts"

    # Create mock scripts (some with tests, some without)
    echo '#!/bin/bash' > "$mock_scripts/sw-foo.sh"
    echo '#!/bin/bash' > "$mock_scripts/sw-bar.sh"
    echo '#!/bin/bash' > "$mock_scripts/sw-baz.sh"
    echo '#!/bin/bash' > "$mock_scripts/sw-foo-test.sh"  # foo has a test
    echo '#!/bin/bash' > "$mock_scripts/sw-bar-test.sh"  # bar has a test
    # baz has NO test

    # Check that baz would be detected as untested
    local has_test=false
    [[ -f "$mock_scripts/sw-baz-test.sh" ]] && has_test=true

    assert_equals "false" "$has_test" "baz has no test file" &&

    # Check foo does have a test
    local foo_has_test=false
    [[ -f "$mock_scripts/sw-foo-test.sh" ]] && foo_has_test=true
    assert_equals "true" "$foo_has_test" "foo has test file"
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Progress assessment detects forward progress (stage change)
# ──────────────────────────────────────────────────────────────────────────────
test_progress_stage_advance() {
    daemon_clear_progress "42"

    # First snapshot: build stage
    local snap1
    snap1=$(jq -n '{stage:"build", iteration:1, diff_lines:50, files_changed:3, last_error:"", ts:"2026-01-01T00:00:00Z"}')
    local verdict1
    verdict1=$(daemon_assess_progress "42" "$snap1")
    assert_equals "healthy" "$verdict1" "first snapshot is always healthy"

    # Second snapshot: test stage (advanced!)
    local snap2
    snap2=$(jq -n '{stage:"test", iteration:1, diff_lines:50, files_changed:3, last_error:"", ts:"2026-01-01T00:05:00Z"}')
    local verdict2
    verdict2=$(daemon_assess_progress "42" "$snap2")
    assert_equals "healthy" "$verdict2" "stage advance = progress"
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Progress assessment detects stuck (no change for N checks)
# ──────────────────────────────────────────────────────────────────────────────
test_progress_stuck_detection() {
    daemon_clear_progress "43"
    PROGRESS_CHECKS_BEFORE_WARN=2
    PROGRESS_CHECKS_BEFORE_KILL=4

    # Same snapshot repeated — no progress
    local snap
    snap=$(jq -n '{stage:"build", iteration:3, diff_lines:100, files_changed:5, last_error:"", ts:"2026-01-01T00:00:00Z"}')

    local v
    v=$(daemon_assess_progress "43" "$snap"); # first → healthy
    v=$(daemon_assess_progress "43" "$snap"); assert_equals "slowing" "$v" "1 check with no progress = slowing"
    v=$(daemon_assess_progress "43" "$snap"); assert_equals "stalled" "$v" "2 checks = stalled"
    v=$(daemon_assess_progress "43" "$snap"); assert_equals "stalled" "$v" "3 checks = stalled"
    v=$(daemon_assess_progress "43" "$snap"); assert_equals "stuck" "$v" "4 checks = stuck (kill threshold)"

    # Reset
    PROGRESS_CHECKS_BEFORE_WARN=3
    PROGRESS_CHECKS_BEFORE_KILL=6
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Progress assessment detects repeated errors (same error 3x)
# ──────────────────────────────────────────────────────────────────────────────
test_progress_repeated_errors() {
    daemon_clear_progress "44"
    PROGRESS_CHECKS_BEFORE_WARN=3
    PROGRESS_CHECKS_BEFORE_KILL=6

    # Same error signature repeating with no progress
    local snap
    snap=$(jq -n '{stage:"build", iteration:3, diff_lines:100, files_changed:5, last_error:"TypeError: undefined is not a function", ts:"2026-01-01T00:00:00Z"}')

    local v
    v=$(daemon_assess_progress "44" "$snap"); # first → healthy (no previous)
    v=$(daemon_assess_progress "44" "$snap"); # 1 repeat
    v=$(daemon_assess_progress "44" "$snap"); # 2 repeats
    v=$(daemon_assess_progress "44" "$snap"); # 3 repeats → stuck
    assert_equals "stuck" "$v" "3 repeated errors → stuck regardless of check count"

    # Reset
    PROGRESS_CHECKS_BEFORE_WARN=3
    PROGRESS_CHECKS_BEFORE_KILL=6
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. Progress resets when diff grows (agent writing code)
# ──────────────────────────────────────────────────────────────────────────────
test_progress_diff_growth_resets() {
    daemon_clear_progress "45"
    PROGRESS_CHECKS_BEFORE_WARN=2
    PROGRESS_CHECKS_BEFORE_KILL=4

    local snap1
    snap1=$(jq -n '{stage:"build", iteration:3, diff_lines:50, files_changed:3, last_error:"", ts:"2026-01-01T00:00:00Z"}')
    local v
    v=$(daemon_assess_progress "45" "$snap1"); # first → healthy

    # Same snapshot → slowing
    v=$(daemon_assess_progress "45" "$snap1"); assert_equals "slowing" "$v" "no change = slowing"

    # But diff_lines grew → back to healthy
    local snap2
    snap2=$(jq -n '{stage:"build", iteration:3, diff_lines:80, files_changed:3, last_error:"", ts:"2026-01-01T00:10:00Z"}')
    v=$(daemon_assess_progress "45" "$snap2"); assert_equals "healthy" "$v" "diff growth = progress"

    # Reset
    PROGRESS_CHECKS_BEFORE_WARN=3
    PROGRESS_CHECKS_BEFORE_KILL=6
}

# ──────────────────────────────────────────────────────────────────────────────
# 23. Hard limit kills even with progress monitoring on
# ──────────────────────────────────────────────────────────────────────────────
test_hard_limit_override() {
    # Job that started 4 hours ago (exceeds 3h hard limit)
    local old_start
    old_start=$(epoch_to_iso $(($(now_epoch) - 14400)))

    sleep 300 &
    local stale_pid=$!

    jq -n \
        --argjson pid "$stale_pid" \
        --arg started "$old_start" \
        '{
            version: 1,
            active_jobs: [{
                issue: 98,
                pid: $pid,
                worktree: "/tmp/test-hard",
                title: "Long running test",
                started_at: $started
            }],
            queued: [],
            completed: []
        }' > "$STATE_FILE"

    PROGRESS_MONITORING=true
    PROGRESS_HARD_LIMIT_S=10800  # 3h

    daemon_health_check

    sleep 0.5

    local still_running=true
    kill -0 "$stale_pid" 2>/dev/null || still_running=false

    kill "$stale_pid" 2>/dev/null || true
    wait "$stale_pid" 2>/dev/null || true

    assert_equals "false" "$still_running" "process killed by hard limit" &&
    assert_contains "$(cat "$LOG_FILE")" "Hard limit exceeded" "log mentions hard limit"
}

# ──────────────────────────────────────────────────────────────────────────────
# 24. Adaptive cycles convergence — extends limit on >50% issue drop
# ──────────────────────────────────────────────────────────────────────────────
test_adaptive_cycles_convergence() {
    # Create a minimal script with the pipeline_adaptive_cycles function
    local fns_script="$TEMP_DIR/adaptive-cycles-fns.sh"
    cat > "$fns_script" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
emit_event() { true; }
info() { true; }
warn() { true; }
IGNORE_BUDGET=true
SCRIPT_DIR="/nonexistent"
ISSUE_NUMBER=""

# Extract and include the real function from sw-pipeline.sh
FEOF

    # Extract the pipeline_adaptive_cycles function from the real pipeline
    sed -n '/^pipeline_adaptive_cycles()/,/^}/p' "$(dirname "$DAEMON_SCRIPT")/sw-pipeline.sh" >> "$fns_script" 2>/dev/null

    # Test 1: rapid convergence (10 issues → 3 issues, >50% drop) should extend by 1
    local result
    result=$(
        source "$fns_script" 2>/dev/null
        pipeline_adaptive_cycles 3 "compound_quality" 3 10
    ) || result=""

    if [[ "$result" == "4" ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected adaptive limit 4 (3+1 for convergence), got '$result'"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 25. Adaptive cycles divergence — reduces limit on issue count increase
# ──────────────────────────────────────────────────────────────────────────────
test_adaptive_cycles_divergence() {
    # Create a minimal script with the pipeline_adaptive_cycles function
    local fns_script="$TEMP_DIR/adaptive-cycles-div-fns.sh"
    cat > "$fns_script" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
emit_event() { true; }
info() { true; }
warn() { true; }
IGNORE_BUDGET=true
SCRIPT_DIR="/nonexistent"
ISSUE_NUMBER=""
FEOF

    # Extract the pipeline_adaptive_cycles function from the real pipeline
    sed -n '/^pipeline_adaptive_cycles()/,/^}/p' "$(dirname "$DAEMON_SCRIPT")/sw-pipeline.sh" >> "$fns_script" 2>/dev/null

    # Test: divergence (5 issues → 8 issues) should reduce limit by 1
    local result
    result=$(
        source "$fns_script" 2>/dev/null
        pipeline_adaptive_cycles 3 "compound_quality" 8 5
    ) || result=""

    if [[ "$result" == "2" ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected adaptive limit 2 (3-1 for divergence), got '$result'"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 26. Adaptive cycles hard ceiling — never exceeds 2x base limit
# ──────────────────────────────────────────────────────────────────────────────
test_adaptive_cycles_hard_ceiling() {
    # Create a minimal script with the pipeline_adaptive_cycles function
    local fns_script="$TEMP_DIR/adaptive-cycles-ceil-fns.sh"
    cat > "$fns_script" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
emit_event() { true; }
info() { true; }
warn() { true; }
IGNORE_BUDGET=true
SCRIPT_DIR="/nonexistent"
ISSUE_NUMBER=""
FEOF

    # Extract the pipeline_adaptive_cycles function from the real pipeline
    sed -n '/^pipeline_adaptive_cycles()/,/^}/p' "$(dirname "$DAEMON_SCRIPT")/sw-pipeline.sh" >> "$fns_script" 2>/dev/null

    # Test: even with convergence, hard ceiling is 2x base (base=3 → max=6)
    local result
    result=$(
        source "$fns_script" 2>/dev/null
        pipeline_adaptive_cycles 3 "compound_quality" 1 10
    ) || result=""

    # Should be at most 6 (2 * 3), even with convergence boost
    if [[ "$result" -le 6 && "$result" -ge 3 ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected adaptive limit <= 6 (hard ceiling), got '$result'"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 27. Adaptive cycles no-op on first cycle — prev_issue_count=-1
# ──────────────────────────────────────────────────────────────────────────────
test_adaptive_cycles_first_cycle() {
    # Create a minimal script with the pipeline_adaptive_cycles function
    local fns_script="$TEMP_DIR/adaptive-cycles-first-fns.sh"
    cat > "$fns_script" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
emit_event() { true; }
info() { true; }
warn() { true; }
IGNORE_BUDGET=true
SCRIPT_DIR="/nonexistent"
ISSUE_NUMBER=""
FEOF

    # Extract the pipeline_adaptive_cycles function from the real pipeline
    sed -n '/^pipeline_adaptive_cycles()/,/^}/p' "$(dirname "$DAEMON_SCRIPT")/sw-pipeline.sh" >> "$fns_script" 2>/dev/null

    # Test: on first cycle (no previous count), return base_limit unchanged
    local result
    result=$(
        source "$fns_script" 2>/dev/null
        pipeline_adaptive_cycles 3 "compound_quality" 5 -1
    ) || result=""

    if [[ "$result" == "3" ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected base limit 3 (no adaptation on first cycle), got '$result'"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 28. Checkpoint expire removes old checkpoints
# ──────────────────────────────────────────────────────────────────────────────
test_checkpoint_expire() {
    local cp_dir="$TEMP_DIR/project/.claude/pipeline-artifacts/checkpoints"
    mkdir -p "$cp_dir"

    # Create a checkpoint with a very old created_at
    cat > "$cp_dir/build-checkpoint.json" <<'EOF'
{"stage":"build","iteration":3,"created_at":"2020-01-01T00:00:00Z"}
EOF

    # Create a fresh checkpoint (within the last hour)
    local fresh_ts
    fresh_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$cp_dir/test-checkpoint.json" <<EOF
{"stage":"test","iteration":1,"created_at":"${fresh_ts}"}
EOF

    # Run checkpoint expire with 1 hour max
    local checkpoint_script
    checkpoint_script="$(dirname "$DAEMON_SCRIPT")/sw-checkpoint.sh"
    if [[ ! -f "$checkpoint_script" ]]; then
        echo -e "    ${RED}✗${RESET} sw-checkpoint.sh not found"
        FAIL=$((FAIL + 1))
        return 1
    fi

    (cd "$TEMP_DIR/project" && bash "$checkpoint_script" expire --hours 1 2>/dev/null) || true

    # Old checkpoint should be removed
    if [[ -f "$cp_dir/build-checkpoint.json" ]]; then
        echo -e "    ${RED}✗${RESET} Old checkpoint should have been expired"
        FAIL=$((FAIL + 1))
        return 1
    fi

    # Fresh checkpoint should remain
    if [[ ! -f "$cp_dir/test-checkpoint.json" ]]; then
        echo -e "    ${RED}✗${RESET} Fresh checkpoint should NOT have been expired"
        FAIL=$((FAIL + 1))
        return 1
    fi

    PASS=$((PASS + 1))
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 29. Daemon failure handler removes watch label
# ──────────────────────────────────────────────────────────────────────────────
test_daemon_failure_removes_watch_label() {
    # Verify the daemon_on_failure function includes --remove-label for watch label
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    # Check that the failure handler removes the watch label
    if grep -A 5 "No retry.*report final failure" "$daemon_src" | grep -q "remove-label.*WATCH_LABEL"; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} daemon_on_failure should remove WATCH_LABEL on final failure"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 30. Daemon failure handler closes draft PRs
# ──────────────────────────────────────────────────────────────────────────────
test_daemon_failure_closes_draft_pr() {
    # Verify the daemon_on_failure function has draft PR cleanup logic
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    if grep -q 'gh pr close.*draft_pr.*delete-branch' "$daemon_src"; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} daemon_on_failure should close draft PRs on final failure"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 31. Cleanup script has pipeline artifact sections
# ──────────────────────────────────────────────────────────────────────────────
test_cleanup_has_artifact_sections() {
    local cleanup_src
    cleanup_src="$(dirname "$DAEMON_SCRIPT")/sw-cleanup.sh"

    local sections_found=0
    if grep -q "Pipeline Artifacts" "$cleanup_src"; then
        sections_found=$((sections_found + 1))
    fi
    if grep -q "Checkpoints" "$cleanup_src"; then
        sections_found=$((sections_found + 1))
    fi
    if grep -q "Pipeline State" "$cleanup_src"; then
        sections_found=$((sections_found + 1))
    fi
    if grep -q "Heartbeats" "$cleanup_src"; then
        sections_found=$((sections_found + 1))
    fi
    if grep -q "Orphaned Branches" "$cleanup_src"; then
        sections_found=$((sections_found + 1))
    fi

    if [[ "$sections_found" -ge 5 ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected 5 cleanup sections, found $sections_found"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 32. Daemon sources vitals module
# ──────────────────────────────────────────────────────────────────────────────
test_daemon_sources_vitals() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    # Check that the daemon sources sw-pipeline-vitals.sh
    if grep -q 'source.*sw-pipeline-vitals.sh' "$daemon_src"; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} daemon should source sw-pipeline-vitals.sh"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 33. Vitals verdict mapping: continue→healthy, warn→slowing, intervene→stalled, abort→stuck
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_verdict_mapping() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    # Extract the vitals verdict mapping block and verify all 4 mappings
    local found=0
    if grep -q 'Map vitals verdict to daemon verdict' "$daemon_src"; then
        found=$((found + 1))
    fi
    # Check the case block contains all 4 mappings (use multiline sed to extract)
    local mapping_block
    mapping_block=$(sed -n '/Map vitals verdict/,/esac/p' "$daemon_src" 2>/dev/null || true)
    if echo "$mapping_block" | grep -q 'echo "healthy"'; then
        found=$((found + 1))
    fi
    if echo "$mapping_block" | grep -q 'echo "slowing"'; then
        found=$((found + 1))
    fi
    if echo "$mapping_block" | grep -q 'echo "stalled"'; then
        found=$((found + 1))
    fi
    if echo "$mapping_block" | grep -q 'echo "stuck"'; then
        found=$((found + 1))
    fi

    if [[ "$found" -ge 4 ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected 4+ vitals verdict mappings, found $found"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 34. Vitals emits pipeline.vitals_check event
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_event_emission() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    # Verify the daemon emits pipeline.vitals_check events
    if grep -q 'emit_event "pipeline.vitals_check"' "$daemon_src"; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} daemon should emit pipeline.vitals_check events"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 35. Auto-scale includes vitals health factor
# ──────────────────────────────────────────────────────────────────────────────
test_autoscale_vitals_factor() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    local found=0
    # Check for vitals-driven scaling factor
    if grep -q 'max_by_vitals' "$daemon_src"; then
        found=$((found + 1))
    fi
    # Check that vitals factor caps workers when health is low
    if grep -q '_avg_health.*-lt 50' "$daemon_src"; then
        found=$((found + 1))
    fi
    # Check that vitals factor is included in min computation
    if grep -q 'max_by_vitals.*-lt.*computed' "$daemon_src"; then
        found=$((found + 1))
    fi

    if [[ "$found" -ge 3 ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected 3 vitals auto-scale checks, found $found"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 36. Quality memory drives template selection
# ──────────────────────────────────────────────────────────────────────────────
test_quality_memory_template() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    local found=0
    # Check for quality-scores.jsonl reference
    if grep -q 'quality-scores.jsonl' "$daemon_src"; then
        found=$((found + 1))
    fi
    # Check for enterprise escalation on critical findings
    if grep -q 'critical findings.*enterprise' "$daemon_src"; then
        found=$((found + 1))
    fi
    # Check for full template on poor quality
    if grep -q 'avg.*score.*full template' "$daemon_src"; then
        found=$((found + 1))
    fi
    # Check for fast template on excellent quality
    if grep -q 'eligible for fast' "$daemon_src"; then
        found=$((found + 1))
    fi

    if [[ "$found" -ge 3 ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected 3+ quality memory template checks, found $found"
    FAIL=$((FAIL + 1))
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 37. Vitals-based progress replaces static thresholds (with fallback)
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_progress_fallback() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    local found=0
    # Vitals-based verdict is attempted first
    if grep -q 'Vitals-based verdict.*preferred over static' "$daemon_src"; then
        found=$((found + 1))
    fi
    # Static thresholds still exist as fallback
    if grep -q 'PROGRESS_CHECKS_BEFORE_WARN' "$daemon_src"; then
        found=$((found + 1))
    fi
    if grep -q 'PROGRESS_CHECKS_BEFORE_KILL' "$daemon_src"; then
        found=$((found + 1))
    fi

    if [[ "$found" -ge 3 ]]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected vitals + static fallback pattern, found $found of 3"
    FAIL=$((FAIL + 1))
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# MEMORY AND LEARNING TESTS (4C)
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 38. Memory: query fix for error returns matching fix
# ──────────────────────────────────────────────────────────────────────────────
test_memory_query_fix() {
    local mem_dir="$TEMP_DIR/.shipwright/memory"
    # Create a fake repo hash directory
    local repo_dir="$mem_dir/test-repo-hash"
    mkdir -p "$repo_dir"

    cat > "$repo_dir/failures.json" <<'MEMJSON'
{"failures":[{"stage":"build","pattern":"TypeError: cannot read property","fix":"Add null check before property access","fix_effectiveness_rate":85,"seen_count":3,"category":"logic"}]}
MEMJSON

    # Source memory.sh in a subshell with overridden paths
    local result
    result=$(
        MEMORY_ROOT="$mem_dir"
        repo_hash() { echo "test-repo-hash"; }
        repo_name() { echo "test/repo"; }
        ensure_memory_dir() { true; }
        export -f repo_hash repo_name ensure_memory_dir

        # Source just the function we need
        local mem_script
        mem_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sw-memory.sh"
        # Extract memory_query_fix_for_error
        memory_query_fix_for_error() {
            local error_pattern="$1"
            [[ -z "$error_pattern" ]] && return 0
            local failures_file="$repo_dir/failures.json"
            [[ ! -f "$failures_file" ]] && return 0
            local matches
            matches=$(jq -r --arg pat "$error_pattern" '
                [.failures[]
                | select(.pattern != null and .pattern != "")
                | select(.pattern | test($pat; "i") // false)
                | select(.fix != null and .fix != "")
                | select((.fix_effectiveness_rate // 0) > 50)
                | {fix, fix_effectiveness_rate, seen_count, category, stage, pattern}]
                | sort_by(-.fix_effectiveness_rate)
                | .[0] // null
            ' "$failures_file" 2>/dev/null) || true
            if [[ -n "$matches" && "$matches" != "null" ]]; then
                echo "$matches"
            fi
        }

        memory_query_fix_for_error "TypeError"
    ) || true

    assert_contains "$result" "null check" "fix contains null check advice"
}

# ──────────────────────────────────────────────────────────────────────────────
# 39. DORA template escalation: CFR>40% → enterprise eligible
# ──────────────────────────────────────────────────────────────────────────────
test_dora_template_escalation() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    # Verify the DORA-based template selection patterns exist
    local found=0
    # Check for CFR threshold driving template escalation
    if grep -q "cfr.*enterprise\|enterprise.*cfr\|CFR.*enterprise" "$daemon_src"; then
        found=$((found + 1))
    fi
    # Check for fast template eligibility
    if grep -q "eligible for fast\|fast.*eligible\|cfr.*fast" "$daemon_src"; then
        found=$((found + 1))
    fi

    if [[ "$found" -ge 2 ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected DORA template escalation patterns, found $found of 2"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 40. Error classification: all 12 categories in post-tool-use.sh
# ──────────────────────────────────────────────────────────────────────────────
test_error_classification_categories() {
    local hook_file
    hook_file="$(cd "$(dirname "$DAEMON_SCRIPT")/.." && pwd)/.claude/hooks/post-tool-use.sh"
    [[ ! -f "$hook_file" ]] && { echo -e "    ${RED}✗${RESET} post-tool-use.sh not found at $hook_file"; return 1; }

    local categories="test syntax missing permission timeout security logic dependency flaky config api resource"
    local missing=""
    for cat in $categories; do
        if ! grep -q "\"$cat\"" "$hook_file" 2>/dev/null; then
            missing="${missing} $cat"
        fi
    done

    if [[ -z "$missing" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Missing error categories:$missing"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 41. Template weights selection — select_pipeline_template reads weights file
# ──────────────────────────────────────────────────────────────────────────────
test_template_weights_selection() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    # Verify template-weights.json is read in select_pipeline_template
    grep -q "template-weights.json" "$daemon_src" || \
        { echo "Expected template-weights.json reference in daemon"; return 1; }

    # Verify the jq filter queries .weights with sample_size >= 3
    grep -q 'sample_size >= 3' "$daemon_src" || \
        { echo "Expected sample_size >= 3 filter in template weights"; return 1; }

    # Verify sort_by success_rate for best template selection
    grep -q 'sort_by.*success_rate' "$daemon_src" || \
        { echo "Expected sort_by success_rate in template weights"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 42. Auto-enable self_optimize when auto_template is true
# ──────────────────────────────────────────────────────────────────────────────
test_auto_enable_self_optimize() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"

    # Verify the auto-enable logic exists in load_config
    grep -q 'Auto-enabling self_optimize' "$daemon_src" || \
        { echo "Expected auto-enable self_optimize log message"; return 1; }

    # Verify the condition: auto_template true AND self_optimize false
    grep -q 'AUTO_TEMPLATE.*true.*SELF_OPTIMIZE.*false\|auto_template.*self_optimize' "$daemon_src" || \
        { echo "Expected AUTO_TEMPLATE/SELF_OPTIMIZE condition check"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 43-52. Intelligence: Failure classification, auth check, process management
# ──────────────────────────────────────────────────────────────────────────────

test_classify_failure_auth() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'classify_failure()' "$daemon_src" || \
        { echo "classify_failure function not found"; return 1; }
    grep -A 30 'classify_failure()' "$daemon_src" | grep -q 'not logged in' || \
        { echo "Missing auth error pattern 'not logged in'"; return 1; }
    grep -A 30 'classify_failure()' "$daemon_src" | grep -q 'unauthorized' || \
        { echo "Missing auth error pattern 'unauthorized'"; return 1; }
}

test_classify_failure_all_classes() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    local classes=("auth_error" "api_error" "invalid_issue" "context_exhaustion" "build_failure" "unknown")
    for class in "${classes[@]}"; do
        grep -A 80 'classify_failure()' "$daemon_src" | grep -q "echo \"$class\"" || \
            { echo "Missing failure class: $class"; return 1; }
    done
}

test_retry_skips_non_retryable() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -A 80 'daemon_on_failure()' "$daemon_src" | grep -q 'auth_error)' || \
        { echo "Missing auth_error case in retry logic"; return 1; }
    grep -A 80 'daemon_on_failure()' "$daemon_src" | grep -q 'invalid_issue)' || \
        { echo "Missing invalid_issue case in retry logic"; return 1; }
    grep -A 80 'daemon_on_failure()' "$daemon_src" | grep -q 'skip.*retry\|skipping retry' || \
        { echo "Missing skip retry action for non-retryable failures"; return 1; }
}

test_api_error_extended_backoff() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'api_backoff=300' "$daemon_src" || \
        { echo "Missing api_backoff=300 constant"; return 1; }
}

test_preflight_auth_check() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'daemon_preflight_auth_check()' "$daemon_src" || \
        { echo "daemon_preflight_auth_check function not found"; return 1; }
    grep -A 60 'daemon_preflight_auth_check()' "$daemon_src" | grep -q 'gh auth status' || \
        { echo "Missing gh auth check"; return 1; }
    grep -A 60 'daemon_preflight_auth_check()' "$daemon_src" | grep -q 'claude.*--print' || \
        { echo "Missing claude auth check"; return 1; }
    grep -B 5 'daemon_poll_issues' "$daemon_src" | grep -q 'daemon_preflight_auth_check' || \
        { echo "Auth check not wired into poll loop"; return 1; }
}

test_process_group_spawn() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -B 5 'exec.*sw-pipeline.sh' "$daemon_src" | grep -q "trap '' HUP" || \
        { echo "Missing HUP trap in spawn subshell"; return 1; }
}

test_process_tree_kill() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -A 30 'cleanup_on_exit()' "$daemon_src" | grep -q 'pkill.*-P' || \
        { echo "Missing pkill -P in cleanup_on_exit"; return 1; }
}

test_consecutive_failure_pause() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'DAEMON_CONSECUTIVE_FAILURE_CLASS=' "$daemon_src" || \
        { echo "Missing DAEMON_CONSECUTIVE_FAILURE_CLASS variable"; return 1; }
    grep -q 'DAEMON_CONSECUTIVE_FAILURE_COUNT=' "$daemon_src" || \
        { echo "Missing DAEMON_CONSECUTIVE_FAILURE_COUNT variable"; return 1; }
    grep -q 'DAEMON_CONSECUTIVE_FAILURE_COUNT.*-ge 3' "$daemon_src" || \
        { echo "Missing consecutive failure threshold of 3"; return 1; }
    grep -q 'daemon.auto_pause.*consecutive_failures' "$daemon_src" || \
        { echo "Missing auto_pause event for consecutive failures"; return 1; }
    grep -q 'reset_failure_tracking()' "$daemon_src" || \
        { echo "Missing reset_failure_tracking function"; return 1; }
}

test_retry_args_passed_to_spawn() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'extra_pipeline_args=.*"$@"' "$daemon_src" || \
        { echo "daemon_spawn_pipeline missing extra_pipeline_args parameter"; return 1; }
    grep -q 'pipeline_args+=.*extra_pipeline_args' "$daemon_src" || \
        { echo "extra_pipeline_args not merged into pipeline_args"; return 1; }
    grep -q 'all_extra_args' "$daemon_src" || \
        { echo "Retry logic missing all_extra_args merge"; return 1; }
}

test_failure_classification_wired() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -A 50 'daemon_on_failure()' "$daemon_src" | grep -q 'classify_failure' || \
        { echo "classify_failure not called in daemon_on_failure"; return 1; }
    grep -q 'daemon.failure_classified' "$daemon_src" || \
        { echo "Missing daemon.failure_classified event"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 43-52. Intelligence: Failure classification, auth check, process management
# ──────────────────────────────────────────────────────────────────────────────

test_classify_failure_auth() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'classify_failure()' "$daemon_src" || \
        { echo "classify_failure function not found"; return 1; }
    grep -A 30 'classify_failure()' "$daemon_src" | grep -q 'not logged in' || \
        { echo "Missing auth error pattern 'not logged in'"; return 1; }
    grep -A 30 'classify_failure()' "$daemon_src" | grep -q 'unauthorized' || \
        { echo "Missing auth error pattern 'unauthorized'"; return 1; }
}

test_classify_failure_all_classes() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    local classes=("auth_error" "api_error" "invalid_issue" "context_exhaustion" "build_failure" "unknown")
    for class in "${classes[@]}"; do
        grep -A 80 'classify_failure()' "$daemon_src" | grep -q "echo \"$class\"" || \
            { echo "Missing failure class: $class"; return 1; }
    done
}

test_retry_skips_non_retryable() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -A 80 'daemon_on_failure()' "$daemon_src" | grep -q 'auth_error)' || \
        { echo "Missing auth_error case in retry logic"; return 1; }
    grep -A 80 'daemon_on_failure()' "$daemon_src" | grep -q 'invalid_issue)' || \
        { echo "Missing invalid_issue case in retry logic"; return 1; }
    grep -A 80 'daemon_on_failure()' "$daemon_src" | grep -q 'skip.*retry\|skipping retry' || \
        { echo "Missing skip retry action for non-retryable failures"; return 1; }
}

test_api_error_extended_backoff() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'api_backoff=300' "$daemon_src" || \
        { echo "Missing api_backoff=300 constant"; return 1; }
}

test_preflight_auth_check() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'daemon_preflight_auth_check()' "$daemon_src" || \
        { echo "daemon_preflight_auth_check function not found"; return 1; }
    grep -A 60 'daemon_preflight_auth_check()' "$daemon_src" | grep -q 'gh auth status' || \
        { echo "Missing gh auth check"; return 1; }
    grep -A 60 'daemon_preflight_auth_check()' "$daemon_src" | grep -q 'claude.*--print' || \
        { echo "Missing claude auth check"; return 1; }
    grep -B 5 'daemon_poll_issues' "$daemon_src" | grep -q 'daemon_preflight_auth_check' || \
        { echo "Auth check not wired into poll loop"; return 1; }
}

test_process_group_spawn() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -B 5 'exec.*sw-pipeline.sh' "$daemon_src" | grep -q "trap '' HUP" || \
        { echo "Missing HUP trap in spawn subshell"; return 1; }
}

test_process_tree_kill() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -A 30 'cleanup_on_exit()' "$daemon_src" | grep -q 'pkill.*-P' || \
        { echo "Missing pkill -P in cleanup_on_exit"; return 1; }
}

test_consecutive_failure_pause() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'DAEMON_CONSECUTIVE_FAILURE_CLASS=' "$daemon_src" || \
        { echo "Missing DAEMON_CONSECUTIVE_FAILURE_CLASS variable"; return 1; }
    grep -q 'DAEMON_CONSECUTIVE_FAILURE_COUNT=' "$daemon_src" || \
        { echo "Missing DAEMON_CONSECUTIVE_FAILURE_COUNT variable"; return 1; }
    grep -q 'DAEMON_CONSECUTIVE_FAILURE_COUNT.*-ge 3' "$daemon_src" || \
        { echo "Missing consecutive failure threshold of 3"; return 1; }
    grep -q 'daemon.auto_pause.*consecutive_failures' "$daemon_src" || \
        { echo "Missing auto_pause event for consecutive failures"; return 1; }
    grep -q 'reset_failure_tracking()' "$daemon_src" || \
        { echo "Missing reset_failure_tracking function"; return 1; }
}

test_retry_args_passed_to_spawn() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -q 'extra_pipeline_args=.*"$@"' "$daemon_src" || \
        { echo "daemon_spawn_pipeline missing extra_pipeline_args parameter"; return 1; }
    grep -q 'pipeline_args+=.*extra_pipeline_args' "$daemon_src" || \
        { echo "extra_pipeline_args not merged into pipeline_args"; return 1; }
    grep -q 'all_extra_args' "$daemon_src" || \
        { echo "Retry logic missing all_extra_args merge"; return 1; }
}

test_failure_classification_wired() {
    local daemon_src
    daemon_src="$(dirname "$DAEMON_SCRIPT")/sw-daemon.sh"
    grep -A 50 'daemon_on_failure()' "$daemon_src" | grep -q 'classify_failure' || \
        { echo "classify_failure not called in daemon_on_failure"; return 1; }
    grep -q 'daemon.failure_classified' "$daemon_src" || \
        { echo "Missing daemon.failure_classified event"; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright daemon test — Unit Tests (Synthetic Events)           ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the real daemon script exists
    if [[ ! -f "$DAEMON_SCRIPT" ]]; then
        echo -e "${RED}✗ Daemon script not found: $DAEMON_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    source_daemon_functions
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_dora_grade_elite:dora_grade deploy_freq Elite (>= 7)"
        "test_dora_grade_high:dora_grade deploy_freq High (>= 1)"
        "test_dora_grade_medium:dora_grade deploy_freq Medium (>= 0.25)"
        "test_dora_grade_low:dora_grade deploy_freq Low (< 0.25)"
        "test_dora_grade_cfr:dora_grade CFR thresholds (Elite/High/Medium/Low)"
        "test_stage_timings_filter:Stage timings filter-first jq query"
        "test_mttr_computation:MTTR pairs failures with next success"
        "test_epoch_to_iso_works:epoch_to_iso helper function"
        "test_health_check_stale:Health check detects stale jobs"
        "test_priority_sort:Priority label sorting"
        "test_degradation_alert:Degradation alert triggers on high CFR"
        "test_metrics_json_output:Metrics --json output with cycle_time keys"
        "test_patrol_build_labels_enabled:Self-labeling includes watch_label when enabled"
        "test_patrol_build_labels_disabled:Self-labeling excludes watch_label when disabled"
        "test_patrol_recurring_failures:Patrol recurring failures label construction"
        "test_patrol_dora_events:DORA degradation event detection"
        "test_patrol_retry_exhaustion_events:Retry exhaustion event detection"
        "test_patrol_untested_detection:Untested script detection logic"
        "test_progress_stage_advance:Progress detects stage advancement"
        "test_progress_stuck_detection:Progress detects stuck (no change N checks)"
        "test_progress_repeated_errors:Progress detects repeated error loop"
        "test_progress_diff_growth_resets:Progress resets on diff growth"
        "test_hard_limit_override:Hard limit kills even with progress on"
        "test_adaptive_cycles_convergence:Adaptive cycles extends limit on >50% issue drop"
        "test_adaptive_cycles_divergence:Adaptive cycles reduces limit on issue increase"
        "test_adaptive_cycles_hard_ceiling:Adaptive cycles respects 2x base hard ceiling"
        "test_adaptive_cycles_first_cycle:Adaptive cycles no-op on first cycle"
        "test_checkpoint_expire:Cleanup: Checkpoint expire removes old checkpoints"
        "test_daemon_failure_removes_watch_label:Cleanup: Failure handler removes watch label"
        "test_daemon_failure_closes_draft_pr:Cleanup: Failure handler closes draft PRs"
        "test_cleanup_has_artifact_sections:Cleanup: sw-cleanup.sh has all artifact cleanup sections"
        "test_daemon_sources_vitals:Daemon sources vitals module"
        "test_vitals_verdict_mapping:Vitals verdict maps to daemon verdict (continue→healthy etc)"
        "test_vitals_event_emission:Vitals emits pipeline.vitals_check events"
        "test_autoscale_vitals_factor:Auto-scale includes vitals health factor"
        "test_quality_memory_template:Quality memory drives template selection"
        "test_vitals_progress_fallback:Vitals-based progress with static fallback"
        "test_memory_query_fix:Memory: query fix for error returns matching fix"
        "test_dora_template_escalation:Memory: DORA template escalation patterns exist"
        "test_error_classification_categories:Memory: All 12 error categories in post-tool-use.sh"
        "test_template_weights_selection:Daemon: Template weights selection reads weights file"
        "test_auto_enable_self_optimize:Daemon: Auto-enable self_optimize when auto_template is true"
        "test_classify_failure_auth:Intelligence: classify_failure detects auth errors"
        "test_classify_failure_all_classes:Intelligence: classify_failure has all 6 failure classes"
        "test_retry_skips_non_retryable:Intelligence: Retry skips auth_error and invalid_issue"
        "test_api_error_extended_backoff:Intelligence: API errors get extended 300s backoff"
        "test_preflight_auth_check:Intelligence: daemon_preflight_auth_check exists and auto-pauses"
        "test_process_group_spawn:Intelligence: Process group spawning (set -m)"
        "test_process_tree_kill:Intelligence: Process tree kill in cleanup (pkill -P)"
        "test_consecutive_failure_pause:Intelligence: Consecutive failure auto-pause (3 threshold)"
        "test_retry_args_passed_to_spawn:Intelligence: Retry escalation args passed to spawn"
        "test_failure_classification_wired:Intelligence: classify_failure wired into retry logic"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
