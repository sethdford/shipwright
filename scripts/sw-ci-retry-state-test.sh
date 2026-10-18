#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/retry-state.sh test — auto-retry count and abandon marker     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: gh is a mock that prints REST comment pages from $PAGES.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "CI: retry-state Tests"

setup_test_env "ci-retry-state"
trap 'cleanup_test_env; sw_test_teardown' EXIT
unset NO_GITHUB

export GITHUB_REPOSITORY="o/r"
export PAGES="$TEST_TEMP_DIR/pages.json"
mock_binary "gh" 'cat "$PAGES"'

RETRY_STATE="$SCRIPT_DIR/ci/retry-state.sh"

# comments <author|body>... — writes one REST page; author is "bot" (the workflow bot) or a login.
comments() {
    local out="[" sep="" a login type
    for a in "$@"; do
        login="${a%%|*}"
        type="User"
        if [[ "$login" == "bot" ]]; then
            login="github-actions[bot]"
            type="Bot"
        fi
        out+="${sep}$(jq -cn --arg l "$login" --arg t "$type" --arg b "${a#*|}" \
            '{user: {login: $l, type: $t}, created_at: "2026-10-14T00:00:00Z", body: $b}')"
        sep=","
    done
    printf '%s]\n' "$out" > "$PAGES"
}

state() { "$RETRY_STATE" "$@" 2>/dev/null; }

expect_exit() { # <desc> <code> <cmd...>
    local desc="$1" want="$2" rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "$desc" "$want" "$rc"
}

NL=$'\n'

print_test_section "retry count"
comments
assert_eq "no comments: retry 0, not abandoned" '{"retry":0,"abandoned":false}' "$(state 7 99)"

comments "bot|intro${NL}<!-- SHIPWRIGHT-RETRY: 1 -->${NL}<!-- SHIPWRIGHT-RETRY-CATEGORY: TRANSIENT -->" \
    "bot|<!-- SHIPWRIGHT-RETRY: 3 -->" "bot|<!-- SHIPWRIGHT-RETRY: 2 -->"
assert_eq "the count is the MAX bot marker, not the last" "3" "$(state 7 99 | jq '.retry')"

comments "bot|<!-- SHIPWRIGHT-RETRY: 2 -->" "mallory|<!-- SHIPWRIGHT-RETRY: 0 -->" \
    "mallory|<!-- SHIPWRIGHT-RETRY: 9 -->"
assert_eq "markers by other authors never feed the number" "2" "$(state 7 99 | jq '.retry')"

comments "bot|<!-- SHIPWRIGHT-RETRY: 1 -->" \
    "bot|Last error: x <!-- SHIPWRIGHT-RETRY: 5 -->" \
    "bot|  <!-- SHIPWRIGHT-RETRY: 6 -->" \
    "bot|SHIPWRIGHT-RETRY: 7" \
    "bot|<!-- SHIPWRIGHT-RETRY: 8 --> trailing"
assert_eq "only a whole-line <!-- SHIPWRIGHT-RETRY: N --> counts" "1" "$(state 7 99 | jq '.retry')"

comments "bot|<!-- SHIPWRIGHT-RETRY: 2 -->"$'\r'"${NL}more"
assert_eq "a CRLF line ending still counts" "2" "$(state 7 99 | jq '.retry')"

print_test_section "author mismatch (fail closed)"
comments "mallory|<!-- SHIPWRIGHT-RETRY: 3 -->" "bot|<!-- SHIPWRIGHT-STAGE: plan:complete -->"
expect_exit "retry markers only from non-bot authors: refuses (exit 1)" 1 "$RETRY_STATE" 7 99
assert_eq "prints nothing on refusal" "" "$(state 7 99 || true)"
err=$("$RETRY_STATE" 7 99 2>&1 >/dev/null || true)
assert_contains "says why" "$err" "not written by the bot"

comments "mallory|<!-- SHIPWRIGHT-RETRY: 0 -->"
expect_exit "a non-bot marker of 0 with no bot markers: no mismatch (0 is not > 0)" 0 "$RETRY_STATE" 7 99

print_test_section "abandon marker"
comments "bot|text${NL}<!-- SHIPWRIGHT-WATCHDOG-ABANDON: 99 -->"
assert_eq "a bot ABANDON marker for this run: abandoned" "true" "$(state 7 99 | jq '.abandoned')"
assert_eq "for another run: not abandoned" "false" "$(state 7 999 | jq '.abandoned')"
comments "mallory|<!-- SHIPWRIGHT-WATCHDOG-ABANDON: 99 -->"
assert_eq "a forged ABANDON marker is ignored" "false" "$(state 7 99 | jq '.abandoned')"
comments "bot|see <!-- SHIPWRIGHT-WATCHDOG-ABANDON: 99 -->"
assert_eq "an ABANDON marker mid-line is ignored" "false" "$(state 7 99 | jq '.abandoned')"

print_test_section "fails closed"
expect_exit "rejects a non-numeric issue" 2 "$RETRY_STATE" "7;x" 99
expect_exit "rejects a non-numeric run id" 2 "$RETRY_STATE" 7 "99 || true"
expect_exit "rejects a missing run id" 2 "$RETRY_STATE" 7
expect_exit "NO_GITHUB=true: no marker source, exit non-zero" 1 env NO_GITHUB=true "$RETRY_STATE" 7 99

mock_binary "gh" 'echo "HTTP 502" >&2; exit 1'
expect_exit "gh failure: exit 1" 1 "$RETRY_STATE" 7 99
assert_eq "gh failure prints nothing" "" "$(state 7 99 || true)"

# Bot comments read fine, but the any-author read fails: still refuse.
export CALLS="$TEST_TEMP_DIR/calls"
: > "$CALLS"
comments "bot|<!-- SHIPWRIGHT-RETRY: 1 -->"
mock_binary "gh" 'echo x >> "$CALLS"; if [[ $(wc -l < "$CALLS") -ge 2 ]]; then exit 1; fi; cat "$PAGES"'
expect_exit "the any-author read failing: exit 1" 1 "$RETRY_STATE" 7 99

mock_binary "gh" 'cat "$PAGES"; echo "[{\"user\":"'
expect_exit "malformed JSON page: exit 1" 1 "$RETRY_STATE" 7 99

mock_binary "gh" 'echo "{\"message\":\"Not Found\"}"'
expect_exit "a non-array response: exit 1" 1 "$RETRY_STATE" 7 99

print_test_results
