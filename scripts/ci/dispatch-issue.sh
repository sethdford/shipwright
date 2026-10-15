#!/usr/bin/env bash
# dispatch-issue.sh <issue-number> — ask for one shipwright-pipeline.yml run for an issue: post the
# bot's SHIPWRIGHT-DISPATCHED marker first, then dispatch. Shared by shipwright-dispatch.yml and
# shipwright-label-dispatch.yml (ADR-0007). The caller has already passed the safety gates.
#
# The marker goes first: if it cannot be posted, nothing is dispatched, so no run can exist that a
# later dispatch would not see. Fails closed: exit 2 on bad input, otherwise 1 when either write fails.
set -euo pipefail

usage() { echo "dispatch-issue.sh: $1" >&2; exit 2; }
fail() { echo "dispatch-issue.sh: $1" >&2; exit 1; }

issue="${1:-}"
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage "usage: dispatch-issue.sh <issue-number>"
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be owner/repo"

requested_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! gh issue comment "$issue" --repo "$repo" \
    --body "Shipwright dispatch requested a pipeline run for this issue.

<!-- SHIPWRIGHT-DISPATCHED: run-request ${requested_at} -->" >/dev/null; then
    fail "could not post the dispatch marker on #${issue}; not dispatching"
fi
if ! gh workflow run shipwright-pipeline.yml --repo "$repo" -f issue_number="$issue" -f template=standard; then
    fail "failed to dispatch a pipeline for #${issue}"
fi
