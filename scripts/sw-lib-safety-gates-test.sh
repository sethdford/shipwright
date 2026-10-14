#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/safety-gates test — bash callers of the TS safety gates  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun and gh are mocks; no tmux, no network, temp HOME.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: safety-gates Tests"

setup_test_env "lib-safety-gates"
trap cleanup_test_env EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log"
export GH_LOG="$TEST_TEMP_DIR/gh.log"
export BUN_EXIT=0
# Each argument on its own line, so tests can check argv boundaries exactly.
mock_binary "bun" 'printf "%s\n" "$@" >> "$BUN_LOG"; printf -- "--\n" >> "$BUN_LOG"; exit "$BUN_EXIT"'
mock_binary "gh" 'printf "%s\n" "$@" >> "$GH_LOG"'

source "$SCRIPT_DIR/lib/safety-gates.sh"

# bun_call — the arguments after the CLI path, space-joined (one call logged).
bun_call() {
    sed -n '2,$p' "$BUN_LOG" | sed '/^--$/,$d' | tr '\n' ' ' | sed 's/ $//'
}

# ─── safety_gates_ok ──────────────────────────────────────────────────────
print_test_section "safety_gates_ok"

assert_file_exists "CLI path resolves to src/cli.ts" "$SW_TS_CLI"
assert_eq "CLI path is the first bun argument" "$SW_TS_CLI" "$(cd / && : > "$BUN_LOG" && safety_gates_ok 0 2>/dev/null; head -1 "$BUN_LOG")"

: > "$BUN_LOG"
if safety_gates_ok 0 2>/dev/null; then
    assert_pass "open gates allow a first dispatch"
else
    assert_fail "open gates allow a first dispatch"
fi
assert_eq "first dispatch passes --retry 0 and --no-github (NO_GITHUB=true)" \
    "gates check --retry 0 --no-github" "$(bun_call)"

: > "$BUN_LOG"
NO_GITHUB=false safety_gates_ok 2 2>/dev/null || true
assert_eq "a retry passes its number; GitHub mode omits --no-github" \
    "gates check --retry 2" "$(bun_call)"

: > "$BUN_LOG"
if safety_gates_ok "2;echo pwned" 2>/dev/null; then
    assert_fail "a non-numeric retry blocks"
else
    assert_pass "a non-numeric retry blocks"
fi
assert_eq "a non-numeric retry never reaches the CLI" "" "$(cat "$BUN_LOG")"

: > "$BUN_LOG"
if safety_gates_ok 2>/dev/null; then
    assert_fail "a missing retry blocks (unknown is not 'first')"
else
    assert_pass "a missing retry blocks (unknown is not 'first')"
fi
assert_eq "a missing retry never reaches the CLI" "" "$(cat "$BUN_LOG")"

for code in 1 2 3 137; do
    if BUN_EXIT="$code" safety_gates_ok 0 2>/dev/null; then
        assert_fail "gates exit ${code} blocks dispatch"
    else
        assert_pass "gates exit ${code} blocks dispatch"
    fi
done

if SW_BUN="no-such-bun-binary" safety_gates_ok 0 2>/dev/null; then
    assert_fail "missing bun fails closed"
else
    assert_pass "missing bun fails closed"
fi

# ─── patrol_issue_create ──────────────────────────────────────────────────
print_test_section "patrol_issue_create"

: > "$BUN_LOG"
: > "$GH_LOG"
title='Security: x $(touch pwned) in y'
(cd "$TEST_TEMP_DIR" && patrol_issue_create --title "$title" --body "b" --label "auto-patrol" 2>/dev/null)
assert_eq "asks the intake gate with the title and patrol label as argv" \
    "intake check --title ${title} --label auto-patrol" "$(bun_call)"
assert_eq "files the issue with the original arguments" \
    "issue create --title ${title} --body b --label auto-patrol" "$(tr '\n' ' ' < "$GH_LOG" | sed 's/ $//')"
assert_file_not_exists "title text is never executed" "$TEST_TEMP_DIR/pwned"

: > "$BUN_LOG"
PATROL_LABEL="patrol" patrol_issue_create --title "t" --body "b" 2>/dev/null
assert_eq "passes a configured PATROL_LABEL" "intake check --title t --label patrol" "$(bun_call)"

for code in 1 2 127; do
    : > "$GH_LOG"
    if BUN_EXIT="$code" patrol_issue_create --title "dup" --body "b" 2>/dev/null; then
        assert_fail "intake exit ${code} refuses"
    else
        assert_pass "intake exit ${code} refuses"
    fi
    assert_eq "nothing filed when intake exits ${code}" "" "$(cat "$GH_LOG")"
done

: > "$GH_LOG"
if SW_BUN="no-such-bun-binary" patrol_issue_create --title "t" --body "b" 2>/dev/null; then
    assert_fail "missing bun files nothing"
else
    assert_pass "missing bun files nothing"
fi
assert_eq "nothing filed without bun" "" "$(cat "$GH_LOG")"

# ─── dispatch eligibility ─────────────────────────────────────────────────
print_test_section "dispatch eligibility (auto-filed and stuck issues are skipped)"

if dispatch_eligible "shipwright,bug"; then
    assert_pass "a human-filed issue is eligible"
else
    assert_fail "a human-filed issue is eligible"
fi
if dispatch_eligible "shipwright,auto-patrol,security"; then
    assert_fail "an auto-patrol issue is skipped"
else
    assert_pass "an auto-patrol issue is skipped"
fi
if dispatch_eligible "shipwright-stuck,shipwright"; then
    assert_fail "a shipwright-stuck issue is skipped"
else
    assert_pass "a shipwright-stuck issue is skipped"
fi
if dispatch_eligible "shipwright,auto-patrol-meta"; then
    assert_pass "only the exact label matches"
else
    assert_fail "only the exact label matches"
fi
if dispatch_eligible ""; then
    assert_pass "an issue without labels is eligible"
else
    assert_fail "an issue without labels is eligible"
fi
if PATROL_LABEL="patrol" dispatch_eligible "shipwright,patrol"; then
    assert_fail "honors a configured PATROL_LABEL"
else
    assert_pass "honors a configured PATROL_LABEL"
fi
issues='[{"number":1,"labels":[{"name":"shipwright"}]},
 {"number":2,"labels":[{"name":"auto-patrol"},{"name":"shipwright"}]},
 {"number":3,"labels":[]},
 {"number":4,"labels":[{"name":"shipwright-stuck"}]}]'
assert_eq "filters gh issue list JSON" "1 3" \
    "$(dispatchable_issue_numbers <<<"$issues" | tr '\n' ' ' | sed 's/ $//')"
if dispatchable_issue_numbers <<<"not json" >/dev/null 2>&1; then
    assert_fail "malformed issue JSON fails"
else
    assert_pass "malformed issue JSON fails"
fi

print_test_results
