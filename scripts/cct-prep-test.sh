#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright prep test — Validate repo preparation                             ║
# ║  Every test runs cct-prep.sh as a subprocess · No logic reimpl.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP_SCRIPT="$SCRIPT_DIR/cct-prep.sh"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT SETUP
# Creates a temporary directory for each test run.
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-prep-test.XXXXXX")
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# PROJECT CREATORS — set up mock repos for each language
# ═══════════════════════════════════════════════════════════════════════════════

create_node_project() {
    local dir="$1"
    mkdir -p "$dir/src"
    cat > "$dir/package.json" <<'PKG'
{
  "name": "test-node-project",
  "version": "1.0.0",
  "scripts": {
    "test": "jest",
    "build": "tsc",
    "lint": "eslint .",
    "dev": "nodemon"
  },
  "dependencies": {
    "express": "^4.18.0"
  },
  "devDependencies": {
    "jest": "^29.0.0",
    "eslint": "^8.0.0",
    "typescript": "^5.0.0"
  }
}
PKG
    cat > "$dir/src/index.js" <<'SRC'
const express = require('express');
const app = express();
app.get('/health', (req, res) => res.json({ status: 'ok' }));
module.exports = app;
SRC
    init_git_repo "$dir"
}

create_python_project() {
    local dir="$1"
    mkdir -p "$dir/src" "$dir/tests"
    cat > "$dir/requirements.txt" <<'REQ'
fastapi>=0.100.0
uvicorn>=0.23.0
REQ
    cat > "$dir/src/main.py" <<'SRC'
from fastapi import FastAPI
app = FastAPI()

@app.get("/health")
def health():
    return {"status": "ok"}
SRC
    init_git_repo "$dir"
}

create_go_project() {
    local dir="$1"
    mkdir -p "$dir/cmd"
    cat > "$dir/go.mod" <<'MOD'
module example.com/test-project

go 1.21
MOD
    cat > "$dir/cmd/main.go" <<'SRC'
package main

import "fmt"

func main() {
    fmt.Println("Hello")
}
SRC
    init_git_repo "$dir"
}

create_rust_project() {
    local dir="$1"
    mkdir -p "$dir/src"
    cat > "$dir/Cargo.toml" <<'TOML'
[package]
name = "test-project"
version = "0.1.0"
edition = "2021"
TOML
    cat > "$dir/src/main.rs" <<'SRC'
fn main() {
    println!("Hello, world!");
}
SRC
    init_git_repo "$dir"
}

init_git_repo() {
    local dir="$1"
    (
        cd "$dir"
        git init --quiet -b main
        git config user.email "test@test.com"
        git config user.name "Test User"
        git add -A
        git commit -m "Initial commit" --quiet
    )
}

# ═══════════════════════════════════════════════════════════════════════════════
# PREP INVOCATION HELPER
# Every test calls this to invoke the REAL prep script as a subprocess.
# ═══════════════════════════════════════════════════════════════════════════════

PREP_OUTPUT=""
PREP_EXIT=0

invoke_prep() {
    local test_dir="$1"
    shift
    PREP_OUTPUT=""
    PREP_EXIT=0

    PREP_OUTPUT=$(
        cd "$test_dir"
        bash "$PREP_SCRIPT" "$@" 2>&1
    ) || PREP_EXIT=$?
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_exit_code() {
    local expected="$1" label="${2:-exit code}"
    if [[ "$PREP_EXIT" -eq "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit code $expected, got $PREP_EXIT ($label)"
    return 1
}

assert_output_contains() {
    local pattern="$1" label="${2:-output match}"
    if echo "$PREP_OUTPUT" | grep -qiE "$pattern"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $pattern ($label)"
    echo -e "    ${DIM}Output (last 5 lines):${RESET}"
    echo "$PREP_OUTPUT" | tail -5 | sed 's/^/      /'
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_file_contains() {
    local filepath="$1" pattern="$2" label="${3:-file content}"
    if [[ ! -f "$filepath" ]]; then
        echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
        return 1
    fi
    if grep -qiE "$pattern" "$filepath"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File $filepath missing pattern: $pattern ($label)"
    return 1
}

assert_file_not_contains() {
    local filepath="$1" pattern="$2" label="${3:-file exclusion}"
    if [[ ! -f "$filepath" ]]; then
        # File doesn't exist — pattern can't be in it, so pass
        return 0
    fi
    if ! grep -qiE "$pattern" "$filepath"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File $filepath unexpectedly contains: $pattern ($label)"
    return 1
}

assert_file_executable() {
    local filepath="$1" label="${2:-executable}"
    if [[ -x "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not executable: $filepath ($label)"
    return 1
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
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS — Each invokes the REAL prep script. NO logic reimplementation.
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Node.js project detection
# ──────────────────────────────────────────────────────────────────────────────
test_nodejs_detection() {
    local test_dir="$TEMP_DIR/nodejs"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed" &&
    assert_file_exists "$test_dir/.claude/CLAUDE.md" "CLAUDE.md generated" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "nodejs|typescript" "language detected" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "npm|yarn|pnpm" "package manager detected" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "express" "framework detected"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Python project detection
# ──────────────────────────────────────────────────────────────────────────────
test_python_detection() {
    local test_dir="$TEMP_DIR/python"
    mkdir -p "$test_dir"
    create_python_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed" &&
    assert_file_exists "$test_dir/.claude/CLAUDE.md" "CLAUDE.md generated" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "python" "language detected" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "fastapi" "framework detected" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "pytest|pip" "python tooling detected"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Go project detection
# ──────────────────────────────────────────────────────────────────────────────
test_go_detection() {
    local test_dir="$TEMP_DIR/go"
    mkdir -p "$test_dir"
    create_go_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed" &&
    assert_file_exists "$test_dir/.claude/CLAUDE.md" "CLAUDE.md generated" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "go" "language detected" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "go test|go build" "go commands in CLAUDE.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Rust project detection
# ──────────────────────────────────────────────────────────────────────────────
test_rust_detection() {
    local test_dir="$TEMP_DIR/rust"
    mkdir -p "$test_dir"
    create_rust_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed" &&
    assert_file_exists "$test_dir/.claude/CLAUDE.md" "CLAUDE.md generated" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "rust" "language detected" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "cargo" "cargo commands in CLAUDE.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. settings.json is valid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_settings_json_valid() {
    local test_dir="$TEMP_DIR/settings"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed" &&
    assert_file_exists "$test_dir/.claude/settings.json" "settings.json generated"

    # Validate with jq
    if ! jq empty "$test_dir/.claude/settings.json" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} settings.json is not valid JSON"
        return 1
    fi

    # Verify it has a permissions.allow array
    local allow_count
    allow_count=$(jq '.permissions.allow | length' "$test_dir/.claude/settings.json" 2>/dev/null || echo "0")
    if [[ "$allow_count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} settings.json has no permissions.allow entries"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Hooks are executable
# ──────────────────────────────────────────────────────────────────────────────
test_hooks_executable() {
    local test_dir="$TEMP_DIR/hooks-exec"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed"

    # Check each hook
    local hook_found=false
    for hook in "$test_dir/.claude/hooks/"*.sh; do
        [[ -f "$hook" ]] || continue
        hook_found=true
        if ! assert_file_executable "$hook" "$(basename "$hook") executable"; then
            return 1
        fi
    done

    if ! $hook_found; then
        echo -e "    ${RED}✗${RESET} No hook scripts found in .claude/hooks/"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Hooks have valid bash syntax
# ──────────────────────────────────────────────────────────────────────────────
test_hooks_syntax_valid() {
    local test_dir="$TEMP_DIR/hooks-syntax"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed"

    for hook in "$test_dir/.claude/hooks/"*.sh; do
        [[ -f "$hook" ]] || continue
        if ! bash -n "$hook" 2>/dev/null; then
            echo -e "    ${RED}✗${RESET} Syntax error in $(basename "$hook")"
            return 1
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. CLAUDE.md has required sections
# ──────────────────────────────────────────────────────────────────────────────
test_claude_md_sections() {
    local test_dir="$TEMP_DIR/sections"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed" &&
    assert_file_exists "$test_dir/.claude/CLAUDE.md" "CLAUDE.md exists" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "## Stack" "has Stack section" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "## Commands" "has Commands section" &&
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "## Structure|## Conventions|## Important" "has Structure/Conventions section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Check mode outputs scoring without overwriting
# ──────────────────────────────────────────────────────────────────────────────
test_check_mode() {
    local test_dir="$TEMP_DIR/check-mode"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    # First run: generate files
    invoke_prep "$test_dir" --force
    assert_exit_code 0 "initial prep should succeed"

    # Record content hash of CLAUDE.md (more reliable than mtime across platforms)
    local hash_before
    hash_before=$(shasum "$test_dir/.claude/CLAUDE.md" 2>/dev/null | awk '{print $1}' || md5sum "$test_dir/.claude/CLAUDE.md" 2>/dev/null | awk '{print $1}' || cat "$test_dir/.claude/CLAUDE.md" | wc -c)

    # Second run: check mode
    invoke_prep "$test_dir" --check

    assert_exit_code 0 "check should succeed" &&
    assert_output_contains "Score|Grade|Audit" "check shows scoring"

    # Verify file content was not modified
    local hash_after
    hash_after=$(shasum "$test_dir/.claude/CLAUDE.md" 2>/dev/null | awk '{print $1}' || md5sum "$test_dir/.claude/CLAUDE.md" 2>/dev/null | awk '{print $1}' || cat "$test_dir/.claude/CLAUDE.md" | wc -c)

    if [[ "$hash_before" != "$hash_after" ]]; then
        echo -e "    ${RED}✗${RESET} CLAUDE.md content was modified during --check"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Idempotency — second run without --force doesn't overwrite
# ──────────────────────────────────────────────────────────────────────────────
test_idempotency() {
    local test_dir="$TEMP_DIR/idempotent"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    # First run
    invoke_prep "$test_dir" --force
    assert_exit_code 0 "first prep should succeed"

    # Record content
    local content_before
    content_before=$(cat "$test_dir/.claude/CLAUDE.md")

    # Small delay
    sleep 1

    # Record modification time
    local mtime_before
    mtime_before=$(stat -f "%m" "$test_dir/.claude/CLAUDE.md" 2>/dev/null || stat -c "%Y" "$test_dir/.claude/CLAUDE.md" 2>/dev/null)

    # Second run without --force
    invoke_prep "$test_dir"
    assert_exit_code 0 "second prep should succeed"

    # Verify file was NOT rewritten (mtime unchanged)
    local mtime_after
    mtime_after=$(stat -f "%m" "$test_dir/.claude/CLAUDE.md" 2>/dev/null || stat -c "%Y" "$test_dir/.claude/CLAUDE.md" 2>/dev/null)

    if [[ "$mtime_before" != "$mtime_after" ]]; then
        echo -e "    ${RED}✗${RESET} CLAUDE.md was overwritten without --force"
        return 1
    fi

    # Verify output mentions skipping
    assert_output_contains "Skipping|exists" "output mentions skipping existing files"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. --force overwrites modified files
# ──────────────────────────────────────────────────────────────────────────────
test_force_overwrites() {
    local test_dir="$TEMP_DIR/force"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    # First run
    invoke_prep "$test_dir" --force
    assert_exit_code 0 "first prep should succeed"

    # Modify a generated file with a unique marker
    echo "# CUSTOM_MARKER_12345" >> "$test_dir/.claude/CLAUDE.md"
    assert_file_contains "$test_dir/.claude/CLAUDE.md" "CUSTOM_MARKER_12345" "marker was added"

    # Re-run with --force
    invoke_prep "$test_dir" --force
    assert_exit_code 0 "forced prep should succeed"

    # Verify marker was overwritten
    assert_file_not_contains "$test_dir/.claude/CLAUDE.md" "CUSTOM_MARKER_12345" "marker was overwritten by --force"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. No eval in generated hooks
# ──────────────────────────────────────────────────────────────────────────────
test_no_eval_in_hooks() {
    local test_dir="$TEMP_DIR/no-eval"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed"

    # Check all hooks for eval
    local eval_count=0
    for hook in "$test_dir/.claude/hooks/"*.sh; do
        [[ -f "$hook" ]] || continue
        local count
        count=$(grep -c 'eval ' "$hook" 2>/dev/null || true)
        eval_count=$((eval_count + ${count:-0}))
    done

    if [[ "$eval_count" -gt 0 ]]; then
        echo -e "    ${RED}✗${RESET} Found $eval_count eval statement(s) in hook scripts"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Definition of Done is generated with checklist items
# ──────────────────────────────────────────────────────────────────────────────
test_dod_generated() {
    local test_dir="$TEMP_DIR/dod"
    mkdir -p "$test_dir"
    create_node_project "$test_dir"

    invoke_prep "$test_dir" --force

    assert_exit_code 0 "prep should succeed" &&
    assert_file_exists "$test_dir/.claude/DEFINITION-OF-DONE.md" "DoD file exists" &&
    assert_file_contains "$test_dir/.claude/DEFINITION-OF-DONE.md" "\\- \\[" "DoD has checklist items" &&
    assert_file_contains "$test_dir/.claude/DEFINITION-OF-DONE.md" "Definition of Done" "DoD has title" &&
    assert_file_contains "$test_dir/.claude/DEFINITION-OF-DONE.md" "tests pass" "DoD mentions tests"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright prep test — Validation Suite (Real Subprocess)        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the real prep script exists
    if [[ ! -f "$PREP_SCRIPT" ]]; then
        echo -e "${RED}✗ Prep script not found: $PREP_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available (required by prep)
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_nodejs_detection:Node.js project detection"
        "test_python_detection:Python project detection"
        "test_go_detection:Go project detection"
        "test_rust_detection:Rust project detection"
        "test_settings_json_valid:settings.json is valid JSON"
        "test_hooks_executable:Hook scripts are executable"
        "test_hooks_syntax_valid:Hook scripts have valid syntax"
        "test_claude_md_sections:CLAUDE.md has required sections"
        "test_check_mode:Check mode outputs scoring"
        "test_idempotency:Idempotency without --force"
        "test_force_overwrites:--force overwrites modified files"
        "test_no_eval_in_hooks:No eval in generated hooks"
        "test_dod_generated:Definition of Done generated"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
