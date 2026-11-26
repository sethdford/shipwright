#!/usr/bin/env bash
# state-sync.sh — restore and persist Shipwright state on the shipwright-data branch across CI runs.
#
#   state-sync.sh restore [dir...]          copy the branch's state into $SW_STATE_HOME
#   state-sync.sh persist <label> [dir...]  merge $SW_STATE_HOME into the branch and push it
#
# Files: events.jsonl, costs.json and budget.json, plus each named directory (memory, baselines, ...).
#
# Concurrent runs used to copy their whole costs.json and events.jsonl over the branch and force-push
# on a rebase conflict, so the last writer erased every other run's entries. persist now merges onto
# the branch's current head and never force-pushes:
#   costs.json   union of .entries (an identical entry counts once), ordered by ts_epoch, last 1000
#                kept (the cap sw-cost.sh applies); .summary keys from this run win.
#   events.jsonl the branch's lines, then this run's lines the branch does not already have.
#   budget.json  this run's copy when it is valid JSON (it is configuration, not a ledger).
#   directories  this run's files are copied over the branch's; files only on the branch stay.
# A rejected push (another run pushed first) re-fetches the head and merges again, up to
# STATE_SYNC_ATTEMPTS times. When every attempt fails, persist exits 1 and nothing was overwritten.
#
# Env: GITHUB_REPOSITORY (owner/repo), GITHUB_TOKEN (optional; given to git through a credential
# helper that reads the environment, never on a command line), STATE_REMOTE (overrides the remote,
# for tests), STATE_BRANCH (default shipwright-data), SW_STATE_HOME (default ~/.shipwright),
# STATE_SYNC_ATTEMPTS (default 6), STATE_SYNC_MAX_SLEEP (default 10 seconds of jitter).
set -euo pipefail

FILES="events.jsonl costs.json budget.json"
COST_CAP=1000

usage() { echo "state-sync.sh: $1" >&2; exit 2; }
warn() { echo "::warning::state-sync: $1" >&2; }

BRANCH="${STATE_BRANCH:-shipwright-data}"
STATE_HOME="${SW_STATE_HOME:-$HOME/.shipwright}"
ATTEMPTS="${STATE_SYNC_ATTEMPTS:-6}"
MAX_SLEEP="${STATE_SYNC_MAX_SLEEP:-10}"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || usage "STATE_BRANCH is not a branch name"
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || usage "STATE_SYNC_ATTEMPTS must be a positive integer"
[[ "$MAX_SLEEP" =~ ^[0-9]+$ ]] || usage "STATE_SYNC_MAX_SLEEP must be a whole number"

if [[ -n "${STATE_REMOTE:-}" ]]; then
    REMOTE="$STATE_REMOTE"
else
    [[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be owner/repo"
    REMOTE="https://github.com/${GITHUB_REPOSITORY}.git"
fi

# The helper reads GITHUB_TOKEN from the environment when git asks, so the token never appears in argv.
# shellcheck disable=SC2016 # expanded by git's shell when the helper runs, not here
HELPER='!f() { test "$1" = get || exit 0; t=${GITHUB_TOKEN:-}; [ -n "$t" ] && printf "username=x-access-token\npassword=%s\n" "$t"; }; f'

g() { git -c credential.helper= -c "credential.helper=$HELPER" -c core.hooksPath=/dev/null "$@"; }

# check_dir <name> — directory names are plain relative names: no slashes, no dot names.
check_dir() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || usage "directory '$1' must be a plain name"
}

# open_branch <workdir> — prints "present", "absent" or fails (exit 1) when the remote cannot be read.
open_branch() {
    local wd="$1" rc=0
    g -C "$wd" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) g -C "$wd" fetch --quiet --depth 1 origin "$BRANCH" >/dev/null 2>&1 || return 1
           git -C "$wd" checkout --quiet -B "$BRANCH" FETCH_HEAD || return 1
           echo "present" ;;
        2) git -C "$wd" checkout --quiet --orphan "$BRANCH" || return 1
           echo "absent" ;;
        *) return 1 ;;
    esac
}

new_workdir() {
    local wd
    wd=$(mktemp -d)
    git -C "$wd" init --quiet
    git -C "$wd" remote add origin "$REMOTE"
    git -C "$wd" config user.name "shipwright[bot]"
    git -C "$wd" config user.email "shipwright[bot]@users.noreply.github.com"
    echo "$wd"
}

cmd_restore() {
    local d wd state
    for d in "$@"; do check_dir "$d"; done
    mkdir -p "$STATE_HOME/memory"
    for d in "$@"; do mkdir -p "$STATE_HOME/$d"; done
    wd=$(new_workdir)
    if ! state=$(open_branch "$wd"); then
        rm -rf "$wd"
        warn "cannot read the ${BRANCH} branch; starting from empty state"
        return 0
    fi
    if [[ "$state" == "absent" ]]; then
        echo "No ${BRANCH} branch yet; starting fresh"
    else
        local f
        for f in $FILES; do
            [[ -f "$wd/$f" ]] && cp "$wd/$f" "$STATE_HOME/$f"
        done
        for d in memory "$@"; do
            [[ -d "$wd/$d" ]] && cp -R "$wd/$d/." "$STATE_HOME/$d/"
        done
        echo "State restored from ${BRANCH}"
    fi
    rm -rf "$wd"
}

# merge_costs <branch-file> <local-file> <out>
merge_costs() {
    local remote="$1" mine="$2" out="$3" empty r l
    empty=$(mktemp)
    echo '{}' > "$empty"
    r="$empty"
    l="$empty"
    if [[ -f "$remote" ]] && jq -e 'type == "object"' "$remote" >/dev/null 2>&1; then r="$remote"; fi
    if [[ -f "$mine" ]] && jq -e 'type == "object"' "$mine" >/dev/null 2>&1; then
        l="$mine"
    elif [[ -f "$mine" ]]; then
        warn "this run's costs.json is not a JSON object; keeping the branch's entries only"
    fi
    jq -s --argjson cap "$COST_CAP" '
        def entries: (.entries // []) | if type == "array" then map(select(type == "object")) else [] end;
        def summary: (.summary // {}) | if type == "object" then . else {} end;
        (.[0] | entries) as $r | (.[1] | entries) as $l
        | (reduce ($r + $l)[] as $e ({seen: {}, out: []};
              ($e | tostring) as $k
              | if .seen[$k] then . else .seen[$k] = true | .out += [$e] end)
          | .out) as $all
        | {entries: ($all | sort_by(.ts_epoch // 0) | .[-$cap:]),
           summary: ((.[0] | summary) * (.[1] | summary))}
    ' "$r" "$l" > "$out"
    rm -f "$empty"
}

# merge_events <branch-file> <local-file> <out>
merge_events() {
    local remote="$1" mine="$2" out="$3"
    [[ -f "$remote" ]] || remote=/dev/null
    [[ -f "$mine" ]] || mine=/dev/null
    awk 'NR == FNR { if (NF) { seen[$0] = 1; print }; next }
         NF && !($0 in seen) { seen[$0] = 1; print }' "$remote" "$mine" > "$out"
}

# merge_into <workdir> <dir...> — applies this run's state onto the checked-out branch.
merge_into() {
    local wd="$1" tmp d
    shift
    tmp=$(mktemp)
    if [[ -f "$STATE_HOME/costs.json" || -f "$wd/costs.json" ]]; then
        merge_costs "$wd/costs.json" "$STATE_HOME/costs.json" "$tmp"
        cp "$tmp" "$wd/costs.json"
    fi
    if [[ -f "$STATE_HOME/events.jsonl" || -f "$wd/events.jsonl" ]]; then
        merge_events "$wd/events.jsonl" "$STATE_HOME/events.jsonl" "$tmp"
        cp "$tmp" "$wd/events.jsonl"
    fi
    rm -f "$tmp"
    if [[ -f "$STATE_HOME/budget.json" ]] && jq -e . "$STATE_HOME/budget.json" >/dev/null 2>&1; then
        cp "$STATE_HOME/budget.json" "$wd/budget.json"
    fi
    for d in memory "$@"; do
        if [[ -d "$STATE_HOME/$d" ]]; then
            mkdir -p "$wd/$d"
            cp -R "$STATE_HOME/$d/." "$wd/$d/"
        fi
    done
}

cmd_persist() {
    local label="${1:-}" attempt wd state pause
    [[ "$label" =~ ^[a-z0-9-]+$ ]] || usage "usage: state-sync.sh persist <label> [dir...]"
    shift
    local d
    for d in "$@"; do check_dir "$d"; done
    for attempt in $(seq 1 "$ATTEMPTS"); do
        wd=$(new_workdir)
        if ! state=$(open_branch "$wd"); then
            warn "attempt ${attempt}: cannot read the ${BRANCH} branch"
        else
            if [[ "$state" == "absent" ]]; then
                printf '# Shipwright Persistent State\n\nEvents, costs and memory across CI runs. Never merge into main.\n' > "$wd/README.md"
            fi
            merge_into "$wd" "$@"
            git -C "$wd" add -A
            if git -C "$wd" diff --cached --quiet; then
                rm -rf "$wd"
                echo "No state changes to persist"
                return 0
            fi
            git -C "$wd" commit --quiet -m "chore: persist ${label} state [skip ci]"
            if g -C "$wd" push --quiet origin "HEAD:refs/heads/${BRANCH}" 2>/dev/null; then
                rm -rf "$wd"
                echo "State persisted to ${BRANCH} (attempt ${attempt})"
                return 0
            fi
            echo "Push attempt ${attempt} was rejected; merging onto the new head"
        fi
        rm -rf "$wd"
        if [[ "$attempt" -lt "$ATTEMPTS" && "$MAX_SLEEP" -gt 0 ]]; then
            pause=$((RANDOM % MAX_SLEEP + 1))
            sleep "$pause"
        fi
    done
    echo "::error::state-sync: could not persist state to ${BRANCH} after ${ATTEMPTS} attempts" >&2
    return 1
}

case "${1:-}" in
    restore) shift; cmd_restore "$@" ;;
    persist) shift; cmd_persist "$@" ;;
    *) usage "usage: state-sync.sh restore [dir...] | persist <label> [dir...]" ;;
esac
