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

# Print the pids of all descendants of the space-separated pids in $1, one per line.
# Walks `ps -axo pid,ppid` breadth-first (BASHPID does not exist in bash 3.2).
_sw_test_descendants() {
    local roots="$1" snap
    snap="$(ps -axo pid=,ppid= 2>/dev/null)" || return 0
    awk -v roots="$roots" '
        { kids[$2] = kids[$2] " " $1 }
        END {
            n = split(roots, q, " ")
            head = 1; tail = 0
            for (i = 1; i <= n; i++) queue[++tail] = q[i]
            while (head <= tail) {
                p = queue[head++]
                m = split(kids[p], ch, " ")
                for (j = 1; j <= m; j++)
                    if (!(ch[j] in seen)) { seen[ch[j]] = 1; queue[++tail] = ch[j]; print ch[j] }
            }
        }' <<< "$snap"
}

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

# Print the pids holding this run's lock fd open. Every descendant inherits fd 190, and an orphan keeps
# it after its parent exits (macOS ps cannot show a process environment), so lsof finds backgrounded
# subshells after they are reparented to launchd (ppid 1). Excludes the owner shell.
_sw_test_holder_pids() {
    [[ -n "${_SW_TEST_LOCK:-}" ]] && command -v lsof >/dev/null 2>&1 || return 0
    lsof -t -- "$_SW_TEST_LOCK" 2>/dev/null | awk -v me="$$" '$1 != me' || true
}

# Print the pids of processes whose command line names this run's temp root.
_sw_test_root_pids() {
    [[ -n "${_SW_TEST_ROOT:-}" ]] || return 0
    ps -axwwo pid=,command= 2>/dev/null | awk -v r="$_SW_TEST_ROOT" -v me="$$" \
        'index($0, r) && $1 != me { print $1 }' || true
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
    # so the private directory must exist for every tmux call below and after. Recreate it if an
    # earlier EXIT trap removed it, and never delete it here.
    mkdir -p "$_SW_TEST_TMUX_DIR"

    local panes="" pids
    if command -v tmux >/dev/null 2>&1; then
        panes="$(TMUX_TMPDIR="$_SW_TEST_TMUX_DIR" tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ' || true)"
    fi
    # Pane shells are children of the tmux server, so they are not in this shell's tree: walk from them too.
    pids="$panes $(_sw_test_descendants "$$ $panes" | tr '\n' ' ' || true) $(_sw_test_holder_pids | tr '\n' ' ') $(_sw_test_root_pids | tr '\n' ' ')"
    _sw_test_kill_pids "$pids"

    if command -v tmux >/dev/null 2>&1; then
        TMUX_TMPDIR="$_SW_TEST_TMUX_DIR" tmux kill-server >/dev/null 2>&1 || true
    fi
    case "${_SW_TEST_ROOT:-}" in
        */sw-test-iso.*) rm -rf "$_SW_TEST_ROOT" ;;
    esac
    return 0
}

sw_test_isolate() {
    # Idempotent: a second call in the same shell does nothing.
    [[ -z "${_SW_TEST_TMUX_DIR:-}" ]] || return 0

    export SHIPWRIGHT_TEST_MODE=1
    _SW_TEST_REAL_TMUX_TMPDIR="${TMUX_TMPDIR:-}"
    _SW_TEST_REAL_HOME="${HOME:-}"
    # /tmp is short enough for a unix socket path; mktemp under $TMPDIR on macOS is not.
    _SW_TEST_TMUX_DIR="$(mktemp -d /tmp/sw-test-tmux.XXXXXX)"
    _SW_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-iso.XXXXXX")"
    # Lock fd: inherited by every descendant, so teardown can find orphans with lsof (see _sw_test_holder_pids).
    _SW_TEST_LOCK="$_SW_TEST_ROOT/owner.lock"
    : > "$_SW_TEST_LOCK"
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
