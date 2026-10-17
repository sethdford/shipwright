#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-lib-test-isolate-test.sh — regression test for test isolation (#8648) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Runs the harness in a separate bash process that starts a background sleep and a private tmux
# session, then exits. Asserts both are gone, the private socket differs from the real one, and the
# real tmux server never saw the probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Test isolation (#8648)"

PROBE_DIR="$TEST_TEMP_DIR/probe"
mkdir -p "$PROBE_DIR"
REAL_TMUX_DIR="${_SW_TEST_REAL_TMUX_TMPDIR:-/tmp}"
REAL_SOCKET_DIR="$REAL_TMUX_DIR/tmux-$(id -u)"
REAL_SESSIONS_BEFORE="$(TMUX_TMPDIR="$REAL_TMUX_DIR" tmux ls 2>/dev/null || true)"

# The probe runs in its own process so `$$` and the process tree belong to it, as in a real suite.
bash -c '
    set -euo pipefail
    source "$1/lib/test-helpers.sh"
    sw_test_isolate
    sw_test_isolate
    echo "$TMUX_TMPDIR" > "$2/tmpdir"
    echo "${TMUX-unset}" > "$2/tmux-var"
    sleep 300 &
    echo "$!" > "$2/sleep.pid"
    # Orphan: a grandchild whose parent subshell exits first, so it is reparented to launchd.
    ( sleep 302 & echo "$!" > "$2/orphan.pid" )
    sleep 0.2
    ps -o ppid= -p "$(cat "$2/orphan.pid")" | tr -d " " > "$2/orphan.ppid"
    if command -v tmux >/dev/null 2>&1; then
        tmux new-session -d -s sw-iso-probe "sleep 300"
        tmux list-panes -a -F "#{pane_pid}" > "$2/pane.pid"
        tmux ls > "$2/private-ls"
    fi
' _ "$SCRIPT_DIR" "$PROBE_DIR"

PROBE_TMUX_DIR="$(cat "$PROBE_DIR/tmpdir")"
SLEEP_PID="$(cat "$PROBE_DIR/sleep.pid")"

assert_eq "probe tmux variable is unset (TMUX cleared)" "unset" "$(cat "$PROBE_DIR/tmux-var")"
if [[ "$PROBE_TMUX_DIR" != "$REAL_TMUX_DIR" ]]; then
    assert_pass "private TMUX_TMPDIR differs from the real one"
else
    assert_fail "private TMUX_TMPDIR differs from the real one" "both are $REAL_TMUX_DIR"
fi
case "$PROBE_TMUX_DIR" in
    /tmp/sw-test-tmux.*) assert_pass "TMUX_TMPDIR is an isolated directory under /tmp" ;;
    *) assert_fail "TMUX_TMPDIR is an isolated directory under /tmp" "got: $PROBE_TMUX_DIR" ;;
esac

if kill -0 "$SLEEP_PID" 2>/dev/null; then
    assert_fail "background sleep is gone after the probe exits" "pid $SLEEP_PID still alive"
    kill -KILL "$SLEEP_PID" 2>/dev/null || true
else
    assert_pass "background sleep is gone after the probe exits"
fi

ORPHAN_PID="$(cat "$PROBE_DIR/orphan.pid")"
assert_eq "orphaned grandchild was reparented to launchd before the probe exited" "1" \
    "$(cat "$PROBE_DIR/orphan.ppid")"
if kill -0 "$ORPHAN_PID" 2>/dev/null; then
    assert_fail "orphaned grandchild is gone after the probe exits" "pid $ORPHAN_PID still alive"
    kill -KILL "$ORPHAN_PID" 2>/dev/null || true
else
    assert_pass "orphaned grandchild is gone after the probe exits"
fi

if command -v tmux >/dev/null 2>&1; then
    PANE_PID="$(head -n 1 "$PROBE_DIR/pane.pid")"
    if kill -0 "$PANE_PID" 2>/dev/null; then
        assert_fail "private tmux pane process is gone after the probe exits" "pid $PANE_PID still alive"
        kill -KILL "$PANE_PID" 2>/dev/null || true
    else
        assert_pass "private tmux pane process is gone after the probe exits"
    fi
    if [[ -d "$PROBE_TMUX_DIR" ]]; then
        assert_pass "private tmux directory still exists (tmux would fall back to the real socket if it were removed)"
    else
        assert_fail "private tmux directory still exists (tmux would fall back to the real socket if it were removed)"
    fi
    if grep -qF "sw-iso-probe" "$PROBE_DIR/private-ls"; then
        assert_pass "probe session was created on the private tmux server (positive control)"
    else
        assert_fail "probe session was created on the private tmux server (positive control)"
    fi
    PRIVATE_SESSIONS="$(TMUX_TMPDIR="$PROBE_TMUX_DIR" tmux ls 2>/dev/null || true)"
    assert_eq "private tmux server is gone after the probe exits" "" "$PRIVATE_SESSIONS"
fi

REAL_SESSIONS_AFTER="$(TMUX_TMPDIR="$REAL_TMUX_DIR" tmux ls 2>/dev/null || true)"
assert_eq "real tmux server never saw the probe session" "$REAL_SESSIONS_BEFORE" "$REAL_SESSIONS_AFTER"
if [[ "$REAL_SESSIONS_AFTER" == *sw-iso-probe* ]]; then
    assert_fail "real tmux server has no sw-iso-probe session"
else
    assert_pass "real tmux server has no sw-iso-probe session"
fi

print_test_section "private tmux directory collection (#8653)"
GC_BASE="$TEST_TEMP_DIR/gc"
mkdir -p "$GC_BASE"
mk_tmux_dir() { mkdir -p "$GC_BASE/$1"; }
# Dead owner: a pid that has already exited.
sleep 0 & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
mk_tmux_dir sw-test-tmux.stale-done;    : > "$GC_BASE/sw-test-tmux.stale-done/.done"
mk_tmux_dir sw-test-tmux.recent-done;   : > "$GC_BASE/sw-test-tmux.recent-done/.done"
mk_tmux_dir sw-test-tmux.stale-live;    echo "$$" > "$GC_BASE/sw-test-tmux.stale-live/.owner"
mk_tmux_dir sw-test-tmux.stale-dead;    echo "$DEAD_PID" > "$GC_BASE/sw-test-tmux.stale-dead/.owner"
# Backdate after writing the markers: writing a file changes the directory's mtime.
for d in stale-done stale-live stale-dead; do touch -t 202001010000 "$GC_BASE/sw-test-tmux.$d"; done
_sw_test_collect_done_dirs "$GC_BASE/"
if [[ -d "$GC_BASE/sw-test-tmux.stale-done" ]]; then
    assert_fail "a backdated directory with .done is removed"
else
    assert_pass "a backdated directory with .done is removed"
fi
if [[ -d "$GC_BASE/sw-test-tmux.recent-done" ]]; then
    assert_pass "a recent .done directory is kept"
else
    assert_fail "a recent .done directory is kept"
fi
if [[ -d "$GC_BASE/sw-test-tmux.stale-live" ]]; then
    assert_pass "a backdated directory whose owner is alive is kept"
else
    assert_fail "a backdated directory whose owner is alive is kept"
fi
if [[ -d "$GC_BASE/sw-test-tmux.stale-dead" ]]; then
    assert_fail "a backdated abandoned directory (owner gone) is removed"
else
    assert_pass "a backdated abandoned directory (owner gone) is removed"
fi

print_test_results
