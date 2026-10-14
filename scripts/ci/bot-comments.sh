#!/usr/bin/env bash
# bot-comments.sh <issue-number> — comments written by the Shipwright bot on an issue, as a JSON
# array of {createdAt, body}. Workflows read SHIPWRIGHT-* markers only from this output, so a
# marker typed by anyone else is ignored (ADR-0007).
#
# The bot is the GitHub App user of the workflow token: login $SHIPWRIGHT_BOT_LOGIN (default
# "github-actions[bot]") AND account type "Bot" — a user cannot register a "[bot]" login.
# Needs GITHUB_REPOSITORY and a gh token. Exits non-zero, printing nothing on stdout, when gh
# fails, pagination stops early or a page is not a JSON array; callers fail closed.
set -euo pipefail

issue="${1:-}"
if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: bot-comments.sh <issue-number>" >&2
    exit 2
fi
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
bot="${SHIPWRIGHT_BOT_LOGIN:-github-actions[bot]}"

# Buffer every page first: a gh failure part-way must not emit a truncated list.
pages=$(gh api --paginate "repos/${repo}/issues/${issue}/comments?per_page=100")

jq -s --arg bot "$bot" '
    if all(.[]; type == "array") then . else error("comments page is not an array") end
    | [.[][] | select(.user.login? == $bot and .user.type? == "Bot")
       | {createdAt: .created_at, body: .body}]' <<<"$pages"
