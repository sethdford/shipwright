#!/usr/bin/env bash
# lib/test-gate-baseline.sh — differential test gate for the build loop (#8633).
#
# The loop's test gate used to mark an iteration failed when ANY test command exited non-zero.
# On a repo whose suite already fails (or whose test scripts overlap), no iteration could ever
# converge. This lib blocks only on failures the iteration introduced:
#
#   a failing command is judged against the same command run on the loop's base commit
#   (LOOP_START_COMMIT), in a temporary detached worktree that is removed afterwards.
#     base passes                         -> regression, block
#     base fails, both logs parsable      -> block only if the iteration fails a unit the base does not
#     base fails, not parsable            -> pre-existing, do not block (recorded)
#     baseline cannot be computed         -> block (fail closed)
#
# Usage (sw-loop.sh run_test_gate):
#   tg_begin_gate                                         # once per gate run
#   tg_judge "$cmd" "$exit" "$log" "$timeout" 1 || all_passed=false    # only when exit != 0
#   results=$(tg_record "$results" "$cmd" "$exit" "$duration")
#   TEST_OUTPUT="$(tg_verdict_text; echo "$combined_output" | tail -50)"
#
# Baseline results are cached per base commit and command under $LOG_DIR, so each command runs
# on the base at most once per loop.

[[ -n "${_SW_TEST_GATE_BASELINE_LOADED:-}" ]] && return 0
_SW_TEST_GATE_BASELINE_LOADED=1

# Judgement of the last tg_judge call (read by tg_record and the caller).
TG_BLOCKING="true"
TG_BASE_EXIT=""          # exit code on the base commit, "uncomputable", or empty
TG_NEW_FAILURES=""       # newline-separated units this iteration failed that the base did not
TG_PREEXISTING="false"
_TG_VERDICTS=""          # accumulated human-readable lines for this gate run

# tg_begin_gate — reset per-gate state. Call at the start of each test gate run.
tg_begin_gate() {
    _TG_VERDICTS=""
    tg_reset_judgement
}

tg_reset_judgement() {
    TG_BLOCKING="true"
    TG_BASE_EXIT=""
    TG_NEW_FAILURES=""
    TG_PREEXISTING="false"
}

# tg_verdict_text — print the verdict lines for this gate run (nothing when there are none).
tg_verdict_text() {
    [[ -z "$_TG_VERDICTS" ]] && return 0
    printf '%s\n' "$_TG_VERDICTS"
}

# tg_parse_log <log> — sets TG_UNITS (newline list of failing units, sorted, unique) and
# TG_PARSABLE (1 when the log has a known runner summary, else 0).
# Formats: sw-test-all.sh per-suite lines "  ✗ <suite>  exit N" / "  ⧗ <suite>  TIMEOUT";
# bun test "(fail) <name> [Nms]" lines with a "Ran N tests across M files" summary.
tg_parse_log() {
    local log="$1" plain units="" summary=0
    plain="$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$log" 2>/dev/null || true)"
    units="$(printf '%s\n' "$plain" | grep -E '^  (✗|⧗) ' | awk '{print $2}' || true)"
    units="$units"$'\n'"$(printf '%s\n' "$plain" | grep -E '^\(fail\) ' \
        | sed -E 's/^\(fail\) //; s/ \[[0-9.]+m?s\]$//' || true)"
    units="$(printf '%s\n' "$units" | grep -v '^$' | sort -u || true)"
    if printf '%s\n' "$plain" | grep -E ' passed +[0-9]+ failed +[0-9]+ timed out' >/dev/null; then
        summary=1
    elif printf '%s\n' "$plain" | grep -E '^Ran [0-9]+ tests? across' >/dev/null; then
        summary=1
    fi
    TG_UNITS="$units"
    TG_PARSABLE=0
    [[ "$summary" -eq 1 ]] && TG_PARSABLE=1
    return 0
}

# tg_run_cmd <dir> <cmd> <timeout_s> <log> — run cmd in dir with the gate's credential scrub and
# timeout; prints the exit code. The command is written to a script file and run as `bash <file>`,
# so no command string is ever passed to a shell with -c.
tg_run_cmd() {
    local dir="$1" cmd="$2" limit="$3" log="$4" script rc=0
    local -a prefix=()
    script="$(dirname "$log")/test-baseline-cmd-$$.sh"
    printf '%s\n' "$cmd" > "$script"
    if command -v timeout >/dev/null 2>&1; then
        prefix=(timeout "$limit")
    elif command -v gtimeout >/dev/null 2>&1; then
        prefix=(gtimeout "$limit")
    fi
    ( cd "$dir" && PROJECT_ROOT="$dir" sw_test_gate_env "${prefix[@]+"${prefix[@]}"}" bash "$script" ) \
        > "$log" 2>&1 || rc=$?
    rm -f "$script"
    echo "$rc"
}

# tg_cache_file <cmd> — cache path for cmd on the current base commit.
tg_cache_file() {
    local key
    key="$(printf '%s\n%s' "${LOOP_START_COMMIT:-none}" "$1" | cksum | awk '{print $1}')"
    echo "${LOG_DIR}/test-baseline-${key}.txt"
}

# tg_compute_baseline <cmd> — run cmd on LOOP_START_COMMIT in a temporary worktree and write the
# cache file. Records "exit=uncomputable" when the worktree or the run cannot be set up.
tg_compute_baseline() {
    local cmd="$1" cache="$2" base="${LOOP_START_COMMIT:-}" tmp wt rc
    local root="${PROJECT_ROOT:-.}" limit="${SW_TEST_TIMEOUT:-900}"
    if [[ -z "$base" ]]; then
        tg_write_cache "$cache" "uncomputable" 0 ""
        return 0
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-baseline.XXXXXX")" || {
        tg_write_cache "$cache" "uncomputable" 0 ""; return 0; }
    wt="$tmp/wt"
    if ! git -C "$root" worktree add --detach "$wt" "$base" >/dev/null 2>&1; then
        rmdir "$tmp" 2>/dev/null || true
        tg_write_cache "$cache" "uncomputable" 0 ""
        return 0
    fi
    # Dependencies are not in git: reuse the project's installed tree (a symlink in worktrees).
    if [[ -e "$root/node_modules" && ! -e "$wt/node_modules" ]]; then
        ln -s "$root/node_modules" "$wt/node_modules" 2>/dev/null || true
    fi
    rc="$(tg_run_cmd "$wt" "$cmd" "$limit" "${cache%.txt}.log")"
    tg_parse_log "${cache%.txt}.log"
    if [[ "$rc" == "124" || "$rc" == "137" || "$rc" == "143" ]]; then
        rc="uncomputable"   # timed out: no trustworthy baseline
    fi
    git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true
    rmdir "$tmp" 2>/dev/null || true
    tg_write_cache "$cache" "$rc" "$TG_PARSABLE" "$TG_UNITS"
}

# tg_write_cache <cache> <exit> <parsable> <units> — atomic write (temp file + mv).
tg_write_cache() {
    local cache="$1" tmp
    tmp="${cache}.tmp.$$"
    {
        echo "exit=$2"
        echo "parsable=$3"
        printf '%s\n' "$4" | grep -v '^$' | sed 's/^/unit=/' || true
    } > "$tmp"
    mv "$tmp" "$cache"
}

# tg_load_baseline <cmd> — sets TG_BASE_EXIT, TG_BASE_PARSABLE and TG_BASE_UNITS, computing the
# baseline once per command and base commit.
tg_load_baseline() {
    local cmd="$1" cache line
    cache="$(tg_cache_file "$cmd")"
    [[ -f "$cache" ]] || tg_compute_baseline "$cmd" "$cache"
    TG_BASE_EXIT="uncomputable"
    TG_BASE_PARSABLE=0
    TG_BASE_UNITS=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            exit=*)     TG_BASE_EXIT="${line#exit=}" ;;
            parsable=*) TG_BASE_PARSABLE="${line#parsable=}" ;;
            unit=*)     TG_BASE_UNITS="${TG_BASE_UNITS}${line#unit=}"$'\n' ;;
        esac
    done < "$cache"
    return 0
}

# tg_judge <cmd> <exit> <log> <timeout_s> <baseline_eligible 0|1>
# Call only for a failing command. Sets the TG_* judgement. Returns 1 when the failure blocks.
# baseline_eligible=0 marks a command with no base-commit counterpart (e.g. a test file created
# during this loop); it always blocks.
tg_judge() {
    local cmd="$1" rc="$2" log="$3" limit="$4" eligible="${5:-1}"
    local iter_units new="" line label
    tg_reset_judgement
    tg_parse_log "$log"
    iter_units="$TG_UNITS"
    if [[ "$eligible" != "1" ]]; then
        TG_BASE_EXIT="n/a"
        _tg_add_verdict "BLOCKING: '${cmd}' (exit ${rc}) is a test created during this loop; it has no base-commit baseline."
        return 1
    fi
    tg_load_baseline "$cmd"
    if [[ "$TG_BASE_EXIT" == "uncomputable" ]]; then
        _tg_add_verdict "BLOCKING: could not compute the base-commit baseline for '${cmd}' (exit ${rc}); treated as a regression."
        return 1
    fi
    if [[ "$TG_BASE_EXIT" == "0" ]]; then
        _tg_add_verdict "NEW FAILURE: '${cmd}' exits ${rc} but passes on the base commit. Fix it."
        [[ -n "$iter_units" ]] && _tg_add_verdict "  failing: $(echo "$iter_units" | tr '\n' ' ')"
        TG_NEW_FAILURES="$iter_units"
        return 1
    fi
    # The base commit also fails. Attribute the failure only when both runs can be compared.
    if [[ "$TG_BASE_PARSABLE" == "1" && "$TG_PARSABLE" == "1" && -n "$iter_units" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if ! printf '%s\n' "$TG_BASE_UNITS" | grep -Fx -- "$line" >/dev/null; then
                new="${new}${line}"$'\n'
            fi
        done <<< "$iter_units"
        new="$(printf '%s' "$new" | grep -v '^$' || true)"
    fi
    if [[ -n "$new" ]]; then
        TG_NEW_FAILURES="$new"
        _tg_add_verdict "NEW FAILURES in '${cmd}' (not failing on the base commit), fix these: $(echo "$new" | tr '\n' ' ')"
        return 1
    fi
    TG_PREEXISTING="true"
    label="${iter_units:-(failure not attributable to a suite)}"
    _tg_add_verdict "PRE-EXISTING, not blocking: '${cmd}' also fails on the base commit (exit ${TG_BASE_EXIT}). Do NOT try to fix these failures: $(echo "$label" | tr '\n' ' ')"
    return 0
}

_tg_add_verdict() {
    if [[ -z "$_TG_VERDICTS" ]]; then
        _TG_VERDICTS="$1"
    else
        _TG_VERDICTS="${_TG_VERDICTS}"$'\n'"$1"
    fi
}

# tg_record <results_json> <cmd> <exit> <duration_s> — append one evidence entry. Uses the last
# tg_judge judgement when exit is non-zero. Prints the new JSON array. Runs in a subshell, so it
# must not change the judgement globals.
tg_record() {
    local results="$1" cmd="$2" rc="$3" dur="$4" base_json="null" new_json="[]" pre="false"
    if ! command -v jq >/dev/null 2>&1; then
        echo "$results"
        return 0
    fi
    if [[ "$rc" -ne 0 ]]; then
        [[ "$TG_BASE_EXIT" =~ ^[0-9]+$ ]] && base_json="$TG_BASE_EXIT"
        new_json="$(printf '%s' "$TG_NEW_FAILURES" | jq -R -s 'split("\n") | map(select(length > 0))')"
        pre="$TG_PREEXISTING"
    fi
    echo "$results" | jq --arg cmd "$cmd" --argjson exit "$rc" --argjson dur "$dur" \
        --argjson base "$base_json" --argjson new "$new_json" --argjson pre "$pre" \
        '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur,
               "baseline_exit_code": $base, "new_failures": $new, "preexisting": $pre}]'
}
