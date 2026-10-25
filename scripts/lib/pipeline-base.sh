#!/usr/bin/env bash
# pipeline-base.sh — the pipeline's base record (#8671, #8662, #8706).
#
# The base is the commit the test stage judges failures against, and the remote and branch the
# pipeline started on. It is recorded once, at the very first start of a pipeline, before intake and
# before any agent code runs. The record lives under ~/.shipwright, keyed by the repository's common
# git directory and the pipeline id. It is never in .claude/ or the worktree, which the agent can write.
#
# Interface (stable; other pipeline features consume it):
#   pipeline_base_record <repo> <id>        create the record on first start; on resume reuse it. Exports
#                                           SW_PIPELINE_BASE_SHA. Returns non-zero (and exports nothing) when
#                                           the record is missing on a resume, or invalid.
#   pipeline_base_get <repo> <id>           print the recorded base SHA. Non-zero if missing or invalid.
#   pipeline_base_get_field <repo> <id> F   print one field: base | remote | push_url | branch | nm. Non-zero
#                                           if missing or invalid.
#   pipeline_base_init                      the pipeline's entry point: records or reloads the base for the
#                                           current PROJECT_ROOT and ISSUE_NUMBER/PIPELINE_NAME.
#   pipeline_base_nm_unchanged <repo> <id>  0 when node_modules matches the fingerprint taken at start.
#
# Nothing here derives the base from refs once the record exists. Resumes (PIPELINE_RESUMING or
# RESUME_FROM_CHECKPOINT) never create a record.

[[ -n "${_PIPELINE_BASE_LOADED:-}" ]] && return 0
_PIPELINE_BASE_LOADED=1

_pipeline_base_root() { printf '%s' "${SHIPWRIGHT_HOME:-$HOME/.shipwright}/pipeline-base"; }

# _pipeline_base_valid_id <id> — ids are plain tokens, so they cannot escape the record directory.
_pipeline_base_valid_id() {
    [[ -n "$1" && "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}

# _pipeline_base_file <repo> <id> — the record path. Keyed by the repository's common git dir, so the
# same repository in a worktree gets the same record.
_pipeline_base_file() {
    local common key
    common="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    common="$(cd "$1" && cd "$common" && pwd -P)" || return 1
    key="$(printf '%s' "$common" | cksum | awk '{ print $1 }')"
    printf '%s/%s/%s.json' "$(_pipeline_base_root)" "$key" "$2"
}

# _pipeline_base_nm_fingerprint <repo> — a content checksum of node_modules (the real directory, following
# the worktree's symlink), or "absent". The agent can write node_modules, so the check catches changes.
_pipeline_base_nm_fingerprint() {
    local nm
    if [[ ! -e "$1/node_modules" ]]; then printf 'absent'; return 0; fi
    nm="$(cd "$1/node_modules" 2>/dev/null && pwd -P)" || { printf 'unreadable'; return 0; }
    (cd "$nm" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum) | cksum | awk '{ print $1 "-" $2 }'
}

# _pipeline_base_compute <repo> — the fork point of HEAD and the base branch, empty when none resolves.
_pipeline_base_compute() {
    local ref base=""
    for ref in "origin/${BASE_BRANCH:-main}" "${BASE_BRANCH:-main}"; do
        base="$(git -C "$1" merge-base HEAD "$ref" 2>/dev/null || true)"
        [[ -n "$base" ]] && break
    done
    printf '%s' "$base"
}

# pipeline_base_get <repo> <id> — validate the record and print its base.
pipeline_base_get() {
    pipeline_base_get_field "$1" "$2" base
}

# pipeline_base_get_field <repo> <id> <base|remote|branch|nm>
pipeline_base_get_field() {
    local repo="$1" id="$2" field="$3" file common base
    _pipeline_base_valid_id "$id" || return 1
    case "$field" in base|remote|push_url|branch|nm) ;; *) return 1 ;; esac
    file="$(_pipeline_base_file "$repo" "$id")" || return 1
    [[ -f "$file" ]] || return 1
    common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
    jq -e --arg repo "$common" --arg id "$id" \
        '.version == 1 and .repo == $repo and .id == $id and (.base | type == "string") and (.push_url | type == "string")' "$file" >/dev/null 2>&1 || return 1
    base="$(jq -r '.base' "$file")"
    [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 1
    git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null || return 1
    jq -r --arg f "$field" '.[$f] // ""' "$file"
}

# pipeline_base_record <repo> <id>
pipeline_base_record() {
    local repo="$1" id="$2" file dir base remote push branch nm common tmp
    unset SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    _pipeline_base_valid_id "$id" || return 1
    file="$(_pipeline_base_file "$repo" "$id")" || return 1
    if [[ -f "$file" ]]; then
        # Never recompute an existing record: reuse it, or fail closed when it is invalid.
        base="$(pipeline_base_get "$repo" "$id")" || return 1
        push="$(pipeline_base_get_field "$repo" "$id" push_url)" || return 1
        export SW_PIPELINE_BASE_SHA="$base" SW_PIPELINE_PUSH_URL="$push"
        return 0
    fi
    # A resume without a record cannot prove the base: refs may have moved since the first start.
    if [[ "${PIPELINE_RESUMING:-false}" == "true" || "${RESUME_FROM_CHECKPOINT:-false}" == "true" ]]; then
        return 1
    fi
    base="$(_pipeline_base_compute "$repo")"
    [[ -n "$base" ]] || return 1
    remote="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
    push="$(git -C "$repo" remote get-url --push origin 2>/dev/null || true)"
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    nm="$(_pipeline_base_nm_fingerprint "$repo")"
    common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
    dir="$(dirname "$file")"
    mkdir -p "$dir" && chmod 700 "$(_pipeline_base_root)" "$dir" 2>/dev/null || return 1
    tmp="$(mktemp "$dir/.base.XXXXXX")" || return 1
    if jq -n --arg repo "$common" --arg id "$id" --arg base "$base" --arg remote "$remote" --arg push "$push" \
        --arg branch "$branch" --arg nm "$nm" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: 1, repo: $repo, id: $id, base: $base, remote: $remote, push_url: $push, branch: $branch, nm: $nm, created_at: $at}' \
        > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"; then
        export SW_PIPELINE_BASE_SHA="$base" SW_PIPELINE_PUSH_URL="$push"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# pipeline_base_nm_unchanged <repo> <id>
pipeline_base_nm_unchanged() {
    local recorded now
    recorded="$(pipeline_base_get_field "$1" "$2" nm)" || return 1
    now="$(_pipeline_base_nm_fingerprint "$1")"
    [[ -n "$recorded" && "$recorded" == "$now" ]]
}

# pipeline_base_init — the pipeline's entry point, called before intake. Exports SW_PIPELINE_BASE_SHA and
# SW_PIPELINE_PUSH_URL (git remote get-url --push origin at the first start). The id is the issue number, or the
# pipeline name, reduced to a plain token.
pipeline_base_init() {
    local root="${PROJECT_ROOT:-.}" raw id
    raw="${ISSUE_NUMBER:-${PIPELINE_NAME:-inline}}"
    id="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
    export SW_PIPELINE_BASE_ID="$id"
    if ! pipeline_base_record "$root" "$id"; then
        unset SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
        if declare -F warn >/dev/null 2>&1; then
            warn "Pipeline base: no valid record for '$id'; the test stage will block (no differential judgement)"
        fi
        return 1
    fi
    return 0
}
