#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright context test — Context Engine for Pipeline Stages tests      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"

    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    if command -v shasum &>/dev/null; then
        ln -sf "$(command -v shasum)" "$TEST_TEMP_DIR/bin/shasum"
    fi

    # Create a mock CLAUDE.md
    cat > "$TEST_TEMP_DIR/repo/.claude/CLAUDE.md" <<'MOCK_MD'
# Shipwright

## Shell Standards
- All scripts use set -euo pipefail
- Bash 3.2 compatible

### Common Pitfalls
- grep -c under pipefail = double output

## Other Section
MOCK_MD

    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    config)
        case "${3:-}" in
            remote.origin.url) echo "git@github.com:test/repo.git" ;;
            *) echo "" ;;
        esac
        ;;
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

    # Create a mock find that works with the repo dir
    cat > "$TEST_TEMP_DIR/bin/find" <<MOCK
#!/usr/bin/env bash
$(command -v find) "\$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/find"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    export SHIPWRIGHT_REPO_DIR="$TEST_TEMP_DIR/repo"
}

trap cleanup_test_env EXIT

