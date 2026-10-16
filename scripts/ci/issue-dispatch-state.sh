#!/usr/bin/env bash
# issue-dispatch-state.sh <issue-number> — what a dispatch may do with one issue, as one word:
#   ready    no pipeline run is queued or running for it, and no bot comment says it was already
#            dispatched, retried or run: the first dispatch may proceed
#   active   a shipwright-pipeline.yml run is queued or running for it
#   handled  a bot comment carries SHIPWRIGHT-DISPATCHED, SHIPWRIGHT-RETRY, "Shipwright Pipeline" or
#            "Pipeline Auth Failure": auto-retry owns any retry (ADR-0007)
# Shared by shipwright-dispatch.yml (scheduled scan) and shipwright-label-dispatch.yml (labeled
# entry point), so both apply the same first-dispatch rule. Read-only.
#
# Fails closed, printing nothing else on stdout: exit 2 on bad input, 1 when a read fails or the
# answer cannot be judged.
set -euo pipefail

usage() { echo "issue-dispatch-state.sh: $1" >&2; exit 2; }
fail() { echo "issue-dispatch-state.sh: $1" >&2; exit 1; }

issue="${1:-}"
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage "usage: issue-dispatch-state.sh <issue-number>"
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check 1: a pipeline already running or queued for this issue.
if ! ACTIVE=$("$CI_DIR/pipeline-active.sh" "$issue"); then
    fail "cannot list pipeline runs for #${issue}"
fi
case "$ACTIVE" in
    true) echo active; exit 0 ;;
    false) ;;
    *) fail "unreadable pipeline activity for #${issue}" ;;
esac

# Check 2: first dispatch only. Bot-authored comments only (bot-comments.sh).
if ! COMMENTS_JSON=$("$CI_DIR/bot-comments.sh" "$issue"); then
    fail "cannot read bot comments for #${issue}"
fi
# jq -e: 0 = a marker exists, 1 = none, anything else = unreadable (fail closed).
HANDLED_RC=0
jq -e 'any(.[]; .body | test("SHIPWRIGHT-DISPATCHED|SHIPWRIGHT-RETRY|Shipwright Pipeline|Pipeline Auth Failure"))' \
    <<<"$COMMENTS_JSON" >/dev/null || HANDLED_RC=$?
case "$HANDLED_RC" in
    0) echo handled ;;
    1) echo ready ;;
    *) fail "cannot read the bot comments of #${issue} (jq exit ${HANDLED_RC})" ;;
esac
