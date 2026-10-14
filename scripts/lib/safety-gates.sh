# shellcheck shell=bash
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

# _safety_gates_log <level> <message> — the daemon log when loaded, else stderr.
_safety_gates_log() {
    if [[ "$(type -t daemon_log 2>/dev/null)" == "function" ]]; then
        daemon_log "$1" "$2"
    else
        echo "safety gates: $2" >&2
    fi
}

# _sw_lower <text> — lowercase (bash 3.2 has no ${var,,}).
_sw_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# safety_gates_ok <retry> — 0 only when dispatch is allowed; otherwise the CLI's exit code
# (1 blocked or unverifiable, 2 usage, 127 no Bun, anything else). The report goes to stderr.
# retry: the retry number about to be dispatched (0 = first dispatch, N = Nth retry). Required:
# a missing or non-numeric count returns 2, because an unknown count must not read as "first".
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
    return "$rc"
}

# patrol_issue_create [--intake-label LABEL] <gh issue create args...> — files the issue only
# when the intake gate allows it (open issues with LABEL under the cap, no open issue with the
# same title fingerprint). LABEL defaults to $PATROL_LABEL (auto-patrol); pass the label the
# site actually applies when it differs. The title must be given as `--title VALUE`; the
# `--title=VALUE` and `-t` forms are refused (2) because the gate would not see the title.
# `--repo R` / `-R R` scopes the gate to that repo (GH_REPO). Newlines in the title become
# spaces. The title goes to the gate as one argv element, never through a shell string.
# A refusal is logged with the gate's exit code and returns 1.
patrol_issue_create() {
    local intake_label="${PATROL_LABEL:-auto-patrol}"
    if [[ "${1:-}" == "--intake-label" ]]; then
        if [[ $# -lt 2 ]]; then
            _safety_gates_log ERROR "patrol_issue_create: --intake-label needs a value"
            return 2
        fi
        intake_label="$2"
        shift 2
    fi
    local args=() title="" repo="" prev="" arg
    for arg in "$@"; do
        case "$prev" in
            --title)
                arg="$(printf '%s' "$arg" | tr -s '\r\n' '  ' | sed 's/[[:space:]]*$//')"
                title="$arg"
                ;;
            --repo | -R)
                repo="$arg"
                ;;
            --body | --label | -b | -l | --assignee | -a | --milestone | -m | --project | -p) ;;
            *)
                case "$arg" in
                    --title=* | -t | -t?*)
                        _safety_gates_log ERROR "patrol_issue_create: use --title VALUE (got ${arg%%=*})"
                        return 2
                        ;;
                    --repo=*) repo="${arg#--repo=}" ;;
                esac
                ;;
        esac
        args+=("$arg")
        # An option's value is never itself treated as an option
        if [[ "$prev" =~ ^(--title|--repo|-R|--body|--label|-b|-l|--assignee|-a|--milestone|-m|--project|-p)$ ]]; then
            prev=""
        else
            prev="$arg"
        fi
    done
    local out="" rc=0
    if [[ -n "$repo" ]]; then
        out="$(GH_REPO="$repo" _sw_ts intake check --title "$title" --label "$intake_label" 2>&1)" || rc=$?
    else
        out="$(_sw_ts intake check --title "$title" --label "$intake_label" 2>&1)" || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        local reason
        reason="$(printf '%s\n' "$out" | grep -m1 '✗' || printf '%s\n' "$out" | head -1)"
        _safety_gates_log WARN "Patrol issue not filed: intake gate refused (rc=${rc}): ${reason}"
        return 1
    fi
    gh issue create ${args[@]+"${args[@]}"}
}

# Auto-filed issues (label $PATROL_LABEL, default auto-patrol) are never dispatched until a human
# opts one in by removing that label (ADR-0007); automation never removes it. Issues labelled
# shipwright-stuck are skipped too, until a human clears the label. Labels match ignoring case.

# dispatch_eligible <labels-csv> — 0 when an issue with these labels may be dispatched.
# Callers must treat an empty or unreadable label list as not eligible (polled issues always
# carry the watch label).
dispatch_eligible() {
    local labels auto
    labels="$(_sw_lower "${1:-}")"
    auto="$(_sw_lower "${PATROL_LABEL:-auto-patrol}")"
    case ",${labels}," in
        *",${auto},"* | *",shipwright-stuck,"*) return 1 ;;
    esac
    return 0
}

# dispatchable_issue_numbers — reads `gh issue list --json number,labels` on stdin and prints the
# numbers of the issues the CI workflows may dispatch, one per line: not auto-filed, not
# shipwright-stuck, not shipwright-failed or shipwright-infra-issue (both wait for a human), and
# not claimed by a daemon (a claimed:<machine> label).
# Anything but an array of issues exits non-zero.
dispatchable_issue_numbers() {
    jq -r --arg auto "$(_sw_lower "${PATROL_LABEL:-auto-patrol}")" '
        [$auto, "shipwright-stuck", "shipwright-failed", "shipwright-infra-issue"] as $held
        | if type == "array" then .[] else error("issue list is not an array") end
        | select(any(.labels[].name | ascii_downcase; IN($held[]) or startswith("claimed:")) | not)
        | .number'
}


# _fleet_token — prints the dashboard fleet token: $SHIPWRIGHT_FLEET_TOKEN, else the contents of
# $SHIPWRIGHT_FLEET_TOKEN_FILE with surrounding whitespace trimmed (warns unless the file is mode
# 600). Prints nothing when neither is set. Returns 1 when the file is unreadable or empty, or the
# token contains a line break (it would inject a header). Messages never include the token.
_fleet_token() {
    local token="${SHIPWRIGHT_FLEET_TOKEN:-}" file="${SHIPWRIGHT_FLEET_TOKEN_FILE:-}"
    if [[ -z "$token" && -n "$file" ]]; then
        if [[ ! -f "$file" || ! -r "$file" ]]; then
            echo "fleet token: cannot read SHIPWRIGHT_FLEET_TOKEN_FILE (${file})" >&2
            return 1
        fi
        local mode
        mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null || true)"
        if [[ ! "$mode" =~ ^[0-7]+$ ]] || (( 8#$mode & 8#077 )); then
            echo "fleet token: warning: SHIPWRIGHT_FLEET_TOKEN_FILE (${file}) should be mode 600 (is ${mode:-unknown})" >&2
        fi
        token="$(cat "$file")"
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        if [[ -z "$token" ]]; then
            echo "fleet token: SHIPWRIGHT_FLEET_TOKEN_FILE (${file}) is empty" >&2
            return 1
        fi
    fi
    if [[ "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
        echo "fleet token: the token contains a line break — refusing to send it" >&2
        return 1
    fi
    printf '%s' "$token"
}

# fleet_curl <curl args...> — curl to a dashboard fleet route (/api/claim*, /api/connect/*) with
# the `X-Shipwright-Token` header (_fleet_token). The header goes to curl on stdin (`-H @-`,
# curl >= 7.55), so the token never appears in argv, `ps` or logs; callers must not use stdin
# themselves. No token configured: plain curl, no header (a loopback dashboard without a token).
# Returns curl's exit status, or 125 (curl not run) when a configured token cannot be used.
# curl exits 0 on HTTP errors unless --fail is given: callers that gate on the call must check
# the HTTP status (-w '%{http_code}').
fleet_curl() {
    local token
    token="$(_fleet_token)" || return 125
    if [[ -z "$token" ]]; then
        curl "$@"
        return
    fi
    { printf 'X-Shipwright-Token: %s\n' "$token" || true; } | curl -H @- "$@"
}
