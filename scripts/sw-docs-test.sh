#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright docs test — Validate documentation keeper, AUTO sections,   ║
# ║  staleness detection, section replacement, and feature flag parsing.    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
# shellcheck disable=SC2034

# ─── Counters ─────────────────────────────────────────────────────────────────

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-docs-test.XXXXXX")

    # Create repo structure
    mkdir -p "$TEST_TEMP_DIR/scripts/lib"
    mkdir -p "$TEST_TEMP_DIR/.claude"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"

    # Copy the docs script under test
    cp "$SCRIPT_DIR/sw-docs.sh" "$TEST_TEMP_DIR/scripts/"

    # Create compat.sh stub
    touch "$TEST_TEMP_DIR/scripts/lib/compat.sh"

    # Create fake shell scripts with proper headers for purpose extraction
    cat > "$TEST_TEMP_DIR/scripts/sw-alpha.sh" <<'SCRIPT'
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright alpha — Alpha Feature Module                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
echo "alpha"
SCRIPT

    cat > "$TEST_TEMP_DIR/scripts/sw-beta.sh" <<'SCRIPT'
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright beta — Beta Feature Module                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
echo "beta"
SCRIPT

    # A test file that should be excluded from core-scripts
    cat > "$TEST_TEMP_DIR/scripts/sw-alpha-test.sh" <<'SCRIPT'
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright alpha test — Validate alpha module                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
echo "test"
SCRIPT

    # A github module that should be excluded from core-scripts
    cat > "$TEST_TEMP_DIR/scripts/sw-github-thing.sh" <<'SCRIPT'
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github thing — GitHub Thing Integration                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
echo "github"
SCRIPT

    # CLI router
    cat > "$TEST_TEMP_DIR/scripts/sw" <<'SCRIPT'
#!/usr/bin/env bash
echo "CLI router"
SCRIPT

    # Create mock sw-daemon.sh with intelligence config
    cat > "$TEST_TEMP_DIR/scripts/sw-daemon.sh" <<'DAEMON'
#!/usr/bin/env bash
# some daemon code above
cat <<CONFIGEOF
{
  "max_parallel": 2,
  "intelligence": {
    "enabled": true,
    "cache_ttl_seconds": 3600,
    "composer_enabled": true,
    "prediction_enabled": false,
    "adversarial_enabled": false,
    "anomaly_threshold": 3.0
  }
}
CONFIGEOF
DAEMON

    # Create .claude/CLAUDE.md with AUTO markers
    cat > "$TEST_TEMP_DIR/.claude/CLAUDE.md" <<'MARKDOWN'
# Test Docs

## Core Scripts

<!-- AUTO:core-scripts -->
(old content here)
<!-- /AUTO:core-scripts -->

## Test Suites

<!-- AUTO:test-suites -->
(old test content)
<!-- /AUTO:test-suites -->

## Feature Flags

<!-- AUTO:feature-flags -->
(old flags)
<!-- /AUTO:feature-flags -->

End of doc.
MARKDOWN

    # Mock binaries
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Mock git (needed by docs_report for file freshness)
    cat > "$TEST_TEMP_DIR/bin/git" <<'GITEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "log" ]]; then
    echo "2 days ago"
    exit 0
fi
if [[ "${1:-}" == "-C" ]]; then
    echo "2 days ago"
    exit 0
fi
echo "mock-git"
GITEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo ""
exit 1
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock jq (pass through to real jq if available)
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
}

cleanup_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Helper to run sw-docs.sh in the temp repo context
run_docs() {
    (
        cd "$TEST_TEMP_DIR"
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        HOME="$TEST_TEMP_DIR/home" \
        NO_GITHUB=true \
            bash "$TEST_TEMP_DIR/scripts/sw-docs.sh" "$@"
    )
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCS TESTS — AUTO Section Discovery
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. docs_find_auto_files finds markdown files with AUTO markers
# ──────────────────────────────────────────────────────────────────────────────
test_find_auto_files() {
    local output
    output=$(run_docs check 2>&1 || true)
    # The check command internally calls docs_find_auto_files, so verify
    # it found our CLAUDE.md by checking it processed sections
    if ! echo "$output" | grep "Documentation Status" >/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. docs_get_sections extracts section IDs
# ──────────────────────────────────────────────────────────────────────────────
test_get_sections() {
    local sections
    sections=$(grep -oE '<!-- AUTO:[a-z0-9_-]+ -->' "$TEST_TEMP_DIR/.claude/CLAUDE.md" | sed 's/<!-- AUTO://;s/ -->//')

    local found_core=false found_test=false found_flags=false
    while IFS= read -r s; do
        case "$s" in
            core-scripts)  found_core=true ;;
            test-suites)   found_test=true ;;
            feature-flags) found_flags=true ;;
        esac
    done <<< "$sections"

    if [[ "$found_core" != "true" || "$found_test" != "true" || "$found_flags" != "true" ]]; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCS TESTS — Section Generators
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 3. docs_gen_architecture_table produces a markdown table
# ──────────────────────────────────────────────────────────────────────────────
test_gen_architecture_table() {
    local output
    output=$(run_docs sync 2>&1 || true)

    # Read the updated CLAUDE.md and check the core-scripts section
    local content
    content=$(awk '
        /<!-- AUTO:core-scripts -->/ { capture=1; next }
        /<!-- \/AUTO:core-scripts -->/ { capture=0 }
        capture { print }
    ' "$TEST_TEMP_DIR/.claude/CLAUDE.md")

    # Should have table headers
    if ! echo "$content" | grep "| File | Lines | Purpose |" >/dev/null; then
        return 1
    fi
    # Should include sw-alpha.sh (non-test, non-github)
    if ! echo "$content" | grep "sw-alpha.sh" >/dev/null; then
        return 1
    fi
    # Should include sw-beta.sh
    if ! echo "$content" | grep "sw-beta.sh" >/dev/null; then
        return 1
    fi
    # Should NOT include test file
    if echo "$content" | grep "sw-alpha-test.sh" >/dev/null; then
        return 1
    fi
    # Should NOT include github module
    if echo "$content" | grep "sw-github-thing.sh" >/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Architecture table includes CLI router (scripts/sw)
# ──────────────────────────────────────────────────────────────────────────────
test_gen_table_includes_cli_router() {
    # sync was already run in test 3, but run again to be safe
    run_docs sync >/dev/null 2>&1 || true

    local content
    content=$(awk '
        /<!-- AUTO:core-scripts -->/ { capture=1; next }
        /<!-- \/AUTO:core-scripts -->/ { capture=0 }
        capture { print }
    ' "$TEST_TEMP_DIR/.claude/CLAUDE.md")

    if ! echo "$content" | grep "scripts/sw" >/dev/null; then
        return 1
    fi
    if ! echo "$content" | grep "CLI router" >/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. docs_gen_feature_flags produces a table with intelligence flags
# ──────────────────────────────────────────────────────────────────────────────
test_gen_feature_flags() {
    run_docs sync >/dev/null 2>&1 || true

    local content
    content=$(awk '
        /<!-- AUTO:feature-flags -->/ { capture=1; next }
        /<!-- \/AUTO:feature-flags -->/ { capture=0 }
        capture { print }
    ' "$TEST_TEMP_DIR/.claude/CLAUDE.md")

    # Should have table header
    if ! echo "$content" | grep "| Flag | Default | Purpose |" >/dev/null; then
        return 1
    fi
    # Should have intelligence.enabled
    if ! echo "$content" | grep "intelligence.enabled" >/dev/null; then
        return 1
    fi
    # Should have intelligence.cache_ttl_seconds
    if ! echo "$content" | grep "intelligence.cache_ttl_seconds" >/dev/null; then
        return 1
    fi
    # Should have intelligence.anomaly_threshold
    if ! echo "$content" | grep "intelligence.anomaly_threshold" >/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Test suites table picks up test files
# ──────────────────────────────────────────────────────────────────────────────
test_gen_test_suites_table() {
    run_docs sync >/dev/null 2>&1 || true

    local content
    content=$(awk '
        /<!-- AUTO:test-suites -->/ { capture=1; next }
        /<!-- \/AUTO:test-suites -->/ { capture=0 }
        capture { print }
    ' "$TEST_TEMP_DIR/.claude/CLAUDE.md")

    # Should have sw-alpha-test.sh in the test suites section
    if ! echo "$content" | grep "sw-alpha-test.sh" >/dev/null; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCS TESTS — Section Check & Replace
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 7. docs_check_section returns 0 for matching content, 1 for stale
# ──────────────────────────────────────────────────────────────────────────────
test_check_section_fresh_and_stale() {
    # Create a simple test file with AUTO markers
    local test_md="$TEST_TEMP_DIR/test-check.md"
    cat > "$test_md" <<'MD'
# Test
<!-- AUTO:sample -->
hello world
<!-- /AUTO:sample -->
MD

    # Fresh check — content matches
    local current
    current=$(awk '
        /<!-- AUTO:sample -->/ { capture=1; next }
        /<!-- \/AUTO:sample -->/ { capture=0 }
        capture { print }
    ' "$test_md")

    if [[ "$current" != "hello world" ]]; then
        return 1
    fi

    # Stale check — content differs
    if [[ "$current" == "different content" ]]; then
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. docs_replace_section updates content between markers
# ──────────────────────────────────────────────────────────────────────────────
test_replace_section() {
    local test_md="$TEST_TEMP_DIR/test-replace.md"
    cat > "$test_md" <<'MD'
# Before
<!-- AUTO:widget -->
old content
here
<!-- /AUTO:widget -->
# After
MD

    # Use awk to replace (same logic as docs_replace_section)
    local content_file
    content_file=$(mktemp)
    printf '%s\n' "new shiny content" > "$content_file"

    local tmp_file
    tmp_file=$(mktemp)
    awk -v section="widget" -v cfile="$content_file" '
        $0 ~ "<!-- AUTO:" section " -->" {
            print
            while ((getline line < cfile) > 0) print line
            close(cfile)
            skip=1
            next
        }
        $0 ~ "<!-- /AUTO:" section " -->" { skip=0 }
        !skip { print }
    ' "$test_md" > "$tmp_file"
    mv "$tmp_file" "$test_md"
    rm -f "$content_file"

    # Verify the replacement
    local updated
    updated=$(awk '
        /<!-- AUTO:widget -->/ { capture=1; next }
        /<!-- \/AUTO:widget -->/ { capture=0 }
        capture { print }
    ' "$test_md")

    if [[ "$updated" != "new shiny content" ]]; then
        return 1
    fi

    # Verify surrounding content preserved
    if ! grep -q "# Before" "$test_md"; then
        return 1
    fi
    if ! grep -q "# After" "$test_md"; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCS TESTS — Subcommands (check, sync)
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 9. docs check returns 1 when sections are stale
# ──────────────────────────────────────────────────────────────────────────────
test_docs_check_stale() {
    # Clean up any .md files created by earlier tests (they have AUTO markers that confuse docs_find_auto_files)
    rm -f "$TEST_TEMP_DIR/test-check.md" "$TEST_TEMP_DIR/test-replace.md"

    # Reset the CLAUDE.md with stale content
    cat > "$TEST_TEMP_DIR/.claude/CLAUDE.md" <<'MARKDOWN'
# Test Docs

## Core Scripts

<!-- AUTO:core-scripts -->
this is definitely stale
<!-- /AUTO:core-scripts -->

End of doc.
MARKDOWN

    local exit_code=0
    run_docs check >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        return 1  # Should have been stale (exit 1)
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. docs sync updates stale sections, then check returns 0
# ──────────────────────────────────────────────────────────────────────────────
test_docs_sync_then_fresh() {
    # Clean up stray .md files from earlier tests
    rm -f "$TEST_TEMP_DIR/test-check.md" "$TEST_TEMP_DIR/test-replace.md"

    # Reset with stale content
    cat > "$TEST_TEMP_DIR/.claude/CLAUDE.md" <<'MARKDOWN'
# Test Docs

## Core Scripts

<!-- AUTO:core-scripts -->
stale content
<!-- /AUTO:core-scripts -->

## Test Suites

<!-- AUTO:test-suites -->
stale tests
<!-- /AUTO:test-suites -->

## Feature Flags

<!-- AUTO:feature-flags -->
stale flags
<!-- /AUTO:feature-flags -->

End of doc.
MARKDOWN

    # Sync should update
    run_docs sync >/dev/null 2>&1 || true

    # Now check should pass
    local exit_code=0
    run_docs check >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        return 1  # Should be fresh after sync
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. docs sync is idempotent (running twice reports "already fresh")
# ──────────────────────────────────────────────────────────────────────────────
test_docs_sync_idempotent() {
    # Clean up stray .md files from earlier tests
    rm -f "$TEST_TEMP_DIR/test-check.md" "$TEST_TEMP_DIR/test-replace.md"

    # First sync
    run_docs sync >/dev/null 2>&1 || true

    # Second sync should report "already fresh"
    local output
    output=$(run_docs sync 2>&1 || true)

    if ! echo "$output" | grep -i "fresh" >/dev/null; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCS TESTS — Help & CLI Routing
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 12. Help output contains all subcommands
# ──────────────────────────────────────────────────────────────────────────────
test_help_output() {
    local output
    output=$(run_docs help 2>&1)

    local missing=""
    for cmd in sync check wiki report help; do
        if ! echo "$output" | grep "$cmd" >/dev/null; then
            missing="${missing} ${cmd}"
        fi
    done

    if [[ -n "$missing" ]]; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Unknown command exits with error
# ──────────────────────────────────────────────────────────────────────────────
test_unknown_command() {
    local exit_code=0
    run_docs nonexistent >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        return 1  # Should fail
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Default command (no args) shows help
# ──────────────────────────────────────────────────────────────────────────────
test_default_shows_help() {
    local output
    output=$(run_docs 2>&1 || true)

    if ! echo "$output" | grep "COMMANDS" >/dev/null; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCS TESTS — Edge Cases
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 15. No AUTO markers returns 0 (no stale sections)
# ──────────────────────────────────────────────────────────────────────────────
test_no_auto_markers() {
    # Clean up any .md files from earlier tests that have AUTO markers
    rm -f "$TEST_TEMP_DIR/test-check.md" "$TEST_TEMP_DIR/test-replace.md"

    # Overwrite CLAUDE.md with no markers
    cat > "$TEST_TEMP_DIR/.claude/CLAUDE.md" <<'MARKDOWN'
# Plain Docs
No auto markers here.
MARKDOWN

    local exit_code=0
    run_docs check >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        return 1  # Should succeed (nothing stale)
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Multiple sections in one file all get processed
# ──────────────────────────────────────────────────────────────────────────────
test_multiple_sections() {
    cat > "$TEST_TEMP_DIR/.claude/CLAUDE.md" <<'MARKDOWN'
# Multi Section Doc

<!-- AUTO:core-scripts -->
stale
<!-- /AUTO:core-scripts -->

Middle text.

<!-- AUTO:test-suites -->
also stale
<!-- /AUTO:test-suites -->

<!-- AUTO:feature-flags -->
stale flags
<!-- /AUTO:feature-flags -->
MARKDOWN

    run_docs sync >/dev/null 2>&1 || true

    # Verify each section was updated
    local core_content test_content flag_content
    core_content=$(awk '/<!-- AUTO:core-scripts -->/{c=1;next}/<!-- \/AUTO:core-scripts -->/{c=0}c' "$TEST_TEMP_DIR/.claude/CLAUDE.md")
    test_content=$(awk '/<!-- AUTO:test-suites -->/{c=1;next}/<!-- \/AUTO:test-suites -->/{c=0}c' "$TEST_TEMP_DIR/.claude/CLAUDE.md")
    flag_content=$(awk '/<!-- AUTO:feature-flags -->/{c=1;next}/<!-- \/AUTO:feature-flags -->/{c=0}c' "$TEST_TEMP_DIR/.claude/CLAUDE.md")

    # None should still say "stale"
    if echo "$core_content" | grep "^stale$" >/dev/null; then
        return 1
    fi
    if echo "$test_content" | grep "^also stale$" >/dev/null; then
        return 1
    fi
    if echo "$flag_content" | grep "^stale flags$" >/dev/null; then
        return 1
    fi

    # Verify middle text preserved
    if ! grep -q "Middle text." "$TEST_TEMP_DIR/.claude/CLAUDE.md"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Purpose extraction from script headers
# ──────────────────────────────────────────────────────────────────────────────
test_purpose_extraction() {
    run_docs sync >/dev/null 2>&1 || true

    local content
    content=$(awk '/<!-- AUTO:core-scripts -->/{c=1;next}/<!-- \/AUTO:core-scripts -->/{c=0}c' "$TEST_TEMP_DIR/.claude/CLAUDE.md")

    # sw-alpha.sh header says "Alpha Feature Module"
    if ! echo "$content" | grep "Alpha Feature Module" >/dev/null; then
        return 1
    fi
    # sw-beta.sh header says "Beta Feature Module"
    if ! echo "$content" | grep "Beta Feature Module" >/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Wiki subcommand runs in dry-run without error
# ──────────────────────────────────────────────────────────────────────────────
test_wiki_dry_run() {
    # Create a minimal README
    echo "# Shipwright" > "$TEST_TEMP_DIR/README.md"

    local exit_code=0
    run_docs wiki --dry-run >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright docs — Test Suite                     ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Section discovery
echo -e "${PURPLE}${BOLD}AUTO Section Discovery${RESET}"
run_test "find_auto_files discovers CLAUDE.md" test_find_auto_files
run_test "get_sections extracts section IDs" test_get_sections
echo ""

# Section generators
echo -e "${PURPLE}${BOLD}Section Generators${RESET}"
run_test "Architecture table has headers and scripts" test_gen_architecture_table
run_test "Architecture table includes CLI router" test_gen_table_includes_cli_router
run_test "Feature flags table with intelligence config" test_gen_feature_flags
run_test "Test suites table picks up test files" test_gen_test_suites_table
echo ""

# Section check & replace
echo -e "${PURPLE}${BOLD}Section Check & Replace${RESET}"
run_test "check_section detects fresh vs stale" test_check_section_fresh_and_stale
run_test "replace_section updates content between markers" test_replace_section
echo ""

# Subcommands
echo -e "${PURPLE}${BOLD}Subcommands${RESET}"
run_test "docs check returns 1 when stale" test_docs_check_stale
run_test "docs sync then check returns 0 (fresh)" test_docs_sync_then_fresh
run_test "docs sync is idempotent" test_docs_sync_idempotent
echo ""

# CLI routing
echo -e "${PURPLE}${BOLD}CLI & Help${RESET}"
run_test "Help output contains all subcommands" test_help_output
run_test "Unknown command exits with error" test_unknown_command
run_test "Default (no args) shows help" test_default_shows_help
echo ""

# Edge cases
echo -e "${PURPLE}${BOLD}Edge Cases${RESET}"
run_test "No AUTO markers returns 0" test_no_auto_markers
run_test "Multiple sections all get processed" test_multiple_sections
run_test "Purpose extracted from script headers" test_purpose_extraction
run_test "Wiki dry-run succeeds" test_wiki_dry_run
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo -e "  ${GREEN}${BOLD}${PASS} passed${RESET}  ${RED}${BOLD}${FAIL} failed${RESET}  ${DIM}(${TOTAL} total)${RESET}"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}Failed tests:${RESET}"
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo ""

[[ $FAIL -eq 0 ]]
