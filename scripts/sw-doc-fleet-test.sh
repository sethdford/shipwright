#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright doc-fleet test — Validate documentation fleet operations     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/doc-fleet"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/agents"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEST_TEMP_DIR/repo/docs/strategy"
    mkdir -p "$TEST_TEMP_DIR/repo/docs/patterns"
    mkdir -p "$TEST_TEMP_DIR/repo/docs/tmux-research"
    mkdir -p "$TEST_TEMP_DIR/repo/claude-code"

    # Link real jq if available
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock binaries
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "abc1234" ;;
    diff) echo "docs/README.md" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    has-session) exit 1 ;;
    new-session) exit 0 ;;
    kill-session) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock stat to return a recent modification time
    cat > "$TEST_TEMP_DIR/bin/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-f" ]]; then
    echo "$(date +%s)"
elif [[ "${1:-}" == "-c" ]]; then
    echo "$(date +%s)"
else
    /usr/bin/stat "$@" 2>/dev/null || echo "0"
fi
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/stat"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true

    # Create mock documentation files
    echo "# Test README" > "$TEST_TEMP_DIR/repo/README.md"
    echo "# Strategy" > "$TEST_TEMP_DIR/repo/STRATEGY.md"
    cat > "$TEST_TEMP_DIR/repo/STRATEGY.md" <<'DOC'
# Strategy

This is the Shipwright strategy document with enough content
to pass the line count check in the audit function.

## Priorities

- P0: Reliability
- P1: Developer Experience
- P2: Intelligence
- P3: Cost Optimization
- P4: Observability
- P5: Community
- P6: Platform Self-Improvement

## Metrics

Current metrics and targets are listed below.

## Vision

Make autonomous delivery accessible.

## Mission

Continuously improve via data from each run.

## Principles

- Bash-first
- Atomic operations
- Graceful degradation
- Data-driven decisions

## Out of Scope

- GUI applications
- Non-Claude integration

Lots of filler content to get past the line check threshold
so we have more than 50 lines in this mock strategy document.
More lines here to pad it out sufficiently for the test suite
to verify that the health audit does not flag it as too thin.
DOC

    echo "# Changelog" > "$TEST_TEMP_DIR/repo/CHANGELOG.md"
    echo "# Tips" > "$TEST_TEMP_DIR/repo/docs/TIPS.md"
    echo "# Known Issues" > "$TEST_TEMP_DIR/repo/docs/KNOWN-ISSUES.md"
    echo "# Config Policy" > "$TEST_TEMP_DIR/repo/docs/config-policy.md"
    echo "# Strategy Index" > "$TEST_TEMP_DIR/repo/docs/strategy/README.md"
    echo "# Patterns Index" > "$TEST_TEMP_DIR/repo/docs/patterns/README.md"
    echo "# tmux Index" > "$TEST_TEMP_DIR/repo/docs/tmux-research/TMUX-RESEARCH-INDEX.md"

    # Create CLAUDE.md and agent definitions
    cat > "$TEST_TEMP_DIR/repo/.claude/CLAUDE.md" <<'DOC'
# Shipwright
Commands and documentation
<!-- AUTO:test-section -->
test content
<!-- /AUTO:test-section -->
DOC

    for agent in pipeline-agent code-reviewer test-specialist devops-engineer shell-script-specialist doc-fleet-agent; do
        echo "# ${agent}" > "$TEST_TEMP_DIR/repo/.claude/agents/${agent}.md"
    done

    # Create sw-docs.sh mock that succeeds
    cat > "$TEST_TEMP_DIR/repo/scripts/sw-docs.sh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    check) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/repo/scripts/sw-docs.sh"

    # Create sw-loop.sh mock
    cat > "$TEST_TEMP_DIR/repo/scripts/sw-loop.sh" <<'MOCK'
#!/usr/bin/env bash
echo "Mock loop"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/repo/scripts/sw-loop.sh"

    # Create some scripts for ratio check
    for s in sw-pipeline sw-daemon sw-loop sw-status sw-doctor; do
        echo "#!/usr/bin/env bash" > "$TEST_TEMP_DIR/repo/scripts/${s}.sh"
    done
}

trap cleanup_test_env EXIT

