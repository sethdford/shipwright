#!/usr/bin/env bash
# pipeline-active.sh <issue-number> — prints "true" when a shipwright-pipeline.yml run for the
# issue (display title ending in "#N" or containing "#N ") is in progress, queued, waiting,
# pending or requested; otherwise "false". Used before every dispatch so that no issue runs twice.
#
# Fails closed, printing nothing on stdout: exit 2 on bad input, otherwise 1 when NO_GITHUB is
# set or any listing fails, prints nothing or is not a JSON array of objects.
set -euo pipefail

usage() { echo "pipeline-active.sh: $1" >&2; exit 2; }
fail() { echo "pipeline-active.sh: $1" >&2; exit 1; }

issue="${1:-}"
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage "usage: pipeline-active.sh <issue-number>"
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be owner/repo"
[[ "${NO_GITHUB:-}" != "true" ]] || fail "NO_GITHUB set; cannot list runs"

count=0
for status in in_progress queued waiting pending requested; do
    if ! out=$(gh run list --repo "$repo" --workflow shipwright-pipeline.yml --status "$status" \
        --limit 100 --json displayTitle); then
        fail "cannot list ${status} pipeline runs"
    fi
    [[ -n "$out" ]] || fail "gh returned no output for ${status} runs"
    if ! n=$(jq --arg t "#${issue}" '
        if type == "array" and all(.[]; type == "object") then
            [.[] | .displayTitle // "" | select(endswith($t) or contains($t + " "))] | length
        else error("run list is not an array of objects") end' <<<"$out"); then
        fail "malformed ${status} run list"
    fi
    count=$((count + n))
done

if [[ "$count" -gt 0 ]]; then echo "true"; else echo "false"; fi
