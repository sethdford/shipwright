#!/usr/bin/env bash
# governance-brief.sh — ADRs, policies, standards and lessons for agent prompts (ADR-0010).
# The TypeScript command `shipwright governance` does the work; this file only calls it and adds its output to
# the build and review prompts. Documents are read at a commit the agent did not write (the base branch), so a
# build agent cannot edit the rules it is told to follow.
# Ablation for paired eval runs: SHIPWRIGHT_LESSONS=off, SHIPWRIGHT_GOVERNANCE=off (read by the command).
# The brief is advice in a prompt, not a gate: when it cannot be built, the run goes on without it and an event
# records that, so a paired comparison can see which runs had it.
[[ -n "${_GOVERNANCE_BRIEF_LOADED:-}" ]] && return 0
_GOVERNANCE_BRIEF_LOADED=1

_GOVERNANCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_governance_cli() {
    local bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-$(cd "${_GOVERNANCE_DIR}/../.." && pwd)/src/cli.ts}"
    command -v "$bun_bin" >/dev/null 2>&1 || return 1
    "$bun_bin" "$cli" governance "$@"
}

_governance_event() {
    if type emit_event >/dev/null 2>&1; then emit_event "$@" 2>/dev/null || true; fi
    return 0
}

# The same switch values the TypeScript command reads: off, 0, false or no, in any case.
_governance_off() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        off|0|false|no) return 0 ;;
    esac
    return 1
}

# Prints the commit the documents are read from: SW_GOVERNANCE_REF, else the base branch on origin, else the
# local base branch. Prints nothing (exit 1) when none resolves.
governance_ref() {
    local base="${BASE_BRANCH:-main}" ref sha
    for ref in "${SW_GOVERNANCE_REF:-}" "origin/${base}" "${base}"; do
        [[ -n "$ref" && "$ref" != -* ]] || continue
        if sha="$(git rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" && [[ -n "$sha" ]]; then
            printf '%s\n' "$sha"
            return 0
        fi
    done
    return 1
}

# governance_brief_section <goal-text> — the brief for a build prompt, or nothing. The paths changed since the
# base commit are passed too, so lessons scoped to paths apply from the second iteration on.
governance_brief_section() {
    local goal="${1:-}" ref tmp_issue tmp_paths out ids
    ref="$(governance_ref)" || { _governance_event "governance.brief_unavailable" "reason=no_base_ref"; return 0; }
    tmp_issue="$(mktemp "${TMPDIR:-/tmp}/sw-gov-issue.XXXXXX")" || return 0
    tmp_paths="$(mktemp "${TMPDIR:-/tmp}/sw-gov-paths.XXXXXX")" || { rm -f "$tmp_issue"; return 0; }
    printf '%s\n' "$goal" > "$tmp_issue"
    git diff --name-only "$ref" -- 2>/dev/null > "$tmp_paths" || true
    if out="$(_governance_cli brief --ref "$ref" --issue "$tmp_issue" --paths "$tmp_paths" --json 2>/dev/null)"; then
        ids="$(printf '%s' "$out" | jq -r '[.lessons[].id] | join(",")' 2>/dev/null || true)"
        _governance_event "governance.brief" "ref=${ref}" "lessons=${ids}" \
            "docs=$(printf '%s' "$out" | jq -r '.docs | length' 2>/dev/null || echo 0)" \
            "lessons_arm=${SHIPWRIGHT_LESSONS:-on}" "governance_arm=${SHIPWRIGHT_GOVERNANCE:-on}" \
            "lessons_trial=${SHIPWRIGHT_LESSONS_TRIAL:-}"
        printf '%s' "$out" | jq -r '.brief // ""' 2>/dev/null || true
    else
        _governance_event "governance.brief_unavailable" "reason=command_failed"
    fi
    rm -f "$tmp_issue" "$tmp_paths"
    return 0
}

# governance_review_checklist — the checklist of rules the change touches, for a review prompt, or nothing.
governance_review_checklist() {
    local ref tmp_changed out=""
    ref="$(governance_ref)" || return 0
    tmp_changed="$(mktemp "${TMPDIR:-/tmp}/sw-gov-changed.XXXXXX")" || return 0
    git diff --name-only "${ref}...HEAD" -- 2>/dev/null > "$tmp_changed" || true
    if [[ -s "$tmp_changed" ]] && ! _governance_off "${SHIPWRIGHT_GOVERNANCE:-}"; then
        out="$(_governance_cli check --ref "$ref" --changed "$tmp_changed" 2>/dev/null)" || out=""
    fi
    rm -f "$tmp_changed"
    printf '%s' "$out"
    return 0
}
