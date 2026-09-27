#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright hygiene test — Repository Organization & Cleanup tests       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"

    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Create a mock script in the test repo
    cat > "$TEST_TEMP_DIR/repo/scripts/sw-example.sh" <<'MOCK_SCRIPT'
#!/usr/bin/env bash
example_func() { echo "hello"; }
MOCK_SCRIPT
    chmod +x "$TEST_TEMP_DIR/repo/scripts/sw-example.sh"

    # Create mock package.json
    echo '{"dependencies":{"jq":"*"},"devDependencies":{}}' > "$TEST_TEMP_DIR/repo/package.json"

    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        case "${2:-}" in
            --git-dir) echo ".git" ;;
            --abbrev-ref) echo "main" ;;
            *) echo "/tmp/mock-repo" ;;
        esac
        ;;
    fetch) exit 0 ;;
    branch) echo "" ;;
    add) exit 0 ;;
    commit) exit 0 ;;
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

    # Mock find to limit scope (avoid scanning host filesystem)
    cat > "$TEST_TEMP_DIR/bin/find" <<MOCK
#!/usr/bin/env bash
# Pass through to real find but only within our temp dir
$(command -v find) "\$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/find"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

