#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright strategic test — Validate strategic intelligence agent       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# setup_env re-exports SCRIPT_DIR to the mock repo (sw-strategic.sh reads it to
# resolve its own siblings), which would make every `$SCRIPT_DIR/sw-strategic.sh`
# invocation below point at a file that does not exist. Keep the real location
# separately and always launch the script under test from here.
REAL_SCRIPT_DIR="$SCRIPT_DIR"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
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
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    issue)
        case "${2:-}" in
            list) echo '[]' ;;
            create) echo "https://github.com/test/repo/issues/99" ;;
            *) echo '[]' ;;
        esac ;;
    label) exit 0 ;;
    *) echo '[]' ;;
esac
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
    export SCRIPT_DIR="$TEST_TEMP_DIR/repo/scripts"
    export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

    # Create mock scripts to count
    for i in 1 2 3 4 5; do
        echo '#!/usr/bin/env bash' > "$TEST_TEMP_DIR/repo/scripts/sw-test${i}.sh"
    done
    # Create one test file
    echo '#!/usr/bin/env bash' > "$TEST_TEMP_DIR/repo/scripts/sw-test1-test.sh"

    # Create STRATEGY.md
    echo "# Strategy" > "$TEST_TEMP_DIR/repo/STRATEGY.md"
    echo "P0: Reliability" >> "$TEST_TEMP_DIR/repo/STRATEGY.md"
}

trap cleanup_test_env EXIT

