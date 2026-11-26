#!/usr/bin/env bash
# lessons-loop.sh — the mining and self-reflection half of the self-improvement loop (ADR-0010 amendment).
#
#   lessons_draft_from_failures <manifest> <out-dir>
#
# Mines recurring failures from the run logs in <manifest> ("<source> <log path>" per line) into proposed lessons,
# asks an agent (through agent-exec.sh, no tools, one turn) to write each draft's rule and hypothesis, and writes
# the drafts to <out-dir>/L-NNNN.md. A draft whose reflection fails is kept with its placeholders, so a person can
# write it. Nothing here commits, opens a pull request or makes a lesson active: a draft is then trialled with
# SHIPWRIGHT_LESSONS_TRIAL on the eval harness, `shipwright governance promote` reads the ratchet verdict, and a
# person merges the result.
[[ -n "${_LESSONS_LOOP_LOADED:-}" ]] && return 0
_LESSONS_LOOP_LOADED=1

_LESSONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW_AGENT_EXEC="${SW_AGENT_EXEC:-${_LESSONS_DIR}/agent-exec.sh}"

_lessons_cli() {
    local bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-$(cd "${_LESSONS_DIR}/../.." && pwd)/src/cli.ts}"
    "$bun_bin" "$cli" governance "$@"
}

_lessons_event() {
    if type emit_event >/dev/null 2>&1; then emit_event "$@" 2>/dev/null || true; fi
    return 0
}

# _lessons_reflect <draft> — prints the reflected draft, or fails (exit 1) and prints nothing.
_lessons_reflect() {
    local draft="$1" prompt reply_file out
    prompt="$(_lessons_cli reflect --draft "$draft" 2>/dev/null)" || return 1
    reply_file="$(mktemp "${TMPDIR:-/tmp}/sw-lesson-reply.XXXXXX")" || return 1
    # The prompt goes in as one argv element; the evidence inside it is fenced and marked untrusted.
    if ! "$SW_AGENT_EXEC" claude --print --max-turns 1 "$prompt" > "$reply_file" 2>/dev/null; then
        rm -f "$reply_file"
        return 1
    fi
    if ! out="$(_lessons_cli apply-reflection --draft "$draft" --reply "$reply_file" 2>/dev/null)"; then
        rm -f "$reply_file"
        return 1
    fi
    rm -f "$reply_file"
    printf '%s\n' "$out"
}

lessons_draft_from_failures() {
    local manifest="$1" out_dir="$2" json n i id draft reflected
    mkdir -p "$out_dir" || return 1
    json="$(_lessons_cli mine --manifest "$manifest" --json)" || return 1
    n="$(printf '%s' "$json" | jq -r '.drafts | length')"
    i=0
    while [[ "$i" -lt "${n:-0}" ]]; do
        id="$(printf '%s' "$json" | jq -r --argjson i "$i" '.drafts[$i].id')"
        [[ "$id" =~ ^L-[0-9]+$ ]] || { i=$((i + 1)); continue; }
        draft="$out_dir/${id}.md"
        printf '%s' "$json" | jq -r --argjson i "$i" '.drafts[$i].markdown' > "$draft.tmp" && mv "$draft.tmp" "$draft"
        if reflected="$(_lessons_reflect "$draft")" && [[ -n "$reflected" ]]; then
            printf '%s\n' "$reflected" > "$draft.tmp" && mv "$draft.tmp" "$draft"
            _lessons_event "lessons.drafted" "id=${id}" "reflected=true"
        else
            _lessons_event "lessons.drafted" "id=${id}" "reflected=false"
        fi
        printf '%s\n' "$draft"
        i=$((i + 1))
    done
    return 0
}
