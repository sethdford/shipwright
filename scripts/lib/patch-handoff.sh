#!/usr/bin/env bash
# patch-handoff.sh — the agent's work crosses into the trusted pipeline only as a patch (#8706).
#
# Before: the build agent and the trusted pipeline shared one checkout, one git dir and one
# .claude/ directory, so the agent could steer what the pipeline did next (git config, hooks,
# fsmonitor, remotes, refs, HEAD, state files). Each review closed one path and found another.
#
# Now the structure is:
#   1. handoff_prepare   makes a disposable clone of the recorded base sha for the agent. It has no
#                        remote and no credentials. The trusted checkout is never given to the agent.
#   2. handoff_export    turns the agent's directory into a patch. It treats that directory as plain
#                        files: it uses a scratch git dir the pipeline owns, never the agent's .git,
#                        so the agent's config, hooks, filters, refs and replace objects do nothing.
#   3. handoff_judge     judges the patch as data, before it touches the trusted checkout: no
#                        symlinks, submodules or unexpected binaries, no protected paths, and file,
#                        added-line and deleted-line budgets (the blast-radius guard).
#   4. handoff_apply     applies a judged patch to the trusted checkout (clean, at the base sha)
#                        and commits it as the pipeline. Delivery pushes that commit.
#
# Every git call on the trusted side runs through _handoff_git: no system or global config, no
# replace objects, hooks/fsmonitor/ssh/external diff off, attributes only from an empty tree.
#
# Scope: this separates the trusted pipeline from what the agent writes. The agent still runs as
# the same OS user; isolation from the host is the sandbox backends' job (roadmap item 5).
#
# Requires git 2.40+ (--attr-source). Bash 3.2 compatible.
[[ -n "${_PATCH_HANDOFF_LOADED:-}" ]] && return 0
_PATCH_HANDOFF_LOADED=1

HANDOFF_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# Budgets (blast radius). Callers may lower them per task type; the env can only set them.
HANDOFF_MAX_FILES="${HANDOFF_MAX_FILES:-60}"
HANDOFF_MAX_ADDED="${HANDOFF_MAX_ADDED:-3000}"
HANDOFF_MAX_DELETED="${HANDOFF_MAX_DELETED:-800}"
HANDOFF_ALLOW_BINARY="${HANDOFF_ALLOW_BINARY:-false}"

# Paths the agent may not change at all through the handoff. Glob semantics: bash [[ == ]], so
# `*` also crosses `/`. A human changes these, not the build agent.
HANDOFF_PROTECTED_DEFAULT='.git/*
.github/workflows/*
.github/actions/*
.claude/settings*.json
.claude/hooks/*
.claude/agents/*
.claude/rules/*
.claude/skills/*
config/agent-permissions.json
config/policy.json
scripts/lib/patch-handoff.sh
scripts/lib/untrusted.sh
scripts/lib/agent-exec.sh
scripts/ci/*
tools/arch/*
docs/adr/*
.gitattributes
*/.gitattributes
.gitmodules
CODEOWNERS
.github/CODEOWNERS'
HANDOFF_PROTECTED="${HANDOFF_PROTECTED:-$HANDOFF_PROTECTED_DEFAULT}"

# Never part of the agent's output: .claude/ holds loop and pipeline runtime state (logs, state
# files, artifacts) and agent configuration. Runtime state is not code, and the configuration is
# for humans to change. Changes there are dropped, not delivered.
HANDOFF_EXCLUDE_PATHSPEC=(':(exclude,top).claude')

_handoff_err() { printf 'patch-handoff: %s\n' "$*" >&2; }

# _handoff_git ARGS... — git with nothing from the environment, system, user or repo that could run
# code or change what a diff says. Callers set GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE explicitly.
_handoff_git() {
    env -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
        -u GIT_EXEC_PATH -u GIT_TEMPLATE_DIR -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_EXTERNAL_DIFF -u GIT_SSH -u GIT_SSH_COMMAND -u GIT_ASKPASS -u SSH_ASKPASS \
        -u GIT_PAGER -u PAGER -u GIT_EDITOR -u GIT_SEQUENCE_EDITOR \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
        GIT_ATTR_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1 \
        git --no-replace-objects --attr-source="$HANDOFF_EMPTY_TREE" \
        -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false \
        -c core.sshCommand=false -c core.attributesFile=/dev/null -c core.excludesFile=/dev/null \
        -c core.symlinks=true -c core.autocrlf=false -c core.safecrlf=false \
        -c diff.external= -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false \
        -c commit.gpgSign=false -c user.useConfigOnly=false \
        "$@"
}

# _handoff_in REPO ARGS... — _handoff_git in REPO (a checkout or linked worktree), with any
# inherited GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE cleared so discovery finds REPO itself.
_handoff_in() {
    local repo="$1"
    shift
    (cd "$repo" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && _handoff_git "$@")
}

# handoff_check_git — fail closed on a git without --attr-source.
handoff_check_git() {
    if ! _handoff_git --version >/dev/null 2>&1; then
        _handoff_err "git 2.40+ is required (--attr-source)"
        return 1
    fi
}

# handoff_prepare TRUSTED_REPO BASE_SHA AGENT_DIR — a disposable clone at BASE_SHA, detached, with
# no remote. AGENT_DIR must not exist yet.
handoff_prepare() {
    local trusted="$1" base="$2" dir="$3"
    handoff_check_git || return 1
    [[ "$base" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || { _handoff_err "base must be a full sha: $base"; return 1; }
    [[ -e "$dir" ]] && { _handoff_err "agent dir already exists: $dir"; return 1; }
    _handoff_in "$trusted" cat-file -e "${base}^{commit}" 2>/dev/null \
        || { _handoff_err "base $base is not a commit in $trusted"; return 1; }
    _handoff_git clone -q --no-hardlinks --no-checkout --no-tags "$trusted" "$dir" \
        || { _handoff_err "clone failed"; return 1; }
    (_handoff_in "$dir" remote remove origin \
        && _handoff_in "$dir" -c advice.detachedHead=false checkout -q --detach "$base") \
        || { _handoff_err "checkout of $base failed"; return 1; }
}

# handoff_carry_over TRUSTED_REPO BASE_SHA AGENT_DIR OUT_PATCH — moves uncommitted work out of the
# trusted checkout and into the agent's clone. Earlier stages (plan, design, spec) run agents in the
# trusted checkout, and what they wrote there is untrusted too: carried over, it is judged with the
# build agent's work instead of riding along unjudged. Tracked files are reset to HEAD; untracked,
# non-ignored files outside .claude/ are moved (their paths are listed in OUT_PATCH.moved).
handoff_carry_over() {
    local trusted="$1" base="$2" dir="$3" out="$4"
    handoff_export "$trusted" "$base" "$trusted" "$out" || return 1
    [[ -s "$out" ]] || return 0
    _handoff_in "$dir" apply --index --binary --whitespace=nowarn "$out" \
        || { _handoff_err "could not carry the trusted checkout's changes into the agent clone"; return 1; }
    _handoff_clean_trusted "$trusted" "$out.moved"
}

# _handoff_clean_trusted TRUSTED_REPO MOVED_LIST — resets tracked files to HEAD and deletes the
# untracked, non-ignored files outside .claude/; their paths are written to MOVED_LIST.
_handoff_clean_trusted() {
    local trusted="$1" moved="$2"
    _handoff_in "$trusted" ls-files -z --others --exclude-standard -- . "${HANDOFF_EXCLUDE_PATHSPEC[@]}" \
        > "$moved" || return 1
    _handoff_in "$trusted" reset -q --hard HEAD || { _handoff_err "could not reset the trusted checkout"; return 1; }
    local path
    while IFS= read -r -d '' path; do
        rm -f -- "$trusted/$path"
    done < "$moved"
    tr '\0' '\n' < "$moved" > "$moved.txt" && mv "$moved.txt" "$moved"
}

# handoff_commit_dirty TRUSTED_REPO MESSAGE OUT_PATCH — commits uncommitted work in the trusted
# checkout only after the judge accepts it, as handoff_apply does for the build agent's patch.
# Replaces `git add -A && git commit`, which would publish whatever an agent left behind.
# Returns 0 with nothing printed when there is nothing to commit, 0 and the new sha on commit, and
# 1 on refusal; either way the trusted checkout is left clean (the work stays in OUT_PATCH).
handoff_commit_dirty() {
    local trusted="$1" msg="$2" out="$3"
    handoff_check_git || return 1
    local base
    base=$(_handoff_in "$trusted" rev-parse HEAD) || return 1
    handoff_export "$trusted" "$base" "$trusted" "$out" || return 1
    _handoff_clean_trusted "$trusted" "$out.moved" || return 1
    [[ -s "$out" ]] || return 0
    handoff_apply "$trusted" "$base" "$out" "$msg"
}

# handoff_export AGENT_DIR BASE_SHA TRUSTED_REPO OUT_PATCH [PATH...] — the agent's files, as a
# binary patch against BASE_SHA. With PATHs, only those repository-relative paths (taken literally,
# no globs) are read. Uses a scratch git dir whose objects borrow from TRUSTED_REPO (read only).
handoff_export() {
    local dir="$1" base="$2" trusted="$3" out="$4"
    shift 4
    handoff_check_git || return 1
    [[ -d "$dir" ]] || { _handoff_err "no agent dir: $dir"; return 1; }
    local scratch
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/sw-handoff.XXXXXX") || return 1
    local rc=0
    _handoff_export_in "$scratch" "$dir" "$base" "$trusted" "$out" "$@" || rc=$?
    rm -rf "$scratch"
    return "$rc"
}

_handoff_export_in() {
    local scratch="$1" dir="$2" base="$3" trusted="$4" out="$5"
    shift 5
    local specs=(.) p
    if [[ $# -gt 0 ]]; then
        specs=()
        for p in "$@"; do specs+=(":(literal,top)$p"); done
    fi
    local gd="$scratch/git"
    _handoff_git init -q --bare "$gd" || return 1
    local objects
    objects=$(_handoff_in "$trusted" rev-parse --path-format=absolute --git-common-dir) || return 1
    objects="$objects/objects"
    printf '%s\n' "$objects" > "$gd/objects/info/alternates"
    # The scratch index starts at the base tree; `add -A` records the agent's files as they are.
    GIT_DIR="$gd" GIT_INDEX_FILE="$scratch/index" _handoff_git read-tree "$base" || return 1
    GIT_DIR="$gd" GIT_WORK_TREE="$dir" GIT_INDEX_FILE="$scratch/index" \
        _handoff_git add -A -- "${specs[@]}" "${HANDOFF_EXCLUDE_PATHSPEC[@]}" \
        || { _handoff_err "could not read the agent's files"; return 1; }
    local tmp="$out.tmp.$$"
    GIT_DIR="$gd" GIT_WORK_TREE="$dir" GIT_INDEX_FILE="$scratch/index" \
        _handoff_git diff --cached --binary --full-index --no-renames --no-ext-diff --no-textconv \
        --no-color "$base" -- > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$out"
}

# _handoff_stats PATCH — one line per file: "<added>\t<deleted>\t<path>" (binary: "-\t-\t<path>").
# A path with a control character, quote or backslash is printed C-quoted ("...") and refused.
_handoff_stats() {
    local scratch rc=0
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/sw-handoff-judge.XXXXXX") || return 1
    (cd "$scratch" && GIT_DIR="$scratch/g" _handoff_git init -q --bare "$scratch/g" \
        && GIT_DIR="$scratch/g" _handoff_git apply --numstat --allow-empty "$1") || rc=$?
    rm -rf "$scratch"
    return "$rc"
}

_handoff_protected() {
    local path="$1" glob
    while IFS= read -r glob; do
        [[ -z "$glob" ]] && continue
        # shellcheck disable=SC2053
        [[ "$path" == $glob ]] && return 0
    done <<< "$HANDOFF_PROTECTED"
    return 1
}

# handoff_judge PATCH — prints one line per violation and returns 1 when there is any.
handoff_judge() {
    local patch="$1" violations=""
    [[ -f "$patch" ]] || { echo "no patch file"; return 1; }
    [[ -s "$patch" ]] || return 0
    local v
    if v=$(_handoff_judge_modes "$patch"); then violations="$v"; fi
    local stats
    stats=$(_handoff_stats "$patch") || { echo "patch does not parse"; return 1; }
    v=$(_handoff_judge_stats "$stats") || violations="${violations:+$violations
}$v"
    [[ -z "$violations" ]] && return 0
    printf '%s\n' "$violations"
    return 1
}

# Symlinks (120000) and submodules (160000) can point the trusted side outside the tree.
_handoff_judge_modes() {
    local found
    found=$(grep -E '^(new file mode|new mode|deleted file mode|old mode|index [0-9a-f]+\.\.[0-9a-f]+) (.* )?1[26]0000$' "$1" || true)
    [[ -z "$found" ]] && return 1
    echo "symlink or submodule entry in patch"
    return 0
}

_handoff_judge_stats() {
    local stats="$1" files=0 added=0 deleted=0 out="" a d p
    while IFS=$'\t' read -r a d p; do
        [[ -z "$p" ]] && continue
        files=$((files + 1))
        [[ "$p" == \"* ]] && out="${out}unusual path (quoted by git): ${p}"$'\n'
        if [[ "$a" == "-" ]]; then
            [[ "$HANDOFF_ALLOW_BINARY" == "true" ]] || out="${out}binary change: ${p}"$'\n'
        else
            added=$((added + a)); deleted=$((deleted + d))
        fi
        _handoff_protected "$p" && out="${out}protected path: ${p}"$'\n'
    done <<< "$stats"
    [[ "$files" -gt "$HANDOFF_MAX_FILES" ]] && out="${out}files ${files} > budget ${HANDOFF_MAX_FILES}"$'\n'
    [[ "$added" -gt "$HANDOFF_MAX_ADDED" ]] && out="${out}added lines ${added} > budget ${HANDOFF_MAX_ADDED}"$'\n'
    [[ "$deleted" -gt "$HANDOFF_MAX_DELETED" ]] && out="${out}deleted lines ${deleted} > budget ${HANDOFF_MAX_DELETED}"$'\n'
    [[ -z "$out" ]] && return 0
    printf '%s' "$out"
    return 1
}

# handoff_apply TRUSTED_REPO BASE_SHA PATCH MESSAGE — applies a judged patch to the trusted
# checkout, which must be clean and at BASE_SHA, and commits it. Prints the new commit sha.
handoff_apply() {
    local repo="$1" base="$2" patch="$3" msg="$4"
    handoff_check_git || return 1
    local head
    head=$(_handoff_in "$repo" rev-parse HEAD) || return 1
    [[ "$head" == "$base" ]] || { _handoff_err "trusted checkout is at $head, not the base $base"; return 1; }
    local dirty
    dirty=$(_handoff_in "$repo" status --porcelain --untracked-files=no) || return 1
    [[ -z "$dirty" ]] || {
        _handoff_err "trusted checkout has uncommitted changes: $(printf '%s' "$dirty" | head -5 | tr '\n' ';')"
        return 1
    }
    local why
    if ! why=$(handoff_judge "$patch"); then
        _handoff_err "patch refused: $(printf '%s' "$why" | tr '\n' ';')"
        return 1
    fi
    [[ -s "$patch" ]] || { _handoff_err "empty patch: nothing to apply"; return 1; }
    _handoff_in "$repo" apply --index --binary --whitespace=nowarn "$patch" \
        || { _handoff_err "patch does not apply to $base"; return 1; }
    local who="${HANDOFF_AUTHOR_NAME:-shipwright-pipeline}" mail="${HANDOFF_AUTHOR_EMAIL:-pipeline@shipwright.local}"
    GIT_AUTHOR_NAME="$who" GIT_AUTHOR_EMAIL="$mail" GIT_COMMITTER_NAME="$who" GIT_COMMITTER_EMAIL="$mail" \
        _handoff_in "$repo" commit -q --no-verify -m "$msg" || { _handoff_err "commit failed"; return 1; }
    _handoff_in "$repo" rev-parse HEAD
}
