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
