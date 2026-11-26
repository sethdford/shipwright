# shellcheck shell=bash
# models.sh — model aliases, the default alias, effort levels and the learned-routing gate (W2-07).
#
# models_resolve <name>: prints the full model ID. Fails closed (non-zero, a message on stderr) for an empty name, a
# name that is neither an alias nor a listed ID, a missing or malformed file, and an alias value that is not a string
# matching ^claude-[a-z0-9-]+$. The message says: use an alias or add the ID to config/models.json.
# models_is_alias <name>: 0 when the name is an alias key.
# models_default_alias: prints the default alias (the "default" key), fails when it is missing.
# models_effort_valid <level>: 0 when the level is listed in "efforts".
# models_provider_routed: 0 when a Bedrock or Vertex provider is selected (aliases then go to the CLI unchanged).
# models_legacy_routing_enabled: 0 only when SW_LEGACY_MODEL_ROUTING=true (learned routing is off by default).
# SW_MODELS_FILE overrides the file. In CI the pipeline snapshots config/models.json and points SW_MODELS_FILE at the
# copy, so a builder cannot change the models a reviewer uses.

_MODELS_ID_RE='^claude-[a-z0-9-]+$'

_models_file() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    printf '%s\n' "${SW_MODELS_FILE:-$root/config/models.json}"
}

_models_check_file() {
    local file="$1" name="$2"
    if [[ ! -f "$file" ]]; then
        echo "models: $file is missing; cannot resolve '$name'" >&2
        return 1
    fi
    if ! jq -e '.aliases | type == "object"' "$file" >/dev/null 2>&1; then
        echo "models: $file is malformed (no .aliases object); cannot resolve '$name'" >&2
        return 1
    fi
    return 0
}

models_resolve() {
    local name="${1-}" file alias
    if [[ -z "$name" ]]; then
        echo "models: empty model name" >&2
        return 1
    fi
    file="$(_models_file)"
    _models_check_file "$file" "$name" || return 1
    alias="$(jq -r --arg a "$name" '.aliases[$a] | if type == "string" then . else empty end' "$file" 2>/dev/null)" || alias=""
    if [[ -n "$alias" ]]; then
        if [[ "$alias" =~ $_MODELS_ID_RE ]]; then
            printf '%s\n' "$alias"
            return 0
        fi
        echo "models: alias '$name' in $file is not a model ID (claude-...): use an alias or add the ID to config/models.json" >&2
        return 1
    fi
    # Not an alias: a full ID passes only when it is one of the string alias values and is well formed.
    if jq -e --arg n "$name" '[.aliases[] | select(type == "string")] | index($n) != null' "$file" >/dev/null 2>&1 \
        && [[ "$name" =~ $_MODELS_ID_RE ]]; then
        printf '%s\n' "$name"
        return 0
    fi
    echo "models: '$name' is neither an alias nor a listed model ID; use an alias or add the ID to config/models.json" >&2
    return 1
}

models_is_alias() {
    local file
    file="$(_models_file)"
    [[ -n "${1-}" && -f "$file" ]] || return 1
    jq -e --arg a "$1" '.aliases | has($a)' "$file" >/dev/null 2>&1
}

models_default_alias() {
    local file alias
    file="$(_models_file)"
    _models_check_file "$file" "default" || return 1
    alias="$(jq -r '.default // empty' "$file" 2>/dev/null)" || alias=""
    if [[ -z "$alias" ]]; then
        echo "models: $file has no \"default\" alias" >&2
        return 1
    fi
    printf '%s\n' "$alias"
}

models_effort_valid() {
    local level="${1-}" file
    [[ -n "$level" ]] || return 1
    file="$(_models_file)"
    [[ -f "$file" ]] || return 1
    jq -e --arg e "$level" '(.efforts // []) | index($e) != null' "$file" >/dev/null 2>&1
}

models_provider_routed() {
    [[ "${CLAUDE_CODE_USE_BEDROCK:-}" == "1" || "${CLAUDE_CODE_USE_VERTEX:-}" == "1" ]]
}

models_legacy_routing_enabled() {
    [[ "${SW_LEGACY_MODEL_ROUTING:-false}" == "true" ]]
}
