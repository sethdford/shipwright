# shellcheck shell=bash
# proof-gate.sh — run-the-app proof before a PR opens (ADR-0019).
# The work lives in TypeScript (`shipwright proof run`); this file only calls it and returns the
# PR section. The app runs through test-gate-exec.sh (no credentials); screenshots, video and logs
# are pushed to the repository's shipwright-proof branch so the PR body can show them.
# SHIPWRIGHT_PROOF: off | advisory (default) | enforce.
#   advisory  never blocks; the section goes in the PR body either way.
#   enforce   blocks when the CLI exits 3: the app did not start, a flow step failed, a page threw,
#             the app answered 4xx/5xx on a changed page, or a CLI run exited unexpectedly.
# SHIPWRIGHT_PROOF_PUBLISH=off keeps the artifacts on this machine (no push); so does NO_GITHUB.
# A proof that cannot run (no Bun, a crash, a bad proof.json) never blocks; it is logged as
# `pr.proof_unavailable`.
[[ -n "${_PROOF_GATE_LOADED:-}" ]] && return 0
_PROOF_GATE_LOADED=1

_PROOF_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_TS_CLI="${PROOF_TS_CLI:-$(cd "${_PROOF_GATE_DIR}/../.." && pwd)/src/cli.ts}"

_proof_emit() {
    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "$@"
    fi
}

_proof_say() {
    local level="$1" message="$2"
    if [[ "$(type -t "$level" 2>/dev/null)" == "function" ]]; then
        "$level" "$message"
    else
        echo "proof: $message" >&2
    fi
}

_proof_publish_on() {
    [[ "${NO_GITHUB:-false}" == "true" ]] && return 1
    case "$(printf '%s' "${SHIPWRIGHT_PROOF_PUBLISH:-on}" | tr '[:upper:]' '[:lower:]')" in
        off | 0 | false | no) return 1 ;;
    esac
    return 0
}

# proof_gate <base-ref> <label> [out-dir]
# Returns 0 to open the PR, 1 to stop. Sets PROOF_PR_SECTION (markdown for the PR body, or "").
proof_gate() {
    local base="${1:-}" label="${2:-run}" out_dir="${3:-}"
    PROOF_PR_SECTION=""
    local mode
    mode="$(printf '%s' "${SHIPWRIGHT_PROOF:-advisory}" | tr '[:upper:]' '[:lower:]')"
    case "$mode" in
        off) return 0 ;;
        advisory | enforce) ;;
        *)
            _proof_say warn "SHIPWRIGHT_PROOF=${mode} is not off, advisory or enforce; using advisory"
            mode="advisory"
            ;;
    esac
    local bun_bin="${SW_BUN:-bun}"
    if [[ -z "$base" ]] || ! command -v "$bun_bin" >/dev/null 2>&1; then
        _proof_say warn "run-the-app proof skipped (no base ref or no ${bun_bin})"
        _proof_emit "pr.proof_unavailable" "issue=${ISSUE_NUMBER:-0}" "reason=no_bun_or_base"
        return 0
    fi
    label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._/-' '-' | cut -c1-100)"
    local args=(proof run --base "$base" --mode "$mode" --label "${label:-run}" --format json)
    [[ -n "$out_dir" ]] && args+=(--out "$out_dir")
    if _proof_publish_on; then args+=(--publish); else args+=(--no-publish); fi
    local out rc=0
    _proof_say info "Running the app for proof (${mode})"
    out="$("$bun_bin" "$PROOF_TS_CLI" "${args[@]}" 2>/dev/null)" || rc=$?
    _proof_result "$rc" "$out"
}

# _proof_result <rc> <json> — the gate's return and PR section from the CLI's answer.
_proof_result() {
    local rc="$1" out="$2" status failures
    if [[ "$rc" != "0" && "$rc" != "3" ]] || ! status="$(printf '%s' "$out" | jq -er '.verdict.status' 2>/dev/null)"; then
        _proof_say warn "run-the-app proof could not run (exit ${rc}); not blocking"
        _proof_emit "pr.proof_unavailable" "issue=${ISSUE_NUMBER:-0}" "exit=${rc}"
        return 0
    fi
    failures="$(printf '%s' "$out" | jq -r '.verdict.failures | join("; ")' 2>/dev/null || true)"
    PROOF_PR_SECTION="$(printf '%s' "$out" | jq -r '.section // ""' 2>/dev/null || true)"
    _proof_emit "pr.proof" "issue=${ISSUE_NUMBER:-0}" "status=${status}"
    if [[ "$rc" == "3" ]]; then
        _proof_say error "run-the-app proof blocked this PR: ${failures}"
        _proof_emit "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=proof"
        return 1
    fi
    [[ "$status" == "fail" ]] && _proof_say warn "run-the-app proof found a problem: ${failures}"
    return 0
}
