# safety-gates.sh — bash callers of the Wave 1a safety gates (ADR-0007).
# The decisions live in TypeScript (`shipwright gates`, `shipwright intake`); this file only
# calls them. Everything fails closed: exit 0 from the CLI is the only "yes"; any other status,
# a signal, or a missing Bun means nothing is dispatched or filed.
[[ -n "${_SAFETY_GATES_LOADED:-}" ]] && return 0
_SAFETY_GATES_LOADED=1

_SAFETY_GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW_TS_CLI="${SW_TS_CLI:-$(cd "${_SAFETY_GATES_DIR}/../.." && pwd)/src/cli.ts}"

# _sw_ts <args...> — runs the TypeScript CLI; 127 when Bun is missing.
_sw_ts() {
    local bun_bin="${SW_BUN:-bun}"
    if ! command -v "$bun_bin" >/dev/null 2>&1; then
        echo "safety gates: ${bun_bin} not found — failing closed" >&2
        return 127
    fi
    "$bun_bin" "$SW_TS_CLI" "$@"
}

# safety_gates_ok <retry> — 0 only when dispatch is allowed; the gate report goes to stderr.
# retry: how many times this issue has already been retried (0 = first dispatch). Required:
# a missing or non-numeric count blocks, because an unknown count must not read as "first".
# --no-github is passed only when the daemon itself runs with NO_GITHUB=true.
safety_gates_ok() {
    local retry="${1:-}"
    if [[ ! "$retry" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
        echo "safety gates: invalid retry count — failing closed" >&2
        return 2
    fi
    local args=(gates check --retry "$retry")
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        args+=(--no-github)
    fi
    local rc=0
    _sw_ts "${args[@]}" >&2 || rc=$?
    [[ "$rc" -eq 0 ]]
}

# patrol_issue_create <gh issue create args...> — files the issue only when the intake gate
# allows it (open auto-filed issues under the cap, no open issue with the same fingerprint).
# The title is passed to the gate as one argv element, never through a shell string.
patrol_issue_create() {
    local title="" prev="" arg
    for arg in "$@"; do
        if [[ "$prev" == "--title" ]]; then
            title="$arg"
        fi
        prev="$arg"
    done
    local rc=0
    _sw_ts intake check --title "$title" --label "${PATROL_LABEL:-auto-patrol}" >&2 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        return 1
    fi
    gh issue create "$@"
}

# Auto-filed issues (label $PATROL_LABEL, default auto-patrol) are never dispatched until a human
# opts one in by removing that label (ADR-0007); automation never removes it. Issues labelled
# shipwright-stuck are skipped too, until a human clears the label.

# dispatch_eligible <labels-csv> — 0 when an issue with these labels may be dispatched.
dispatch_eligible() {
    case ",${1:-}," in
        *",${PATROL_LABEL:-auto-patrol},"* | *",shipwright-stuck,"*) return 1 ;;
    esac
    return 0
}

# dispatchable_issue_numbers — reads `gh issue list --json number,labels` on stdin and prints the
# numbers of the issues that may be dispatched, one per line. Malformed JSON exits non-zero.
dispatchable_issue_numbers() {
    jq -r --arg auto "${PATROL_LABEL:-auto-patrol}" --arg stuck "shipwright-stuck" \
        '.[] | select([.labels[].name] | (index($auto) or index($stuck)) | not) | .number'
}
