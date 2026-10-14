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
assert_eq "library is executable like its siblings" "755" "$(stat -f %Lp "$SCRIPT_DIR/lib/safety-gates.sh" 2>/dev/null || stat -c %a "$SCRIPT_DIR/lib/safety-gates.sh")"
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

rc=0; BUN_EXIT=3 safety_gates_ok 0 2>/dev/null || rc=$?
assert_eq "returns the CLI's exit code" "3" "$rc"
rc=0; SW_BUN="no-such-bun-binary" safety_gates_ok 0 2>/dev/null || rc=$?
assert_eq "missing bun returns 127" "127" "$rc"
rc=0; safety_gates_ok "x" 2>/dev/null || rc=$?
assert_eq "a bad retry count returns 2" "2" "$rc"

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

: > "$BUN_LOG"
: > "$GH_LOG"
patrol_issue_create --intake-label "shipwright:auto" --title "t" --body "b" --label "x,y" 2>/dev/null
assert_eq "--intake-label sets the intake label" "intake check --title t --label shipwright:auto" "$(bun_call)"
assert_eq "--intake-label is not passed to gh" "issue create --title t --body b --label x,y" \
    "$(tr '\n' ' ' < "$GH_LOG" | sed 's/ $//')"

: > "$BUN_LOG"
: > "$GH_LOG"
patrol_issue_create --title "$(printf 'line one\nline two\r')" --body "$(printf 'b1\nb2')" 2>/dev/null
assert_eq "newlines in the title are replaced for the intake gate" \
    "intake check --title line one line two --label auto-patrol" "$(bun_call)"
assert_eq "newlines in the title are replaced for gh; the body keeps them" \
    "issue create --title line one line two --body b1 b2" "$(tr '\n' ' ' < "$GH_LOG" | sed 's/ $//')"

(
    DLOG="$TEST_TEMP_DIR/dlog"
    : > "$DLOG"
    daemon_log() { echo "$*" >> "$DLOG"; }
    BUN_EXIT=1 patrol_issue_create --title "t" --body "b" 2>/dev/null || true
)
assert_contains "a refusal is written to the daemon log with its exit code" \
    "$(cat "$TEST_TEMP_DIR/dlog")" "intake gate refused (rc=1)"

: > "$BUN_LOG"
: > "$GH_LOG"
for form in "--title=t" "-t" "-tFoo"; do
    rc=0
    if [[ "$form" == "-t" ]]; then
        patrol_issue_create "$form" "t" --body "b" 2>/dev/null || rc=$?
    else
        patrol_issue_create "$form" --body "b" 2>/dev/null || rc=$?
    fi
    assert_eq "unparsed title form '${form}' is rejected with 2" "2" "$rc"
done
assert_eq "rejected forms never reach the gate or gh" "" "$(cat "$BUN_LOG" "$GH_LOG")"
rc=0
patrol_issue_create --title "t" --body "-t" 2>/dev/null || rc=$?
assert_eq "'-t' as an option value is not a title flag" "0" "$rc"

: > "$BUN_LOG"
mock_binary "bun" 'printf "%s\n" "$@" >> "$BUN_LOG"; printf "GH_REPO=%s\n" "${GH_REPO:-unset}" >> "$BUN_LOG"; printf -- "--\n" >> "$BUN_LOG"; exit "$BUN_EXIT"'
patrol_issue_create --repo "o/r" --title "t" --body "b" 2>/dev/null
assert_contains "--repo scopes the intake gate to that repo" "$(cat "$BUN_LOG")" "GH_REPO=o/r"
: > "$BUN_LOG"
patrol_issue_create --title "t" --body "b" 2>/dev/null
assert_contains "without --repo the gate uses the current repo" "$(cat "$BUN_LOG")" "GH_REPO=unset"
mock_binary "bun" 'printf "%s\n" "$@" >> "$BUN_LOG"; printf -- "--\n" >> "$BUN_LOG"; exit "$BUN_EXIT"'

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
if dispatch_eligible "shipwright,Auto-Patrol"; then
    assert_fail "label match ignores case"
else
    assert_pass "label match ignores case"
fi
if dispatch_eligible "SHIPWRIGHT-STUCK"; then
    assert_fail "stuck label match ignores case"
else
    assert_pass "stuck label match ignores case"
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
 {"number":4,"labels":[{"name":"shipwright-stuck"}]},
 {"number":5,"labels":[{"name":"Auto-Patrol"}]},
 {"number":6,"labels":[{"name":"shipwright-failed"}]},
 {"number":7,"labels":[{"name":"Shipwright-Infra-Issue"},{"name":"shipwright"}]},
 {"number":8,"labels":[{"name":"shipwright-failed-meta"}]},
 {"number":9,"labels":[{"name":"claimed:host-a"},{"name":"shipwright"}]},
 {"number":10,"labels":[{"name":"Claimed:Host-B"}]},
 {"number":11,"labels":[{"name":"unclaimed:x"}]}]'
assert_eq "filters gh issue list JSON (auto-patrol, stuck, failed, infra-issue, claimed:*)" "1 3 8 11" \
    "$(dispatchable_issue_numbers <<<"$issues" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "honors a configured PATROL_LABEL in the issue list" "1 2 3 5 8 11" \
    "$(PATROL_LABEL="patrol" dispatchable_issue_numbers <<<"$issues" | tr '\n' ' ' | sed 's/ $//')"
if dispatchable_issue_numbers <<<'{"number":1}' >/dev/null 2>&1; then
    assert_fail "a non-array issue list fails"
else
    assert_pass "a non-array issue list fails"
fi
if dispatchable_issue_numbers <<<"not json" >/dev/null 2>&1; then
    assert_fail "malformed issue JSON fails"
else
    assert_pass "malformed issue JSON fails"
fi

# ─── fleet_curl ───────────────────────────────────────────────────────────
print_test_section "fleet_curl"

# Recording curl: one argv element per line in $CURL_ARGS; stdin in $CURL_STDIN only when curl is
# told to read a file from stdin (@-), so a call that must not use stdin never blocks on it.
export CURL_ARGS="$TEST_TEMP_DIR/curl.args" CURL_STDIN="$TEST_TEMP_DIR/curl.stdin" CURL_EXIT=0
mock_binary "curl" 'printf "%s\n" "$@" > "$CURL_ARGS"
for a in "$@"; do [[ "$a" == "@-" ]] && cat > "$CURL_STDIN"; done
printf "ok"; exit "$CURL_EXIT"'
reset_curl() { rm -f "$CURL_ARGS" "$CURL_STDIN"; }
curl_stdin() { cat "$CURL_STDIN" 2>/dev/null || true; }
curl_args() { cat "$CURL_ARGS" 2>/dev/null || true; }
unset SHIPWRIGHT_FLEET_TOKEN SHIPWRIGHT_FLEET_TOKEN_FILE

reset_curl
out="$(SHIPWRIGHT_FLEET_TOKEN="s3cret-token" fleet_curl -s -X POST -d '{"a": 1}' "http://127.0.0.1:8767/api/claim" 2>"$TEST_TEMP_DIR/err")"
assert_eq "token sent as a header line on stdin" "X-Shipwright-Token: s3cret-token" "$(curl_stdin)"
assert_eq "curl reads that header from stdin (-H @-), caller args intact" \
    "-H @- -s -X POST -d {\"a\": 1} http://127.0.0.1:8767/api/claim" "$(curl_args | tr '\n' ' ' | sed 's/ $//')"
assert_eq "token never in argv" "0" "$(grep -c 's3cret-token' "$CURL_ARGS" || true)"
assert_eq "curl stdout passes through" "ok" "$out"
assert_eq "nothing on stderr" "" "$(cat "$TEST_TEMP_DIR/err")"

reset_curl
fleet_curl -s "http://127.0.0.1:8767/api/claim" >/dev/null
assert_eq "no token: no stdin header" "" "$(curl_stdin)"
assert_eq "no token: argv is exactly the caller's" "-s http://127.0.0.1:8767/api/claim" \
    "$(curl_args | tr '\n' ' ' | sed 's/ $//')"

tokfile="$TEST_TEMP_DIR/fleet.token"
printf '  file-token\n\n' > "$tokfile"
chmod 600 "$tokfile"
reset_curl
SHIPWRIGHT_FLEET_TOKEN_FILE="$tokfile" fleet_curl -s "http://x/api/claim" >/dev/null 2>"$TEST_TEMP_DIR/err"
assert_eq "token file is read and trimmed" "X-Shipwright-Token: file-token" "$(curl_stdin)"
assert_eq "mode-600 token file: no warning" "" "$(cat "$TEST_TEMP_DIR/err")"
assert_eq "file token never in argv" "0" "$(grep -c 'file-token' "$CURL_ARGS" || true)"

reset_curl
SHIPWRIGHT_FLEET_TOKEN="env-token" SHIPWRIGHT_FLEET_TOKEN_FILE="$tokfile" fleet_curl -s "http://x/" >/dev/null
assert_eq "SHIPWRIGHT_FLEET_TOKEN wins over the file" "X-Shipwright-Token: env-token" "$(curl_stdin)"

chmod 644 "$tokfile"
reset_curl
SHIPWRIGHT_FLEET_TOKEN_FILE="$tokfile" fleet_curl -s "http://x/" >/dev/null 2>"$TEST_TEMP_DIR/err"
assert_eq "group/world-readable token file is still used" "X-Shipwright-Token: file-token" "$(curl_stdin)"
assert_contains "group/world-readable token file warns (mode 600)" "$(cat "$TEST_TEMP_DIR/err")" "600"
assert_eq "the warning never prints the token" "0" "$(grep -c 'file-token' "$TEST_TEMP_DIR/err" || true)"

reset_curl
rc=0
SHIPWRIGHT_FLEET_TOKEN_FILE="$TEST_TEMP_DIR/no-such-token" fleet_curl -s "http://x/" >/dev/null 2>"$TEST_TEMP_DIR/err" || rc=$?
assert_eq "unreadable token file fails closed (125)" "125" "$rc"
assert_file_not_exists "unreadable token file: curl never runs" "$CURL_ARGS"
assert_contains "unreadable token file is named" "$(cat "$TEST_TEMP_DIR/err")" "SHIPWRIGHT_FLEET_TOKEN_FILE"

printf ' \n' > "$TEST_TEMP_DIR/empty.token"
chmod 600 "$TEST_TEMP_DIR/empty.token"
reset_curl
rc=0
SHIPWRIGHT_FLEET_TOKEN_FILE="$TEST_TEMP_DIR/empty.token" fleet_curl -s "http://x/" >/dev/null 2>&1 || rc=$?
assert_eq "empty token file fails closed (125)" "125" "$rc"
assert_file_not_exists "empty token file: curl never runs" "$CURL_ARGS"

reset_curl
rc=0
SHIPWRIGHT_FLEET_TOKEN=$'tok\nX-Injected: 1' fleet_curl -s "http://x/" >/dev/null 2>"$TEST_TEMP_DIR/err" || rc=$?
assert_eq "a token with a line break fails closed (125)" "125" "$rc"
assert_file_not_exists "a token with a line break never reaches curl" "$CURL_ARGS"
assert_eq "the rejection never prints the token" "0" "$(grep -c 'Injected' "$TEST_TEMP_DIR/err" || true)"

reset_curl
rc=0
CURL_EXIT=22 SHIPWRIGHT_FLEET_TOKEN="t" fleet_curl -s "http://x/" >/dev/null || rc=$?
assert_eq "curl's exit status is returned (with a token)" "22" "$rc"
rc=0
CURL_EXIT=7 fleet_curl -s "http://x/" >/dev/null || rc=$?
assert_eq "curl's exit status is returned (no token)" "7" "$rc"

print_test_results
