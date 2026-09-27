#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright worktree test — Git worktree management for agent isolation  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    # Mock git that simulates a repo at TEMP_DIR/repo
    MOCK_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$MOCK_REPO/.worktrees"
    # Create a .gitignore file (not directory)
    touch "$MOCK_REPO/.gitignore"
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        if [[ "\${2:-}" == "--show-toplevel" ]]; then echo "$MOCK_REPO"
        elif [[ "\${2:-}" == "--abbrev-ref" ]]; then echo "main"
        elif [[ "\${2:-}" == "--is-inside-work-tree" ]]; then echo "true"
        elif [[ "\${2:-}" == "--verify" ]]; then exit 0
        else echo "abc1234"; fi ;;
    branch)
        if [[ "\${2:-}" == "--show-current" ]]; then echo "main"
        elif [[ "\${2:-}" == "--list" ]]; then echo ""
        else echo "main"; fi
        exit 0 ;;
    worktree)
        case "\${2:-}" in
            add) exit 0 ;;
            remove) exit 0 ;;
            prune) exit 0 ;;
            list) echo "$MOCK_REPO abc1234 [main]" ;;
        esac
        exit 0 ;;
    merge) exit 0 ;;
    fetch) exit 0 ;;
    status) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

