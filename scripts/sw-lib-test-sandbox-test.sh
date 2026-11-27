#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/test-sandbox test — agent tests never run in the checkout ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: test-sandbox Tests"

setup_test_env "sw-lib-test-sandbox-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

_TEST_SANDBOX_LOADED=""
source "$SCRIPT_DIR/lib/test-gate-env.sh"
source "$SCRIPT_DIR/lib/test-sandbox.sh"

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T="$(cd "$TEST_TEMP_DIR" && pwd -P)"
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"
unset SW_TEST_SANDBOX SW_TEST_JAIL SW_TEST_SANDBOX_DEPS

expect_ok() { if "${@:2}"; then assert_pass "$1"; else assert_fail "$1"; fi; }
expect_fail() { if "${@:2}" 2>/dev/null; then assert_fail "$1"; else assert_pass "$1"; fi; }
sandboxes_left() { find "$TMPDIR" -maxdepth 1 -name 'sw-test-sandbox.*' | wc -l | tr -d ' '; }

new_trusted() {
    local repo="$1"
    rm -rf "$repo"
    git init -q -b main "$repo"
    (
        cd "$repo"
        mkdir -p src
        printf 'one\n' > src/app.txt
        printf 'node_modules/\n.env\n' > .gitignore
        git add -A && git commit -q -m base
        mkdir -p node_modules/dep .claude
        printf 'dep\n' > node_modules/dep/index.js
        printf 'SECRET=1\n' > .env
        printf 'two\n' >> src/app.txt               # uncommitted edit
        printf 'new\n' > src/new.test.txt            # untracked test file
        printf 'state\n' > .claude/state.json        # pipeline runtime state
    )
}

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "test_sandbox_open / close"
# ═══════════════════════════════════════════════════════════════════════════════

new_trusted "$T/trusted"
BEFORE_STATUS=$(git -C "$T/trusted" status --porcelain --untracked-files=all)
BEFORE_HEAD=$(git -C "$T/trusted" rev-parse HEAD)
SB=$(test_sandbox_open "$T/trusted")
expect_ok "opens a sandbox" test -d "$SB/.git"
assert_eq "sandbox is at the checkout's HEAD" "$BEFORE_HEAD" "$(git -C "$SB" rev-parse HEAD)"
assert_eq "sandbox has no remote" "" "$(git -C "$SB" remote)"
assert_eq "uncommitted edits are copied" "$(printf 'one\ntwo')" "$(cat "$SB/src/app.txt")"
assert_eq "untracked files are copied (and stay untracked)" "?? src/new.test.txt" \
    "$(git -C "$SB" status --porcelain --untracked-files=all -- src/new.test.txt)"
assert_eq "ignored dependency dirs are copied" "dep" "$(cat "$SB/node_modules/dep/index.js")"
expect_fail "other ignored files (.env) are not copied" test -e "$SB/.env"
expect_fail ".claude runtime state is not copied" test -e "$SB/.claude/state.json"
assert_eq "the checkout's status is unchanged" "$BEFORE_STATUS" "$(git -C "$T/trusted" status --porcelain --untracked-files=all)"
test_sandbox_close "$SB"
expect_fail "close removes the sandbox" test -e "$SB"
assert_eq "nothing is left behind" "0" "$(sandboxes_left)"

mkdir -p "$T/keep/repo/x" "$T/keep/tmp"
test_sandbox_close "$T/keep/repo"
expect_ok "close leaves a directory it did not make alone" test -d "$T/keep/repo/x"

SB=$(SW_TEST_SANDBOX_DEPS="" test_sandbox_open "$T/trusted")
expect_fail "SW_TEST_SANDBOX_DEPS empty copies no dependency dirs" test -e "$SB/node_modules"
test_sandbox_close "$SB"

test_sandbox_hydrate() { printf 'cached\n' > "$2/.hydrated"; }
SB=$(test_sandbox_open "$T/trusted")
assert_eq "a defined test_sandbox_hydrate restores into the sandbox" "cached" "$(cat "$SB/.hydrated")"
test_sandbox_close "$SB"
test_sandbox_hydrate() { return 1; }
SB=$(test_sandbox_open "$T/trusted" 2>/dev/null)
expect_ok "a failed restore does not fail the sandbox" test -d "$SB/.git"
test_sandbox_close "$SB"
unset -f test_sandbox_hydrate

mkdir -p "$T/notgit"
expect_fail "open refuses a directory that is not a checkout" test_sandbox_open "$T/notgit"
assert_eq "a failed open leaves nothing behind" "0" "$(sandboxes_left)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "test_sandbox_run"
# ═══════════════════════════════════════════════════════════════════════════════

out=$(ANTHROPIC_API_KEY=leak test_sandbox_run "$T/trusted" 'pwd -P; echo "key=${ANTHROPIC_API_KEY:-none}"; echo junk > planted.txt; git config core.hooksPath /tmp/evil 2>/dev/null; true')
case "$(printf '%s\n' "$out" | head -1)" in
    "$T/trusted") assert_fail "the command runs in a sandbox, not the checkout" ;;
    */sw-test-sandbox.*/repo) assert_pass "the command runs in a sandbox, not the checkout" ;;
    *) assert_fail "the command runs in a sandbox, not the checkout (got: $out)" ;;
esac
assert_contains "credentials are stripped" "$out" "key=none"
expect_fail "files it writes do not reach the checkout" test -e "$T/trusted/planted.txt"
assert_eq "the checkout's git config is untouched" "" "$(git -C "$T/trusted" config --get core.hooksPath || true)"
assert_eq "the sandbox is removed afterwards" "0" "$(sandboxes_left)"
rc=0; test_sandbox_run "$T/trusted" 'exit 3' || rc=$?
assert_eq "the exit status comes back" "3" "$rc"
rc=0; test_sandbox_run "$T/notgit" 'touch "$PWD/ran"' 2>/dev/null || rc=$?
assert_eq "an unpreparable sandbox fails closed" "1" "$rc"
expect_fail "and the command does not run" test -e "$T/notgit/ran"
out=$(SW_TEST_SANDBOX=off test_sandbox_run "$T/trusted" 'pwd -P')
assert_eq "SW_TEST_SANDBOX=off runs in the checkout" "$T/trusted" "$out"

# sw_test_gate_run passes arguments as data, never as shell text.
out=$(sw_test_gate_run 'printf "%s|" "$1"' 'a b; touch '"$T"'/injected')
assert_eq "sw_test_gate_run passes args as \$1" "a b; touch $T/injected|" "$out"
expect_fail "an argument is never run as a command" test -e "$T/injected"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "the OS write jail"
# ═══════════════════════════════════════════════════════════════════════════════

rc=0; (SW_TEST_JAIL="$T/keep/repo/x" sw_test_gate_env true) 2>/dev/null || rc=$?
assert_eq "a jail that is not a sandbox refuses" "126" "$rc"

KIND=$(_test_sandbox_jail_kind)
SB=$(test_sandbox_open "$T/trusted" 2>/dev/null)
if [[ "$KIND" != "none" ]]; then
    rc=0; (cd "$SB" && SW_TEST_JAIL="$SB" sw_test_gate_run 'echo x > "$1"' "$T/trusted/escaped.txt") 2>/dev/null || rc=$?
    expect_fail "jailed ($KIND): writing into the checkout fails" test -e "$T/trusted/escaped.txt"
    rc=0; (cd "$SB" && SW_TEST_JAIL="$SB" sw_test_gate_run 'echo x > inside.txt && echo y > "$TMPDIR/t.txt"') || rc=$?
    assert_eq "jailed ($KIND): writing in the sandbox and TMPDIR works" "0" "$rc"
    # The executable form used by `shipwright acceptance` is jailed the same way.
    (cd "$SB" && SW_TEST_JAIL="$SB" bash "$SCRIPT_DIR/lib/test-gate-exec.sh" bash -c 'echo x > "$1"' _ "$T/trusted/escaped2.txt") 2>/dev/null || true
    expect_fail "jailed ($KIND): test-gate-exec.sh cannot write into the checkout" test -e "$T/trusted/escaped2.txt"
else
    echo "  (no OS jail on this machine: checking the fallbacks)"
    rc=0; (cd "$SB" && SW_TEST_SANDBOX=jail SW_TEST_JAIL="$SB" sw_test_gate_env true) 2>/dev/null || rc=$?
    assert_eq "SW_TEST_SANDBOX=jail without a jail refuses (126)" "126" "$rc"
    rc=0; (cd "$SB" && SW_TEST_JAIL="$SB" sw_test_gate_env true) || rc=$?
    assert_eq "auto without a jail still runs in the sandbox" "0" "$rc"
fi
test_sandbox_close "$SB"

# Mode clone: the sandbox without the jail (a write outside it goes through).
SB=$(test_sandbox_open "$T/trusted" 2>/dev/null)
rc=0; (cd "$SB" && SW_TEST_SANDBOX=clone SW_TEST_JAIL="$SB" sw_test_gate_run 'echo x > "$1"' "$T/clone-wrote.txt") || rc=$?
expect_ok "SW_TEST_SANDBOX=clone runs without the jail" test -e "$T/clone-wrote.txt"
test_sandbox_close "$SB"

# Forced fallback, whatever this machine has.
rc=0; (cd "$T/trusted" && _TEST_SANDBOX_KIND=none SW_TEST_SANDBOX=jail test_sandbox_run "$T/trusted" 'true') 2>/dev/null || rc=$?
assert_eq "mode jail fails closed when no jail can start" "126" "$rc"

print_test_results
