#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright compat — Cross-platform compatibility helpers               ║
# ║  Source this AFTER color definitions for NO_COLOR + platform support    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source "$SCRIPT_DIR/lib/compat.sh"
#
# Provides:
#   - NO_COLOR / dumb terminal / non-tty detection (auto-blanks color vars)
#   - sed_i()    — cross-platform sed in-place editing
#   - open_url() — cross-platform browser open
#   - tmp_dir()  — returns best temp directory for platform
#   - is_wsl()   — detect WSL environment
#   - is_macos() / is_linux() — platform checks

# ─── NO_COLOR support (https://no-color.org/) ─────────────────────────────
# Blanks standard color variables when:
#   - NO_COLOR is set (any value)
#   - TERM is "dumb" (e.g. Emacs shell, CI without tty)
#   - stdout is not a terminal (piped output)
if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]] || { [[ -z "${SHIPWRIGHT_FORCE_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
    CYAN='' PURPLE='' BLUE='' GREEN='' YELLOW='' RED='' DIM='' BOLD='' RESET=''
    UNDERLINE='' ITALIC=''
fi

# ─── Platform detection ───────────────────────────────────────────────────
_COMPAT_UNAME="${_COMPAT_UNAME:-$(uname -s 2>/dev/null || echo "Unknown")}"

is_macos() { [[ "$_COMPAT_UNAME" == "Darwin" ]]; }
is_linux() { [[ "$_COMPAT_UNAME" == "Linux" ]]; }
is_wsl()   { is_linux && [[ -n "${WSL_DISTRO_NAME:-}" || -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; }

# ─── sed -i (macOS vs GNU) ────────────────────────────────────────────────
# macOS sed requires '' after -i, GNU sed does not
sed_i() {
    if is_macos; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ─── Open URL in browser ──────────────────────────────────────────────────
open_url() {
    local url="$1"
    if is_macos; then
        open "$url"
    elif is_wsl; then
        # WSL: use wslview (from wslu) or powershell
        if command -v wslview &>/dev/null; then
            wslview "$url"
        elif command -v powershell.exe &>/dev/null; then
            powershell.exe -Command "Start-Process '$url'" 2>/dev/null
        else
            return 1
        fi
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    else
        return 1
    fi
}

# ─── Temp directory (respects Windows %TEMP% and %TMP%) ──────────────────
tmp_dir() {
    echo "${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
}

# ─── Process existence check (portable) ──────────────────────────────────
pid_exists() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# ─── Shared Error Taxonomy ───────────────────────────────────────────────
# Canonical error categories used by sw-pipeline.sh, sw-memory.sh, and others.
# Extend via ~/.shipwright/optimization/error-taxonomy.json
SW_ERROR_CATEGORIES="test_failure build_error lint_error timeout dependency flaky config security permission unknown"

sw_valid_error_category() {
    local category="${1:-}"
    local custom_file="$HOME/.shipwright/optimization/error-taxonomy.json"
    # Check custom taxonomy first
    if [[ -f "$custom_file" ]] && command -v jq &>/dev/null; then
        local custom_cats
        custom_cats=$(jq -r '.categories[]? // empty' "$custom_file" 2>/dev/null || true)
        if [[ -n "$custom_cats" ]]; then
            local cat_item
            while IFS= read -r cat_item; do
                if [[ "$cat_item" == "$category" ]]; then
                    return 0
                fi
            done <<< "$custom_cats"
        fi
    fi
    # Check built-in categories
    local builtin
    for builtin in $SW_ERROR_CATEGORIES; do
        if [[ "$builtin" == "$category" ]]; then
            return 0
        fi
    done
    return 1
}

# ─── Complexity Bucketing ────────────────────────────────────────────────
# Shared by sw-intelligence.sh and sw-self-optimize.sh.
# Thresholds tunable via ~/.shipwright/optimization/complexity-clusters.json
complexity_bucket() {
    local complexity="${1:-5}"
    local config_file="$HOME/.shipwright/optimization/complexity-clusters.json"
    local low_boundary=3
    local high_boundary=6
    if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
        local lb hb
        lb=$(jq -r '.low_boundary // 3' "$config_file" 2>/dev/null || echo "3")
        hb=$(jq -r '.high_boundary // 6' "$config_file" 2>/dev/null || echo "6")
        [[ "$lb" =~ ^[0-9]+$ ]] && low_boundary="$lb"
        [[ "$hb" =~ ^[0-9]+$ ]] && high_boundary="$hb"
    fi
    if [[ "$complexity" -le "$low_boundary" ]]; then
        echo "low"
    elif [[ "$complexity" -le "$high_boundary" ]]; then
        echo "medium"
    else
        echo "high"
    fi
}

# ─── Framework / Language Detection ──────────────────────────────────────
# Shared by sw-prep.sh and sw-pipeline.sh.
detect_primary_language() {
    local dir="${1:-.}"
    if [[ -f "$dir/package.json" ]]; then
        if [[ -f "$dir/tsconfig.json" ]]; then
            echo "typescript"
        else
            echo "javascript"
        fi
    elif [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
        echo "python"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$dir/build.gradle" || -f "$dir/pom.xml" ]]; then
        echo "java"
    elif [[ -f "$dir/mix.exs" ]]; then
        echo "elixir"
    else
        echo "unknown"
    fi
}

detect_test_framework() {
    local dir="${1:-.}"
    if [[ -f "$dir/package.json" ]] && command -v jq &>/dev/null; then
        local runner
        runner=$(jq -r '
            if .devDependencies.vitest then "vitest"
            elif .devDependencies.jest then "jest"
            elif .devDependencies.mocha then "mocha"
            elif .devDependencies.ava then "ava"
            elif .devDependencies.tap then "tap"
            else ""
            end' "$dir/package.json" 2>/dev/null || echo "")
        if [[ -n "$runner" ]]; then
            echo "$runner"
            return 0
        fi
    fi
    if [[ -f "$dir/pytest.ini" || -f "$dir/pyproject.toml" ]]; then
        echo "pytest"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go test"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "cargo test"
    elif [[ -f "$dir/build.gradle" ]]; then
        echo "gradle test"
    else
        echo ""
    fi
}
