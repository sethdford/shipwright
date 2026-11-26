# shellcheck shell=bash
# verifier-gate.sh — the merge verifier before a PR opens (ADR-0012).
# The decision lives in TypeScript (`shipwright verify score`); this file only calls it.
# SHIPWRIGHT_VERIFIER: off | advisory (default) | enforce.
#   advisory  never blocks; the verdict is logged, emitted and noted in the PR body.
#   enforce   blocks when the CLI exits 3: a hard stop (no real change, failing tests, run output
#             in the diff) or, once the model is trusted, a predicted merge chance below 20%.
# A verifier that cannot run (no Bun, no git base, a crash) never blocks: it is a quality signal
# layered on the existing gates, not a safety gate, and the hard stops it enforces are also
# covered by the PR stage's own scrubbing. That is logged as `pr.verifier_unavailable`.
[[ -n "${_VERIFIER_GATE_LOADED:-}" ]] && return 0
_VERIFIER_GATE_LOADED=1

_VERIFIER_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER_TS_CLI="${VERIFIER_TS_CLI:-$(cd "${_VERIFIER_GATE_DIR}/../.." && pwd)/src/cli.ts}"

# _verifier_emit <event> <key=value...> — emit_event when the pipeline loaded it.
_verifier_emit() {
    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "$@"
    fi
}

# _verifier_say <level> <message> — pipeline info/warn/error when loaded, else stderr.
_verifier_say() {
    local level="$1" message="$2"
    if [[ "$(type -t "$level" 2>/dev/null)" == "function" ]]; then
        "$level" "$message"
    else
        echo "verifier: $message" >&2
    fi
}

# verifier_gate <base-ref> <title> <body> [tests: pass|fail|unknown]
# Returns 0 to open the PR, 1 to stop. Sets VERIFIER_PR_NOTE (a line for the PR body, or "").
verifier_gate() {
    local base="${1:-}" title="${2:-}" body="${3:-}" tests="${4:-unknown}"
    VERIFIER_PR_NOTE=""
    local mode
    mode="$(printf '%s' "${SHIPWRIGHT_VERIFIER:-advisory}" | tr '[:upper:]' '[:lower:]')"
    case "$mode" in
        off) return 0 ;;
        advisory | enforce) ;;
        *)
            _verifier_say warn "SHIPWRIGHT_VERIFIER=${mode} is not off, advisory or enforce; using advisory"
            mode="advisory"
            ;;
    esac
    case "$tests" in pass | fail | unknown) ;; *) tests="unknown" ;; esac
    local bun_bin="${SW_BUN:-bun}"
    if [[ -z "$base" ]] || ! command -v "$bun_bin" >/dev/null 2>&1; then
        _verifier_say warn "merge verifier skipped (no base ref or no ${bun_bin})"
        _verifier_emit "pr.verifier_unavailable" "issue=${ISSUE_NUMBER:-0}" "reason=no_bun_or_base"
        return 0
    fi
    local body_file out rc=0
    body_file="$(mktemp "${TMPDIR:-/tmp}/sw-verifier-body.XXXXXX")"
    printf '%s' "$body" > "$body_file"
    out="$("$bun_bin" "$VERIFIER_TS_CLI" verify score --base "$base" --title "$title" \
        --body-file "$body_file" --tests "$tests" --mode "$mode" --format json 2>/dev/null)" || rc=$?
    rm -f "$body_file"
    _verifier_result "$rc" "$out"
}

# _verifier_result <rc> <json> — turns the CLI's answer into the gate's return and PR note.
_verifier_result() {
    local rc="$1" out="$2" verdict pct reasons
    if [[ "$rc" != "0" && "$rc" != "3" ]] || ! verdict="$(printf '%s' "$out" | jq -er '.decision.verdict' 2>/dev/null)"; then
        _verifier_say warn "merge verifier could not run (exit ${rc}); not blocking"
        _verifier_emit "pr.verifier_unavailable" "issue=${ISSUE_NUMBER:-0}" "exit=${rc}"
        return 0
    fi
    pct="$(printf '%s' "$out" | jq -r '(.probability * 100 | round)' 2>/dev/null || echo "?")"
    reasons="$(printf '%s' "$out" | jq -r '.decision.reasons | join("; ")' 2>/dev/null || true)"
    _verifier_emit "pr.verifier" "issue=${ISSUE_NUMBER:-0}" "verdict=${verdict}" "merge_chance=${pct}"
    if [[ "$rc" == "3" ]]; then
        _verifier_say error "merge verifier blocked this PR (merge chance ${pct}%): ${reasons}"
        _verifier_emit "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=verifier"
        return 1
    fi
    [[ "$verdict" == "warn" ]] && _verifier_say warn "merge verifier: ${reasons}"
    VERIFIER_PR_NOTE="Merge verifier: ${pct}% predicted chance to merge (${verdict})."
    return 0
}
