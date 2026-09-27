#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright public-dashboard test — Validate public dashboard generation ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    log) echo "abc1234 fix: something" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) echo "main: 1 windows" ;;
    list-panes|list-windows) echo "" ;;
    new-window|split-window|send-keys) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    # Mock find to avoid filesystem issues
    cat > "$TEST_TEMP_DIR/bin/find" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/find"
    # Mock openssl
    cat > "$TEST_TEMP_DIR/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
echo "abcdef1234567890abcdef1234567890"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/openssl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    # Create a mock repo dir for the script
    export REPO_DIR="$TEST_TEMP_DIR/repo"
}

trap cleanup_test_env EXIT

