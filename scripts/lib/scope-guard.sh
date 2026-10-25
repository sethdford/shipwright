#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#   scope-guard.sh — blast-radius guard for the build loop (#8644)
#
#   TRUST MODEL. The agent runs inside the loop's repo and can write any file in it, including
#   .claude/. So nothing the guard trusts is read back from the repo or the loop's logs after the run
#   starts. The config is read once from the base commit (or the install copy when the project has
#   none), the scope is resolved once, and both are held in shell globals of the loop process.
#   Strikes are a global counter. Evidence files are written for humans and never read back.
#
#   A scope is a set of allowed path globs plus file, added-line and deleted-line budgets. Every
#   input can only TIGHTEN it: the deterministic type from the goal, the label type, the intake type
#   and a spec's `.scope` are combined by taking the strictest, and each spec number is min(model,
#   default). After each loop commit the guard diffs base..HEAD. A violation (path outside scope,
#   protected path deleted or modified, binary or symlink or submodule change, budget overrun)
#   reverts this iteration (git reset --hard to the pre-iteration sha, only on the loop's own branch
#   and only when the tree was clean at start or the loop has its own worktree). Two strikes block.
#
#   GLOBS. `*` matches within one path segment, `**` crosses `/`, and `**/` matches zero or more
#   directories. `*.md` therefore means the repo-root .md files only.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

[[ -n "${_SCOPE_GUARD_LOADED:-}" ]] && return 0
_SCOPE_GUARD_LOADED=1

# ─── Trusted state (loop process memory) ─────────────────────────────────────

SCOPE_CONFIG=""            # config JSON, loaded once
SCOPE_CONFIG_SOURCE=""     # "base:<sha>" or "install"
SCOPE_PROTECTED_LIST=""    # newline list from config
SCOPE_RUNTIME_LIST=""      # newline list from config
SCOPE_JSON=""              # the resolved scope for this run
SCOPE_STRIKES=0            # blast-radius strikes for this run
SCOPE_NOTE=""              # scope note for the next prompt, set after a revert
SCOPE_CAN_REVERT=0         # 1 when a revert is safe (own worktree, or clean tree at start)
SCOPE_LOOP_BRANCH=""       # symbolic ref the loop commits to
SCOPE_META_SNAPSHOT=""  # .git/config checksum and attributes state at setup

# Every git call the guard makes runs with the system and global config disabled, so a machine-wide
# or user-wide setting (attributes file, diff driver, excludes) cannot change how a change is judged.
_scope_git() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git "$@"
}

_scope_install_config() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/scope-budgets.json"
}

# Set the config globals from a JSON string. Returns 1 when the JSON has no types table.
_scope_set_config_json() {
    local json="$1"
    if ! jq -e '(.types | type) == "object" and (.protected_paths | type) == "array"' <<< "$json" >/dev/null 2>&1; then
        return 1
    fi
    SCOPE_CONFIG="$json"
    SCOPE_PROTECTED_LIST="$(jq -r '.protected_paths[]' <<< "$json")"
    SCOPE_RUNTIME_LIST="$(jq -r '(.runtime_paths // [])[]' <<< "$json")"
    return 0
}

# Load the config ONCE: from the base commit when the project has one, else from the install copy.
# Working-tree edits never count. Call from the loop's top-level shell, never inside $( ).
scope_load_config() {
    local repo="$1" base="${2:-}" json=""
    if [[ -n "$base" ]]; then
        json="$(_scope_git -C "$repo" show "$base:config/scope-budgets.json" 2>/dev/null || true)"
        if [[ -n "$json" ]] && _scope_set_config_json "$json"; then
            SCOPE_CONFIG_SOURCE="base:$base"
            return 0
        fi
    fi
    json="$(cat "$(_scope_install_config)" 2>/dev/null || true)"
    if [[ -n "$json" ]] && _scope_set_config_json "$json"; then
        SCOPE_CONFIG_SOURCE="install"
        return 0
    fi
    SCOPE_CONFIG=""
    return 1
}

# Used by intake, which runs before the loop has loaded a base config.
_scope_ensure_config() {
    if [[ -z "$SCOPE_CONFIG" ]]; then
        local json
        json="$(cat "$(_scope_install_config)" 2>/dev/null || true)"
        _scope_set_config_json "$json" || return 1
        SCOPE_CONFIG_SOURCE="install"
    fi
    return 0
}

# ─── Globs ───────────────────────────────────────────────────────────────────

# Translate glob $1 into the anchored ERE in _SCOPE_RE. Pure bash: no forks.
_scope_glob_to_ere() {
    local g="$1" out="" i=0 n c nxt
    n=${#g}
    while [[ $i -lt $n ]]; do
        c="${g:$i:1}"
        case "$c" in
            '*')
                nxt="${g:$((i + 1)):1}"
                if [[ "$nxt" == "*" ]]; then
                    if [[ "${g:$((i + 2)):1}" == "/" ]]; then
                        out="${out}(.*/)?"
                        i=$((i + 3))
                        continue
                    fi
                    out="${out}.*"
                    i=$((i + 2))
                    continue
                fi
                out="${out}[^/]*"
                ;;
            '?') out="${out}[^/]" ;;
            '.'|'+'|'('|')'|'['|']'|'{'|'}'|'|'|'^'|'$'|'\') out="${out}\\${c}" ;;
            *) out="${out}${c}" ;;
        esac
        i=$((i + 1))
    done
    _SCOPE_RE="^${out}\$"
}

# True when path $1 matches glob $2.
_scope_glob_match() {
    local s="$1"
    _scope_glob_to_ere "$2"
    [[ "$s" =~ $_SCOPE_RE ]]
}

# True when path $1 matches any glob in the newline-separated list $2.
_scope_matches_any() {
    local s="$1" list="$2" p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if _scope_glob_match "$s" "$p"; then return 0; fi
    done <<< "$list"
    return 1
}

# True when the newline-separated list $1 contains the exact string $2.
_scope_list_has() {
    local list="$1" x="$2" line
    while IFS= read -r line; do
        [[ "$line" == "$x" ]] && return 0
    done <<< "$list"
    return 1
}

# Print the protected glob that matches path $1 (nothing and status 1 when none does).
_scope_protected_match() {
    local path="$1" p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if _scope_glob_match "$path" "$p"; then
            echo "$p"
            return 0
        fi
    done <<< "$SCOPE_PROTECTED_LIST"
    return 1
}

# ─── Type and scope resolution ───────────────────────────────────────────────

# Deterministic task type for a goal and comma-separated labels (no model call). Labels win over
# keywords. Anything unrecognised is "unknown", which has the strictest budget.
scope_infer_type() {
    local goal="$1" labels="${2:-}" l words padded
    while IFS= read -r l; do
        l="$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
        case "$l" in
            docs|documentation) echo "docs"; return 0 ;;
            bug|hotfix) echo "bug"; return 0 ;;
            enhancement|feature) echo "feature"; return 0 ;;
            refactor) echo "refactor"; return 0 ;;
        esac
    done <<< "$(printf '%s' "$labels" | tr ',' '\n')"

    words="$(printf '%s' "$goal" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ')"
    padded=" $words "
    case "$padded" in
        *" docs "*|*" doc "*|*" readme "*|*" runbook "*|*" documentation "*) echo "docs" ;;
        *" fix "*|*" fixes "*|*" bug "*|*" bugs "*|*" regression "*|*" hotfix "*) echo "bug" ;;
        *" refactor "*|*" refactoring "*) echo "refactor" ;;
        *" add "*|*" implement "*|*" feature "*|*" support "*|*" introduce "*) echo "feature" ;;
        *) echo "unknown" ;;
    esac
}

# The first label that names a known type, or nothing.
scope_label_type() {
    local l t=""
    while IFS= read -r l; do
        l="$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
        case "$l" in
            docs|documentation|bug|hotfix|enhancement|feature|refactor) t="$(scope_infer_type "" "$l")"; break ;;
        esac
    done <<< "$(printf '%s' "${1:-}" | tr ',' '\n')"
    echo "$t"
}

# Known type for $1: the type itself, its alias, or "unknown".
scope_canonical_type() {
    local t
    _scope_ensure_config || return 1
    t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    jq -r --arg t "$t" '
        if (.types[$t] != null) then $t
        elif (.aliases[$t] != null and .types[.aliases[$t]] != null) then .aliases[$t]
        else "unknown" end' <<< "$SCOPE_CONFIG"
}

# Default scope JSON for a type.
scope_defaults() {
    local t
    t="$(scope_canonical_type "$1")"
    jq -c --arg t "$t" '.types[$t] + {type: $t}' <<< "$SCOPE_CONFIG"
}

# Budget sum of a type: the stricter of two types is the one with the smaller sum.
scope_stricter_type() {
    local a b sa sb
    a="$(scope_canonical_type "$1")"
    b="$(scope_canonical_type "$2")"
    sa="$(jq -r '.types[$t] | .max_files_changed + .max_lines_added + .max_lines_deleted' --arg t "$a" <<< "$SCOPE_CONFIG")"
    sb="$(jq -r '.types[$t] | .max_files_changed + .max_lines_added + .max_lines_deleted' --arg t "$b" <<< "$SCOPE_CONFIG")"
    if [[ "$sb" -lt "$sa" ]]; then echo "$b"; else echo "$a"; fi
}

# Final scope JSON for a type and an optional spec file. The spec's `.scope` may only tighten:
# each number becomes min(model, default), and each model path survives only inside a default glob.
# A protected glob survives only when the default lists it literally.
scope_resolve() {
    local type="$1" spec="${2:-}" defaults model default_list kept="" kept_json p
    _scope_ensure_config || return 1
    defaults="$(scope_defaults "$type")" || return 1
    default_list="$(echo "$defaults" | jq -r '.allowed_paths[]')"
    model="null"
    if [[ -n "$spec" && -f "$spec" ]]; then
        model="$(jq -c 'if (.scope | type) == "object" then .scope else null end' "$spec" 2>/dev/null || echo "null")"
        [[ -z "$model" ]] && model="null"
    fi
    if [[ "$model" == "null" ]]; then
        echo "$defaults" | jq -c '. + {source: "default"}'
        return 0
    fi

    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _scope_matches_any "$p" "$default_list" || continue
        if [[ -n "$(_scope_protected_match "$p" || true)" ]] && ! _scope_list_has "$default_list" "$p"; then
            continue
        fi
        kept="${kept}${p}"$'\n'
    done < <(echo "$model" | jq -r 'if (.allowed_paths | type) == "array" then .allowed_paths[] | strings else empty end' 2>/dev/null || true)

    if [[ -z "$kept" ]]; then
        kept_json="$(echo "$defaults" | jq -c '.allowed_paths')"
    else
        kept_json="$(printf '%s' "$kept" | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique')"
    fi

    echo "$defaults" | jq -c --argjson m "$model" --argjson paths "$kept_json" '
        def clampn(k):
            if ($m[k] | type) == "number" and $m[k] >= 0 and $m[k] == ($m[k] | floor)
            then [$m[k], .[k]] | min else .[k] end;
        {type: .type, allowed_paths: $paths,
         max_files_changed: clampn("max_files_changed"),
         max_lines_added: clampn("max_lines_added"),
         max_lines_deleted: clampn("max_lines_deleted"),
         source: "model_clamped"}'
}

# The type for a run: the strictest of the deterministic type from the goal, the label type and the
# intake type. Labels and the model may only tighten.
scope_type_for_run() {
    local artifacts="$1" goal="$2" labels="${3:-}" t lab intk
    t="$(scope_infer_type "$goal" "")"
    lab="$(scope_label_type "$labels")"
    [[ -n "$lab" ]] && t="$(scope_stricter_type "$t" "$lab")"
    if [[ -f "$artifacts/intake.json" ]]; then
        intk="$(jq -r '.type // empty' "$artifacts/intake.json" 2>/dev/null || true)"
        [[ -n "$intk" ]] && t="$(scope_stricter_type "$t" "$intk")"
    fi
    echo "$t"
}

# Write the resolved scope into a spec file as `.scope` (in place, atomically). Intake calls this
# so the artifact records the scope; the loop resolves its own copy at start.
scope_attach_to_spec() {
    local spec="$1" type="$2" scope tmp
    [[ -f "$spec" ]] || return 1
    jq -e 'type == "object"' "$spec" >/dev/null 2>&1 || return 1
    scope="$(scope_resolve "$type" "$spec")" || return 1
    tmp="$(mktemp "${spec}.XXXXXX")"
    if jq --argjson s "$scope" '.scope = $s' "$spec" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$spec"
    else
        rm -f "$tmp"
        return 1
    fi
}

# ─── Run setup (loop start) ──────────────────────────────────────────────────

# True when the loop's repo is a linked worktree (its own checkout, safe to reset).
_scope_is_linked_worktree() {
    local repo="$1" gd cd
    gd="$(cd "$repo" && cd "$(git rev-parse --git-dir)" && pwd -P)" || return 1
    cd="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
    [[ "$gd" != "$cd" ]]
}

# The diff needs git 2.40+ (--attr-source). Probe it once per run; older git refuses to start with a
# message that names the requirement. Attributes are never read from the working tree instead.
scope_require_git() {
    local repo="$1" empty ver
    empty="$(_scope_git -C "$repo" hash-object -t tree --stdin < /dev/null 2>/dev/null)" || return 1
    if ! _scope_git -C "$repo" --attr-source="$empty" rev-parse --git-dir >/dev/null 2>&1; then
        ver="$(git --version 2>/dev/null || echo "unknown")"
        echo "blast-radius guard requires git >= 2.40 (--attr-source); found: ${ver}. Upgrade git to run the build loop." >&2
        return 1
    fi
    return 0
}

# Resolve everything the guard trusts, once, at loop start. Returns 1 to refuse the run.
#   $1 repo, $2 base sha (LOOP_START_COMMIT), $3 artifacts dir, $4 goal, $5 labels
scope_setup_run() {
    local repo="$1" base="${2:-}" artifacts="$3" goal="${4:-}" labels="${5:-}" restart="${6:-0}" type dirty
    # An in-process restart keeps the trusted state of the run it continues (clean start, same base).
    if [[ "$restart" != "1" ]]; then
        SCOPE_CAN_REVERT=0
    fi
    SCOPE_JSON=""
    if [[ -z "$base" ]] || ! _scope_git -C "$repo" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1; then
        return 1
    fi
    # The base must be an ancestor of HEAD. A base the agent forged onto a commit it made is still an
    # ancestor, so the base itself must come from a trusted source (see the loop's resume path).
    if ! _scope_git -C "$repo" merge-base --is-ancestor "$base" HEAD >/dev/null 2>&1; then
        echo "blast-radius guard: base ${base} is not an ancestor of HEAD" >&2
        return 1
    fi
    scope_require_git "$repo" || return 1
    scope_load_config "$repo" "$base" || return 1
    type="$(scope_type_for_run "$artifacts" "$goal" "$labels")"
    SCOPE_JSON="$(scope_resolve "$type" "$artifacts/spec.json")" || return 1

    SCOPE_LOOP_BRANCH="$(_scope_git -C "$repo" symbolic-ref -q HEAD 2>/dev/null || true)"
    [[ -n "$SCOPE_LOOP_BRANCH" ]] || return 1
    SCOPE_META_SNAPSHOT="$(_scope_git_meta "$repo")" || return 1
    if [[ "$SCOPE_META_SNAPSHOT" == *ATTR* ]]; then
        echo "blast-radius guard: .git/info/attributes is not empty; remove it before the loop starts" >&2
        return 1
    fi
    if [[ "$restart" == "1" ]]; then
        export SW_SCOPE_JSON="$SCOPE_JSON" SW_SCOPE_CONFIG="$SCOPE_CONFIG" SW_SCOPE_BASE="$base"
        return 0
    fi
    # Reverting resets the checkout. Allowed in the loop's own worktree, or when no unrelated work is
    # pending (the .claude/ bookkeeping of this run is excluded).
    if _scope_is_linked_worktree "$repo"; then
        SCOPE_CAN_REVERT=1
    else
        dirty="$(_scope_git -C "$repo" status --porcelain -- . ':!.claude' 2>/dev/null || true)"
        if [[ -n "$dirty" ]]; then return 1; fi
        SCOPE_CAN_REVERT=1
    fi
    export SW_SCOPE_JSON="$SCOPE_JSON" SW_SCOPE_CONFIG="$SCOPE_CONFIG" SW_SCOPE_BASE="$base"
    return 0
}

# Snapshot of the git metadata the guard relies on: .git/config and whether info/attributes is
# non-empty. An agent that edits either could change how changes are counted, so each check compares.
_scope_git_meta() {
    local repo="$1" gd sum=""
    gd="$(_scope_git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    sum="$(cksum < "$gd/config" 2>/dev/null || echo none)"
    if [[ -s "$gd/info/attributes" ]]; then
        printf 'ATTR %s\n' "$sum"
    else
        printf '%s\n' "$sum"
    fi
}

# Strikes restart with each fresh run. A resumed process starts again at zero: see the PR notes.
scope_reset_strikes() {
    SCOPE_STRIKES=0
    return 0
}

# ─── Diff classification ─────────────────────────────────────────────────────

# True when git blob $2 in repo $1 contains a NUL byte.
_scope_blob_is_binary() {
    local repo="$1" sha="$2" tmp n
    tmp="$(mktemp "${TMPDIR:-/tmp}/scope-blob.XXXXXX")"
    if ! _scope_git -C "$repo" cat-file blob "$sha" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    n="$(LC_ALL=C tr -cd '\000' < "$tmp" | wc -c | tr -d ' ')"
    rm -f "$tmp"
    [[ "${n:-0}" -gt 0 ]]
}

# One row per changed path: status<TAB>added<TAB>deleted<TAB>kind<TAB>path. Diffs are forced to text
# (-a, no textconv, no ext-diff) and attributes are not read from the global file, so an in-tree
# .gitattributes cannot make a change count as zero lines. Kinds: ok, binary (added or modified
# binary blob), symlink, submodule. A deleted binary is counted by its old blob's line count.
# Head "INDEX" diffs the staged index against base (used by workers before a commit).
scope_diff_rows() {
    local repo="$1" base="$2" head="$3" raw num
    local -a args
    if [[ "$head" == "INDEX" ]]; then args=(--cached "$base"); else args=("$base" "$head"); fi
    # --attr-source reads attributes from the empty tree, so an in-tree .gitattributes (-diff, binary,
    # text, eol) cannot change how a change is counted. Needs git 2.40+; older git fails closed.
    if [[ -z "${_SCOPE_EMPTY_TREE:-}" ]]; then
        _SCOPE_EMPTY_TREE="$(_scope_git -C "$repo" hash-object -t tree --stdin < /dev/null)" || return 1
    fi
    local empty="$_SCOPE_EMPTY_TREE"
    raw="$(_scope_git -C "$repo" --attr-source="$empty" -c core.attributesFile=/dev/null -c core.quotePath=false \
        diff -a --no-ext-diff --no-textconv --no-renames --raw "${args[@]}")" || return 1
    num="$(_scope_git -C "$repo" --attr-source="$empty" -c core.attributesFile=/dev/null -c core.quotePath=false \
        diff -a --no-ext-diff --no-textconv --no-renames --numstat "${args[@]}")" || return 1
    {
        printf '%s\n' "$raw" | awk 'NF { print "R\t" $0 }'
        printf '%s\n' "$num" | awk 'NF { print "N\t" $0 }'
    } | awk -F'\t' '
        $1 == "R" {
            split($2, f, " ")
            p = $3; for (i = 4; i <= NF; i++) p = p "\t" $i
            if (!(p in seen)) { order[++n] = p; seen[p] = 1 }
            st[p] = substr(f[5], 1, 1); nm[p] = f[2]; ns[p] = f[4]
            next
        }
        $1 == "N" {
            p = $4; for (i = 5; i <= NF; i++) p = p "\t" $i
            if (!(p in seen)) { order[++n] = p; seen[p] = 1 }
            add[p] = ($2 == "-") ? 0 : $2; del[p] = ($3 == "-") ? 0 : $3
            if ($2 == "-" || $3 == "-") dash[p] = 1
        }
        END {
            for (k = 1; k <= n; k++) {
                p = order[k]
                kind = "ok"
                # numstat "-" means git could not count lines (a driver or binary attribute, e.g. from
                # .git/info/attributes or diff.<drv>.binary). Never count that as zero lines.
                if (dash[p]) kind = "binary"
                else if (st[p] != "D") {
                    if (nm[p] == "120000") kind = "symlink"
                    else if (nm[p] == "160000") kind = "submodule"
                }
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", st[p], add[p] + 0, del[p] + 0, kind, ns[p], p
            }
        }' | while IFS=$'\t' read -r st add del kind sha path; do
            # Bookkeeping is dropped downstream; skip its binary check (a fork per row) here.
            if _scope_is_bookkeeping "$path"; then
                printf '%s\t%s\t%s\t%s\t%s\n' "$st" "$add" "$del" "$kind" "$path"
                continue
            fi
            if [[ "$kind" == "ok" && "$st" != "D" && -n "$sha" && "$sha" != "0000000000000000000000000000000000000000" ]]; then
                if _scope_blob_is_binary "$repo" "$sha"; then kind="binary"; fi
            fi
            printf '%s\t%s\t%s\t%s\t%s\n' "$st" "$add" "$del" "$kind" "$path"
        done
    return 0
}

# A runtime path (config runtime_paths) that is not protected: loop bookkeeping, not repo changes.
_scope_is_bookkeeping() {
    local path="$1"
    [[ "$path" == .claude/* ]] || return 1
    [[ -z "$(_scope_protected_match "$path" || true)" ]] || return 1
    _scope_matches_any "$path" "$SCOPE_RUNTIME_LIST"
}

# Drop loop bookkeeping rows.
_scope_drop_bookkeeping() {
    local st add del kind path
    while IFS=$'\t' read -r st add del kind path; do
        [[ -z "$path" ]] && continue
        if _scope_is_bookkeeping "$path"; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$st" "$add" "$del" "$kind" "$path"
    done
    return 0
}

# Print "files added deleted binary deleted_files" for the rows on stdin.
_scope_totals() {
    awk -F'\t' '
        BEGIN { f = 0; a = 0; d = 0; b = 0; df = 0 }
        NF >= 5 { f++; a += $2; d += $3; if ($4 == "binary") b++; if ($1 == "D") df++ }
        END { print f, a, d, b, df }'
}

# Print "reason<TAB>path" for each path violation in the rows on stdin, judged against scope $1.
scope_path_violations() {
    local scope="$1" allowed st add del kind path pm
    allowed="$(jq -r '.allowed_paths[]' <<< "$scope")"
    while IFS=$'\t' read -r st add del kind path; do
        [[ -z "$path" ]] && continue
        if [[ "$kind" == "symlink" ]]; then printf 'symlink\t%s\n' "$path"; continue; fi
        if [[ "$kind" == "submodule" ]]; then printf 'submodule\t%s\n' "$path"; continue; fi
        if [[ "$kind" == "binary" ]]; then printf 'binary_file\t%s\n' "$path"; continue; fi
        pm="$(_scope_protected_match "$path" || true)"
        if [[ -n "$pm" ]]; then
            if [[ "$st" == "D" ]]; then
                printf 'protected_deleted\t%s\n' "$path"
            elif ! _scope_list_has "$allowed" "$pm" && ! _scope_list_has "$allowed" "$path"; then
                printf 'protected_modified\t%s\n' "$path"
            fi
        elif ! _scope_matches_any "$path" "$allowed"; then
            printf 'outside_allowed_paths\t%s\n' "$path"
        fi
    done
    return 0
}

# Print "reason<TAB>-" for each exceeded budget. $2 files, $3 added, $4 deleted.
scope_budget_violations() {
    local scope="$1" files="$2" added="$3" deleted="$4" max
    max="$(jq -r '.max_files_changed' <<< "$scope")"
    [[ "$files" -gt "$max" ]] && printf 'too_many_files\t-\n'
    max="$(jq -r '.max_lines_added' <<< "$scope")"
    [[ "$added" -gt "$max" ]] && printf 'too_many_lines_added\t-\n'
    max="$(jq -r '.max_lines_deleted' <<< "$scope")"
    [[ "$deleted" -gt "$max" ]] && printf 'too_many_lines_deleted\t-\n'
    return 0
}

# ─── Guard ───────────────────────────────────────────────────────────────────

_scope_emit() {
    local name="$1"
    shift
    if type emit_event >/dev/null 2>&1; then emit_event "$name" "$@" || true; fi
    if type audit_emit >/dev/null 2>&1; then audit_emit "$name" "$@" || true; fi
    return 0
}

# Write evidence file $1 atomically. Remaining args are jq --argjson / --arg pairs. Evidence is
# written for humans; the guard never reads it back.
_scope_write_evidence() {
    local file="$1" tmp
    shift
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    if jq -n "$@" '{
        iteration: $iteration, verdict: $verdict, reason: $reason,
        base: $base, pre: $pre, head: $head, strikes: $strikes,
        scope: $scope, cumulative: $cumulative, iteration_diff: $iteration_diff,
        violations: $violations
    }' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"
        return 1
    fi
}

_scope_totals_json() {
    echo "$1" | awk '{printf "{\"files\":%s,\"added\":%s,\"deleted\":%s,\"binary\":%s,\"deleted_files\":%s}", $1, $2, $3, $4, $5}'
}

# Check the loop's commits for iteration $4 against the run's scope and revert on violation.
#   $1 repo, $2 base sha (LOOP_START_COMMIT), $3 pre-iteration sha, $4 iteration, $5 evidence dir,
#   $6 optional evidence tag ("-cleanup" for the post-audit commit).
# Uses the globals SCOPE_JSON, SCOPE_STRIKES, SCOPE_CAN_REVERT and SCOPE_LOOP_BRANCH.
# Returns 0 pass, 1 reverted (SCOPE_NOTE set; the caller skips the rest of the iteration), 2 blocked.
scope_guard_check() {
    local repo="$1" base="${2:-}" pre="${3:-}" iter="$4" dir="$5" tag="${6:-}"
    local evidence="$dir/scope-check-iter-${iter}${tag}.json"
    local head="" rows="" irows="" viol="" budget="" reason="" summary="" verdict="pass" rc=0 cur=""
    local cum="0 0 0 0 0" iter_tot="0 0 0 0 0" files=0 added=0 deleted=0 max strikes
    local scope_json="null" cum_json="null" iter_json="null" viol_json="[]" allowed
    strikes="${SCOPE_STRIKES:-0}"
    [[ -z "$pre" ]] && pre="$base"

    # Fail closed: nothing the guard trusts may be missing or unreadable.
    if [[ -z "$SCOPE_CONFIG" ]]; then
        reason="config_unloaded"
    elif [[ -z "$SCOPE_JSON" ]] || ! jq -e 'type == "object"' <<< "$SCOPE_JSON" >/dev/null 2>&1; then
        reason="scope_unreadable"
    elif [[ -z "$base" ]] || ! _scope_git -C "$repo" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1; then
        reason="baseline_uncomputable"
    else
        head="$(_scope_git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
        if [[ -z "$head" ]]; then
            reason="head_unreadable"
        elif [[ "$(_scope_git_meta "$repo" 2>/dev/null)" != "$SCOPE_META_SNAPSHOT" ]]; then
            reason="git_metadata_changed"
        elif ! rows="$(scope_diff_rows "$repo" "$base" "$head")"; then
            reason="diff_failed"
        elif ! irows="$(scope_diff_rows "$repo" "$pre" "$head")"; then
            reason="diff_failed"
        fi
    fi

    if [[ -n "$reason" ]]; then
        verdict="blocked"
    else
        rows="$(printf '%s\n' "$rows" | _scope_drop_bookkeeping)"
        irows="$(printf '%s\n' "$irows" | _scope_drop_bookkeeping)"
        cum="$(printf '%s\n' "$rows" | _scope_totals)"
        iter_tot="$(printf '%s\n' "$irows" | _scope_totals)"
        read -r files added deleted _ _ <<< "$cum"

        viol="$(printf '%s\n' "$rows" | scope_path_violations "$SCOPE_JSON" || true)"
        budget="$(scope_budget_violations "$SCOPE_JSON" "$files" "$added" "$deleted")"
        viol="$(printf '%s\n%s\n' "$viol" "$budget" | sed '/^$/d')"

        scope_json="$SCOPE_JSON"
        cum_json="$(_scope_totals_json "$cum")"
        iter_json="$(_scope_totals_json "$iter_tot")"
        viol_json="$(printf '%s\n' "$viol" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {reason: .[0], path: .[1]})')"
        if [[ -n "$viol" ]]; then verdict="violation"; fi
    fi

    # Revert this iteration's commits on the loop's own branch, then count the strike. Every
    # precondition for a reset is checked first; any failure blocks instead of resetting.
    if [[ "$verdict" == "violation" ]]; then
        cur="$(_scope_git -C "$repo" symbolic-ref -q HEAD 2>/dev/null || true)"
        if [[ "${SCOPE_CAN_REVERT:-0}" != "1" ]]; then
            reason="cannot_revert_unsafe_tree"
            verdict="blocked"
        elif [[ -z "$cur" || "$cur" != "$SCOPE_LOOP_BRANCH" ]]; then
            reason="head_not_on_loop_branch"
            verdict="blocked"
        elif ! _scope_git -C "$repo" reset --hard "$pre" >/dev/null 2>&1; then
            reason="revert_failed"
            verdict="blocked"
        else
            strikes=$(( strikes + 1 ))
            SCOPE_STRIKES="$strikes"
            summary="$(printf '%s\n' "$viol" | awk -F'\t' '{ printf "%s%s (%s)", sep, $2, $1; sep = "; " }')"
            reason="$summary"
            allowed="$(jq -r '.allowed_paths | join(", ")' <<< "$SCOPE_JSON")"
            max="$(jq -r '"\(.max_files_changed) files, \(.max_lines_added) added and \(.max_lines_deleted) deleted lines"' <<< "$SCOPE_JSON")"
            if [[ "$strikes" -ge 2 ]]; then
                verdict="blocked"
            else
                verdict="reverted"
                SCOPE_NOTE="Scope violation in iteration ${iter}: ${summary}. The loop reverted this iteration's changes. Stay within the declared scope: allowed paths are ${allowed}; budget is ${max}. Never delete or edit protected test, workflow, ADR, settings, hook, rule or skill files, and never change .gitattributes, symlinks or binary files. A second violation fails the build."
            fi
        fi
    fi

    case "$verdict" in
        pass) rc=0 ;;
        reverted) rc=1 ;;
        *) rc=2 ;;
    esac
    [[ -n "$reason" && "$verdict" == "blocked" ]] && summary="$reason"

    # Evidence is written after any revert. If it cannot be recorded, the stage fails closed.
    if ! _scope_write_evidence "$evidence" --argjson iteration "$iter" --arg verdict "$verdict" \
        --arg reason "${summary:-$reason}" --arg base "$base" --arg pre "$pre" --arg head "$head" \
        --argjson strikes "$strikes" --argjson scope "$scope_json" \
        --argjson cumulative "$cum_json" --argjson iteration_diff "$iter_json" \
        --argjson violations "$viol_json"; then
        if [[ "$rc" -eq 0 ]]; then rc=2; fi
        verdict="blocked"
    fi
    if [[ "$verdict" != "pass" ]]; then
        _scope_emit "loop.scope_violation" "iteration=$iter" "verdict=$verdict" "strikes=$strikes"
    fi
    return "$rc"
}

# Worker gate (multi-agent). Judges the worker's staged changes before its commit. A violation
# discards the staged work (inside the worker's own worktree) and counts a strike in the worker's
# own process. Returns 0 commit, 1 discarded, 2 blocked. Uses the exported SW_SCOPE_JSON and
# SW_SCOPE_CONFIG, which the parent loop set before it launched the worker.
#   $1 worktree, $2 iteration, $3 agent number, $4 evidence dir
scope_worker_precommit() {
    local repo="$1" iter="$2" agent="$3" dir="$4" rows viol budget files=0 added=0 deleted=0 rc=0
    local evidence="$dir/scope-check-agent-${agent}-iter-${iter}.json"
    _scope_set_config_json "${SW_SCOPE_CONFIG:-}" || return 2
    SCOPE_JSON="${SW_SCOPE_JSON:-}"
    jq -e 'type == "object"' <<< "$SCOPE_JSON" >/dev/null 2>&1 || return 2
    # Cumulative: the staged tree against the loop base, not against HEAD, so a worker cannot spend
    # its budget one commit at a time. A missing base fails closed.
    local base="${SW_SCOPE_BASE:-}"
    [[ -n "$base" ]] && _scope_git -C "$repo" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1 || return 2
    rows="$(scope_diff_rows "$repo" "$base" "INDEX")" || return 2
    rows="$(printf '%s\n' "$rows" | _scope_drop_bookkeeping)"
    read -r files added deleted _ _ <<< "$(printf '%s\n' "$rows" | _scope_totals)"
    viol="$(printf '%s\n' "$rows" | scope_path_violations "$SCOPE_JSON" || true)"
    budget="$(scope_budget_violations "$SCOPE_JSON" "$files" "$added" "$deleted")"
    viol="$(printf '%s\n%s\n' "$viol" "$budget" | sed '/^$/d')"
    if [[ -z "$viol" ]]; then
        return 0
    fi
    _scope_git -C "$repo" reset -q --hard HEAD >/dev/null 2>&1 || return 2
    SCOPE_STRIKES=$(( ${SCOPE_STRIKES:-0} + 1 ))
    _scope_write_evidence "$evidence" --argjson iteration "$iter" --arg verdict "reverted" \
        --arg reason "$(printf '%s' "$viol" | tr '\t\n' ' :')" --arg base "HEAD" --arg pre "HEAD" --arg head "INDEX" \
        --argjson strikes "$SCOPE_STRIKES" --argjson scope "$SCOPE_JSON" \
        --argjson cumulative "null" --argjson iteration_diff "null" \
        --argjson violations "$(printf '%s\n' "$viol" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {reason: .[0], path: .[1]})')" || true
    if [[ "$SCOPE_STRIKES" -ge 2 ]]; then rc=2; else rc=1; fi
    return "$rc"
}

# Trusted base for a resumed run. The state file is agent-writable, so a resumed base is never read
# from it: it is the merge-base of HEAD with the default branch, i.e. where the feature branch forked.
# Prints nothing and returns 1 when that cannot be established, or when HEAD is the default branch
# itself (then no fork point exists and the guard cannot tell the loop's commits apart).
scope_trusted_base() {
    local repo="$1" ref b head
    head="$(_scope_git -C "$repo" rev-parse HEAD 2>/dev/null)" || return 1
    for ref in refs/remotes/origin/HEAD refs/heads/main refs/heads/master; do
        _scope_git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 || continue
        b="$(_scope_git -C "$repo" merge-base HEAD "$ref" 2>/dev/null)" || continue
        [[ -n "$b" ]] || continue
        if [[ "$b" == "$head" ]]; then
            return 1
        fi
        echo "$b"
        return 0
    done
    return 1
}
