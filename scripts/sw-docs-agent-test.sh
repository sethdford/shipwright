#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright docs-agent test — Validate documentation agent operations    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/docs-agent"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
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
        else echo "abc1234"; fi ;;
    diff) echo "scripts/sw-test.sh" ;;
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
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    # Mock wc to return numbers
    cat > "$TEST_TEMP_DIR/bin/stat" <<'MOCK'
#!/usr/bin/env bash
# Return a mock modification time
if [[ "${1:-}" == "-c" ]]; then
    echo "1700000000"
elif [[ "${1:-}" == "-f" ]]; then
    echo "1700000000"
else
    /usr/bin/stat "$@"
fi
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/stat"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true

    # Create mock scripts and CLAUDE.md for coverage tests
    for name in sw-pipeline sw-daemon sw-loop sw-status sw-doctor; do
        cat > "$TEST_TEMP_DIR/repo/scripts/${name}.sh" <<SCRIPT
#!/usr/bin/env bash
# ║  ${name} — Mock script for testing
VERSION="3.3.0"
show_help() { echo "Usage: ${name}"; }
SCRIPT
    done

    cat > "$TEST_TEMP_DIR/repo/.claude/CLAUDE.md" <<'DOC'
# Test CLAUDE.md
pipeline and daemon are documented here.
<!-- AUTO:test-section -->
test content
<!-- /AUTO:test-section -->
DOC

    cat > "$TEST_TEMP_DIR/repo/README.md" <<'DOC'
# Test README
<!-- AUTO:core-scripts -->
test
<!-- /AUTO:core-scripts -->
DOC
}

trap cleanup_test_env EXIT

