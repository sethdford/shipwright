#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright team-stages test — Validate multi-agent stage execution      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/team-state"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"
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
        elif [[ "${2:-}" == "HEAD" ]]; then echo "abc1234"
        else echo "abc1234"; fi ;;
    diff) echo "file1.sh"; echo "file2.sh"; echo "file3.sh" ;;
    ls-files) echo "file1.sh"; echo "file2.sh" ;;
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
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    export REPO_DIR="$TEST_TEMP_DIR/repo"
}

trap cleanup_test_env EXIT

