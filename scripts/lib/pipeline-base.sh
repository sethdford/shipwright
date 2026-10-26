#!/usr/bin/env bash
# pipeline-base.sh — the pipeline's base record (#8671, #8662, #8706).
#
# A run records the commit the test stage judges against (the base), the origin URL it proved the base
# against, and a fingerprint of node_modules. A fresh start creates the record only when HEAD is the fork
# point of the remote's base branch, so the branch has no commits beyond it. Otherwise nothing is recorded
# and the test stage blocks.
#
# Threat model, stated plainly. The test command runs agent-written code as this same OS user, so files this
# user owns give no integrity against it. Guards, and the residual:
#  - Within one process, pipeline_base_init copies the base, node_modules fingerprint and push URL into
#    readonly shell variables. The judgement reads only those, never the record on disk. The test command runs
#    in its own process group, which is killed before the base run starts.
#  - A resume crosses a process boundary, so it reads the record from disk, validating owner, mode, shape,
#    worktree and commit. Between processes, code running as this user can still rewrite the record. That
#    residual is what #8706 fixes structurally (a record the agent cannot write).
#  - A fresh start takes the base from the remote: git ls-remote against the URL from SW_TRUSTED_REMOTE_URL
#    (set by the daemon), or else the repository's own origin URL, read with the global and system config
#    ignored and pinned at the first start. A local config that sets pushurl or insteadOf blocks the start.
#    Local refs and replace objects are never consulted for the base.
#  - The node_modules walk is bounded by SW_PIPELINE_NM_TIMEOUT seconds (default 120); a timeout blocks.
#
# Storage: <SHIPWRIGHT_HOME or ~/.shipwright>/pipeline-base, never .claude/ or the worktree. Layout:
#   <root>/<repo-key>/<run-id>.json      the record, mode 0600
#   <root>/<repo-key>/<worktree-key>.run the run id this worktree's resumes use, mode 0600
#   <root>/<repo-key>/origin.url         the pinned origin URL, mode 0600
# repo-key checksums the repository's common git dir. worktree-key checksums the worktree path, so the pointer
# survives the intake step's branch change. Records are removed at completion or abort, and any older than 14
# days are swept at each fresh start.
#
# Interface (stable; #8662 and #8706 consume it):
#   pipeline_base_init                       the entry point, before intake. Exports SW_PIPELINE_RUN_ID,
#                                            SW_PIPELINE_BASE_SHA, SW_PIPELINE_PUSH_URL. Returns non-zero and
#                                            exports nothing when no valid record exists or a start cannot be proved.
#   pipeline_base_record <repo> <run-id>     create the record for a run at a proven first start.
#   pipeline_base_get <repo> <run-id>        print the recorded base SHA. Non-zero if missing or invalid.
#   pipeline_base_get_field <repo> <run-id> F   print base | remote | push_url | branch | nm.
#   pipeline_base_nm_unchanged_now [repo]    0 when node_modules matches this process's start fingerprint.
#   pipeline_base_release [repo]             delete the run's record and pointer (completion, abort).
#
# Resumes set PIPELINE_RESUMING or RESUME_FROM_CHECKPOINT. A resume never creates a record. A resume without a
# valid record fails closed, so a forged checkpoint can only lead to that path.

[[ -n "${_PIPELINE_BASE_LOADED:-}" ]] && return 0
_PIPELINE_BASE_LOADED=1

_PIPELINE_BASE_TTL_DAYS=14
_PIPELINE_BASE_BAD_CFG='^(remote\..*\.pushurl|url\..*\.(pushinsteadof|insteadof))$'

_pipeline_base_home() { printf '%s' "${SHIPWRIGHT_HOME:-$HOME/.shipwright}"; }
_pipeline_base_root() { printf '%s/pipeline-base' "$(_pipeline_base_home)"; }

# _pipeline_base_valid_id <token> — ids are plain tokens, so they cannot escape the record directory.
_pipeline_base_valid_id() {
    [[ -n "$1" && "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}

# _pipeline_base_stat <path> <linux-format> <macos-format>
_pipeline_base_stat() { stat -c "$2" "$1" 2>/dev/null || stat -f "$3" "$1" 2>/dev/null; }

# _pipeline_base_secure <path> <file|dir> — a real file or directory (not a link), owned by this user, mode
# 0600 for a file and 0700 for a directory.
_pipeline_base_secure() {
    local path="$1" kind="$2" want owner mode
    [[ ! -L "$path" ]] || return 1
    if [[ "$kind" == dir ]]; then [[ -d "$path" ]] || return 1; want=700; else [[ -f "$path" ]] || return 1; want=600; fi
    owner="$(_pipeline_base_stat "$path" %u %u)" || return 1
    mode="$(_pipeline_base_stat "$path" %a %Lp)" || return 1
    [[ "$owner" == "$(id -u)" && "$mode" == "$want" ]]
}

# _pipeline_base_home_ok — SHIPWRIGHT_HOME is a real directory owned by this user and not writable by group or
# others (it may hold other shipwright state, so it is not forced to 0700). Created when absent. Never chmods
# through a link.
_pipeline_base_home_ok() {
    local home owner mode g o
    home="$(_pipeline_base_home)"
    [[ ! -L "$home" ]] || return 1
    if [[ ! -e "$home" ]]; then (umask 077 && mkdir -p "$home") || return 1; fi
    [[ -d "$home" ]] || return 1
    owner="$(_pipeline_base_stat "$home" %u %u)" || return 1
    mode="$(_pipeline_base_stat "$home" %a %Lp)" || return 1
    [[ "$owner" == "$(id -u)" ]] || return 1
    g="${mode: -2:1}"; o="${mode: -1}"
    (( (g & 2) == 0 && (o & 2) == 0 ))
}

# _pipeline_base_ensure_dir <path> — a real directory with mode 0700, created when absent. Never follows a link.
_pipeline_base_ensure_dir() {
    [[ ! -L "$1" ]] || return 1
    if [[ ! -e "$1" ]]; then (umask 077 && mkdir "$1") || return 1; fi
    _pipeline_base_secure "$1" dir
}

# _pipeline_base_repo_key <repo> — the repository's common git dir, checksummed.
_pipeline_base_repo_key() {
    local common
    common="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    common="$(cd "$1" && cd "$common" && pwd -P)" || return 1
    printf '%s' "$common" | cksum | awk '{ print $1 }'
}

# _pipeline_base_dir <repo> — the repository's record directory (not created).
_pipeline_base_dir() {
    local key
    key="$(_pipeline_base_repo_key "$1")" || return 1
    printf '%s/%s' "$(_pipeline_base_root)" "$key"
}

# _pipeline_base_prepare <repo> — validates the home and creates the record directories. Prints the repo's dir.
_pipeline_base_prepare() {
    local dir
    _pipeline_base_home_ok || return 1
    dir="$(_pipeline_base_dir "$1")" || return 1
    _pipeline_base_ensure_dir "$(_pipeline_base_root)" || return 1
    _pipeline_base_ensure_dir "$dir" || return 1
    printf '%s' "$dir"
}

# _pipeline_base_top <repo> — the worktree's real path.
_pipeline_base_top() {
    local top
    top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ -n "$top" ]] || return 1
    (cd "$top" && pwd -P)
}

# _pipeline_base_pointer <repo> — the pointer for this worktree (keyed by path, not by branch).
_pipeline_base_pointer() {
    local dir top wkey
    dir="$(_pipeline_base_dir "$1")" || return 1
    top="$(_pipeline_base_top "$1")" || return 1
    wkey="$(printf '%s' "$top" | cksum | awk '{ print $1 }')"
    printf '%s/%s.run' "$dir" "$wkey"
}

# _pipeline_base_nm_fingerprint <repo> — a checksum of node_modules, or "absent". Symlinks are followed (find -L),
# and every link's target is part of the sum. Non-zero when the walk times out or the tree cannot be read, so
# callers fail closed.
_pipeline_base_nm_fingerprint() {
    local nm out
    if [[ ! -e "$1/node_modules" && ! -L "$1/node_modules" ]]; then printf 'absent'; return 0; fi
    nm="$(cd "$1/node_modules" 2>/dev/null && pwd -P)" || return 1
    out="$(perl -e 'alarm shift; exec @ARGV' "${SW_PIPELINE_NM_TIMEOUT:-120}" bash -c '
        cd "$1" || exit 1
        {
            find -L . -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null
            find . -type l -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r l; do
                printf "link %s -> %s\n" "$l" "$(readlink "$l")"
            done
        } | cksum
    ' _ "$nm")" || return 1
    printf '%s' "$out" | awk '{ print $1 "-" $2 }'
}

# _pipeline_base_config_clean <repo> — the repository's own config sets no push URL and no URL rewrite.
_pipeline_base_config_clean() {
    local bad
    bad="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$1" config --local --get-regexp "$_PIPELINE_BASE_BAD_CFG" 2>/dev/null || true)"
    bad="$bad$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$1" config --worktree --get-regexp "$_PIPELINE_BASE_BAD_CFG" 2>/dev/null || true)"
    [[ -z "$bad" ]]
}

# _pipeline_base_origin_url <repo> <dir> — the URL the start is proved against. SW_TRUSTED_REMOTE_URL (the daemon's)
# wins. Otherwise the repository's origin URL, read with global and system config ignored, pinned in <dir>/origin.url
# at the first start: a later start that finds another URL blocks. Delete the pin only when the remote was moved on purpose.
_pipeline_base_origin_url() {
    local repo="$1" dir="$2" url="" pin tmp
    if [[ -n "${SW_TRUSTED_REMOTE_URL:-}" ]]; then
        url="$SW_TRUSTED_REMOTE_URL"
    else
        url="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" config --local --get remote.origin.url 2>/dev/null || true)"
    fi
    [[ -n "$url" ]] || return 1
    pin="$dir/origin.url"
    if [[ -e "$pin" || -L "$pin" ]]; then
        _pipeline_base_secure "$pin" file || return 1
        [[ "$(head -n 1 "$pin")" == "$url" ]] || return 1
    else
        tmp="$(mktemp "$dir/.origin.XXXXXX")" || return 1
        printf '%s\n' "$url" > "$tmp" && mv "$tmp" "$pin" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s' "$url"
}

# _pipeline_base_remote_sha <url> <branch> — the remote's head of the branch, from ls-remote. Global and system
# config are ignored, so the agent's config cannot rewrite the URL or the credentials used.
_pipeline_base_remote_sha() {
    local url="$1" branch="$2" sha
    sha="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
        git -c core.hooksPath=/dev/null -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
        ls-remote --heads "$url" "refs/heads/$branch" 2>/dev/null |
        BR="$branch" awk 'BEGIN { want = "refs/heads/" ENVIRON["BR"] } $2 == want { print $1; exit }')" || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && printf '%s' "$sha"
}

# _pipeline_base_proof <repo> <url> — the base for a fresh start. HEAD must be the fork point of the remote's base
# branch, so the branch has no commits beyond it. Prints HEAD. Local refs and replace objects are not consulted.
_pipeline_base_proof() {
    local repo="$1" url="$2" branch sha head fork
    branch="${BASE_BRANCH:-main}"
    sha="$(_pipeline_base_remote_sha "$url" "$branch")" || return 1
    if ! GIT_NO_REPLACE_OBJECTS=1 git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 \
            git -C "$repo" -c core.hooksPath=/dev/null fetch -q --no-tags --no-write-fetch-head "$url" "$sha" >/dev/null 2>&1 || return 1
        GIT_NO_REPLACE_OBJECTS=1 git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
    fi
    head="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$repo" rev-parse --verify -q HEAD)" || return 1
    fork="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$repo" merge-base HEAD "$sha" 2>/dev/null)" || return 1
    [[ -n "$fork" && "$fork" == "$head" ]] || return 1
    printf '%s' "$head"
}

# _pipeline_base_load <repo> <run-id> <field> — validate a run's record and print one field. Non-zero when the
# record is missing, insecure, malformed, from another worktree, or names a base that is not a commit here.
_pipeline_base_load() {
    local repo="$1" id="$2" field="$3" dir file common top base
    _pipeline_base_valid_id "$id" || return 1
    case "$field" in base|remote|push_url|branch|nm) ;; *) return 1 ;; esac
    _pipeline_base_home_ok || return 1
    dir="$(_pipeline_base_dir "$repo")" || return 1
    file="$dir/$id.json"
    _pipeline_base_secure "$dir" dir || return 1
    _pipeline_base_secure "$file" file || return 1
    common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
    top="$(_pipeline_base_top "$repo")" || return 1
    jq -e --arg repo "$common" --arg wt "$top" --arg id "$id" '
        .version == 1 and .repo == $repo and .worktree == $wt and .run == $id
        and (.base | type == "string") and (.remote | type == "string") and (.push_url | type == "string")
        and (.nm | type == "string" and (. == "absent" or test("^[0-9]+-[0-9]+$")))' \
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

# pipeline_base_nm_unchanged_now [repo] — node_modules now matches the fingerprint captured by this process's
# pipeline_base_init. Non-zero when there was no init in this process, or the walk fails.
pipeline_base_nm_unchanged_now() {
    local now
    [[ -n "${_PB_INIT_DONE:-}" ]] || return 1
    now="$(_pipeline_base_nm_fingerprint "${1:-$_PB_ROOT}")" || return 1
    [[ "$now" == "$_PB_NM" ]]
}

# _pipeline_base_expire <repo> — delete records and pointers older than the TTL.
_pipeline_base_expire() {
    local dir
    dir="$(_pipeline_base_dir "$1")" || return 0
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    find "$dir" -maxdepth 1 \( -name '*.json' -o -name '*.run' \) -type f -mtime +"$_PIPELINE_BASE_TTL_DAYS" \
        -exec rm -f {} + 2>/dev/null || true
}

# pipeline_base_record <repo> <run-id> — create the record for a run at a proven first start, and point this
# worktree's resumes at it.
pipeline_base_record() {
    local repo="$1" id="$2" dir file url base nm top common branch tmp ptr
    _pipeline_base_valid_id "$id" || return 1
    dir="$(_pipeline_base_prepare "$repo")" || return 1
    file="$dir/$id.json"
    [[ ! -e "$file" && ! -L "$file" ]] || return 1
    _pipeline_base_config_clean "$repo" || return 1
    url="$(_pipeline_base_origin_url "$repo" "$dir")" || return 1
    base="$(_pipeline_base_proof "$repo" "$url")" || return 1
    nm="$(_pipeline_base_nm_fingerprint "$repo")" || return 1
    top="$(_pipeline_base_top "$repo")" || return 1
    common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    tmp="$(mktemp "$dir/.base.XXXXXX")" || return 1
    if jq -n --arg repo "$common" --arg wt "$top" --arg run "$id" --arg base "$base" --arg url "$url" \
        --arg branch "$branch" --arg nm "$nm" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: 1, repo: $repo, worktree: $wt, run: $run, base: $base, remote: $url, push_url: $url, branch: $branch, nm: $nm, created_at: $at}' \
        > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"; then
        ptr="$(_pipeline_base_pointer "$repo")" || return 1
        tmp="$(mktemp "$dir/.ptr.XXXXXX")" || return 1
        printf '%s\n' "$id" > "$tmp" && mv "$tmp" "$ptr" || { rm -f "$tmp"; return 1; }
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# _pipeline_base_resume_id <repo> — the run id this worktree's resumes use, from its pointer.
_pipeline_base_resume_id() {
    local ptr id
    ptr="$(_pipeline_base_pointer "$1")" || return 1
    _pipeline_base_secure "$ptr" file || return 1
    id="$(head -n 1 "$ptr")"
    _pipeline_base_valid_id "$id" || return 1
    printf '%s' "$id"
}

# _pipeline_base_adopt <id> <base> <push-url> <nm> <root> — this process's state. Readonly: nothing later in this
# process can change what the judgement uses. Also exports the values for #8662 and other consumers.
_pipeline_base_adopt() {
    readonly _PB_RUN_ID="$1" _PB_BASE="$2" _PB_PUSH_URL="$3" _PB_NM="$4" _PB_ROOT="$5" _PB_INIT_DONE=1
    export SW_PIPELINE_RUN_ID="$1" SW_PIPELINE_BASE_SHA="$2" SW_PIPELINE_PUSH_URL="$3"
}

# pipeline_base_init — the entry point, before intake. A resume reloads this worktree's run from disk (a new
# process). A fresh start creates a run, and only when the proof holds. Once a process has adopted a run, later
# calls in it change nothing.
pipeline_base_init() {
    local root="${PROJECT_ROOT:-.}" id base push nm
    if [[ -n "${_PB_INIT_DONE:-}" ]]; then return 0; fi
    unset SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    if [[ "${PIPELINE_RESUMING:-false}" == "true" || "${RESUME_FROM_CHECKPOINT:-false}" == "true" ]]; then
        id="$(_pipeline_base_resume_id "$root")" || id=""
        if [[ -n "$id" ]] && base="$(pipeline_base_get "$root" "$id")" \
            && push="$(pipeline_base_get_field "$root" "$id" push_url)" && [[ -n "$push" ]] \
            && nm="$(pipeline_base_get_field "$root" "$id" nm)" && [[ -n "$nm" ]]; then
            _pipeline_base_adopt "$id" "$base" "$push" "$nm" "$root"
            return 0
        fi
        _pipeline_base_fail "no valid base record for this worktree's run: the test stage is blocked. Start the pipeline again from a clean branch at ${BASE_BRANCH:-main}, or restore the run's record."
        return 1
    fi
    _pipeline_base_expire "$root"
    id="run-$(date -u +%Y%m%d%H%M%S)-$$-$RANDOM"
    if pipeline_base_record "$root" "$id" \
        && base="$(pipeline_base_get "$root" "$id")" \
        && push="$(pipeline_base_get_field "$root" "$id" push_url)" \
        && nm="$(pipeline_base_get_field "$root" "$id" nm)"; then
        _pipeline_base_adopt "$id" "$base" "$push" "$nm" "$root"
        return 0
    fi
    _pipeline_base_fail "the start could not be proved. The branch must be at the fork point of origin/${BASE_BRANCH:-main} as the remote reports it, the repository's config must not set pushurl or insteadOf, the origin URL must match the one pinned at the first start, and SHIPWRIGHT_HOME must be a real directory. The test stage is blocked."
    return 1
}

_pipeline_base_fail() {
    unset SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    # stderr: callers capture stdout (a resume's exit is judged by its status, not by captured text).
    if declare -F warn >/dev/null 2>&1; then warn "Pipeline base: $1" >&2; else echo "Pipeline base: $1" >&2; fi
}

# pipeline_base_release [repo] — remove this run's record and the worktree's pointer. Call on completion or abort,
# not on failure: a failed run stays resumable. Works after the branch changed, because the pointer is per worktree.
pipeline_base_release() {
    local root="${1:-${PROJECT_ROOT:-.}}" ptr id dir
    dir="$(_pipeline_base_dir "$root" 2>/dev/null)" || dir=""
    ptr="$(_pipeline_base_pointer "$root" 2>/dev/null)" || ptr=""
    if [[ -n "$ptr" && -f "$ptr" && ! -L "$ptr" ]]; then
        id="$(head -n 1 "$ptr" 2>/dev/null || true)"
        if [[ -n "$dir" ]] && _pipeline_base_valid_id "$id" && [[ ! -L "$dir/$id.json" ]]; then rm -f "$dir/$id.json"; fi
        rm -f "$ptr"
    fi
    if [[ -n "$dir" && -n "${_PB_RUN_ID:-}" && -f "$dir/$_PB_RUN_ID.json" && ! -L "$dir/$_PB_RUN_ID.json" ]]; then
        rm -f "$dir/$_PB_RUN_ID.json"
    fi
    unset SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    return 0
}
