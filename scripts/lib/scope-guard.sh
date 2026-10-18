#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#   scope-guard.sh — blast-radius guard for the build loop (#8644)
#
#   A task declares a scope: allowed path globs plus files / added-lines / deleted-lines budgets,
#   derived from its type (config/scope-budgets.json). After each loop commit the guard diffs
#   LOOP_START_COMMIT..HEAD. A path outside the scope, a protected path deleted or modified without
#   an explicit allow, or a budget overrun reverts this iteration's commits (git reset --hard to the
#   pre-iteration sha) and counts a strike. Two strikes fail closed.
#
#   A spec's `.scope` can only TIGHTEN the defaults: every number is min(model, default) and every
#   allowed path must sit inside a default glob. Missing or unparsable scope means the default.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

[[ -n "${_SCOPE_GUARD_LOADED:-}" ]] && return 0
_SCOPE_GUARD_LOADED=1

# ─── Config and globs ────────────────────────────────────────────────────────

_scope_config_file() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/scope-budgets.json"
}

# `**/` matches zero or more directories and `**` any run. In a bash case pattern `*` already crosses
# `/`, so `src/**/*.test.ts` becomes `src/*.test.ts`.
_scope_normalize_glob() {
    local p="$1" star="*"
    p="${p//\*\*\//}"
    p="${p//\*\*/$star}"
    echo "$p"
}

# True when path $1 matches glob $2.
_scope_glob_match() {
    local s="$1" pat
    pat="$(_scope_normalize_glob "$2")"
    # shellcheck disable=SC2254 # the pattern comes from config and is meant as a glob
    case "$s" in
        $pat) return 0 ;;
    esac
    return 1
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
    done < <(jq -r '.protected_paths[]' "$(_scope_config_file)")
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

# Known type for $1: the type itself, its alias, or "unknown".
scope_canonical_type() {
    local t
    t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    jq -r --arg t "$t" '
        if (.types[$t] != null) then $t
        elif (.aliases[$t] != null and .types[.aliases[$t]] != null) then .aliases[$t]
        else "unknown" end' "$(_scope_config_file)"
}

# Default scope JSON for a type.
scope_defaults() {
    local t
    t="$(scope_canonical_type "$1")"
    jq -c --arg t "$t" '.types[$t] + {type: $t}' "$(_scope_config_file)"
}

# Final scope JSON for a type and an optional spec file. The spec's `.scope` may only tighten:
# each number becomes min(model, default), and each model path survives only inside a default glob.
# A protected glob survives only when the default lists it literally.
scope_resolve() {
    local type="$1" spec="${2:-}" defaults model default_list kept="" kept_json p
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

# Resolve the loop's scope: intake.json's type when the pipeline wrote one, else inferred from the
# goal and labels. The spec, when present, supplies the (tightened) scope.
scope_resolve_for_loop() {
    local artifacts="$1" goal="$2" labels="${3:-}" type=""
    if [[ -f "$artifacts/intake.json" ]]; then
        type="$(jq -r '.type // empty' "$artifacts/intake.json" 2>/dev/null || true)"
    fi
    [[ -z "$type" ]] && type="$(scope_infer_type "$goal" "$labels")"
    scope_resolve "$type" "$artifacts/spec.json"
}

# Write the resolved scope into a spec file as `.scope` (in place, atomically). Called by intake and
# spec_generation so the artifact records the scope the loop will enforce.
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

# ─── Diff classification ─────────────────────────────────────────────────────

# One row per changed path between $2 and $3 in repo $1: status, added, deleted, binary, path.
# Renames are off, so a rename is a delete plus an add and both sides are judged. Binary files
# count as files with zero line changes.
scope_diff_rows() {
    local repo="$1" base="$2" head="$3" ns nu
    ns="$(git -C "$repo" -c core.quotePath=false diff --name-status --no-renames "$base" "$head")" || return 1
    nu="$(git -C "$repo" -c core.quotePath=false diff --numstat --no-renames "$base" "$head")" || return 1
    awk -F'\t' '
        NR == FNR { if (NF >= 2) status[$2] = substr($1, 1, 1); next }
        NF >= 3 {
            bin = ($1 == "-") ? 1 : 0
            add = bin ? 0 : $1
            del = bin ? 0 : $2
            st = ($3 in status) ? status[$3] : "M"
            print st "\t" add "\t" del "\t" bin "\t" $3
        }' <(printf '%s\n' "$ns") <(printf '%s\n' "$nu")
}

# Drop loop bookkeeping (`.claude/**`, such as loop logs and state) unless it is protected.
_scope_drop_bookkeeping() {
    local status add del bin path
    while IFS=$'\t' read -r status add del bin path; do
        [[ -z "$path" ]] && continue
        if [[ "$path" == .claude/* ]] && [[ -z "$(_scope_protected_match "$path" || true)" ]]; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$add" "$del" "$bin" "$path"
    done
}

# Print "files added deleted binary deleted_files" for the rows on stdin.
_scope_totals() {
    awk -F'\t' '
        BEGIN { f = 0; a = 0; d = 0; b = 0; df = 0 }
        NF >= 5 { f++; a += $2; d += $3; b += $4; if ($1 == "D") df++ }
        END { print f, a, d, b, df }'
}

# Print "reason<TAB>path" for each path violation in the rows on stdin, judged against scope $1.
scope_path_violations() {
    local scope="$1" allowed status add del bin path pm
    allowed="$(jq -r '.allowed_paths[]' "$scope")"
    while IFS=$'\t' read -r status add del bin path; do
        [[ -z "$path" ]] && continue
        pm="$(_scope_protected_match "$path" || true)"
        if [[ -n "$pm" ]]; then
            if [[ "$status" == "D" ]]; then
                printf 'protected_deleted\t%s\n' "$path"
            elif ! _scope_list_has "$allowed" "$pm" && ! _scope_list_has "$allowed" "$path"; then
                printf 'protected_modified\t%s\n' "$path"
            fi
        elif ! _scope_matches_any "$path" "$allowed"; then
            printf 'outside_allowed_paths\t%s\n' "$path"
        fi
    done
}

# Print "reason<TAB>-" for each exceeded budget. $2 files, $3 added, $4 deleted.
scope_budget_violations() {
    local scope="$1" files="$2" added="$3" deleted="$4" max
    max="$(jq -r '.max_files_changed' "$scope")"
    [[ "$files" -gt "$max" ]] && printf 'too_many_files\t-\n'
    max="$(jq -r '.max_lines_added' "$scope")"
    [[ "$added" -gt "$max" ]] && printf 'too_many_lines_added\t-\n'
    max="$(jq -r '.max_lines_deleted' "$scope")"
    [[ "$deleted" -gt "$max" ]] && printf 'too_many_lines_deleted\t-\n'
    return 0
}

# A new build run starts with no strikes. Resume and session restart do not call this.
scope_reset_strikes() {
    [[ -n "$1" ]] && rm -f "$1/scope-strikes" 2>/dev/null || true
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

# Write the evidence file $1 atomically. Remaining args are jq --argjson / --arg pairs.
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

# Check the loop's commits for iteration $4 against the scope in $5 and revert on violation.
#   $1 repo, $2 base sha (LOOP_START_COMMIT), $3 pre-iteration sha, $4 iteration, $5 scope file,
#   $6 evidence dir (scope-check-iter-N.json and scope-strikes live here), $7 optional evidence tag
#   (e.g. "-cleanup" for the post-audit commit, so it does not overwrite the agent commit's record).
# Returns 0 pass, 1 reverted (strike 1 of 2; SCOPE_NOTE is set for the next prompt), 2 blocked.
scope_guard_check() {
    local repo="$1" base="${2:-}" pre="${3:-}" iter="$4" scope="${5:-}" dir="$6" tag="${7:-}"
    local evidence="$dir/scope-check-iter-${iter}${tag}.json"
    local head="" rows="" irows="" viol="" budget="" reason="" summary="" verdict="pass" rc=0
    local cum="0 0 0 0 0" iter_tot="0 0 0 0 0" strikes=0 files=0 added=0 deleted=0 max
    local scope_json="null" cum_json="null" iter_json="null" viol_json="[]" allowed

    strikes="$(cat "$dir/scope-strikes" 2>/dev/null || echo 0)"
    [[ "$strikes" =~ ^[0-9]+$ ]] || strikes=0
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")"
    [[ -z "$pre" ]] && pre="$base"

    # Fail closed: an uncomputable baseline or unreadable scope blocks the stage.
    if [[ -z "$base" ]] || ! git -C "$repo" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1; then
        reason="baseline_uncomputable"
    elif [[ -z "$scope" || ! -f "$scope" ]] || ! jq -e 'type == "object"' "$scope" >/dev/null 2>&1; then
        reason="scope_unreadable"
    elif ! jq -e '.protected_paths | type == "array"' "$(_scope_config_file)" >/dev/null 2>&1; then
        reason="config_unreadable"
    elif [[ -z "$head" ]]; then
        reason="head_unreadable"
    elif ! rows="$(scope_diff_rows "$repo" "$base" "$head")"; then
        reason="diff_failed"
    elif ! irows="$(scope_diff_rows "$repo" "$pre" "$head")"; then
        reason="diff_failed"
    fi

    if [[ -n "$reason" ]]; then
        verdict="blocked"
    else
        rows="$(printf '%s\n' "$rows" | _scope_drop_bookkeeping)"
        irows="$(printf '%s\n' "$irows" | _scope_drop_bookkeeping)"
        cum="$(printf '%s\n' "$rows" | _scope_totals)"
        iter_tot="$(printf '%s\n' "$irows" | _scope_totals)"
        read -r files added deleted _ _ <<< "$cum"

        viol="$(printf '%s\n' "$rows" | scope_path_violations "$scope" || true)"
        budget="$(scope_budget_violations "$scope" "$files" "$added" "$deleted")"
        viol="$(printf '%s\n%s\n' "$viol" "$budget" | sed '/^$/d')"

        scope_json="$(cat "$scope")"
        cum_json="$(echo "$cum" | awk '{printf "{\"files\":%s,\"added\":%s,\"deleted\":%s,\"binary\":%s,\"deleted_files\":%s}", $1, $2, $3, $4, $5}')"
        iter_json="$(echo "$iter_tot" | awk '{printf "{\"files\":%s,\"added\":%s,\"deleted\":%s,\"binary\":%s,\"deleted_files\":%s}", $1, $2, $3, $4, $5}')"
        viol_json="$(printf '%s\n' "$viol" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {reason: .[0], path: .[1]})')"
        if [[ -n "$viol" ]]; then verdict="violation"; fi
    fi

    # Revert this iteration's commits on the loop's own branch, then count the strike.
    if [[ "$verdict" == "violation" ]]; then
        if ! git -C "$repo" reset --hard "$pre" >/dev/null 2>&1; then
            reason="revert_failed"
            verdict="blocked"
        else
            strikes=$(( strikes + 1 ))
            summary="$(printf '%s\n' "$viol" | awk -F'\t' '{ printf "%s%s (%s)", sep, $2, $1; sep = "; " }')"
            reason="$summary"
            if ! echo "$strikes" > "$dir/scope-strikes" 2>/dev/null; then
                reason="strike_record_failed"
                verdict="blocked"
            fi
            allowed="$(echo "$scope_json" | jq -r '.allowed_paths | join(", ")')"
            max="$(echo "$scope_json" | jq -r '"\(.max_files_changed) files, \(.max_lines_added) added and \(.max_lines_deleted) deleted lines"')"
            if [[ "$verdict" == "blocked" ]]; then
                : # strike could not be recorded: already blocked
            elif [[ "$strikes" -ge 2 ]]; then
                verdict="blocked"
            else
                verdict="reverted"
                SCOPE_NOTE="Scope violation in iteration ${iter}: ${summary}. The loop reverted this iteration's changes. Stay within the declared scope: allowed paths are ${allowed}; budget is ${max}. Never delete or edit protected test, workflow, ADR or settings files. A second violation fails the build."
            fi
        fi
    fi

    case "$verdict" in
        pass) rc=0 ;;
        reverted) rc=1 ;;
        *) rc=2 ;;
    esac

    # Evidence is written after any revert, so the reset cannot remove it. If it cannot be written,
    # the stage fails closed: an unrecorded decision is not a pass.
    if ! _scope_write_evidence "$evidence" --argjson iteration "$iter" --arg verdict "$verdict" \
        --arg reason "$reason" --arg base "$base" --arg pre "$pre" --arg head "$head" \
        --argjson strikes "$strikes" --argjson scope "$scope_json" \
        --argjson cumulative "$cum_json" --argjson iteration_diff "$iter_json" \
        --argjson violations "$viol_json"; then
        verdict="blocked"
    fi
    if [[ "$verdict" == "blocked" ]]; then
        rc=2
    fi
    if [[ "$verdict" != "pass" ]]; then
        _scope_emit "loop.scope_violation" "iteration=$iter" "verdict=$verdict" "strikes=$strikes"
    fi
    return "$rc"
}
