#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright checkpoint test — Validate checkpoint save/restore           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
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

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-checkpoint-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/.claude/pipeline-artifacts/checkpoints"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls stat shasum; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        elif [[ "${2:-}" == "HEAD" ]]; then echo "abc1234def5678"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEMP_DIR/bin/$mock"
        chmod +x "$TEMP_DIR/bin/$mock"
    done

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

# ─── Setup ────────────────────────────────────────────────────────────────────
setup_env

SRC="$SCRIPT_DIR/sw-checkpoint.sh"

# Run tests from within mock repo so CHECKPOINT_DIR is relative to it
cd "$TEMP_DIR/repo"

echo ""
echo -e "${CYAN}${BOLD}  shipwright checkpoint test${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

if grep -qF 'set -euo pipefail' "$SRC" 2>/dev/null; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -qF 'trap' "$SRC" 2>/dev/null; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -qE '^VERSION=' "$SRC" 2>/dev/null; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

echo ""

# ─── 2. Help ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

HELP_OUT=$(bash "$SRC" help 2>&1) || true

assert_contains "help exits 0 and contains USAGE" "$HELP_OUT" "USAGE"
assert_contains "help lists 'save' subcommand" "$HELP_OUT" "save"
assert_contains "help lists 'restore' subcommand" "$HELP_OUT" "restore"
assert_contains "help lists 'list' subcommand" "$HELP_OUT" "list"
assert_contains "help lists 'clear' subcommand" "$HELP_OUT" "clear"
assert_contains "help lists 'expire' subcommand" "$HELP_OUT" "expire"

HELP2=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help alias works" "$HELP2" "USAGE"

HELP3=$(bash "$SRC" -h 2>&1) || true
assert_contains "-h alias works" "$HELP3" "USAGE"

echo ""

# ─── 3. Error Handling ───────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_fail "Unknown command exits non-zero"
else
    assert_pass "Unknown command exits non-zero"
fi

echo ""

# ─── 4. Save subcommand ─────────────────────────────────────────────────────
echo -e "${BOLD}  Save Subcommand${RESET}"

# save without --stage exits non-zero
if bash "$SRC" save 2>/dev/null; then
    assert_fail "save without --stage exits non-zero"
else
    assert_pass "save without --stage exits non-zero"
fi

# save with --stage creates checkpoint file
bash "$SRC" save --stage build --iteration 5 2>/dev/null || true
CKPT=".claude/pipeline-artifacts/checkpoints/build-checkpoint.json"
if [[ -f "$CKPT" ]]; then
    assert_pass "save creates checkpoint file"
else
    assert_fail "save creates checkpoint file"
fi

# Verify checkpoint is valid JSON
if jq empty "$CKPT" 2>/dev/null; then
    assert_pass "Checkpoint is valid JSON"
else
    assert_fail "Checkpoint is valid JSON"
fi

# Verify stage field
STAGE_VAL=$(jq -r '.stage' "$CKPT" 2>/dev/null || echo "")
assert_eq "Checkpoint stage field correct" "build" "$STAGE_VAL"

# Verify iteration field
ITER_VAL=$(jq -r '.iteration' "$CKPT" 2>/dev/null || echo "")
assert_eq "Checkpoint iteration field correct" "5" "$ITER_VAL"

# Verify git_sha is populated (from mock git)
SHA_VAL=$(jq -r '.git_sha' "$CKPT" 2>/dev/null || echo "")
if [[ -n "$SHA_VAL" && "$SHA_VAL" != "null" ]]; then
    assert_pass "Checkpoint git_sha populated"
else
    assert_fail "Checkpoint git_sha populated"
fi

# save with --tests-passing flag
bash "$SRC" save --stage test --tests-passing 2>/dev/null || true
CKPT2=".claude/pipeline-artifacts/checkpoints/test-checkpoint.json"
TESTS_VAL=$(jq -r '.tests_passing' "$CKPT2" 2>/dev/null || echo "")
assert_eq "save --tests-passing sets true" "true" "$TESTS_VAL"

# save with --files-modified
bash "$SRC" save --stage review --files-modified "src/a.ts,src/b.ts" 2>/dev/null || true
CKPT3=".claude/pipeline-artifacts/checkpoints/review-checkpoint.json"
FILES_COUNT=$(jq '.files_modified | length' "$CKPT3" 2>/dev/null || echo "0")
assert_eq "save --files-modified stores 2 files" "2" "$FILES_COUNT"

# save with --loop-state
bash "$SRC" save --stage deploy --loop-state running 2>/dev/null || true
CKPT4=".claude/pipeline-artifacts/checkpoints/deploy-checkpoint.json"
LOOP_VAL=$(jq -r '.loop_state' "$CKPT4" 2>/dev/null || echo "")
assert_eq "save --loop-state stores state" "running" "$LOOP_VAL"

# Verify created_at timestamp is present
CREATED=$(jq -r '.created_at' "$CKPT" 2>/dev/null || echo "")
if [[ -n "$CREATED" && "$CREATED" != "null" ]]; then
    assert_pass "Checkpoint created_at timestamp present"
else
    assert_fail "Checkpoint created_at timestamp present"
fi

echo ""

# ─── 5. Restore subcommand ──────────────────────────────────────────────────
echo -e "${BOLD}  Restore Subcommand${RESET}"

# restore returns checkpoint JSON
OUT=$(bash "$SRC" restore --stage build 2>/dev/null) || true
if echo "$OUT" | jq -e '.stage' >/dev/null 2>&1; then
    assert_pass "restore returns checkpoint JSON"
else
    assert_fail "restore returns checkpoint JSON" "$OUT"
fi

RESTORED_STAGE=$(echo "$OUT" | jq -r '.stage' 2>/dev/null || echo "")
assert_eq "Restored checkpoint has correct stage" "build" "$RESTORED_STAGE"

# restore with missing stage exits non-zero
if bash "$SRC" restore --stage nonexistent 2>/dev/null; then
    assert_fail "restore missing stage exits non-zero"
else
    assert_pass "restore missing stage exits non-zero"
fi

# restore without --stage exits non-zero
if bash "$SRC" restore 2>/dev/null; then
    assert_fail "restore without --stage exits non-zero"
else
    assert_pass "restore without --stage exits non-zero"
fi

echo ""

# ─── 6. List subcommand ─────────────────────────────────────────────────────
echo -e "${BOLD}  List Subcommand${RESET}"

LIST_OUT=$(bash "$SRC" list 2>&1) || true
assert_contains "list shows Checkpoints header" "$LIST_OUT" "Checkpoints"
assert_contains "list shows build checkpoint" "$LIST_OUT" "build"
assert_contains "list shows checkpoint count" "$LIST_OUT" "checkpoint(s)"

# list with no checkpoints
rm -f .claude/pipeline-artifacts/checkpoints/*-checkpoint.json
LIST_OUT2=$(bash "$SRC" list 2>&1) || true
assert_contains "list with no checkpoints shows empty" "$LIST_OUT2" "No checkpoints found"

echo ""

# ─── 7. Clear subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}  Clear Subcommand${RESET}"

# Create some checkpoints first
bash "$SRC" save --stage build --iteration 1 2>/dev/null || true
bash "$SRC" save --stage test --iteration 2 2>/dev/null || true

# clear --stage removes specific checkpoint
bash "$SRC" clear --stage build 2>/dev/null || true
if [[ ! -f ".claude/pipeline-artifacts/checkpoints/build-checkpoint.json" ]]; then
    assert_pass "clear --stage removes specific checkpoint"
else
    assert_fail "clear --stage removes specific checkpoint"
fi

# The other checkpoint should still exist
if [[ -f ".claude/pipeline-artifacts/checkpoints/test-checkpoint.json" ]]; then
    assert_pass "clear --stage preserves other checkpoints"
else
    assert_fail "clear --stage preserves other checkpoints"
fi

# clear without args exits non-zero
if bash "$SRC" clear 2>/dev/null; then
    assert_fail "clear without args exits non-zero"
else
    assert_pass "clear without args exits non-zero"
fi

# clear --all removes all checkpoints
bash "$SRC" save --stage build --iteration 3 2>/dev/null || true
bash "$SRC" clear --all 2>/dev/null || true
REMAINING=$(find .claude/pipeline-artifacts/checkpoints -name "*-checkpoint.json" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "clear --all removes all checkpoints" "0" "$REMAINING"

echo ""

# ─── 8. Expire subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}  Expire Subcommand${RESET}"

# expire with no checkpoints exits 0
if bash "$SRC" expire --hours 1 2>/dev/null; then
    assert_pass "expire with no checkpoints exits 0"
else
    assert_fail "expire with no checkpoints exits 0"
fi

echo ""

# ─── 9. Save-context / Restore-context ─────────────────────────────────────────
echo -e "${BOLD}  Save-context / Restore-context${RESET}"

# Create build context via save-context (SW_LOOP_* env vars)
export SW_LOOP_GOAL="Fix the auth bug"
export SW_LOOP_FINDINGS="Found issue in middleware"
export SW_LOOP_MODIFIED="src/auth.ts,src/middleware.ts"
export SW_LOOP_TEST_OUTPUT="1 test failed"
export SW_LOOP_ITERATION="5"
export SW_LOOP_STATUS="running"
bash "$SRC" save-context --stage build 2>/dev/null || true
CTX_FILE=".claude/pipeline-artifacts/checkpoints/build-claude-context.json"
if [[ -f "$CTX_FILE" ]]; then
    assert_pass "save-context creates claude-context.json"
else
    assert_fail "save-context creates claude-context.json"
fi

# Verify saved context contents
CTX_GOAL=$(jq -r '.goal // empty' "$CTX_FILE" 2>/dev/null || echo "")
CTX_ITER=$(jq -r '.iteration // 0' "$CTX_FILE" 2>/dev/null || echo "0")
assert_eq "Context goal saved correctly" "Fix the auth bug" "$CTX_GOAL"
assert_eq "Context iteration saved correctly" "5" "$CTX_ITER"

# restore-context exports both RESTORED_* and SW_LOOP_* (run in subshell, eval exports)
RESTORE_OUT=$(bash -c "source \"$SRC\" && checkpoint_restore_context build && echo \"RESTORED_GOAL=\$RESTORED_GOAL\" && echo \"SW_LOOP_GOAL=\$SW_LOOP_GOAL\"" 2>/dev/null) || true
assert_contains "restore-context exports RESTORED_GOAL" "$RESTORE_OUT" "RESTORED_GOAL=Fix the auth bug"
assert_contains "restore-context exports SW_LOOP_GOAL" "$RESTORE_OUT" "SW_LOOP_GOAL=Fix the auth bug"

echo ""

# ─── Results ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
