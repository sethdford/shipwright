#!/usr/bin/env bash
# lib/test-gate-baseline.sh — differential test gate for the build loop (#8633).
#
# The loop's test gate used to mark an iteration failed when ANY test command exited non-zero.
# A repo whose suite already fails (or whose test scripts overlap) could then never converge.
# This lib lets an iteration pass only on positive evidence that a failure already exists on the
# loop's base commit (LOOP_START_COMMIT). Every other case blocks.
#
# A failing command is judged like this:
#   blocks   base passes                                         (regression)
#   blocks   base result untrusted (see below)                   (fail closed)
#   blocks   iteration timed out or was killed (124/137/143)
#   blocks   iteration output not parsable, or no failing unit recognised
#   blocks   iteration fails a unit the base does not fail       (new failure)
#   pre-existing (does not block) only when: both runs parsable, the iteration has failing
#            units, every one of them also fails on the base, and the iteration did not time out.
#
# The base result is trusted only when the base command was actually run (not 126/127, no
# "missing script"/"not found" message, no timeout), its output is parsable, it does not fail
# every unit (a broken environment), and two independent runs agree. Only trusted results are
# cached. The base runs in a temporary detached worktree created with hooks disabled, under a
# watchdog (SW_TEST_TIMEOUT; no `timeout` binary needed). Its process tree, worktree and temp
# files are removed on exit and on INT/TERM. The cache lives in a per-loop directory outside the
# repository (mode 700), not in LOG_DIR, so the agent cannot forge it.
#
# A unit is one failing assertion ("suite::assertion") when the suite lists it, otherwise the
# suite as a whole. Coarse suite-level units are a known limit: a crash in a suite that already
# fails is attributed to that suite.
#
# Usage (sw-loop.sh run_test_gate):
#   tg_begin_gate                                                   # once per gate run
#   tg_judge "$cmd" "$exit" "$log" "$timeout" 1 || all_passed=false  # only when exit != 0
#   results=$(tg_record "$results" "$cmd" "$exit" "$duration")
#   TEST_OUTPUT="$(tg_verdict_text; echo "$combined_output" | tail -50)"

[[ -n "${_SW_TEST_GATE_BASELINE_LOADED:-}" ]] && return 0
_SW_TEST_GATE_BASELINE_LOADED=1

# Judgement of the last tg_judge call.
TG_BLOCKING="true"
TG_VERDICT=""            # pass | pre-existing | regression | new-failures | unattributed | timeout | untrusted-baseline | created-in-loop
TG_BASE_EXIT=""          # trusted base exit code, or "n/a"; empty when untrusted
TG_NEW_FAILURES=""       # newline-separated units this iteration failed that the base did not
TG_PREEXISTING="false"
TG_BASE_OK=0             # 1 when the base result is trusted
TG_BASE_UNITS=""         # newline-separated failing units on the base
TG_BASE_REASON=""        # why the base is not trusted
_TG_VERDICTS=""          # verdict lines for this gate run
_TG_STORE=""             # per-loop directory holding the trusted base cache (owned by this process)
_TG_ROOT=""              # repository that owns the base worktree
_TG_WT=""                # active base worktree
_TG_TMP=""               # active temp dir (script, logs, timeout flag)
_TG_PID=""               # root process of the active base run (its descendants are killed with it)
_TG_WD=""                # watchdog subshell of the active base run

tg_begin_gate() {
    _TG_VERDICTS=""
    tg_reset_judgement
}

tg_reset_judgement() {
    TG_BLOCKING="true"
    TG_VERDICT=""
    TG_BASE_EXIT=""
    TG_NEW_FAILURES=""
    TG_PREEXISTING="false"
}

# tg_verdict_text — print the verdict lines for this gate run (nothing when there are none).
tg_verdict_text() {
    [[ -z "$_TG_VERDICTS" ]] && return 0
    printf '%s\n' "$_TG_VERDICTS"
}

_tg_add_verdict() {
    if [[ -z "$_TG_VERDICTS" ]]; then
        _TG_VERDICTS="$1"
    else
        _TG_VERDICTS="${_TG_VERDICTS}"$'\n'"$1"
    fi
}

# _tg_block <verdict> <message> — record a blocking judgement.
_tg_block() {
    TG_BLOCKING="true"
    TG_VERDICT="$1"
    _tg_add_verdict "$2"
}

# ─── Parsing ──────────────────────────────────────────────────────────────────

# tg_parse_log <log> — sets TG_UNITS (sorted unique failing units), TG_PARSABLE (1 when the log
# has a known runner summary), TG_PASSCOUNT (passing units, empty if unknown) and TG_MISSING
# (1 when the output reports a missing command, script or module).
# A unit is "suite::assertion" for an assertion that failed inside a suite (sw-test-all.sh prints
# the failing assertions of each failing suite, because the gate sets FAIL_LOG_LINES), or the
# suite name when no assertion is listed. bun test units are the test names.
tg_parse_log() {
    local log="$1" plain units pass summary=0
    plain="$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$log" 2>/dev/null || true)"
    units="$(printf '%s\n' "$plain" | awk '
        /^━━━ [^ ]+ \(/ { cur = $2; next }
        /^  FAILING SUITES/ { cur = ""; next }
        /^  (✗|⧗) [^ ]+/ { cur = ""; sfail[$2] = 1; next }
        /^\(fail\) / { line = $0; sub(/^\(fail\) /, "", line); sub(/ \[[0-9.]+m?s\]$/, "", line); print line; next }
        cur != "" && /^ +✗ / { line = $0; sub(/^ +✗ /, "", line); print cur "::" line; cnt[cur]++; next }
        END { for (s in sfail) if (!(s in cnt)) print s }
    ' || true)"
    TG_UNITS="$(printf '%s\n' "$units" | grep -v '^$' | sort -u || true)"
    pass="$(printf '%s\n' "$plain" | sed -nE 's/^ *([0-9]+) passed +[0-9]+ failed.*$/\1/p' | tail -1 || true)"
    if [[ -z "$pass" ]]; then
        pass="$(printf '%s\n' "$plain" | sed -nE 's/^ *([0-9]+) pass$/\1/p' | tail -1 || true)"
    fi
    TG_PASSCOUNT="$pass"
    if printf '%s\n' "$plain" | grep -E ' passed +[0-9]+ failed +[0-9]+ timed out' >/dev/null; then
        summary=1
    elif printf '%s\n' "$plain" | grep -E '^Ran [0-9]+ tests? across' >/dev/null; then
        summary=1
    fi
    TG_PARSABLE=0
    [[ "$summary" -eq 1 ]] && TG_PARSABLE=1
    TG_MISSING=0
    if printf '%s\n' "$plain" | grep -E 'No such file or directory|command not found|Missing script|MODULE_NOT_FOUND|Cannot find module' >/dev/null; then
        TG_MISSING=1
    fi
    return 0
}

# ─── Base run ─────────────────────────────────────────────────────────────────

# tg_store_dir — create the per-loop store (mode 700, outside the repo) once. Not run in a
# subshell: it installs the exit guard.
tg_store_dir() {
    if [[ -z "$_TG_STORE" ]]; then
        _TG_STORE="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-gate-store.XXXXXX")" || return 1
        chmod 700 "$_TG_STORE" 2>/dev/null || true
        _tg_install_guards
    fi
    return 0
}

# _tg_install_guards — make sure base resources are removed on exit and on INT/TERM. Existing
# handlers (the loop's own cleanup) are left in place; their exit runs the EXIT guard.
_tg_install_guards() {
    # In the loop's own process, an existing INT/TERM handler (the loop's cleanup, which writes
    # state) is kept, and the EXIT guard does the base cleanup. A subshell does not run the
    # inherited EXIT/INT/TERM handlers reliably, so it always installs its own.
    local main=0
    [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] && main=1   # BASHPID is not available in bash 3.2
    if [[ -z "$(trap -p EXIT)" ]]; then
        trap '_tg_on_exit' EXIT
    fi
    if [[ "$main" -eq 0 || -z "$(trap -p INT)" ]]; then
        trap '_tg_cleanup_base; exit 130' INT
    fi
    if [[ "$main" -eq 0 || -z "$(trap -p TERM)" ]]; then
        trap '_tg_cleanup_base; exit 143' TERM
    fi
}

_tg_on_exit() {
    _tg_cleanup_base
    if [[ -n "$_TG_STORE" ]]; then
        rm -f "$_TG_STORE"/*.txt 2>/dev/null || true
        rmdir "$_TG_STORE" 2>/dev/null || true
        _TG_STORE=""
    fi
}

# _tg_cleanup_base — stop the active base run and remove its worktree, temp files. Idempotent.
_tg_cleanup_base() {
    _tg_stop_run
    if [[ -n "$_TG_WT" ]]; then
        git -C "$_TG_ROOT" worktree remove --force "$_TG_WT" >/dev/null 2>&1 || true
        git -C "$_TG_ROOT" worktree prune >/dev/null 2>&1 || true
        _TG_WT=""
    fi
    if [[ -n "$_TG_TMP" ]]; then
        rm -f "$_TG_TMP"/cmd.sh "$_TG_TMP"/*.log "$_TG_TMP"/timeout.flag 2>/dev/null || true
        rmdir "$_TG_TMP" 2>/dev/null || true
        _TG_TMP=""
    fi
}

# _tg_kill_tree <pid> <signal> — signal a process and all of its descendants. Descendants are
# found through the process table, not the process group, so it works without job control.
_tg_kill_tree() {
    local pid="$1" sig="$2" child
    [[ -z "$pid" ]] && return 0
    for child in $(ps -axo pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2 == p { print $1 }'); do
        _tg_kill_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

# _tg_run_base_once <worktree> <cmd> <limit_s> <log> — run cmd once in the worktree, with a
# watchdog that kills the run's process tree after <limit_s> (TERM, then KILL). Sets _TB_RC.
# Both subshells reset INT/TERM/EXIT first, so handlers inherited from the loop are not run in
# the children.
_tg_run_base_once() {
    local wt="$1" cmd="$2" limit="$3" log="$4" pid wd
    printf '%s\n' "$cmd" > "$_TG_TMP/cmd.sh"
    rm -f "$_TG_TMP/timeout.flag"
    (
        trap - INT TERM EXIT
        cd "$wt" && PROJECT_ROOT="$wt" sw_test_gate_env bash "$_TG_TMP/cmd.sh"
    ) > "$log" 2>&1 &
    pid=$!
    _TG_PID="$pid"
    (
        trap - INT TERM EXIT
        sleep "$limit"
        : > "$_TG_TMP/timeout.flag"
        _tg_kill_tree "$pid" TERM
        sleep 2
        _tg_kill_tree "$pid" KILL
    ) &
    wd=$!
    _TG_WD="$wd"
    _TB_RC=0
    wait "$pid" 2>/dev/null || _TB_RC=$?
    _tg_stop_run
    if [[ -f "$_TG_TMP/timeout.flag" ]]; then
        _TB_RC=124
    fi
    return 0
}

# _tg_stop_run — kill the active base run's process tree and its watchdog's. Idempotent.
_tg_stop_run() {
    if [[ -n "$_TG_PID" ]]; then
        _tg_kill_tree "$_TG_PID" KILL
        _TG_PID=""
    fi
    if [[ -n "$_TG_WD" ]]; then
        _tg_kill_tree "$_TG_WD" KILL
        _TG_WD=""
    fi
}

# _tg_compute_base <cmd> — run the base twice and decide whether the result is trusted.
# Sets TG_BASE_OK, TG_BASE_EXIT, TG_BASE_UNITS, TG_BASE_REASON.
_tg_compute_base() {
    local cmd="$1" limit="${SW_TEST_TIMEOUT:-900}" root="${PROJECT_ROOT:-.}" base="${LOOP_START_COMMIT:-}"
    local wt rc1 rc2 units1 units2 pass1 parsable1 missing1 wt_ok=0
    TG_BASE_OK=0
    TG_BASE_EXIT="untrusted"
    TG_BASE_UNITS=""
    TG_BASE_REASON=""
    if [[ -z "$base" ]]; then
        TG_BASE_REASON="the loop state has no LOOP_START_COMMIT"
        return 0
    fi
    if ! git -C "$root" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1; then
        TG_BASE_REASON="LOOP_START_COMMIT is not a commit"
        return 0
    fi
    if ! git -C "$root" rev-parse --verify -q "${base}^" >/dev/null 2>&1; then
        TG_BASE_REASON="LOOP_START_COMMIT is a root commit (it is the fallback, not the loop's base)"
        return 0
    fi
    # Guards are per shell: a subshell does not inherit them, so install them for this run too.
    _tg_install_guards
    _TG_ROOT="$root"
    _TG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-baseline.XXXXXX")" || {
        TG_BASE_REASON="could not create a temp dir"; return 0; }
    wt="$_TG_TMP/wt"
    _TG_WT="$wt"
    if git -C "$root" -c core.hooksPath=/dev/null worktree add --detach "$wt" "$base" >/dev/null 2>&1; then
        wt_ok=1
    fi
    if [[ "$wt_ok" -ne 1 ]]; then
        _tg_cleanup_base
        TG_BASE_REASON="git worktree add failed for the base commit"
        return 0
    fi
    # Dependencies are not in git: reuse the project's installed tree.
    if [[ -e "$root/node_modules" && ! -e "$wt/node_modules" ]]; then
        ln -s "$root/node_modules" "$wt/node_modules" 2>/dev/null || true
    fi
    _tg_run_base_once "$wt" "$cmd" "$limit" "$_TG_TMP/run1.log"; rc1="$_TB_RC"
    tg_parse_log "$_TG_TMP/run1.log"
    units1="$TG_UNITS"; pass1="$TG_PASSCOUNT"; parsable1="$TG_PARSABLE"; missing1="$TG_MISSING"
    _tg_run_base_once "$wt" "$cmd" "$limit" "$_TG_TMP/run2.log"; rc2="$_TB_RC"
    tg_parse_log "$_TG_TMP/run2.log"
    units2="$TG_UNITS"
    _tg_cleanup_base
    if [[ "$rc1" != "$rc2" || "$units1" != "$units2" ]]; then
        TG_BASE_REASON="two base runs disagree (exit $rc1 then $rc2): the base is flaky"
        return 0
    fi
    if [[ "$rc1" == "0" ]]; then
        TG_BASE_OK=1
        TG_BASE_EXIT=0
        return 0
    fi
    case "$rc1" in
        124|137|143) TG_BASE_REASON="the base run timed out or was killed (exit $rc1)"; return 0 ;;
        126|127)     TG_BASE_REASON="the base command could not run (exit $rc1)"; return 0 ;;
    esac
    if [[ "$missing1" == "1" ]]; then
        TG_BASE_REASON="the base output reports a missing command, script or module"
        return 0
    fi
    if [[ "$parsable1" != "1" ]]; then
        TG_BASE_REASON="the base output is not parsable"
        return 0
    fi
    if [[ -z "$units1" ]]; then
        TG_BASE_REASON="the base failed with no identifiable failing units"
        return 0
    fi
    if [[ -z "$pass1" || "$pass1" == "0" ]]; then
        TG_BASE_REASON="every unit fails on the base (broken environment)"
        return 0
    fi
    TG_BASE_OK=1
    TG_BASE_EXIT="$rc1"
    TG_BASE_UNITS="$units1"
    return 0
}

# tg_baseline_for <cmd> — sets TG_BASE_OK / TG_BASE_EXIT / TG_BASE_UNITS / TG_BASE_REASON.
# Trusted results are cached per base commit and command in the loop's store. Untrusted ones are
# never cached, so the base is re-checked on the next failure.
tg_baseline_for() {
    local cmd="$1" key file
    if ! tg_store_dir; then
        TG_BASE_OK=0; TG_BASE_EXIT="untrusted"; TG_BASE_UNITS=""
        TG_BASE_REASON="could not create the baseline store"
        return 0
    fi
    key="$(printf '%s\n%s' "${LOOP_START_COMMIT:-none}" "$cmd" | cksum | awk '{print $1}')"
    file="$_TG_STORE/base-$key.txt"
    if [[ -f "$file" ]]; then
        TG_BASE_OK=1
        TG_BASE_EXIT="$(sed -n 's/^exit=//p' "$file" | head -1)"
        TG_BASE_UNITS="$(sed -n 's/^unit=//p' "$file")"
        TG_BASE_REASON=""
        return 0
    fi
    _tg_compute_base "$cmd"
    if [[ "$TG_BASE_OK" == "1" ]]; then
        local tmp="${file}.tmp.$$"
        {
            echo "exit=$TG_BASE_EXIT"
            printf '%s\n' "$TG_BASE_UNITS" | grep -v '^$' | sed 's/^/unit=/' || true
        } > "$tmp" && mv "$tmp" "$file"
    fi
    return 0
}

# ─── Judgement ────────────────────────────────────────────────────────────────

# tg_judge <cmd> <exit> <log> <timeout_s> <baseline_eligible 0|1>
# Call only for a failing command. Sets the TG_* judgement. Returns 1 when the failure blocks.
# baseline_eligible=0 marks a test created during this loop: it has no base-commit counterpart.
tg_judge() {
    local cmd="$1" rc="$2" log="$3" limit="$4" eligible="${5:-1}"
    local iter_units new="" u
    tg_reset_judgement
    if [[ "$eligible" != "1" ]]; then
        TG_BASE_EXIT="n/a"
        _tg_block created-in-loop "BLOCKING: '${cmd}' (exit ${rc}) is a test created during this loop and has no base-commit counterpart. Fix it."
        return 1
    fi
    tg_baseline_for "$cmd"
    if [[ "$TG_BASE_OK" != "1" ]]; then
        _tg_block untrusted-baseline "BLOCKING: '${cmd}' (exit ${rc}) failed, and no trustworthy base-commit baseline could be established (${TG_BASE_REASON}). Treated as a regression. Fix it."
        return 1
    fi
    if [[ "$TG_BASE_EXIT" == "0" ]]; then
        TG_NEW_FAILURES=""
        _tg_block regression "BLOCKING: NEW FAILURE: '${cmd}' exits ${rc} but passes on the base commit. Fix it."
        return 1
    fi
    tg_parse_log "$log"
    case "$rc" in
        124|137|143)
            _tg_block timeout "BLOCKING: '${cmd}' timed out or was killed (exit ${rc}); it cannot be shown to be pre-existing. Fix it."
            return 1 ;;
    esac
    iter_units="$TG_UNITS"
    if [[ "$TG_PARSABLE" != "1" || -z "$iter_units" ]]; then
        _tg_block unattributed "BLOCKING: '${cmd}' (exit ${rc}) failed with no recognisable failing units, so it cannot be shown to be pre-existing. Fix it."
        return 1
    fi
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        if ! printf '%s\n' "$TG_BASE_UNITS" | grep -Fx -- "$u" >/dev/null; then
            new="${new}${u}"$'\n'
        fi
    done <<< "$iter_units"
    new="$(printf '%s' "$new" | grep -v '^$' || true)"
    if [[ -n "$new" ]]; then
        TG_NEW_FAILURES="$new"
        _tg_block new-failures "BLOCKING: NEW FAILURES in '${cmd}' (not failing on the base commit). Fix these: $(echo "$new" | tr '\n' ' ')"
        return 1
    fi
    TG_PREEXISTING="true"
    TG_VERDICT="pre-existing"
    _tg_add_verdict "PRE-EXISTING, not blocking: '${cmd}' fails the same units on the base commit (exit ${TG_BASE_EXIT}). Do NOT try to fix these; they are not part of this task: $(echo "$iter_units" | tr '\n' ' ')"
    return 0
}

# tg_record <results_json> <cmd> <exit> <duration_s> — append one evidence entry. Uses the last
# tg_judge judgement when exit is non-zero. Prints the new JSON array. Runs in a subshell, so it
# must not change the judgement globals.
tg_record() {
    local results="$1" cmd="$2" rc="$3" dur="$4" base_json="null" new_json="[]" pre="false" verdict="pass"
    if ! command -v jq >/dev/null 2>&1; then
        echo "$results"
        return 0
    fi
    if [[ "$rc" -ne 0 ]]; then
        [[ "$TG_BASE_EXIT" =~ ^[0-9]+$ ]] && base_json="$TG_BASE_EXIT"
        new_json="$(printf '%s' "$TG_NEW_FAILURES" | jq -R -s 'split("\n") | map(select(length > 0))')"
        pre="$TG_PREEXISTING"
        verdict="$TG_VERDICT"
    fi
    echo "$results" | jq --arg cmd "$cmd" --argjson exit "$rc" --argjson dur "$dur" \
        --argjson base "$base_json" --argjson new "$new_json" --argjson pre "$pre" --arg verdict "$verdict" \
        '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur,
               "baseline_exit_code": $base, "new_failures": $new, "preexisting": $pre, "verdict": $verdict}]'
}
