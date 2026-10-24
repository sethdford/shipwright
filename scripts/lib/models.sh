# shellcheck shell=bash
# models.sh — resolves a model alias through config/models.json (W2-07). A name that is not an
# alias passes through unchanged. The no-pinned-models test refuses any ID outside the alias values.
models_resolve() {
    local name="$1"
    local root file
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    file="${SW_MODELS_FILE:-$root/config/models.json}"
    if [[ ! -f "$file" ]]; then
        echo "models: $file is missing; cannot resolve '$name'" >&2
        return 1
    fi
    jq -r --arg a "$name" '.aliases[$a] // $a' "$file"
}
