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
#  - A fresh start takes the base from the remote, and only from the remote. ls-remote, and the fetch that
#    proves the fork point, run in an empty scratch directory with no repository context: the checkout's config
#    (includes, insteadOf, sshCommand, proxies, credential helpers) is never read. The URL is SW_TRUSTED_REMOTE_URL
#    (the daemon's, authoritative), or else the origin URL pinned at the first start (<record dir>/origin.url). A
#    url.*.insteadOf in the checkout's config is evidence of tampering and refuses the start. Local refs are never
#    consulted for the base.
#  - Residual (same UID), pointing to #8706: rewriting the origin.url pin poisons a fresh start, not only a resume,
#    because the pin then names the attacker's remote. Between processes, the record and pointer are ordinary files the
#    same user can rewrite. Config and environment that the transport itself reads are also reachable by code running as
#    this user: ~/.ssh/config (ssh reads it, including ProxyCommand and LocalCommand), the environment the daemon or the
#    user passes (GIT_SSH, GIT_SSH_COMMAND, GIT_PROXY_COMMAND, SSH_AUTH_SOCK), and LaunchAgents. The proof reads no global
#    core.sshCommand, so ~/.gitconfig cannot choose the proof's ssh command, but other git calls in the pipeline do read
#    it. The agent's Edit and Write tools are denied ~/.gitconfig, ~/.config/git, ~/.ssh, ~/Library/LaunchAgents and
#    ~/.shipwright, but the Bash tool is not covered by that deny. Structurally fixing these needs state the agent cannot
#    write, which is #8706.
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
#   pipeline_base_repin [--yes] [repo]       a human's reset of the origin pin: `shipwright pipeline base-repin`.
#
# Resumes set PIPELINE_RESUMING or RESUME_FROM_CHECKPOINT. A resume never creates a record. A resume without a
# valid record fails closed, so a forged checkpoint can only lead to that path.

[[ -n "${_PIPELINE_BASE_LOADED:-}" ]] && return 0
_PIPELINE_BASE_LOADED=1

_PIPELINE_BASE_TTL_DAYS=14
_PIPELINE_BASE_TAMPER_CFG='^url\..*\.insteadof$'
_PIPELINE_BASE_NOTE_CFG='^(remote\..*\.pushurl|url\..*\.pushinsteadof)$'

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
# _pipeline_base_config_clean <repo> — a DIAGNOSTIC, not the defence. The start reads nothing from this checkout's
# config (see _pipeline_base_git). This fails early, with a clear message, when the repository's config (including
# its includes) rewrites or redirects the origin remote.
_pipeline_base_config_clean() {
    local bad note
    bad="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$1" config --local --includes --get-regexp "$_PIPELINE_BASE_TAMPER_CFG" 2>/dev/null || true)"
    bad="$bad$(GIT_NO_REPLACE_OBJECTS=1 git -C "$1" config --worktree --includes --get-regexp "$_PIPELINE_BASE_TAMPER_CFG" 2>/dev/null || true)"
    if [[ -n "$bad" ]]; then
        _PB_WHY="the checkout's config rewrites the origin URL (url.*.insteadOf), so the URL it names is not the one git would use. Remove that entry from the checkout's config, then start again"
        _PB_TAMPER=1
        return 1
    fi
    # pushurl and pushInsteadOf change only where pushes go. The proof reads only the fetch URL, so they are a note.
    note="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$1" config --local --includes --get-regexp "$_PIPELINE_BASE_NOTE_CFG" 2>/dev/null || true)"
    if [[ -n "$note" ]]; then
        echo "Pipeline base: note: the checkout sets a push-only URL (pushurl or pushInsteadOf). It does not affect the base proof." >&2
    fi
    return 0
}

# _pipeline_base_origin_url <repo> <dir> — the URL the start is proved against. SW_TRUSTED_REMOTE_URL (the daemon's)
# wins. Otherwise the repository's origin URL, read with global and system config ignored, pinned in <dir>/origin.url
# at the first start: a later start that finds another URL blocks. Delete the pin only when the remote was moved on purpose.
# _pipeline_base_origin_url <repo> <dir> — the URL the start is proved against, in _PB_URL. SW_TRUSTED_REMOTE_URL (the
# daemon's) is authoritative: it replaces the pin, so a differently spelled URL cannot block forever. Otherwise the
# origin URL is read from this repository's own config without following includes, and pinned in <dir>/origin.url at
# the first start. A later start that finds another URL blocks. Rewriting the pin poisons a fresh start, as well as a
# resume (a same-UID residual, see the header).
_pipeline_base_origin_url() {
    local repo="$1" dir="$2" url="" pin="$2/origin.url" tmp
    if [[ -n "${SW_TRUSTED_REMOTE_URL:-}" ]]; then
        url="$SW_TRUSTED_REMOTE_URL"
        tmp="$(mktemp "$dir/.origin.XXXXXX")" || { _PB_WHY="the origin URL pin could not be written"; return 1; }
        if printf '%s\n' "$url" > "$tmp" && mv "$tmp" "$pin"; then _PB_URL="$url"; return 0; fi
        rm -f "$tmp"; _PB_WHY="the origin URL pin could not be written"; return 1
    fi
    url="$(cd "$repo" && GIT_NO_REPLACE_OBJECTS=1 git config --local --get remote.origin.url 2>/dev/null || true)"
    if [[ -z "$url" ]]; then
        _PB_WHY="there is no origin remote, so the base cannot be proved against the remote"
        return 1
    fi
    if [[ -e "$pin" || -L "$pin" ]]; then
        _pipeline_base_secure "$pin" file || { _PB_WHY="the origin URL pin is not a private file"; return 1; }
        if [[ "$(head -n 1 "$pin")" != "$url" ]]; then
            _PB_WHY="the origin URL differs from the one pinned at the first start. If the change is deliberate (a rename, or https to ssh), a person runs: shipwright pipeline base-repin"
            _PB_TAMPER=1
            return 1
        fi
    else
        tmp="$(mktemp "$dir/.origin.XXXXXX")" || { _PB_WHY="the origin URL pin could not be written"; return 1; }
        if printf '%s\n' "$url" > "$tmp" && mv "$tmp" "$pin"; then :; else rm -f "$tmp"; _PB_WHY="the origin URL pin could not be written"; return 1; fi
    fi
    _PB_URL="$url"
}

# _pipeline_base_git_raw <scratch> <git args...> — git with no repository and no config from this checkout. The
# command runs in an empty scratch directory, with GIT_DIR and the other GIT_* repository variables unset, and
# GIT_CEILING_DIRECTORIES set so git cannot discover a repository. Global and system config are ignored. The overrides
# below clear what could redirect the connection (ssh, proxies, credential helpers, a file-protocol allowance).
_pipeline_base_git_raw() {
    local scratch="$1"; shift
    local -a cfg
    local n=0 pair
    # Overrides go in through GIT_CONFIG_COUNT (git 2.31+), which the checkout's files cannot reach. Each one clears
    # what could redirect the connection or the object reads: credentials, proxies, the file-protocol allowance, hooks,
    # fsmonitor, the commit-graph (a forged graph can change ancestry answers), and the low-speed bounds.
    cfg=(credential.helper= core.askPass= http.extraheader= http.proxy= https.proxy= core.gitProxy=
         protocol.file.allow=user core.hooksPath=/dev/null core.fsmonitor=false core.commitGraph=false
         http.lowSpeedLimit=1000 http.lowSpeedTime=30)
    # The ssh command is the user's own only through the environment: GIT_SSH_COMMAND and GIT_SSH are honoured as they
    # are. Without either, the default is ssh with BatchMode (no prompt can hang the pipeline). The global config's
    # core.sshCommand is not read: a file an agent could write must not choose the command the proof runs.
    if [[ -n "$_PB_SSH_CMD" ]]; then
        cfg=("${cfg[@]}" "core.sshCommand=$_PB_SSH_CMD")
    fi
    local -a envs=()
    for pair in "${cfg[@]}"; do
        envs=(${envs[@]+"${envs[@]}"} "GIT_CONFIG_KEY_$n=${pair%%=*}" "GIT_CONFIG_VALUE_$n=${pair#*=}")
        n=$((n + 1))
    done
    (
        cd "$scratch" || exit 1
        # GIT_SSH, GIT_SSH_COMMAND, GIT_PROXY_COMMAND and SSH_AUTH_SOCK are kept (the user's transport, as `git push`
        # would use it). HOME is kept, so ~/.ssh/config is read by ssh.
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
            -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS \
            -u GIT_EXEC_PATH -u GIT_TEMPLATE_DIR -u GIT_NAMESPACE \
            GIT_CEILING_DIRECTORIES="$scratch" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_COUNT="$n" ${envs[@]+"${envs[@]}"} \
            GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 \
            git "$@"
    )
}

# _pipeline_base_user_ssh — the ssh command the transport gets from the pipeline's own environment (not the repository,
# and not the global config). Empty when the environment already sets GIT_SSH_COMMAND or GIT_SSH, so those are used as set.
_pipeline_base_user_ssh() {
    if [[ -n "${GIT_SSH_COMMAND:-}" || -n "${GIT_SSH:-}" ]]; then
        return 0
    fi
    printf '%s' 'ssh -o BatchMode=yes -o ConnectTimeout=20'
}


# _pipeline_base_git <scratch> <git args...> — _pipeline_base_git_raw, inside the gate's credential scrub when loaded.
_pipeline_base_git() {
    local ssh_cmd
    ssh_cmd="$(_pipeline_base_user_ssh)"
    if declare -F sw_test_gate_env >/dev/null 2>&1; then
        _PB_SSH_CMD="$ssh_cmd" sw_test_gate_env _pipeline_base_git_raw "$@"
    else
        _PB_SSH_CMD="$ssh_cmd" _pipeline_base_git_raw "$@"
    fi
}

# _pipeline_base_scrub <dir> — remove a temporary directory this file created.
_pipeline_base_scrub() {
    case "$1" in
        "${TMPDIR:-/tmp}"/sw-base-proof.*) [[ -d "$1" && ! -L "$1" ]] && rm -rf "$1" ;;
    esac
    return 0
}

# _pipeline_base_remote_sha <url> <branch> — the remote's head of the branch, from ls-remote. Global and system
# config are ignored, so the agent's config cannot rewrite the URL or the credentials used.
# _pipeline_base_remote_sha <url> <branch> <scratch> — the remote's head of the branch, from ls-remote, run in isolation.
_pipeline_base_remote_sha() {
    local url="$1" branch="$2" scratch="$3" sha
    sha="$(_pipeline_base_git "$scratch" ls-remote --heads "$url" "refs/heads/$branch" 2>/dev/null |
        BR="$branch" awk 'BEGIN { want = "refs/heads/" ENVIRON["BR"] } $2 == want { print $1; exit }')" || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && printf '%s' "$sha"
}

# _pipeline_base_proof <repo> <url> — the base for a fresh start. HEAD must be the fork point of the remote's base
# branch, so the branch has no commits beyond it. Prints HEAD. Local refs and replace objects are not consulted.
# _pipeline_base_proof <repo> <url> — the base for a fresh start, in _PB_BASE_SHA: HEAD, when HEAD is the fork point of the remote's
# base branch. The remote's history is fetched into a temporary bare repository, which reads the local objects through
# an alternates file (no config of this checkout is read, and no transport runs in it). Its merge-base with HEAD must be
# HEAD. Local refs and replace objects are not consulted for the base.
_pipeline_base_proof() {
    local repo="$1" url="$2" branch sha head fork scratch proof objdir
    branch="${BASE_BRANCH:-main}"
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/sw-base-proof.XXXXXX")" || { _PB_WHY="no temporary directory for the proof"; return 1; }
    proof="$scratch/proof.git"
    _PB_WHY="the branch is not at the fork point of origin/$branch as the remote reports it, or the remote could not be read"
    sha="$(_pipeline_base_remote_sha "$url" "$branch" "$scratch")" || sha=""
    [[ -n "$sha" ]] || { _pipeline_base_scrub "$scratch"; return 1; }
    head="$(cd "$repo" && GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify -q HEAD 2>/dev/null)" || head=""
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { _pipeline_base_scrub "$scratch"; return 1; }
    objdir="$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)/objects" 2>/dev/null && pwd -P)" || objdir=""
    [[ -n "$objdir" ]] || { _pipeline_base_scrub "$scratch"; return 1; }
    fork=""
    if _pipeline_base_git "$scratch" init -q --bare "$proof" \
        && printf '%s\n' "$objdir" > "$proof/objects/info/alternates" \
        && _pipeline_base_git "$scratch" --git-dir="$proof" fetch -q --no-tags --no-write-fetch-head "$url" "$sha" >/dev/null 2>&1; then
        fork="$(_pipeline_base_git "$scratch" --git-dir="$proof" merge-base "$head" "$sha" 2>/dev/null)" || fork=""
    fi
    _pipeline_base_scrub "$scratch"
    [[ -n "$fork" && "$fork" == "$head" ]] || return 1
    _PB_BASE_SHA="$head"
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
    _PB_WHY=""
    _PB_TAMPER=""
    _pipeline_base_valid_id "$id" || { _PB_WHY="the run id is not valid"; return 1; }
    dir="$(_pipeline_base_prepare "$repo")" || { _PB_WHY="the record directories are not private directories of this user (a link, another owner, or a mode other than 0700)"; return 1; }
    file="$dir/$id.json"
    [[ ! -e "$file" && ! -L "$file" ]] || { _PB_WHY="a record for this run already exists"; return 1; }
    _pipeline_base_config_clean "$repo" || return 1
    _pipeline_base_origin_url "$repo" "$dir" || return 1
    url="$_PB_URL"
    _pipeline_base_proof "$repo" "$url" || return 1
    base="$_PB_BASE_SHA"
    nm="$(_pipeline_base_nm_fingerprint "$repo")" || { _PB_WHY="node_modules could not be fingerprinted (the walk timed out or the tree is unreadable)"; return 1; }
    top="$(_pipeline_base_top "$repo")" || { _PB_WHY="the worktree path could not be read"; return 1; }
    common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || { _PB_WHY="the git directory could not be read"; return 1; }
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    tmp="$(mktemp "$dir/.base.XXXXXX")" || { _PB_WHY="the record could not be written"; return 1; }
    if jq -n --arg repo "$common" --arg wt "$top" --arg run "$id" --arg base "$base" --arg url "$url" \
        --arg branch "$branch" --arg nm "$nm" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: 1, repo: $repo, worktree: $wt, run: $run, base: $base, remote: $url, push_url: $url, branch: $branch, nm: $nm, created_at: $at}' \
        > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"; then
        ptr="$(_pipeline_base_pointer "$repo")" || { _PB_WHY="the pointer path could not be read"; return 1; }
        tmp="$(mktemp "$dir/.ptr.XXXXXX")" || { _PB_WHY="the pointer could not be written"; return 1; }
        printf '%s\n' "$id" > "$tmp" && mv "$tmp" "$ptr" || { rm -f "$tmp"; _PB_WHY="the pointer could not be written"; return 1; }
        return 0
    fi
    rm -f "$tmp"
    _PB_WHY="the record could not be written"
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
    if [[ "${_PB_TAMPER:-}" == 1 ]]; then
        _pipeline_base_fail "refusing to start: ${_PB_WHY}. This is evidence that the checkout was altered, so the pipeline does not run."
        return 2
    fi
    _pipeline_base_fail "the start could not be proved: ${_PB_WHY:-unknown reason}. The test stage blocks failing tests only; the pipeline still runs, and passing tests pass."
    return 1
}

_pipeline_base_fail() {
    unset SW_PIPELINE_RUN_ID SW_PIPELINE_BASE_SHA SW_PIPELINE_PUSH_URL
    # stderr: callers capture stdout (a resume's exit is judged by its status, not by captured text).
    if declare -F warn >/dev/null 2>&1; then warn "Pipeline base: $1" >&2; else echo "Pipeline base: $1" >&2; fi
}

# pipeline_base_repin [--yes] [repo] — the explicit reset of the origin pin, for a deliberate change of remote (a
# rename, or https to ssh). A human runs it: `shipwright pipeline base-repin`. The pipeline never does. It prints the old
# and new URLs, asks for a typed "yes" on the terminal (or --yes), and appends a line to <record dir>/repin.log.
# Agents are denied this command in config/agent-permissions.json and src/adapters/agent/agent-permissions.ts. That
# string match is defence in depth, not the boundary: an agent that sources this library can still call the function.
pipeline_base_repin() {
    local yes=0 repo="" arg dir pin old="" new logf reply tmp
    for arg in "$@"; do
        case "$arg" in
            --yes) yes=1 ;;
            *) repo="$arg" ;;
        esac
    done
    repo="${repo:-${PROJECT_ROOT:-.}}"
    dir="$(_pipeline_base_prepare "$repo")" || { echo "base-repin: the record directory is not a private directory of this user" >&2; return 1; }
    pin="$dir/origin.url"
    if [[ -n "${SW_TRUSTED_REMOTE_URL:-}" ]]; then
        new="$SW_TRUSTED_REMOTE_URL"
    else
        new="$(cd "$repo" && git config --local --get remote.origin.url 2>/dev/null || true)"
    fi
    [[ -n "$new" ]] || { echo "base-repin: there is no origin remote to pin" >&2; return 1; }
    if [[ -f "$pin" && ! -L "$pin" ]]; then old="$(head -n 1 "$pin")"; fi
    echo "Pinned origin URL: ${old:-(none)}"
    echo "New origin URL:    $new"
    if [[ "$old" == "$new" ]]; then echo "Already pinned to this URL; nothing to change."; return 0; fi
    if [[ "$yes" -ne 1 ]]; then
        { : < /dev/tty; } 2>/dev/null || { echo "base-repin: confirming needs a terminal; pass --yes to confirm non-interactively" >&2; return 1; }
        printf 'Repin the base record of %s to the new URL? Type yes to confirm: ' "$repo" > /dev/tty
        read -r reply < /dev/tty || reply=""
        [[ "$reply" == "yes" ]] || { echo "base-repin: not confirmed; nothing changed" >&2; return 1; }
    fi
    tmp="$(mktemp "$dir/.origin.XXXXXX")" || { echo "base-repin: could not write the pin" >&2; return 1; }
    if printf '%s\n' "$new" > "$tmp" && mv "$tmp" "$pin"; then :; else rm -f "$tmp"; echo "base-repin: could not write the pin" >&2; return 1; fi
    logf="$dir/repin.log"
    ( umask 077; printf '%s user=%s old=%s new=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un)" "${old:-none}" "$new" >> "$logf" )
    chmod 600 "$logf" 2>/dev/null || true
    echo "Repinned. The change is in $logf."
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
