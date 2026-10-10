#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  test-flakiness — Classify a failing test run as flaky or regression      ║
# ║                                                                         ║
# ║  When a test command fails with exactly one failing test, rerun that     ║
# ║  test in isolation. Only an explicit exit 0 from the rerun yields        ║
# ║  "flaky"; every other outcome is "regression" or "unclassified", both of ║
# ║  which callers treat exactly like an ordinary failure.                   ║
# ║                                                                         ║
# ║  This module is the single owner of the flaky/regression label. The     ║
# ║  loop persists it to error-summary.json; the daemon only reads it.       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard
[[ -n "${_TEST_FLAKINESS_LOADED:-}" ]] && return 0
_TEST_FLAKINESS_LOADED=1

VERSION="3.3.0"

# Bounds on log parsing — never scan or emit unbounded data
_FLAKY_LOG_TAIL_LINES=500
_FLAKY_MAX_IDS=50
_FLAKY_HISTORY_KEEP=100

# ─── Configuration ───────────────────────────────────────────────────────────

# _flaky_cfg <ENV_NAME> <config.dotpath> <default>
# Env var wins, then config.sh (if loaded), then the default.
_flaky_cfg() {
    local env_name="$1" dotpath="$2" default="$3"
    local val="${!env_name:-}"
    if [[ -z "$val" ]] && [[ "$(type -t _config_get 2>/dev/null)" == "function" ]]; then
        val="$(_config_get "$dotpath" "$default" 2>/dev/null || echo "")"
    fi
    echo "${val:-$default}"
}

# _flaky_cfg_int — same as _flaky_cfg, but non-numeric values fall back to default
_flaky_cfg_int() {
    local val
    val="$(_flaky_cfg "$1" "$2" "$3")"
    [[ "$val" =~ ^[0-9]+$ ]] || val="$3"
    echo "$val"
}

# flaky_detection_enabled — 0 when detection is on (the default)
flaky_detection_enabled() {
    case "$(_flaky_cfg SW_FLAKY_DETECTION loop.flaky_detection true)" in
        false|0|no|off) return 1 ;;
        *) return 0 ;;
    esac
}

# _flaky_timeout_bin — echoes the timeout binary, or nothing.
# Honors an explicitly set TIMEOUT_CMD (even empty) from the caller.
_flaky_timeout_bin() {
    if [[ -n "${TIMEOUT_CMD+x}" ]]; then
        echo "${TIMEOUT_CMD}"
        return 0
    fi
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
    fi
}

# ─── Runner Detection & Extraction ───────────────────────────────────────────

# _flaky_strip_ansi — remove color codes so anchored patterns match
_flaky_strip_ansi() {
    sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g'
}

# flaky_detect_runner <test_cmd> [test_log]
# Echoes vitest|jest|pytest|go|sw-suite|unknown. Never fails.
flaky_detect_runner() {
    local test_cmd="${1:-}" test_log="${2:-}"
    case "$test_cmd" in
        *vitest*)                    echo "vitest"; return 0 ;;
        *jest*)                      echo "jest"; return 0 ;;
        *pytest*)                    echo "pytest"; return 0 ;;
        *"go test"*)                 echo "go"; return 0 ;;
        *sw-test-all*|*-test.sh*)    echo "sw-suite"; return 0 ;;
    esac

    # Wrapper commands (npm test, make test) — sniff the log output instead
    if [[ -n "$test_log" && -f "$test_log" ]]; then
        local sample
        sample="$(tail -n "$_FLAKY_LOG_TAIL_LINES" "$test_log" 2>/dev/null | _flaky_strip_ansi || true)"
        if grep -q 'FAILING SUITES' <<< "$sample"; then
            echo "sw-suite"; return 0
        elif grep -qE '^ *(FAIL|×) +[^ ]+\.(test|spec)\.[cm]?[jt]sx? > ' <<< "$sample"; then
            echo "vitest"; return 0
        elif grep -qE '^Tests: +.*total' <<< "$sample"; then
            echo "jest"; return 0
        elif grep -q 'short test summary info' <<< "$sample"; then
            echo "pytest"; return 0
        elif grep -qE '^--- FAIL: ' <<< "$sample"; then
            echo "go"; return 0
        fi
    fi
    echo "unknown"
}

# flaky_extract_failed_tests <test_log> <runner>
# Echoes unique failing test IDs, one per line, at most _FLAKY_MAX_IDS.
# Patterns are anchored per runner; no match yields no output.
flaky_extract_failed_tests() {
    local test_log="$1" runner="$2"
    [[ -f "$test_log" ]] || return 0

    local sample
    sample="$(tail -n "$_FLAKY_LOG_TAIL_LINES" "$test_log" 2>/dev/null | _flaky_strip_ansi || true)"
    [[ -z "$sample" ]] && return 0

    {
        case "$runner" in
            vitest)
                # " FAIL  src/a.test.ts > suite > name"  (also "×" in newer reporters)
                sed -nE 's/^ *(FAIL|×) +([^ ]+\.(test|spec)\.[cm]?[jt]sx? > .*[^ ]) *$/\2/p' <<< "$sample" \
                    | sed -E 's/ +\[[^]]*\]$//; s/ +[0-9]+ms$//'
                ;;
            jest)
                # "FAIL src/a.test.js" — jest reruns at file granularity
                sed -nE 's/^ *FAIL +([^ ]+\.(test|spec)\.[cm]?[jt]sx?)( .*)?$/\1/p' <<< "$sample"
                ;;
            pytest)
                # "FAILED tests/test_a.py::test_x - AssertionError"
                sed -nE 's/^FAILED +([^ ]+::[^ ]+)( .*)?$/\1/p' <<< "$sample"
                ;;
            go)
                # Top-level only: "--- FAIL: TestFoo (0.01s)"; indented lines are subtests
                sed -nE 's/^--- FAIL: ([A-Za-z0-9_]+) .*$/\1/p' <<< "$sample"
                ;;
            sw-suite)
                # sw-test-all summary row: "  ✗ sw-foo-test.sh   exit 1 3s"
                sed -nE 's/^ *✗ +([A-Za-z0-9._-]+-test\.sh) +(exit [0-9]+|TIMEOUT).*$/\1/p' <<< "$sample"
                ;;
        esac
    } | awk 'NF && !seen[$0]++' | head -n "$_FLAKY_MAX_IDS"
}

# ─── Rerun Command Construction ──────────────────────────────────────────────

# _flaky_fill_template <template> <quoted_id>
# Replaces every "{test}" without pattern-substitution expansion of the value.
_flaky_fill_template() {
    local rest="$1" quoted="$2" out=""
    while [[ "$rest" == *"{test}"* ]]; do
        out="${out}${rest%%\{test\}*}${quoted}"
        rest="${rest#*\{test\}}"
    done
    echo "${out}${rest}"
}

# flaky_build_rerun_cmd <runner> <test_id>
# Echoes a shell command that reruns only that test; empty when unsupported.
# Every piece taken from the log is escaped with printf %q (SEC-003).
flaky_build_rerun_cmd() {
    local runner="$1" test_id="$2"
    [[ -z "$test_id" ]] && return 0

    local q_id
    q_id="$(printf '%q' "$test_id")"

    if [[ -n "${SW_FLAKY_RERUN_TEMPLATE:-}" ]]; then
        _flaky_fill_template "$SW_FLAKY_RERUN_TEMPLATE" "$q_id"
        return 0
    fi

    case "$runner" in
        vitest)
            local file="${test_id%% > *}" name="${test_id##* > }"
            printf 'npx vitest run %q -t %q\n' "$file" "$name"
            ;;
        jest)     printf 'npx jest %q\n' "$test_id" ;;
        pytest)   printf 'python -m pytest %q\n' "$test_id" ;;
        go)       printf 'go test -count=1 -run %q ./...\n' "^${test_id}\$" ;;
        sw-suite) printf 'bash %q\n' "scripts/${test_id}" ;;
    esac
}

# ─── History (repeat-offender cap) ───────────────────────────────────────────

# _flaky_history_count <history_file> <test_id> — prior flaky classifications
_flaky_history_count() {
    local history="$1" test_id="$2"
    [[ -f "$history" ]] || { echo 0; return 0; }
    jq -r --arg id "$test_id" '.tests[$id].count // 0' "$history" 2>/dev/null || echo 0
}

# _flaky_history_record <history_file> <test_id>
# Atomically increments the count, keeping the newest _FLAKY_HISTORY_KEEP IDs.
_flaky_history_record() {
    local history="$1" test_id="$2"
    local base='{"tests":{}}'
    [[ -f "$history" ]] && base="$(cat "$history" 2>/dev/null || echo '{"tests":{}}')"
    local tmp="${history}.tmp.$$"
    jq -n --argjson base "$base" --arg id "$test_id" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson keep "$_FLAKY_HISTORY_KEEP" '
        ($base.tests // {}) as $t
        | ($t + {($id): {count: (($t[$id].count // 0) + 1), last: $ts}})
        | to_entries | sort_by(.value.last) | .[-$keep:] | from_entries
        | {tests: .}' > "$tmp" 2>/dev/null && mv "$tmp" "$history" && return 0
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# ─── Result Persistence ──────────────────────────────────────────────────────

# _flaky_write_result <result_json> <class> <runner> <reason> <failed> <flaky> <regression> <rerun_exit> <duration> <rerun_log>
# ID lists are newline-separated. Written atomically (tmp + mv).
_flaky_write_result() {
    local result_json="$1" cls="$2" runner="$3" reason="$4"
    local failed="$5" flaky="$6" regression="$7"
    local rerun_exit="$8" duration="$9" rerun_log="${10}"
    [[ -z "$result_json" ]] && return 0
    local tmp="${result_json}.tmp.$$"
    jq -n --arg class "$cls" --arg runner "$runner" --arg reason "$reason" \
        --arg failed "$failed" --arg flaky "$flaky" --arg regression "$regression" \
        --arg exit "$rerun_exit" --arg dur "$duration" \
        --arg log "$(basename "${rerun_log:-}")" '
        def lines: split("\n") | map(select(length > 0));
        {class: $class, runner: $runner, reason: $reason,
         failed_tests: ($failed | lines),
         flaky_tests: ($flaky | lines),
         regression_tests: ($regression | lines),
         rerun: (if $exit == "" then null
                 else {exit_code: ($exit | tonumber), duration_s: ($dur | tonumber), log: $log} end)}' \
        > "$tmp" 2>/dev/null && mv "$tmp" "$result_json" && return 0
    rm -f "$tmp" 2>/dev/null || true
}

# _flaky_emit <class> <test_id> <runner> <reason>
_flaky_emit() {
    [[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || return 0
    local event=""
    case "$1" in
        flaky)      event="loop.flaky_test_detected" ;;
        regression) event="loop.test_regression_confirmed" ;;
        *)          return 0 ;;
    esac
    emit_event "$event" "test_id=$2" "runner=$3" "iteration=${ITERATION:-0}" "reason=$4" 2>/dev/null || true
}

# ─── Classification ──────────────────────────────────────────────────────────

# _flaky_rerun <workdir> <rerun_cmd> <timeout_s> <timeout_bin> <rerun_log>
# Runs the rerun in a subshell (caller's cwd untouched). Echoes "exit duration".
_flaky_rerun() {
    local workdir="$1" rerun_cmd="$2" timeout_s="$3" tbin="$4" rerun_log="$5"
    local start end rc=0
    start="$(date +%s)"
    ( cd "$workdir" && "$tbin" "$timeout_s" bash -c "$rerun_cmd" ) > "$rerun_log" 2>&1 || rc=$?
    end="$(date +%s)"
    echo "$rc $((end - start))"
}

# _flaky_classify_one <runner> <test_id> <workdir> <history> <rerun_log> <timeout_bin>
# Reruns one test. Echoes "class reason rerun_exit duration" (exit "-" = no rerun).
_flaky_classify_one() {
    local runner="$1" test_id="$2" workdir="$3" history="$4" rerun_log="$5" tbin="$6"
    local max_repeats rerun_timeout prior rerun_cmd
    max_repeats="$(_flaky_cfg_int SW_FLAKY_MAX_REPEATS loop.flaky_max_repeats 2)"
    rerun_timeout="$(_flaky_cfg_int SW_FLAKY_RERUN_TIMEOUT loop.flaky_rerun_timeout 180)"
    prior="$(_flaky_history_count "$history" "$test_id")"
    rerun_cmd="$(flaky_build_rerun_cmd "$runner" "$test_id")"

    if [[ $((prior + 1)) -ge "$max_repeats" ]]; then
        # Excused before — an isolated pass can hide an order-dependent bug
        echo "regression repeat_offender - 0"; return 0
    fi
    [[ -z "$rerun_cmd" ]] && { echo "unclassified unknown_runner - 0"; return 0; }

    local out rerun_exit duration cls reason
    out="$(_flaky_rerun "$workdir" "$rerun_cmd" "$rerun_timeout" "$tbin" "$rerun_log")"
    rerun_exit="${out%% *}"; duration="${out##* }"
    case "$rerun_exit" in
        0)       cls="flaky"; reason="rerun_pass" ;;
        124|137) cls="regression"; reason="rerun_timeout" ;;
        126|127) cls="unclassified"; reason="rerun_error" ;;
        *)       cls="regression"; reason="rerun_fail" ;;
    esac
    if [[ "$cls" == "flaky" ]] && ! _flaky_history_record "$history" "$test_id"; then
        # Cannot enforce the repeat cap — fail safe
        cls="regression"; reason="history_unwritable"
    fi
    echo "$cls $reason $rerun_exit $duration"
}

# _flaky_classify_ids <runner> <ids> <workdir> <result_json> <test_log> <timeout_bin>
# Classifies each ID, aggregates, writes the result. Echoes the gate class.
_flaky_classify_ids() {
    local runner="$1" ids="$2" workdir="$3" result_json="$4" test_log="$5" tbin="$6"
    local log_base="${result_json%.json}"
    [[ -z "$result_json" ]] && log_base="$(dirname "$test_log")/flaky"
    local history="${SW_FLAKY_HISTORY_FILE:-$(dirname "$log_base")/flaky-history.json}"
    local classes="" flaky_ids="" regression_ids="" reason="" rerun_exit="" duration=0 rerun_log=""
    local test_id verdict cls why ex dur n=0

    while IFS= read -r test_id; do
        [[ -z "$test_id" ]] && continue
        n=$((n + 1))
        rerun_log="${log_base}-rerun.log"
        [[ "$n" -gt 1 ]] && rerun_log="${log_base}-rerun-${n}.log"
        verdict="$(_flaky_classify_one "$runner" "$test_id" "$workdir" "$history" "$rerun_log" "$tbin")"
        read -r cls why ex dur <<< "$verdict"
        classes="${classes} ${cls}"
        reason="$why"
        if [[ "$ex" != "-" ]]; then rerun_exit="$ex"; duration=$((duration + dur)); fi
        case "$cls" in
            flaky)      flaky_ids="${flaky_ids}${test_id}"$'\n' ;;
            regression) regression_ids="${regression_ids}${test_id}"$'\n' ;;
        esac
        _flaky_emit "$cls" "$test_id" "$runner" "$why"
    done <<< "$ids"

    # shellcheck disable=SC2086
    cls="$(flaky_gate_aggregate $classes)"
    [[ -z "$rerun_exit" ]] && rerun_log=""
    _flaky_write_result "$result_json" "$cls" "$runner" "$reason" "$ids" \
        "$flaky_ids" "$regression_ids" "$rerun_exit" "$duration" "$rerun_log"
    echo "$cls"
}

# detect_flaky_failure <test_log> <test_cmd> <workdir> <result_json>
# Precondition: the primary run of <test_cmd> exited non-zero.
# Echoes flaky|regression|unclassified and ALWAYS returns 0.
detect_flaky_failure() {
    local test_log="$1" test_cmd="$2" workdir="${3:-.}" result_json="${4:-}"
    local reason="" runner="unknown" ids=""

    if ! command -v jq >/dev/null 2>&1; then
        echo "unclassified"; return 0
    fi

    if ! flaky_detection_enabled; then
        reason="disabled"
    else
        runner="$(flaky_detect_runner "$test_cmd" "$test_log")"
        ids="$(flaky_extract_failed_tests "$test_log" "$runner" || true)"
        local id_count=0 max_tests tbin
        [[ -n "$ids" ]] && id_count="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
        max_tests="$(_flaky_cfg_int SW_FLAKY_MAX_RERUN_TESTS loop.flaky_max_rerun_tests 1)"
        tbin="$(_flaky_timeout_bin)"

        if [[ "$runner" == "unknown" ]]; then
            reason="unknown_runner"
        elif [[ "$id_count" -eq 0 ]]; then
            reason="no_ids"
        elif [[ "$id_count" -gt "$max_tests" ]]; then
            reason="over_cap"
        elif [[ -z "$tbin" ]]; then
            reason="no_timeout_bin"
        else
            _flaky_classify_ids "$runner" "$ids" "$workdir" "$result_json" "$test_log" "$tbin" || echo "unclassified"
            return 0
        fi
    fi

    _flaky_write_result "$result_json" "unclassified" "$runner" "$reason" "$ids" "" "" "" "0" ""
    echo "unclassified"
    return 0
}

# ─── Consumer Helpers ────────────────────────────────────────────────────────

# flaky_counts_toward_breaker <class>
# Returns 0 (counts, as today) for anything except "flaky", which returns 1.
flaky_counts_toward_breaker() {
    [[ "${1:-}" == "flaky" ]] && return 1
    return 0
}

# flaky_gate_aggregate <class>...
# Any regression → regression; all flaky → flaky; any other mix → unclassified.
# No arguments → empty (no failures were classified).
flaky_gate_aggregate() {
    [[ $# -eq 0 ]] && { echo ""; return 0; }
    local c all_flaky=true
    for c in "$@"; do
        [[ "$c" == "regression" ]] && { echo "regression"; return 0; }
        [[ "$c" == "flaky" ]] || all_flaky=false
    done
    if [[ "$all_flaky" == "true" ]]; then
        echo "flaky"
    else
        echo "unclassified"
    fi
}
