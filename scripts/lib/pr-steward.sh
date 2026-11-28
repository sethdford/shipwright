# shellcheck shell=bash
# pr-steward.sh — keeps a pipeline PR moving after it opens (ADR-0017).
#
#   stage_steward       the pipeline stage between `pr` and `merge`. Each round asks the TypeScript
#                       steward (`shipwright steward inspect`) what to do next: fix failing CI and
#                       review comments, re-run infrastructure failures once, wait, or stop.
#   steward_preflight   the pre-PR self-scan, called by stage_pr before the branch is pushed:
#                       secrets block the push; conflict markers, focused tests and debugger
#                       statements get one fix round.
#
# Trust boundary (ADR-0011): a fix round runs the loop in a disposable clone with no credentials;
# only a judged patch comes back. CI logs and review comments reach the model as wrapped data
# (untrusted_block). The fixer's per-comment report is read as data and rebuilt into replies by
# the TypeScript side. Pushes, replies and re-runs go through `shipwright steward` (F10 writer),
# never from bash. Decisions live in TypeScript; this file only drives the rounds.
#
# SHIPWRIGHT_STEWARD=off skips the stage; SHIPWRIGHT_STEWARD_SCAN=off skips the pre-PR scan.
# Bash 3.2 compatible.
[[ -n "${_PR_STEWARD_LOADED:-}" ]] && return 0
_PR_STEWARD_LOADED=1

_PR_STEWARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=untrusted.sh
source "${_PR_STEWARD_DIR}/untrusted.sh"
# shellcheck source=patch-handoff.sh
source "${_PR_STEWARD_DIR}/patch-handoff.sh"
STEWARD_TS_CLI="${STEWARD_TS_CLI:-$(cd "${_PR_STEWARD_DIR}/../.." && pwd)/src/cli.ts}"
# The fixer's per-comment report, relative to its clone (REPLIES_FILE in steward-brief.ts).
STEWARD_REPLIES_FILE=".claude/steward-replies.json"
# Briefs travel as one loop argument; Linux caps a single argument at 128 KiB.
STEWARD_MAX_BRIEF_BYTES="${STEWARD_MAX_BRIEF_BYTES:-60000}"

_steward_say() {
    local level="$1" message="$2"
    if [[ "$(type -t "$level" 2>/dev/null)" == "function" ]]; then
        "$level" "$message"
    else
        echo "steward: $message" >&2
    fi
}

_steward_emit() {
    [[ "$(type -t emit_event 2>/dev/null)" == "function" ]] && emit_event "$@"
    return 0
}

# _steward_cli ARGS... — `shipwright steward ARGS` from the trusted checkout. GH_REPO pins the
# repository when the pipeline knows it, so a fork-plus-upstream checkout cannot resolve elsewhere.
_steward_cli() {
    (
        cd "${PROJECT_ROOT:-.}" || exit 1
        if [[ -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
            export GH_REPO="${REPO_OWNER}/${REPO_NAME}"
        fi
        "${SW_BUN:-bun}" "$STEWARD_TS_CLI" steward "$@"
    )
}

# _steward_cfg KEY DEFAULT — the steward stage's config value from the pipeline template.
_steward_cfg() {
    local key="$1" def="$2" v=""
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-}" ]]; then
        v=$(jq -r --arg k "$key" '(.stages[]? | select(.id == "steward") | .config[$k]) // empty' \
            "$PIPELINE_CONFIG" 2>/dev/null) || v=""
    fi
    [[ -z "$v" || "$v" == "null" ]] && v="$def"
    printf '%s\n' "$v"
}

# _steward_int KEY DEFAULT MIN MAX — a whole-number config value in [MIN, MAX], else DEFAULT. The
# template may be repository content or model-composed, so it never reaches arithmetic unchecked.
_steward_int() {
    local v
    v=$(_steward_cfg "$1" "$2")
    if [[ ! "$v" =~ ^[0-9]{1,6}$ ]] || [[ "$v" -lt "$3" || "$v" -gt "$4" ]]; then
        v="$2"
    fi
    printf '%s\n' "$v"
}

# _steward_available — bun and the TypeScript CLI are installed (a scripts-only copy has neither).
_steward_available() {
    command -v "${SW_BUN:-bun}" >/dev/null 2>&1 || return 1
    [[ "$STEWARD_TS_CLI" != /* || -f "$STEWARD_TS_CLI" ]]
}

_steward_off() {
    case "$(printf '%s' "${1:-on}" | tr '[:upper:]' '[:lower:]')" in
        off | false | 0 | no) return 0 ;;
    esac
    return 1
}

# _steward_brief REPORT_JSON — the fixer's goal: trusted instructions, then each item wrapped as
# untrusted data. Capped to STEWARD_MAX_BRIEF_BYTES bytes.
_steward_brief() {
    local report="$1" out label text item
    out="$(jq -r '.brief.instructions // ""' "$report")"
    while IFS= read -r item; do
        label=$(printf '%s' "$item" | jq -r '.label')
        text=$(printf '%s' "$item" | jq -r '.text')
        out="${out}

$(untrusted_block "$label" "$text")"
    done < <(jq -c '.brief.items[]?' "$report")
    # A byte substring (C locale), not `| head -c`: under pipefail a cut pipe fails the caller.
    local LC_ALL=C
    printf '%s' "${out:0:$STEWARD_MAX_BRIEF_BYTES}"
}

# _steward_run_fixer AGENT_DIR GOAL — the build loop, credential-free, in the agent's clone.
_steward_run_fixer() {
    local dir="$1" goal="$2" model test_cmd iters
    model=$(_steward_cfg model "${MODEL:-opus}")
    if [[ "$(type -t models_resolve 2>/dev/null)" == "function" ]]; then
        model=$(models_resolve "$model") || return 1
    fi
    iters=$(_steward_int max_iterations 6 1 30)
    # The goal (CI and review text) goes in a file beside the clone, not in the loop's argv (#8711).
    local goal_file
    goal_file="$(dirname "$dir")/steward-goal.md"
    printf '%s\n' "$goal" > "$goal_file" || return 1
    local args=(--goal-file "$goal_file" --repo "$dir" --max-iterations "$iters" --model "$model" --skip-permissions)
    test_cmd=""
    [[ "$(type -t _pipeline_test_cmd 2>/dev/null)" == "function" ]] && test_cmd=$(_pipeline_test_cmd 2>/dev/null || true)
    [[ -n "$test_cmd" && "$test_cmd" != "null" ]] && args+=(--test-cmd "$test_cmd")
    _build_run_loop "${SHIPWRIGHT_LOOP_SCRIPT:-$SCRIPT_DIR/sw-loop.sh}" "${args[@]}" < /dev/null
}

# _steward_handoff_fix GOAL MESSAGE TAG — one fix round through the patch handoff (ADR-0011).
# Prints the new commit sha, or nothing when the fixer changed nothing. Returns 1 when the round
# could not run or its patch was refused. The fixer's report is copied to $STEWARD_DIR/replies-TAG.json.
_steward_handoff_fix() {
    local goal="$1" msg="$2" tag="$3"
    if [[ "${SW_PATCH_HANDOFF:-true}" == "false" ]]; then
        _steward_say error "steward fix rounds need the patch handoff (SW_PATCH_HANDOFF is false)"
        return 1
    fi
    local base work dir patch="${STEWARD_DIR}/fix-${tag}.patch" rc=0
    base=$(git -C "$PROJECT_ROOT" rev-parse HEAD) || return 1
    work=$(mktemp -d "${TMPDIR:-/tmp}/sw-steward.XXXXXX") || return 1
    dir="${work}/repo"
    _steward_fix_in "$base" "$dir" "$goal" "$patch" "$msg" "$tag" || rc=$?
    rm -rf "$work"
    return "$rc"
}

_steward_fix_in() {
    local base="$1" dir="$2" goal="$3" patch="$4" msg="$5" tag="$6"
    handoff_prepare "$PROJECT_ROOT" "$base" "$dir" || return 1
    # stdout carries only the new sha: the loop's output goes to a log beside the patch.
    _steward_run_fixer "$dir" "$goal" > "${STEWARD_DIR}/fixer-${tag}.log" 2>&1 \
        || _steward_say warn "steward fixer exited non-zero; judging what it left" >&2
    if [[ "$(type -t _pipeline_add_loop_tokens 2>/dev/null)" == "function" ]]; then
        _pipeline_add_loop_tokens "${dir}/.claude/loop-logs/loop-tokens.json" >&2 || true
    fi
    _steward_copy_report "$dir" "${STEWARD_DIR}/replies-${tag}.json"
    handoff_export "$dir" "$base" "$PROJECT_ROOT" "$patch" || return 1
    [[ -s "$patch" ]] || return 0
    local why
    if ! why=$(handoff_judge "$patch"); then
        printf '%s\n' "$why" > "${patch}.refused"
        _steward_say error "steward fix refused by the patch judge: $(printf '%s' "$why" | tr '\n' ';')"
        _steward_emit "steward.patch_refused" "issue=${ISSUE_NUMBER:-0}" "round=${tag}"
        return 1
    fi
    handoff_apply "$PROJECT_ROOT" "$base" "$patch" "$msg"
}

# _steward_copy_report AGENT_DIR DEST — the fixer's report as data: a regular file under 256 KiB.
_steward_copy_report() {
    local src="$1/${STEWARD_REPLIES_FILE}" dest="$2" size
    rm -f "$dest"
    [[ ! -L "$1/.claude" && -f "$src" && ! -L "$src" ]] || return 0
    size=$(wc -c < "$src" | tr -d ' ')
    [[ "${size:-0}" -le 262144 ]] || { _steward_say warn "steward: fixer report too large; ignored"; return 0; }
    cp "$src" "$dest"
}

# _steward_history_after_fix HISTORY REPORT UNHANDLED_JSON — one more round, the failure
# signatures it targeted, and one more attempt for each comment the fixer did not report on.
_steward_history_after_fix() {
    local history="$1" report="$2" unhandled="$3" tmp
    tmp="${history}.tmp"
    printf '%s' "$unhandled" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
    jq --slurpfile r "$report" --argjson u "$unhandled" '
        .rounds = ((.rounds // 0) + 1)
        | .fixedSignatures = ((.fixedSignatures // []) + [[$r[0].decision.fixFailures[]?.signature]])
        | .commentAttempts = (reduce $u[] as $id ((.commentAttempts // {}); .[($id|tostring)] = ((.[($id|tostring)] // 0) + 1)))
    ' "$history" > "$tmp" && mv "$tmp" "$history"
}

_steward_history_rerun() {
    local history="$1" checks="$2" tmp="${1}.tmp"
    jq --argjson c "$checks" '.rerunChecks = ((.rerunChecks // []) + $c | unique)' "$history" > "$tmp" && mv "$tmp" "$history"
}

[[ -f "${_PR_STEWARD_DIR}/pr-steward-stage.sh" ]] && source "${_PR_STEWARD_DIR}/pr-steward-stage.sh"
