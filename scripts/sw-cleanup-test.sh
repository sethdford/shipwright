#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cleanup test — Clean up orphaned sessions & artifacts       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--is-inside-work-tree" ]]; then echo "true"
        else echo "abc1234"; fi ;;
    branch)
        echo "" ;;
    worktree)
        case "${2:-}" in
            list) echo "" ;;
            prune) exit 0 ;;
        esac ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) echo "" ;;
    list-sessions) echo "" ;;
    kill-window) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    # Also link common utils we need
    for cmd in find stat du wc sed; do
        if command -v "$cmd" &>/dev/null; then
            ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
        fi
    done
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    # Create a mock repo dir and cd there so relative paths (.claude/) don't pick up real artifacts
    mkdir -p "$TEST_TEMP_DIR/repo"
    cd "$TEST_TEMP_DIR/repo"
}

trap cleanup_test_env EXIT

