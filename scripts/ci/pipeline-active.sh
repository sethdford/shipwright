#!/usr/bin/env bash
# pipeline-active.sh <issue-number> — prints "true" when a shipwright-pipeline.yml run for the
# issue (display title ending in "#N" or containing "#N ") is in progress, queued, waiting,
# pending or requested; otherwise "false". Used before every dispatch so that no issue runs twice.
# action_required is not listed: it is a conclusion for a completed run awaiting approval of a fork
# pull_request, and shipwright-pipeline.yml runs only on issues and workflow_dispatch events.
#
# gh run list does not page past --limit, so a listing that fills it may be truncated and fails
# closed rather than reading as "no run".
#
# Fails closed, printing nothing on stdout: exit 2 on bad input, otherwise 1 when NO_GITHUB is
# set or any listing fails, prints nothing, is not a JSON array of objects or fills the limit.
set -euo pipefail

usage() { echo "pipeline-active.sh: $1" >&2; exit 2; }
fail() { echo "pipeline-active.sh: $1" >&2; exit 1; }

issue="${1:-}"
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage "usage: pipeline-active.sh <issue-number>"
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be owner/repo"
[[ "${NO_GITHUB:-}" != "true" ]] || fail "NO_GITHUB set; cannot list runs"

LIMIT=200
count=0
for status in in_progress queued waiting pending requested; do
    if ! out=$(gh run list --repo "$repo" --workflow shipwright-pipeline.yml --status "$status" \
        --limit "$LIMIT" --json displayTitle); then
        fail "cannot list ${status} pipeline runs"
    fi
    [[ -n "$out" ]] || fail "gh returned no output for ${status} runs"
    if ! n=$(jq --arg t "#${issue}" --argjson limit "$LIMIT" '
        if type != "array" or any(.[]; type != "object") then error("run list is not an array of objects")
        elif length >= $limit then error("run list may be truncated")
        else [.[] | .displayTitle // "" | select(endswith($t) or contains($t + " "))] | length end' <<<"$out"); then
        fail "malformed or possibly truncated ${status} run list"
    fi
    count=$((count + n))
done

if [[ "$count" -gt 0 ]]; then echo "true"; else echo "false"; fi
