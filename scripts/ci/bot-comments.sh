#!/usr/bin/env bash
# bot-comments.sh <issue-number> — comments written by the Shipwright bot on an issue, as a JSON
# array of {createdAt, body}. Workflows read SHIPWRIGHT-* markers only from this output, so a
# marker typed by anyone else is ignored (ADR-0007).
#
# The bot is the GitHub App user of the workflow token: login $SHIPWRIGHT_BOT_LOGIN (default
# "github-actions[bot]"; set but empty is an error) AND account type "Bot" — a user cannot
# register a "[bot]" login. Needs GITHUB_REPOSITORY and a gh token.
#
# Fails closed, printing nothing on stdout: exit 2 on bad input or configuration, exit 3 when
# NO_GITHUB is set, otherwise non-zero when gh fails, prints nothing, pagination stops early or
# a page is not a JSON array of objects. Zero bot comments is "[]" with exit 0.
set -euo pipefail

usage() { echo "bot-comments.sh: $1" >&2; exit 2; }

issue="${1:-}"
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage "usage: bot-comments.sh <issue-number>"
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be owner/repo"
bot="${SHIPWRIGHT_BOT_LOGIN-github-actions[bot]}"
[[ "$bot" =~ ^[A-Za-z0-9][A-Za-z0-9-]*\[bot\]$ ]] || usage "SHIPWRIGHT_BOT_LOGIN must be <name>[bot]"

if [[ "${NO_GITHUB:-}" == "true" ]]; then
    echo "bot-comments.sh: NO_GITHUB set; no marker source" >&2
    exit 3
fi

# Buffer every page first: a gh failure part-way must not emit a truncated list.
pages=$(gh api --paginate "repos/${repo}/issues/${issue}/comments?per_page=100")
if [[ -z "$pages" ]]; then
    echo "bot-comments.sh: gh returned no output for #${issue}" >&2
    exit 1
fi

jq -s --arg bot "$bot" '
    if length == 0 then error("no comment pages")
    elif all(.[]; type == "array" and all(.[]; type == "object")) then .
    else error("comments page is not an array of objects") end
    | [.[][] | select(.user.login? == $bot and .user.type? == "Bot" and (.body | type) == "string")
       | {createdAt: .created_at, body: .body}]' <<<"$pages"
