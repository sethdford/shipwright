#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/bot-comments.sh test — SHIPWRIGHT-* markers from the bot only ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: gh is a mock that prints two pages of REST comments.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "CI: bot-comments Tests"

setup_test_env "ci-bot-comments"
trap cleanup_test_env EXIT

export GITHUB_REPOSITORY="o/r"
export GH_ARGS="$TEST_TEMP_DIR/gh.args"
cat > "$TEST_TEMP_DIR/page1.json" <<'JSON'
[{"user":{"login":"github-actions[bot]","type":"Bot"},"created_at":"2026-10-14T01:00:00Z","body":"<!-- SHIPWRIGHT-RETRY: 1 -->"},
 {"user":{"login":"mallory","type":"User"},"created_at":"2026-10-14T02:00:00Z","body":"<!-- SHIPWRIGHT-RETRY: 0 -->"},
 {"user":null,"created_at":"2026-10-14T02:30:00Z","body":"<!-- SHIPWRIGHT-RETRY: 0 -->"}]
JSON
cat > "$TEST_TEMP_DIR/page2.json" <<'JSON'
[{"user":{"login":"github-actions[bot]","type":"Bot"},"created_at":"2026-10-14T03:00:00Z","body":"<!-- SHIPWRIGHT-STAGE: plan:complete -->"},
 {"user":{"login":"github-actions[bot]","type":"User"},"created_at":"2026-10-14T04:00:00Z","body":"<!-- SHIPWRIGHT-STAGE: build:complete -->"}]
JSON
export PAGE1="$TEST_TEMP_DIR/page1.json" PAGE2="$TEST_TEMP_DIR/page2.json"
mock_binary "gh" 'printf "%s\n" "$@" > "$GH_ARGS"; cat "$PAGE1" "$PAGE2"'

BOT_COMMENTS="$SCRIPT_DIR/ci/bot-comments.sh"

print_test_section "filtering"
out=$("$BOT_COMMENTS" 42)
assert_eq "keeps only Bot-type comments by the bot login" "2" "$(jq 'length' <<<"$out")"
assert_eq "keeps order and timestamps" "2026-10-14T01:00:00Z,2026-10-14T03:00:00Z" \
    "$(jq -r '[.[].createdAt] | join(",")' <<<"$out")"
assert_eq "drops the spoofed marker" "0" "$(grep -c 'RETRY: 0' <<<"$out" || true)"
assert_contains "reads every page of the REST endpoint" "$(cat "$GH_ARGS")" "--paginate"
assert_contains "asks for the issue's comments" "$(cat "$GH_ARGS")" "repos/o/r/issues/42/comments?per_page=100"

out=$(SHIPWRIGHT_BOT_LOGIN="mallory" "$BOT_COMMENTS" 42)
assert_eq "a User account is never the bot, even when named" "0" "$(jq 'length' <<<"$out")"

print_test_section "input validation"
if "$BOT_COMMENTS" "42; echo pwned" >/dev/null 2>&1; then
    assert_fail "rejects a non-numeric issue"
else
    assert_pass "rejects a non-numeric issue"
fi

print_test_section "fails closed"
mock_binary "gh" 'echo "HTTP 502" >&2; exit 1'
if "$BOT_COMMENTS" 42 >/dev/null 2>&1; then
    assert_fail "a gh failure fails the script (callers fail closed)"
else
    assert_pass "a gh failure fails the script (callers fail closed)"
fi

# Pagination that dies after the first page must not yield a short (truncated) list.
mock_binary "gh" 'cat "$PAGE1"; echo "HTTP 502" >&2; exit 1'
if out=$("$BOT_COMMENTS" 42 2>/dev/null); then
    assert_fail "a failure after page 1 fails the script, not a truncated list"
else
    assert_pass "a failure after page 1 fails the script, not a truncated list"
fi
assert_eq "prints nothing when pagination is truncated" "" "$out"

mock_binary "gh" 'echo "{\"message\":\"Not Found\"}"'
if "$BOT_COMMENTS" 42 >/dev/null 2>&1; then
    assert_fail "a non-array response fails the script"
else
    assert_pass "a non-array response fails the script"
fi

mock_binary "gh" 'printf "[{\"user\":{\"login\":\"github-actions[bot]\",\"type\":\"Bot\"},\"created_at\":\"x\",\"body\":\"a\"}]\n[{\"user\":"'
if "$BOT_COMMENTS" 42 >/dev/null 2>&1; then
    assert_fail "malformed JSON on a later page fails the script"
else
    assert_pass "malformed JSON on a later page fails the script"
fi

print_test_results
