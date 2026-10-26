#!/usr/bin/env bash
# pipeline-base.sh — the pipeline's base record (#8671, #8662, #8706).
#
# A pipeline run records the commit the test stage judges against, the remote and push URL it started
# with, and the branch. The record is written only at a proven first start: HEAD must be the fork point
# of the base branch, with no commits beyond it. Otherwise nothing is recorded, and the stage blocks.
#
# Storage: ~/.shipwright/pipeline-base (or $SHIPWRIGHT_HOME), never .claude/ or the worktree, which the
# agent can write. Layout:
#   <root>/<repo-key>/<run-id>.json          the record, mode 0600
#   <root>/<repo-key>/<branch-key>.run       the run id that resumes of this branch use, mode 0600
# repo-key is a checksum of the repository's common git dir, branch-key of the branch name. Every run gets
# its own id, so an old record for the same issue or template is never reused. Records are removed when a
# pipeline completes or is aborted, and any older than 14 days are swept at each fresh start.
#
# Interface (stable; #8662 and #8706 consume it):
#   pipeline_base_init                       the entry point, before intake. Resumes reload the run's record;
#                                            a fresh start proves the fork point and creates a record. Exports
#                                            SW_PIPELINE_RUN_ID, SW_PIPELINE_BASE_SHA, SW_PIPELINE_PUSH_URL.
#                                            Returns non-zero, and exports nothing, when no valid record exists.
#   pipeline_base_record <repo> <run-id>     create the record for a run at a proven first start.
#   pipeline_base_get <repo> <run-id>        print the recorded base SHA. Non-zero if missing or invalid.
#   pipeline_base_get_field <repo> <run-id> F   print base | remote | push_url | branch | nm.
#   pipeline_base_nm_unchanged <repo> <run-id> 0 when node_modules matches the fingerprint taken at start.
#   pipeline_base_release [repo]             delete the current run's record and pointer (completion, abort).
#
# Resumes set PIPELINE_RESUMING or RESUME_FROM_CHECKPOINT. A resume never creates a record.

[[ -n "${_PIPELINE_BASE_LOADED:-}" ]] && return 0
_PIPELINE_BASE_LOADED=1

_PIPELINE_BASE_TTL_DAYS=14

_pipeline_base_root() { printf '%s' "${SHIPWRIGHT_HOME:-$HOME/.shipwright}/pipeline-base"; }

# _pipeline_base_valid_id <token> — ids are plain tokens, so they cannot escape the record directory.
_pipeline_base_valid_id() {
    [[ -n "$1" && "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}

# _pipeline_base_stat <path> <linux-format> <macos-format>
_pipeline_base_stat() { stat -c "$2" "$1" 2>/dev/null || stat -f "$3" "$1" 2>/dev/null; }

# _pipeline_base_secure <path> <file|dir> — the path is a real file or directory (not a symlink), owned by
# this user, with mode 0600 for a file and 0700 for a directory. A record that fails this is not trusted.
_pipeline_base_secure() {
    local path="$1" kind="$2" want owner mode
    [[ ! -L "$path" ]] || return 1
    if [[ "$kind" == dir ]]; then [[ -d "$path" ]] || return 1; want=700; else [[ -f "$path" ]] || return 1; want=600; fi
    owner="$(_pipeline_base_stat "$path" %u %u)" || return 1
    mode="$(_pipeline_base_stat "$path" %a %Lp)" || return 1
    [[ "$owner" == "$(id -u)" && "$mode" == "$want" ]]
}

# _pipeline_base_repo_key <repo> — the repository's common git dir, checksummed.
_pipeline_base_repo_key() {
    local common
    common="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    common="$(cd "$1" && cd "$common" && pwd -P)" || return 1
    printf '%s' "$common" | cksum | awk '{ print $1 }'
}

# _pipeline_base_dir <repo> — the repository's record directory (created 0700 when needed).
_pipeline_base_dir() {
    local key
    key="$(_pipeline_base_repo_key "$1")" || return 1
    printf '%s/%s' "$(_pipeline_base_root)" "$key"
}

# _pipeline_base_branch <repo> — the current branch name ("HEAD" when detached).
_pipeline_base_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }

# _pipeline_base_pointer <repo> [branch] — the pointer file for a branch.
_pipeline_base_pointer() {
    local dir bkey branch="${2:-}"
    [[ -n "$branch" ]] || branch="$(_pipeline_base_branch "$1")"
    dir="$(_pipeline_base_dir "$1")" || return 1
    bkey="$(printf '%s' "$branch" | cksum | awk '{ print $1 }')"
    printf '%s/%s.run' "$dir" "$bkey"
}

# _pipeline_base_fork <repo> — the fork point of HEAD and the base branch, empty when none resolves.
_pipeline_base_fork() {
    local ref base=""
    for ref in "origin/${BASE_BRANCH:-main}" "${BASE_BRANCH:-main}"; do
        base="$(git -C "$1" merge-base HEAD "$ref" 2>/dev/null || true)"
        [[ -n "$base" ]] && break
    done
    printf '%s' "$base"
}

# _pipeline_base_nm_fingerprint <repo> — a checksum of node_modules, or "absent". Symlinks are followed
# (find -L), and every link's target is part of the fingerprint, so poison behind a link is caught.
_pipeline_base_nm_fingerprint() {
    local nm
    if [[ ! -e "$1/node_modules" && ! -L "$1/node_modules" ]]; then printf 'absent'; return 0; fi
    nm="$(cd "$1/node_modules" 2>/dev/null && pwd -P)" || { printf 'unreadable'; return 0; }
    {
        (cd "$nm" && find -L . -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null)
        (cd "$nm" && find . -type l -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r l; do
            printf 'link %s -> %s\n' "$l" "$(readlink "$l")"; done)
    } | cksum | awk '{ print $1 "-" $2 }'
}

# _pipeline_base_load <repo> <run-id> <field> — validate a run's record and print one field. Non-zero when
# the record is missing, insecure, malformed, or names a base that is not a commit in this repository.
_pipeline_base_load() {
    local repo="$1" id="$2" field="$3" dir file common base
    _pipeline_base_valid_id "$id" || return 1
    case "$field" in base|remote|push_url|branch|nm) ;; *) return 1 ;; esac
    dir="$(_pipeline_base_dir "$repo")" || return 1
    file="$dir/$id.json"
    [[ -d "$dir" ]] && _pipeline_base_secure "$dir" dir || return 1
    _pipeline_base_secure "$file" file || return 1
    common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
    jq -e --arg repo "$common" --arg id "$id" \
        '.version == 1 and .repo == $repo and .run == $id and (.base | type == "string") and (.push_url | type == "string")' \
        "$file" >/dev/null 2>&1 || return 1
    base="$(jq -r '.base' "$file")"
    [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 1
    git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null || return 1
    jq -r --arg f "$field" '.[$f] // ""' "$file"
}

# pipeline_base_get <repo> <run-id>
pipeline_base_get() { _pipeline_base_load "$1" "$2" base; }

# pipeline_base_get_field <repo> <run-id> <base|remote|push_url|branch|nm>
pipeline_base_get_field() { _pipeline_base_load "$1" "$2" "$3"; }

# pipeline_base_nm_unchanged <repo> <run-id>
pipeline_base_nm_unchanged() {
    local recorded now
    recorded="$(pipeline_base_get_field "$1" "$2" nm)" || return 1
    now="$(_pipeline_base_nm_fingerprint "$1")"
    [[ -n "$recorded" && "$recorded" == "$now" ]]
}

# _pipeline_base_expire <repo> — delete records and pointers older than the TTL.
_pipeline_base_expire() {
    local dir
    dir="$(_pipeline_base_dir "$1")" || return 0
    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 \( -name '*.json' -o -name '*.run' \) -type f -mtime +"$_PIPELINE_BASE_TTL_DAYS" \
        -exec rm -f {} + 2>/dev/null || true
}

# pipeline_base_record <repo> <run-id> — create the record for a run. Only at a proven first start: HEAD is
# the fork point, so the branch has no commits beyond the base. Also points the branch's resumes at this run.
pipeline_base_record() {
    local repo="$1" id="$2" base head remote push branch nm dir file tmp ptr common
    unset SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    _pipeline_base_valid_id "$id" || return 1
    base="$(_pipeline_base_fork "$repo")"
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    [[ -n "$base" && "$base" == "$head" ]] || return 1
    dir="$(_pipeline_base_dir "$repo")" || return 1
    mkdir -p "$(_pipeline_base_root)" "$dir" && chmod 700 "$(_pipeline_base_root)" "$dir" || return 1
    _pipeline_base_secure "$dir" dir || return 1
    file="$dir/$id.json"
    [[ ! -e "$file" ]] || return 1
    remote="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
    push="$(git -C "$repo" remote get-url --push origin 2>/dev/null || true)"
    branch="$(_pipeline_base_branch "$repo")"
    nm="$(_pipeline_base_nm_fingerprint "$repo")"
    common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
    tmp="$(mktemp "$dir/.base.XXXXXX")" || return 1
    if jq -n --arg repo "$common" --arg run "$id" --arg base "$base" --arg remote "$remote" --arg push "$push" \
        --arg branch "$branch" --arg nm "$nm" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: 1, repo: $repo, run: $run, base: $base, remote: $remote, push_url: $push, branch: $branch, nm: $nm, created_at: $at}' \
        > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"; then
        ptr="$(_pipeline_base_pointer "$repo" "$branch")" || return 1
        printf '%s\n' "$id" > "$ptr.tmp.$$" && chmod 600 "$ptr.tmp.$$" && mv "$ptr.tmp.$$" "$ptr" || return 1
        export SW_PIPELINE_BASE_SHA="$base" SW_PIPELINE_PUSH_URL="$push"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# _pipeline_base_resume_id <repo> — the run id a resume of the current branch uses, from its pointer.
_pipeline_base_resume_id() {
    local ptr id
    ptr="$(_pipeline_base_pointer "$1")" || return 1
    [[ -f "$ptr" && ! -L "$ptr" ]] || return 1
    _pipeline_base_secure "$ptr" file || return 1
    id="$(head -n 1 "$ptr")"
    _pipeline_base_valid_id "$id" || return 1
    printf '%s' "$id"
}

# pipeline_base_init — the pipeline's entry point, called before intake. A resume reloads the current
# branch's run. A fresh start creates a new run, and only when the fork-point proof holds.
pipeline_base_init() {
    local root="${PROJECT_ROOT:-.}" id base
    unset SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    if [[ "${PIPELINE_RESUMING:-false}" == "true" || "${RESUME_FROM_CHECKPOINT:-false}" == "true" ]]; then
        id="$(_pipeline_base_resume_id "$root")" || id=""
        if [[ -n "$id" ]] && base="$(pipeline_base_get "$root" "$id")"; then
            export SW_PIPELINE_RUN_ID="$id" SW_PIPELINE_BASE_SHA="$base"
            export SW_PIPELINE_PUSH_URL="$(pipeline_base_get_field "$root" "$id" push_url)"
            return 0
        fi
        _pipeline_base_fail "no valid base record for this branch's run: the test stage is blocked. Start the pipeline again on a clean branch, or restore the run's record."
        return 1
    fi
    _pipeline_base_expire "$root"
    id="run-$(date -u +%Y%m%d%H%M%S)-$$-$RANDOM"
    if pipeline_base_record "$root" "$id"; then
        export SW_PIPELINE_RUN_ID="$id"
        return 0
    fi
    _pipeline_base_fail "the branch is not at the fork point of ${BASE_BRANCH:-main} (it has commits beyond the base, or no base resolves). The test stage is blocked. Start the pipeline from a clean branch at ${BASE_BRANCH:-main}."
    return 1
}

_pipeline_base_fail() {
    unset SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    if declare -F warn >/dev/null 2>&1; then warn "Pipeline base: $1"; else echo "Pipeline base: $1" >&2; fi
}

# pipeline_base_release [repo] — remove the current run's record and pointer. Call on completion or abort,
# not on failure: a failed run stays resumable.
pipeline_base_release() {
    local root="${1:-${PROJECT_ROOT:-.}}" ptr id dir
    ptr="$(_pipeline_base_pointer "$root")" || return 0
    id="$(head -n 1 "$ptr" 2>/dev/null || true)"
    dir="$(_pipeline_base_dir "$root")" || return 0
    _pipeline_base_valid_id "$id" && rm -f "$dir/$id.json"
    rm -f "$ptr"
    unset SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    return 0
}
