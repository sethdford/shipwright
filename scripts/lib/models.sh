# shellcheck shell=bash
# models.sh — model aliases and effort levels from config/models.json (W2-07).
#
# models_resolve <name>: prints the full model ID. Fails closed (non-zero, a message on stderr) for an empty name,
# a name that is neither an alias nor one of the alias values, a missing file, and a malformed file. Callers must
# check the result: a failed resolve never yields an empty or null --model.
# models_effort_valid <level>: 0 when the level is listed in "efforts", else 1.
# SW_MODELS_FILE overrides the file (tests).

_models_file() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    printf '%s\n' "${SW_MODELS_FILE:-$root/config/models.json}"
}

models_resolve() {
    local name="${1:-}" file resolved
    if [[ -z "$name" ]]; then
        echo "models: empty model name" >&2
        return 1
    fi
    file="$(_models_file)"
    if [[ ! -f "$file" ]]; then
        echo "models: $file is missing; cannot resolve '$name'" >&2
        return 1
    fi
    if ! jq -e '.aliases | type == "object"' "$file" >/dev/null 2>&1; then
        echo "models: $file is malformed (no .aliases object); cannot resolve '$name'" >&2
        return 1
    fi
    resolved="$(jq -r --arg a "$name" '.aliases[$a] // empty' "$file" 2>/dev/null)" || resolved=""
    if [[ -n "$resolved" && "$resolved" != "null" ]]; then
        printf '%s\n' "$resolved"
        return 0
    fi
    # Not an alias: a full ID passes only when it is one of the alias values.
    if jq -e --arg n "$name" '[.aliases[]] | index($n) != null' "$file" >/dev/null 2>&1; then
        printf '%s\n' "$name"
        return 0
    fi
    echo "models: '$name' is neither an alias nor a known model ID in $file" >&2
    return 1
}

models_effort_valid() {
    local level="${1:-}" file
    [[ -n "$level" ]] || return 1
    file="$(_models_file)"
    [[ -f "$file" ]] || return 1
    jq -e --arg e "$level" '(.efforts // []) | index($e) != null' "$file" >/dev/null 2>&1
}
