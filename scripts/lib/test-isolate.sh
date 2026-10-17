#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright test-isolate — keeps a test suite out of the developer's      ║
# ║  real tmux server, HOME and process tree (#8648)                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Every scripts/*-test.sh and scripts/sw-lib-*-test.sh calls `sw_test_isolate` right after it
# sources its harness, before any trap is set (tools/arch/test-isolation.ts enforces this).
# lib/test-helpers.sh sources this file; suites that do not use the harness source it directly.
#
# sw_test_isolate:
#   - exports SHIPWRIGHT_TEST_MODE=1 (production code refuses to start real daemons in this mode);
#   - points TMUX_TMPDIR at a private directory and unsets TMUX/TMUX_PANE, so every tmux call
#     talks to a private server;
#   - points HOME at a temp dir (a suite may set SW_TEST_HOME, or already use a temp HOME);
#   - installs an EXIT/INT/TERM teardown that kills the suite's descendant processes and the
#     private tmux server.
#
# Bash keeps one trap per signal. A suite with its own EXIT trap must end it with
# `; sw_test_teardown`, e.g. `trap 'cleanup_env; sw_test_teardown' EXIT`. The arch check enforces it.

[[ -n "${_SW_TEST_ISOLATE_LOADED:-}" ]] && return 0
_SW_TEST_ISOLATE_LOADED=1

# Teardown never uses command substitution: every snapshot goes to a file under the run root, so no
# subshell of the owner can end up in the kill list (#8653 review).

# SIGTERM the space-separated pids in $1, wait up to ~2 s, then SIGKILL the survivors.
_sw_test_kill_pids() {
    local pids="$1" p alive i
    [[ -n "$pids" ]] || return 0
    for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
    for i in 1 2 3 4 5 6 7 8 9 10; do
        alive=""
        for p in $pids; do
            if kill -0 "$p" 2>/dev/null; then alive="$alive $p"; fi
        done
        [[ -n "$alive" ]] || return 0
        pids="$alive"
        sleep 0.2
    done
    for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
    return 0
}

# Print the pids to kill. Only the tools teardown itself runs are exempt: a suite
# child such as a background sleep or tail -f is a victim. $1 = ps snapshot (pid ppid command), $2 = pane pids, $3 = lock holders.
# Victims are the owner's descendants (including orphans, which lsof and the root path still find),
# the tmux panes and their children, and anything naming this run's root. Never the owner itself,
# and never the helpers teardown runs (ps, lsof, awk and friends).
_sw_test_victims() {
    awk -v me="$$" -v root="${_SW_TEST_ROOT:-}" -v panesf="$2" -v holdf="$3" '
        function is_helper(cmd,    p, n) {
            n = split(cmd, p, " ")
            if (n == 0) return 0
            n = split(p[1], q, "/")
            return q[n] ~ /^(ps|lsof|awk|tr)$/
        }
        BEGIN {
            ns = 0
            while ((getline line < panesf) > 0) if (line ~ /^[0-9]+$/) seeds[++ns] = line
            while ((getline line < holdf) > 0) if (line ~ /^[0-9]+$/) holders[line] = 1
            seeds[++ns] = me
        }
        {
            pid = $1; ppid = $2
            cmd = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", cmd)
            kids[ppid] = kids[ppid] " " pid
            if (root != "" && index(cmd, root) > 0) rooted[pid] = 1
            if (is_helper(cmd)) helpers[pid] = 1
        }
        END {
            head = 1; tail = 0
            for (i = 1; i <= ns; i++) if (!(seeds[i] in seen)) { seen[seeds[i]] = 1; queue[++tail] = seeds[i] }
            while (head <= tail) {
                p = queue[head++]
                m = split(kids[p], ch, " ")
                for (j = 1; j <= m; j++) if (!(ch[j] in seen)) { seen[ch[j]] = 1; queue[++tail] = ch[j] }
            }
            for (p in seen) victims[p] = 1
            for (p in holders) victims[p] = 1
            for (p in rooted) victims[p] = 1
            for (p in victims) if (p != me && !(p in helpers)) print p
        }' "$1"
}

_sw_test_on_signal() {
    sw_test_teardown
    exit "$1"
}

# Kill this suite's processes and its private tmux server. Idempotent. Runs only in the owner shell:
# a subshell shares $$ with its parent, so walking the tree from a subshell would kill the parent's
# children.
sw_test_teardown() {
    [[ "${BASH_SUBSHELL:-0}" == "0" ]] || return 0
    [[ -n "${_SW_TEST_TMUX_DIR:-}" ]] || return 0
    [[ -z "${_SW_TEST_TORN_DOWN:-}" ]] || return 0
    _SW_TEST_TORN_DOWN=1
    # tmux falls back to the developer's default socket when TMUX_TMPDIR names a missing directory,
    # so the private directory must exist for every tmux call below and after. It is never removed
    # here; the next isolate call collects it once it carries a .done marker and is over a day old.
    mkdir -p "$_SW_TEST_TMUX_DIR"

    local panes="$_SW_TEST_ROOT/teardown.panes" holders="$_SW_TEST_ROOT/teardown.holders"
    local snap="$_SW_TEST_ROOT/teardown.snap" victims="$_SW_TEST_ROOT/teardown.victims"
    : > "$panes"
    : > "$holders"
    if command -v tmux >/dev/null 2>&1; then
        TMUX_TMPDIR="$_SW_TEST_TMUX_DIR" tmux list-panes -a -F '#{pane_pid}' > "$panes" 2>/dev/null || true
    fi
    if command -v lsof >/dev/null 2>&1 && [[ -n "${_SW_TEST_LOCK:-}" ]]; then
        lsof -t -- "$_SW_TEST_LOCK" > "$holders" 2>/dev/null || true
    fi
    ps -axwwo pid=,ppid=,command= > "$snap" 2>/dev/null || true
    _sw_test_victims "$snap" "$panes" "$holders" > "$victims" 2>/dev/null || true
    _sw_test_kill_pids "$(tr '\n' ' ' < "$victims")"

    if command -v tmux >/dev/null 2>&1; then
        TMUX_TMPDIR="$_SW_TEST_TMUX_DIR" tmux kill-server >/dev/null 2>&1 || true
    fi
    : > "$_SW_TEST_TMUX_DIR/.done" 2>/dev/null || true
    case "${_SW_TEST_ROOT:-}" in
        */sw-test-iso.*) rm -rf "$_SW_TEST_ROOT" ;;
    esac
    return 0
}

# Remove private tmux directories from finished runs (marked .done, over a day old). Never the current one.
_sw_test_collect_done_dirs() {
    local d
    while IFS= read -r d; do
        if [[ -n "$d" && "$d" != "$_SW_TEST_TMUX_DIR" && -f "$d/.done" ]]; then
            rm -rf "$d"
        fi
    done < <(find /tmp -maxdepth 1 -name 'sw-test-tmux.*' -type d -mtime +1 2>/dev/null)
    return 0
}

sw_test_isolate() {
    # Idempotent: a second call in the same shell does nothing.
    [[ -z "${_SW_TEST_TMUX_DIR:-}" ]] || return 0

    export SHIPWRIGHT_TEST_MODE=1
    _SW_TEST_REAL_TMUX_TMPDIR="${TMUX_TMPDIR:-}"
    _SW_TEST_REAL_HOME="${HOME:-}"
    # Abort rather than run against the developer's tmux server: an empty TMUX_TMPDIR is never used.
    # /tmp is short enough for a unix socket path; mktemp under $TMPDIR on macOS is not.
    _SW_TEST_TMUX_DIR="$(mktemp -d /tmp/sw-test-tmux.XXXXXX)" || _SW_TEST_TMUX_DIR=""
    if [[ -z "$_SW_TEST_TMUX_DIR" || ! -d "$_SW_TEST_TMUX_DIR" ]]; then
        echo "sw_test_isolate: cannot create a private tmux directory; refusing to run this suite" >&2
        exit 1
    fi
    _sw_test_collect_done_dirs
    _SW_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-iso.XXXXXX")" || _SW_TEST_ROOT=""
    if [[ -z "$_SW_TEST_ROOT" || ! -d "$_SW_TEST_ROOT" ]]; then
        echo "sw_test_isolate: cannot create the run directory; refusing to run this suite" >&2
        exit 1
    fi
    # Lock fd: inherited by every descendant, so teardown can find orphans with lsof (see _sw_test_victims).
    _SW_TEST_LOCK="$_SW_TEST_ROOT/owner.lock"
    : > "$_SW_TEST_LOCK"
    # bash 3.2 does not replace an inherited fd 190 on `exec 190>>`, so close it first: a nested suite
    # gets its own lock, not its parent's.
    exec 190>&- 2>/dev/null || true
    exec 190>>"$_SW_TEST_LOCK"
    export TMUX_TMPDIR="$_SW_TEST_TMUX_DIR"
    unset TMUX TMUX_PANE

    # Keep a HOME the suite already pointed at a temp dir; otherwise use a fresh one.
    case "${HOME:-}" in
        "${TMPDIR:-/tmp}"*|/tmp/*|/private/tmp/*|/var/folders/*) ;;
        *)
            if [[ -n "${SW_TEST_HOME:-}" ]]; then
                export HOME="$SW_TEST_HOME"
            else
                mkdir -p "$_SW_TEST_ROOT/home"
                export HOME="$_SW_TEST_ROOT/home"
                # Keep git commits working: copy the developer's identity, never write to the original.
                if [[ -f "$_SW_TEST_REAL_HOME/.gitconfig" ]]; then
                    cp "$_SW_TEST_REAL_HOME/.gitconfig" "$HOME/.gitconfig"
                fi
            fi
            ;;
    esac
    # cleanup_test_env restores HOME to ORIG_HOME; keep that the isolated home, not the real one.
    ORIG_HOME="$HOME"

    trap '_sw_test_on_signal 130' INT
    trap '_sw_test_on_signal 143' TERM
    trap sw_test_teardown EXIT
    return 0
}
