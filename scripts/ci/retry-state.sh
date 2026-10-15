#!/usr/bin/env bash
# retry-state.sh <issue-number> <run-id> — what auto-retry may trust about an issue, as JSON
# {"retry": N, "abandoned": true|false} (ADR-0007).
#
#   retry      the HIGHEST `SHIPWRIGHT-RETRY: N` marker in a bot-authored comment (never the
#              last one), 0 when there is none.
#   abandoned  a bot-authored comment carries `SHIPWRIGHT-WATCHDOG-ABANDON: <run-id>`.
#
# A marker counts only as a whole line `<!-- MARKER: value -->` (a trailing CR is ignored), so
# text quoted mid-line, such as a logged error, never forms one.
#
# Refuses (exit 1) when comments by any author carry retry markers but bot-authored ones carry
# none: the bot's count would read 0 and restart the retry loop. Markers by other authors only
# ever trigger that refusal; they never feed the number.
#
# Fails closed, printing nothing on stdout: exit 2 on bad arguments, otherwise 1 whenever either
# comment read fails (gh error, truncated pagination, malformed page, NO_GITHUB=true).
set -euo pipefail

usage() { echo "retry-state.sh: $1" >&2; exit 2; }
fail() { echo "retry-state.sh: $1" >&2; exit 1; }

issue="${1:-}"
run_id="${2:-}"
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage "usage: retry-state.sh <issue-number> <run-id>"
[[ "$run_id" =~ ^[1-9][0-9]*$ ]] || usage "usage: retry-state.sh <issue-number> <run-id>"
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be owner/repo"

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! bot_json=$("$CI_DIR/bot-comments.sh" "$issue"); then
    fail "cannot read bot comments for #${issue}"
fi

# Any author, only to detect the mismatch. Buffered and validated like bot-comments.sh.
if [[ "${NO_GITHUB:-}" == "true" ]]; then
    fail "NO_GITHUB set; no marker source"
fi
if ! pages=$(gh api --paginate "repos/${repo}/issues/${issue}/comments?per_page=100"); then
    fail "cannot read comments for #${issue}"
fi
[[ -n "$pages" ]] || fail "gh returned no output for #${issue}"
if ! all_json=$(jq -s '
    if length == 0 then error("no comment pages")
    elif all(.[]; type == "array" and all(.[]; type == "object")) then [.[][] | {body}]
    else error("comments page is not an array of objects") end' <<<"$pages"); then
    fail "malformed comments for #${issue}"
fi

# Whole marker lines of every string body.
MARKER_LINES='[.[] | .body | strings | split("\n")[] | rtrimstr("\r")]'
RETRY_MAX="${MARKER_LINES}"' | map(capture("^<!-- SHIPWRIGHT-RETRY: (?<n>[0-9]{1,9}) -->$") | .n | tonumber) | max // 0'

bot_retry=$(jq "$RETRY_MAX" <<<"$bot_json")
any_retry=$(jq "$RETRY_MAX" <<<"$all_json")
if [[ "$any_retry" -gt 0 && "$bot_retry" -eq 0 ]]; then
    fail "issue #${issue} has retry markers not written by the bot (any author: ${any_retry}, bot: 0); refusing to retry"
fi

jq -c --arg abandon "<!-- SHIPWRIGHT-WATCHDOG-ABANDON: ${run_id} -->" --argjson retry "$bot_retry" \
    "{retry: \$retry, abandoned: (${MARKER_LINES} | any(.[]; . == \$abandon))}" <<<"$bot_json"
