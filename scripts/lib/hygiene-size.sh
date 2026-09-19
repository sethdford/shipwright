# hygiene-size.sh — Shared script-size scanning (sw-hygiene.sh + daemon-patrol.sh)
# Source from any script that needs to find oversized shell scripts.
# Requires: jq, find, wc. No other Shipwright libs.
[[ -n "${_HYGIENE_SIZE_LOADED:-}" ]] && return 0
_HYGIENE_SIZE_LOADED=1

# Emit one JSON object per .sh file in a directory (non-recursive).
_emit_script_sizes() {
    local scripts_dir="${1:-${REPO_DIR:-.}/scripts}"
    [[ -d "$scripts_dir" ]] || return 0
    local f lines
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        lines=$(wc -l < "$f" 2>/dev/null || true)
        lines="${lines//[^0-9]/}"
        lines="${lines:-0}"
        printf '{"script":"%s","lines":%s}\n' "$(basename "$f")" "$lines"
    done < <(find "$scripts_dir" -maxdepth 1 -name "*.sh" -type f 2>/dev/null || true)
}

# hygiene_oversized_scripts <threshold> [scripts_dir]
# Returns a JSON array of {script,lines} for scripts with lines > threshold,
# sorted largest-first. Always emits valid JSON ("[]" on any failure).
hygiene_oversized_scripts() {
    local threshold="${1:-1500}"
    local scripts_dir="${2:-${REPO_DIR:-.}/scripts}"
    local raw_file json

    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=1500

    raw_file=$(mktemp "${TMPDIR:-/tmp}/sw-hygiene-sizes.XXXXXX")
    _emit_script_sizes "$scripts_dir" > "$raw_file" 2>/dev/null || true
    json=$(jq -s --argjson t "$threshold" \
        '[ .[] | select(.lines > $t) ] | sort_by(-.lines)' "$raw_file" 2>/dev/null || echo "[]")
    rm -f "$raw_file"
    [[ -n "$json" ]] || json="[]"
    echo "$json"
}

# check_script_sizes [threshold]
# sw-hygiene.sh-facing wrapper: defaults to the hygiene threshold and repo scripts dir.
check_script_sizes() {
    hygiene_oversized_scripts "${1:-${MAX_SCRIPT_LINES:-1500}}" "${REPO_DIR:-.}/scripts"
}
