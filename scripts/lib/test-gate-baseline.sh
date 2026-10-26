#!/usr/bin/env bash
# lib/test-gate-baseline.sh — differential test gate for the build loop (#8633).
#
# The loop's test gate used to mark an iteration failed when ANY test command exited non-zero.
# A repo whose suite already fails (or whose test scripts overlap) could then never converge.
# This lib lets an iteration pass only on positive evidence that every failure it shows already
# exists on the loop's base commit (LOOP_START_COMMIT). Everything else blocks.
#
# Units. A failing run is described by units: "suite::exit=N" or "suite::TIMEOUT" for each failing
# suite, "suite::INCOMPLETE" for a failing suite whose log has no completion line (test-helpers
# prints "N of M tests failed" or "All M tests passed" when it finishes), and "suite::assertion"
# for each failing assertion. bun test units are test names.
# A suite that times out or is INCOMPLETE in the iteration is never pre-existing, even when the base
# has the same unit: its assertions after the stop point are unknown. Suites that do not print a
# completion line therefore cannot be pre-existing; they block until they do.
#
# A failing command is judged like this:
#   blocks   base passes                                         (regression)
#   blocks   base result untrusted (see below)                   (fail closed)
#   blocks   iteration timed out or was killed (124/137/143)
#   blocks   iteration output not parsable, or no failing unit recognised
#   blocks   iteration has a ::TIMEOUT or ::INCOMPLETE unit (it did not finish; nothing proven)
#   blocks   iteration has a unit the base does not have          (new failure)
#   pre-existing (does not block) only when every iteration unit also appears on the base.
#
# The base result is trusted only when: it was run (not 126/127, not killed by a timeout), its
# output has a runner summary, it has failing units, and it does not fail every unit (a broken
# environment). Two independent runs must agree. Only trusted results are cached, and the cache is
# in this shell's memory (run_test_gate runs in the loop's main shell), never on disk.
#
# The base runs in a temporary detached worktree created with hooks disabled, in its own process
# group where perl is available (setpgrp), under a watchdog (SW_TEST_TIMEOUT, no `timeout` binary
# needed). The watchdog also stops the run and removes the worktree when the loop process is gone.
# INT/TERM/EXIT remove the worktree, temp files and process tree.
#
# Usage (sw-loop.sh run_test_gate):
#   tg_begin_gate                                                   # once per gate run
#   tg_judge "$cmd" "$exit" "$log" "$timeout" 1 || all_passed=false  # only when exit != 0
#   results=$(tg_record "$results" "$cmd" "$exit" "$duration")
#   TEST_OUTPUT="$(tg_verdict_text; echo "$combined_output" | tail -50)"

[[ -n "${_SW_TEST_GATE_BASELINE_LOADED:-}" ]] && return 0
_SW_TEST_GATE_BASELINE_LOADED=1
_TG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The base run sources test-gate-env.sh as it was when this library loaded, never from a worktree the
# agent can edit (#8671). The body is kept in memory and written into each run's temp dir.
_TG_ENV_BODY="$(cat "$_TG_LIB_DIR/test-gate-env.sh" 2>/dev/null || true)"

# Judgement of the last tg_judge call.
TG_BLOCKING="true"
TG_VERDICT=""            # pass | pre-existing | regression | new-failures | unattributed | timeout | unverifiable | untrusted-baseline | created-in-loop
TG_BASE_EXIT=""          # trusted base exit code, or "n/a"; empty when untrusted
TG_NEW_FAILURES=""       # newline-separated units this iteration failed that the base did not
TG_PREEXISTING="false"
TG_BASE_OK=0             # 1 when the base result is trusted
TG_BASE_UNITS=""         # newline-separated units of the trusted base result
TG_BASE_REASON=""        # why the base is not trusted
TG_UNITS=""
TG_PARSABLE=0
TG_PASSCOUNT=""
_TG_VERDICTS=""          # verdict lines for this gate run

# Trusted base results, kept in memory as parallel indexed arrays (bash 3.2: no associative arrays).
_TG_CACHE_N=0
_TG_CACHE_BASE=()
_TG_CACHE_CMD=()
_TG_CACHE_EXIT=()
_TG_CACHE_UNITS=()

# Active base run (removed by _tg_cleanup_base).
_TG_ROOT=""              # repository that owns the base worktree
_TG_WT=""                # active base worktree
_TG_TMP=""               # active temp dir (scripts only)
_TG_PID=""               # root process of the active base run
_TG_PGRP=""              # process group of the active base run, when it was started with setpgrp
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

# tg_parse_log <log> — sets TG_UNITS (sorted unique), TG_PARSABLE (1 when the log has a runner
# summary) and TG_PASSCOUNT (passing units, empty if unknown).
# sw-test-all.sh layout: per-suite lines "  ✗ <suite>  exit N" / "  ⧗ <suite>  TIMEOUT"; then, for
# each failing suite, a "━━━ <suite> (…)" section with the suite's full log (the gate sets
# FAIL_LOG_LINES). Assertion lines are indented deeper than the per-suite lines.
# bun test layout (a top-level "Ran N tests across M files" line): "(fail) <name>" lines (or "✗ <name>"
# when bun colours its output, as in a terminal or FORCE_COLOR), a "<file>:" header before each file's
# "# Unhandled error between tests" block, and the summary. Golden logs of each shape: scripts/fixtures/bun-test.
# Under GitHub Actions the header is a "::group::<file>:" line, see tg_parse_log.
# What is covered: ANSI colour codes (ESC[..m) are stripped and CRs are dropped. An ESC[2K line erase or a partial
# line is not rewritten, so a unit cut that way is caught only by the count unit (total against pass plus fail).
# L4, a known limit (#8671): the judgement reads the test command's stdout. Output the tests print themselves
# can imitate a bun file header ("other.test.ts:"), and then a failure is filed under another file. The
# robust input is bun's reporter output (bun 1.2.19 has --reporter=junit --reporter-outfile=...), but the
# gate runs the project's command and cannot add that flag. Until it can, treat a pre-existing verdict
# on a bun run whose tests print such headers as unverified.
tg_parse_log() {
    local log="$1" plain units="" pass summary=0 bun=0
    # CRs go too: a log captured through a pty (script, a terminal-backed CI step) ends every line in
    # CRLF, which breaks the "<file>:" header and the (fail)/✗ line anchors (#8664).
    # GitHub Actions: bun wraps each file in "::group::<file>:" ... "::endgroup::" and reports failures
    # as "::error ...::" annotations. Keep the group title as the file header; drop the rest (#8664).
    plain="$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$log" 2>/dev/null | tr -d '\r' | sed -E -e '/^::(endgroup|error|warning|notice)(::| )/d' -e 's/^::group:://' || true)"
    units="$(printf '%s\n' "$plain" | awk '
        /^━━━ [^ ]+ \(/ { cur = $2; next }
        /^  FAILING SUITES/ { cur = ""; next }
        # Glyph tests are regexes: this awk (macOS) compares multibyte strings wrongly.
        /^  ⧗ [^ ]+/ { cur = ""; s = $2; sfail[s] = 1; sst[s] = "TIMEOUT"; next }
        /^  ✗ [^ ]+/ { cur = ""; s = $2; sfail[s] = 1; sst[s] = "exit=" $4; next }
        # Anchored at both ends to the lines test-helpers prints, at any nesting depth. Output from the code under test can hide a
        # "N of M" or "All N" inside an assertion detail, and a loose match would stop the counting early (#8671).
        cur != "" && /^ +[0-9]+ of [0-9]+ tests? failed$/ {
            comp[cur] = 1
            line = $0; sub(/.* of /, "", line); sub(/ tests? failed.*/, "", line)
            tot[cur] = line; next
        }
        cur != "" && /^ +All [0-9]+ tests? passed$/ { comp[cur] = 1; next }
        # Assertions of a failing suite, passing ones included: the n-th line with a given description
        # is "desc#n", so the position of a repeated name is known. The list that test-helpers prints
        # after its completion line repeats the failures and is not counted.
        # Alternation, not a bracket: under a C locale (LANG unset, as in launchd and systemd) awk matches
        # a bracket byte by byte, so a multibyte glyph inside [...] matches nothing (#8671).
        cur != "" && !(cur in comp) && /^ +(✓|✗) / {
            line = $0; sub(/^ +(✓|✗) /, "", line)
            occ[cur SUBSEP line]++
            if ($0 ~ /^ +✗ /) { nfail[cur]++; print cur "::" line "#" occ[cur SUBSEP line] }
            else { npass[cur]++ }
            next
        }
        END {
            for (s in sfail) {
                print s "::" sst[s]
                if (sst[s] != "TIMEOUT" && !(s in comp)) print s "::INCOMPLETE"
                if (s in tot) print s "::total=" tot[s]
                # test-helpers prints one line per assertion. A suite whose total has assertions that
                # printed no pass line (npass is 0) cannot be positioned: its occurrence numbers are
                # unknown, so it blocks.
                if (s in tot && npass[s] == 0 && tot[s] + 0 > nfail[s] + 0) print s "::UNORDERED"
                # The assertions counted before the completion line must account for the whole total. A
                # mismatch means some assertion was not seen in order, so the suite cannot be verified.
                if (s in tot && npass[s] + nfail[s] != tot[s] + 0) print s "::UNORDERED"
            }
        }
    ' || true)"
    if printf '%s\n' "$plain" | grep -E '^Ran [0-9]+ tests? across [0-9]+ files?' >/dev/null; then
        bun=1
    fi
    if [[ "$bun" -eq 1 ]]; then
        units="${units}"$'\n'"$(_tg_bun_units "$plain")"
    fi
    TG_UNITS="$(printf '%s\n' "$units" | grep -v '^$' | sort || true)"
    pass="$(printf '%s\n' "$plain" | sed -nE 's/^ *([0-9]+) passed +[0-9]+ failed.*$/\1/p' | tail -1 || true)"
    if [[ -z "$pass" ]]; then
        pass="$(printf '%s\n' "$plain" | sed -nE 's/^ *([0-9]+) pass$/\1/p' | tail -1 || true)"
    fi
    TG_PASSCOUNT="$pass"
    if printf '%s\n' "$plain" | grep -E ' passed +[0-9]+ failed +[0-9]+ timed out' >/dev/null; then
        summary=1
    elif [[ "$bun" -eq 1 ]]; then
        summary=1
    fi
    TG_PARSABLE=0
    [[ "$summary" -eq 1 ]] && TG_PARSABLE=1
    return 0
}

# _tg_bun_units <plain_log> — the units of a bun test run: failing names qualified by their file
# (the "<file>:" header bun prints before each file's errors, so "<file>::<name>"), load errors per
# file (or bun::error=N when no header precedes the block), and the counts.
_tg_bun_units() {
    local plain="$1" ran files fail err skip
    printf '%s\n' "$plain" | awk '
        /^[^ #(-].*:$/ && !/^error:/ { hdr = $0; sub(/:$/, "", hdr); next }
        /^# Unhandled error between tests/ { if (hdr != "") print hdr "::LOAD_ERROR"; next }
        # Same name in one file: the n-th (fail) line of that name is "#n". bun does not list passing
        # tests by default, so passes cannot be counted; a repeated name is therefore only ordered
        # among its failures (a documented limit).
        /^(\(fail\)|✗) / { line = $0; sub(/^(\(fail\)|✗) /, "", line); sub(/ \[[0-9.]+m?s\]$/, "", line)
                        if (hdr != "") line = hdr "::" line
                        occ[line]++
                        print line "#" occ[line]; next }
    ' || true
    ran="$(printf '%s\n' "$plain" | sed -nE 's/^Ran ([0-9]+) tests? across .*/\1/p' | tail -1)"
    files="$(printf '%s\n' "$plain" | sed -nE 's/^Ran [0-9]+ tests? across ([0-9]+) files?.*/\1/p' | tail -1)"
    fail="$(printf '%s\n' "$plain" | sed -nE 's/^ *([0-9]+) fail$/\1/p' | tail -1)"
    err="$(printf '%s\n' "$plain" | sed -nE 's/^ *([0-9]+) errors?$/\1/p' | tail -1)"
    skip="$(printf '%s\n' "$plain" | sed -nE 's/^ *([0-9]+) skip$/\1/p' | tail -1)"
    echo "bun::ran=${ran:-0}"
    echo "bun::files=${files:-0}"
    echo "bun::fail=${fail:-0}"
    echo "bun::error=${err:-0}"
    echo "bun::skip=${skip:-0}"
}

# ─── In-memory cache ──────────────────────────────────────────────────────────

# _tg_cache_find <base> <cmd> — sets _TG_CACHE_IDX to the entry index, or -1.
_tg_cache_find() {
    local i=0
    _TG_CACHE_IDX=-1
    while [[ "$i" -lt "$_TG_CACHE_N" ]]; do
        if [[ "${_TG_CACHE_BASE[$i]}" == "$1" && "${_TG_CACHE_CMD[$i]}" == "$2" ]]; then
            _TG_CACHE_IDX="$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 0
}

# ─── Base run ─────────────────────────────────────────────────────────────────

# _tg_kill_tree <pid> <signal> — signal a process and its descendants. A pid that is gone is not
# signalled (kill -0 first), so a reused or reaped pid is never hit.
_tg_kill_tree() {
    local pid="$1" sig="$2" child
    [[ -z "$pid" ]] && return 0
    kill -0 "$pid" 2>/dev/null || return 0
    for child in $(ps -axo pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2 == p { print $1 }'); do
        _tg_kill_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

# _tg_kill_by_path <path> — KILL every process whose command line contains <path> (the base
# worktree). The fallback for runs without a process group; the pipeline's own greps are excluded.
_tg_kill_by_path() {
    local path="$1" pid
    [[ -z "$path" ]] && return 0
    for pid in $(ps -axo pid=,command= 2>/dev/null | grep -F -- "$path" | grep -v grep | awk -v me="$$" '$1 != me { print $1 }'); do
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    done
}

# _tg_group_alive <pgid> — 0 when the process group still has members. Never our own group (a
# reused id could be ours), so a stale id cannot make us signal ourselves.
_tg_group_alive() {
    local g="$1" own
    [[ -z "$g" ]] && return 1
    own="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
    [[ "$g" == "$own" ]] && return 1
    ps -axo pgid= 2>/dev/null | tr -d ' ' | grep -Fx -- "$g" >/dev/null
}

# _tg_kill_run <pid> <signal> — signal the run: its process group when it was started with
# setpgrp (even when the leader has exited, so background children are reached too), then its
# process tree.
_tg_kill_run() {
    local pid="$1" sig="$2"
    [[ -z "$pid" ]] && return 0
    if [[ -n "$_TG_PGRP" && "$pid" == "$_TG_PID" ]] && _tg_group_alive "$_TG_PGRP"; then
        kill "-$sig" -- "-$_TG_PGRP" 2>/dev/null || true
    fi
    kill -0 "$pid" 2>/dev/null || return 0
    _tg_kill_tree "$pid" "$sig"
}

# _tg_stop_run — stop the active base run, its process group and its watchdog. Idempotent.
_tg_stop_run() {
    if _tg_group_alive "$_TG_PGRP"; then
        kill -KILL -- "-$_TG_PGRP" 2>/dev/null || true
    fi
    if [[ -n "$_TG_PID" ]]; then
        _tg_kill_tree "$_TG_PID" KILL
        _TG_PID=""
    fi
    _TG_PGRP=""
    if [[ -n "$_TG_WD" ]]; then
        _tg_kill_run "$_TG_WD" KILL
        { wait "$_TG_WD"; } 2>/dev/null || true
        _TG_WD=""
    fi
    if [[ -n "$_TG_WT" ]]; then
        _tg_kill_by_path "$_TG_WT"
    fi
}

# _tg_install_guards — remove base resources on exit and on INT/TERM. In the loop's own process an
# existing INT/TERM handler (the loop's cleanup, which writes state) is kept, and the EXIT guard
# does the cleanup. A subshell does not reliably run inherited handlers, so it installs its own.
_tg_install_guards() {
    local main=0
    [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] && main=1   # BASHPID is not available in bash 3.2
    if [[ -z "$(trap -p EXIT)" ]]; then
        trap '_tg_cleanup_base' EXIT
    fi
    if [[ "$main" -eq 0 || -z "$(trap -p INT)" ]]; then
        trap '_tg_cleanup_base; exit 130' INT
    fi
    if [[ "$main" -eq 0 || -z "$(trap -p TERM)" ]]; then
        trap '_tg_cleanup_base; exit 143' TERM
    fi
}

# _tg_cleanup_base — stop the active base run and remove its worktree and temp files. Idempotent.
_tg_cleanup_base() {
    _tg_stop_run
    if [[ -n "$_TG_WT" ]]; then
        git -C "$_TG_ROOT" worktree remove --force "$_TG_WT" >/dev/null 2>&1 || true
        git -C "$_TG_ROOT" worktree prune >/dev/null 2>&1 || true
        _TG_WT=""
    fi
    if [[ -n "$_TG_TMP" ]]; then
        rm -f "$_TG_TMP"/cmd.sh "$_TG_TMP"/run.sh "$_TG_TMP"/test-gate-env.sh "$_TG_TMP"/*.log 2>/dev/null || true
        rmdir "$_TG_TMP" 2>/dev/null || true
        _TG_TMP=""
    fi
}

# _tg_run_base_once <worktree> <cmd> <limit_s> <log> — run cmd once in the worktree, under a
# watchdog. Sets _TB_RC (124 when the watchdog stopped the run).
_tg_run_base_once() {
    local wt="$1" cmd="$2" limit="$3" log="$4" pid wd owner="$$" elapsed=0
    printf '%s\n' "$cmd" > "$_TG_TMP/cmd.sh"
    {
        printf 'cd "%s" || exit 1\n' "$wt"
        printf 'export PROJECT_ROOT="%s" FAIL_LOG_LINES=100000\n' "$wt"
        printf 'source "%s/test-gate-env.sh"\n' "$_TG_TMP"
        printf 'sw_test_gate_env bash "%s/cmd.sh"\n' "$_TG_TMP"
    } > "$_TG_TMP/run.sh"
    printf '%s\n' "$_TG_ENV_BODY" > "$_TG_TMP/test-gate-env.sh"
    _TG_PGRP=""
    if command -v perl >/dev/null 2>&1; then
        # perl's setpgrp makes the run a process-group leader; exec keeps the same pid.
        ( trap - INT TERM EXIT
          exec perl -e 'setpgrp(0, 0) or exit 1; exec @ARGV or exit 127' bash "$_TG_TMP/run.sh"
        ) > "$log" 2>&1 &
        _TG_PGRP="$!"
    else
        ( trap - INT TERM EXIT
          exec bash "$_TG_TMP/run.sh"
        ) > "$log" 2>&1 &
    fi
    pid=$!
    _TG_PID="$pid"
    (
        trap - INT TERM EXIT
        # Stop when the run exceeds its limit, or when the loop process that started it is gone.
        while [[ "$elapsed" -lt "$limit" ]]; do
            if ! kill -0 "$owner" 2>/dev/null; then
                _tg_cleanup_base
                exit 0
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        _tg_kill_run "$pid" TERM
        sleep 2
        _tg_kill_run "$pid" KILL
    ) &
    wd=$!
    _TG_WD="$wd"
    _TB_RC=0
    { wait "$pid"; } 2>/dev/null || _TB_RC=$?
    _tg_stop_run
    return 0
}

# _tg_resolve <path> [depth] — the physical path of a file or directory, following symlinks. Fails when the
# path does not resolve.
_tg_resolve() {
    local p="$1" depth="${2:-0}" d b t
    [[ "$depth" -lt 20 ]] || return 1
    d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
    b="$(basename "$p")"
    if [[ -L "$d/$b" ]]; then
        t="$(readlink "$d/$b")" || return 1
        case "$t" in
            /*) _tg_resolve "$t" $((depth + 1)) ;;
            *) _tg_resolve "$d/$t" $((depth + 1)) ;;
        esac
        return
    fi
    printf '%s/%s' "$d" "$b"
}

# _tg_link_entry <entry> <dest> <rootreal> <wt> — link one installed package into the base's node_modules.
# A workspace package (it resolves inside the repository) links to the base commit's copy, so the base judges
# committed code, not the iteration's. Anything else links to its real location (#8671, P3d).
_tg_link_entry() {
    local entry="$1" dest="$2" rootreal="$3" wt="$4" real rel
    real="$(_tg_resolve "$entry")" || return 0
    case "$real" in
        "$rootreal"/node_modules|"$rootreal"/node_modules/*) ln -s "$real" "$dest" 2>/dev/null || true ;;
        "$rootreal"/*)
            rel="${real#"$rootreal"/}"
            ln -s "$wt/$rel" "$dest" 2>/dev/null || true ;;
        *) ln -s "$real" "$dest" 2>/dev/null || true ;;
    esac
}

# _tg_build_base_nm <root> <wt> — node_modules for the base worktree: a real directory of links, one per
# top-level package, and one per scoped package (@scope/name).
_tg_build_base_nm() {
    local root="$1" wt="$2" nm rootreal entry name sub
    [[ -e "$root/node_modules" ]] || return 0
    nm="$(cd "$root/node_modules" 2>/dev/null && pwd -P)" || return 0
    rootreal="$(cd "$root" && pwd -P)" || return 0
    mkdir -p "$wt/node_modules" || return 0
    for entry in "$nm"/* "$nm"/.[!.]*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name="${entry##*/}"
        if [[ -d "$entry" && ! -L "$entry" && "$name" == @* ]]; then
            mkdir -p "$wt/node_modules/$name"
            for sub in "$entry"/* "$entry"/.[!.]*; do
                [[ -e "$sub" || -L "$sub" ]] || continue
                _tg_link_entry "$sub" "$wt/node_modules/$name/${sub##*/}" "$rootreal" "$wt"
            done
        else
            _tg_link_entry "$entry" "$wt/node_modules/$name" "$rootreal" "$wt"
        fi
    done
}

# _tg_compute_base <cmd> — run the base twice and decide whether the result is trusted.
# Sets TG_BASE_OK, TG_BASE_EXIT, TG_BASE_UNITS, TG_BASE_REASON.
_tg_compute_base() {
    local cmd="$1" limit="${SW_TEST_TIMEOUT:-900}" root="${PROJECT_ROOT:-.}" base="${LOOP_START_COMMIT:-}"
    local wt rc1 rc2 units1 units2 pass1 parsable1
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
    _TG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-baseline.XXXXXX")" || {
        TG_BASE_REASON="could not create a temp dir"; return 0; }
    _TG_ROOT="$root"
    _tg_install_guards
    # The worktree's name is random too: the test command runs as this user and must not find it by guessing (#8671).
    wt="$(mktemp -d "$_TG_TMP/wt.XXXXXX")" || { _tg_cleanup_base; TG_BASE_REASON="could not create the base worktree dir"; return 0; }
    _TG_WT="$wt"
    if ! git -C "$root" -c core.hooksPath=/dev/null worktree add --detach "$wt" "$base" >/dev/null 2>&1; then
        _tg_cleanup_base
        TG_BASE_REASON="git worktree add failed for the base commit"
        return 0
    fi
    # Dependencies are not in git: a farm of links, not the live tree (#8671, P3).
    _tg_build_base_nm "$root" "$wt"
    _tg_run_base_once "$wt" "$cmd" "$limit" "$_TG_TMP/run1.log"; rc1="$_TB_RC"
    tg_parse_log "$_TG_TMP/run1.log"
    units1="$TG_UNITS"; pass1="$TG_PASSCOUNT"; parsable1="$TG_PARSABLE"
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
    if [[ "$parsable1" != "1" ]]; then
        TG_BASE_REASON="the base output has no runner summary"
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
# Trusted results are kept in memory per base commit and command. Untrusted ones are not kept, so
# the base is checked again on the next failure.
tg_baseline_for() {
    local cmd="$1" base="${LOOP_START_COMMIT:-none}"
    _tg_cache_find "$base" "$cmd"
    if [[ "$_TG_CACHE_IDX" -ge 0 ]]; then
        TG_BASE_OK=1
        TG_BASE_EXIT="${_TG_CACHE_EXIT[$_TG_CACHE_IDX]}"
        TG_BASE_UNITS="${_TG_CACHE_UNITS[$_TG_CACHE_IDX]}"
        TG_BASE_REASON=""
        return 0
    fi
    _tg_compute_base "$cmd"
    if [[ "$TG_BASE_OK" == "1" ]]; then
        _TG_CACHE_BASE[$_TG_CACHE_N]="$base"
        _TG_CACHE_CMD[$_TG_CACHE_N]="$cmd"
        _TG_CACHE_EXIT[$_TG_CACHE_N]="$TG_BASE_EXIT"
        _TG_CACHE_UNITS[$_TG_CACHE_N]="$TG_BASE_UNITS"
        _TG_CACHE_N=$((_TG_CACHE_N + 1))
    fi
    return 0
}

# ─── Judgement ────────────────────────────────────────────────────────────────

# _tg_base_value <prefix> — the value of the base unit that starts with <prefix> (e.g. "s::total="),
# empty when the base has none. Prefix match is exact (awk index), so names need no escaping.
_tg_base_value() {
    printf '%s\n' "$TG_BASE_UNITS" | awk -v k="$1" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
}

# _tg_unit_is_new <unit> <iteration_count> — 0 when the iteration's units are not explained by the
# base. Units are a multiset: a unit that occurs more often in the iteration than on the base is new. Counts that describe how much ran are lower-is-bad: a suite
# or bun run whose test count drops has lost tests, so it blocks. Counts of failures are
# higher-is-bad: they block when they grow.
_tg_unit_is_new() {
    local u="$1" icount="$2" bcount bval
    bcount="$(printf '%s\n' "$TG_BASE_UNITS" | grep -Fxc -- "$u" || true)"
    if [[ "${bcount:-0}" -ge "$icount" ]]; then
        return 1
    fi
    if [[ "$u" =~ ^(.*::(total|ran|files)=)([0-9]+)$ ]]; then
        bval="$(_tg_base_value "${BASH_REMATCH[1]}")"
        [[ -z "$bval" ]] && return 0
        [[ "${BASH_REMATCH[3]}" -lt "$bval" ]] && return 0
        return 1
    fi
    if [[ "$u" =~ ^(.*::(fail|error|skip)=)([0-9]+)$ ]]; then
        bval="$(_tg_base_value "${BASH_REMATCH[1]}")"
        [[ -z "$bval" ]] && bval=0
        [[ "${BASH_REMATCH[3]}" -gt "$bval" ]] && return 0
        return 1
    fi
    return 0
}

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
    while IFS=$'\t' read -r icount u; do
        [[ -z "$u" ]] && continue
        if _tg_unit_is_new "$u" "$icount"; then
            new="${new}${u}"$'\n'
        fi
    done <<< "$(printf '%s\n' "$iter_units" | sort | uniq -c | awk '{ c = $1; sub(/^ *[0-9]+ /, ""); print c "\t" $0 }')"
    new="$(printf '%s' "$new" | grep -v '^$' || true)"
    if [[ -n "$new" ]]; then
        TG_NEW_FAILURES="$new"
        _tg_block new-failures "BLOCKING: NEW FAILURES in '${cmd}' (not failing on the base commit). Fix these: $(echo "$new" | tr '\n' ' ')"
        return 1
    fi
    # Every iteration unit also fails on the base. A suite that timed out, or that has no completion
    # line, has not shown its later assertions, so its units prove nothing even when the base has
    # them too: those always block.
    if printf '%s\n' "$iter_units" | grep -E '::(TIMEOUT|INCOMPLETE|UNORDERED)$' >/dev/null; then
        _tg_block unverifiable "BLOCKING: '${cmd}' has a suite that timed out, did not finish, or whose assertion order is unknown ($(printf '%s\n' "$iter_units" | grep -E '::(TIMEOUT|INCOMPLETE|UNORDERED)$' | tr '\n' ' ')). Its result cannot be shown to be pre-existing. Fix it."
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
