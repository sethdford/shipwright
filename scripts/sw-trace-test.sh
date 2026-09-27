#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright trace test — E2E traceability (Issue → Commit → PR → Deploy)║
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
    MOCK_REPO_DIR="$TEST_TEMP_DIR/mock-repo"
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        if [[ "\${2:-}" == "--show-toplevel" ]]; then echo "$MOCK_REPO_DIR"
        elif [[ "\${2:-}" == "--is-inside-work-tree" ]]; then echo "true"
        else echo "abc1234"; fi ;;
    log) echo "abc1234 fix: something" ;;
    branch)
        if [[ "\${2:-}" == "-r" ]]; then echo ""
        elif [[ "\${2:-}" == "--show-current" ]]; then echo "main"
        else echo ""; fi ;;
    show-ref) exit 1 ;;
    worktree) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    issue)
        echo '{"title":"Test Issue","state":"OPEN","assignees":[],"labels":[],"url":"https://github.com/test/repo/issues/42","createdAt":"2026-01-15T10:00:00Z","closedAt":null}'
        ;;
    pr)
        echo '[]'
        ;;
    repo)
        echo "test/repo"
        ;;
    *)
        echo '[]'
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$MOCK_REPO_DIR/.claude/pipeline-artifacts"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

