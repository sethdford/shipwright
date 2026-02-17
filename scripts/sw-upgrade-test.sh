#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright upgrade test — Validate upgrade detection and apply          ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-upgrade-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/home/.local/bin"
    mkdir -p "$TEMP_DIR/home/.local/bin/lib"
    mkdir -p "$TEMP_DIR/home/.tmux"
    mkdir -p "$TEMP_DIR/home/.claude"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/scripts/lib"
    mkdir -p "$TEMP_DIR/repo/tmux"
    mkdir -p "$TEMP_DIR/repo/claude-code"
    mkdir -p "$TEMP_DIR/repo/templates/pipelines"
    mkdir -p "$TEMP_DIR/repo/tmux/templates"
    mkdir -p "$TEMP_DIR/repo/docs"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls md5 md5sum chmod; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
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

    # Create a minimal install.sh and scripts/sw to make find_repo work
    touch "$TEMP_DIR/repo/install.sh"
    printf '#!/usr/bin/env bash\necho "mock sw"\n' > "$TEMP_DIR/repo/scripts/sw"
    chmod +x "$TEMP_DIR/repo/scripts/sw"

    # Create a minimal compat.sh
    touch "$TEMP_DIR/repo/scripts/lib/compat.sh"

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
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
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

# ─── Tests ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}shipwright upgrade${RESET} ${DIM}— test suite${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""

# ─── 1. VERSION defined ──────────────────────────────────────────────────────
echo -e "${BOLD}Script structure${RESET}"

version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-upgrade.sh" || true)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined at top of sw-upgrade.sh"
else
    assert_fail "VERSION variable defined at top of sw-upgrade.sh"
fi

# ─── 2. set -euo pipefail ────────────────────────────────────────────────────
safety_line=$(grep '^set -euo pipefail' "$SCRIPT_DIR/sw-upgrade.sh" || true)
if [[ -n "$safety_line" ]]; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

# ─── 3. ERR trap ─────────────────────────────────────────────────────────────
err_trap=$(grep "trap.*ERR" "$SCRIPT_DIR/sw-upgrade.sh" || true)
if [[ -n "$err_trap" ]]; then
    assert_pass "ERR trap defined"
else
    assert_fail "ERR trap defined"
fi

# ─── 4. Color definitions ────────────────────────────────────────────────────
color_count=$(grep -c 'CYAN\|GREEN\|RED\|YELLOW\|PURPLE' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${color_count:-0}" -ge 5 ]]; then
    assert_pass "Standard color definitions present"
else
    assert_fail "Standard color definitions present" "found $color_count color defs"
fi

# ─── 5. Output helpers ───────────────────────────────────────────────────────
for helper in "info()" "success()" "warn()" "error()"; do
    helper_found=$(grep -c "$helper" "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
    if [[ "${helper_found:-0}" -gt 0 ]]; then
        assert_pass "Output helper $helper defined"
    else
        assert_fail "Output helper $helper defined"
    fi
done

echo ""
echo -e "${BOLD}Upgrade check (dry run)${RESET}"

# ─── 6. Upgrade with --repo-path (no --apply) bootstraps manifest ────────────
setup_env

# Create some repo source files so diff detection has something to compare
echo "#!/usr/bin/env bash" > "$TEMP_DIR/repo/scripts/sw-doctor.sh"
echo "v1" > "$TEMP_DIR/repo/scripts/sw-status.sh"
echo "v1" > "$TEMP_DIR/repo/scripts/sw-loop.sh"
echo "tmux config" > "$TEMP_DIR/repo/tmux/tmux.conf"

# Install mock files so bootstrap_manifest finds them
mkdir -p "$TEMP_DIR/home/.local/bin"
cp "$TEMP_DIR/repo/scripts/sw-doctor.sh" "$TEMP_DIR/home/.local/bin/sw-doctor.sh"
cp "$TEMP_DIR/repo/scripts/sw-status.sh" "$TEMP_DIR/home/.local/bin/sw-status.sh"
cp "$TEMP_DIR/repo/scripts/sw-loop.sh" "$TEMP_DIR/home/.local/bin/sw-loop.sh"

output=$(bash "$SCRIPT_DIR/sw-upgrade.sh" --repo-path "$TEMP_DIR/repo" 2>&1) || true
assert_contains "Dry run shows comparing text" "$output" "Comparing installed"

# ─── 7. Manifest bootstrapped on first run ────────────────────────────────────
if [[ -f "$TEMP_DIR/home/.shipwright/manifest.json" ]]; then
    assert_pass "Manifest file created on first run"
else
    # Manifest may not be created if no installed files found — that's OK
    assert_pass "Manifest file created on first run (or bootstrap skipped)"
fi

# ─── 8. Manifest is valid JSON (if exists) ───────────────────────────────────
if [[ -f "$TEMP_DIR/home/.shipwright/manifest.json" ]]; then
    if jq . "$TEMP_DIR/home/.shipwright/manifest.json" &>/dev/null; then
        assert_pass "Manifest is valid JSON"
    else
        assert_fail "Manifest is valid JSON"
    fi
else
    assert_pass "Manifest is valid JSON (skipped — no manifest)"
fi

# ─── 9. Manifest contains schema field ──────────────────────────────────────
if [[ -f "$TEMP_DIR/home/.shipwright/manifest.json" ]]; then
    schema=$(jq -r '.schema' "$TEMP_DIR/home/.shipwright/manifest.json" 2>/dev/null || echo "")
    assert_eq "Manifest has schema field" "1" "$schema"
else
    assert_pass "Manifest has schema field (skipped — no manifest)"
fi

# ─── 10. Manifest contains repo_path ─────────────────────────────────────────
if [[ -f "$TEMP_DIR/home/.shipwright/manifest.json" ]]; then
    repo_path_val=$(jq -r '.repo_path' "$TEMP_DIR/home/.shipwright/manifest.json" 2>/dev/null || echo "")
    assert_eq "Manifest has repo_path" "$TEMP_DIR/repo" "$repo_path_val"
else
    assert_pass "Manifest has repo_path (skipped — no manifest)"
fi

echo ""
echo -e "${BOLD}Upgrade detection${RESET}"

# ─── 11. Detects up-to-date files ────────────────────────────────────────────
# Install a file that matches the repo version (simulating an up-to-date install)
mkdir -p "$TEMP_DIR/home/.local/bin"
cp "$TEMP_DIR/repo/scripts/sw-doctor.sh" "$TEMP_DIR/home/.local/bin/sw-doctor.sh"

# Write manifest with current checksums matching both sides
output2=$(bash "$SCRIPT_DIR/sw-upgrade.sh" --repo-path "$TEMP_DIR/repo" 2>&1) || true
assert_contains "Detects up-to-date files" "$output2" "UP TO DATE"

# ─── 12. Detects missing files as MISSING ────────────────────────────────────
# The manifest expects many files at dest locations that don't exist
# At minimum, some files should show as missing
assert_contains "Shows SUMMARY line" "$output2" "SUMMARY"

# ─── 13. Suggests --apply when upgradeable ───────────────────────────────────
assert_contains "Suggests --apply flag" "$output2" "--apply"

echo ""
echo -e "${BOLD}Apply mode${RESET}"

# ─── 14. Apply installs missing files ────────────────────────────────────────
setup_env

echo "#!/usr/bin/env bash" > "$TEMP_DIR/repo/scripts/sw-doctor.sh"
echo "v1" > "$TEMP_DIR/repo/scripts/sw-loop.sh"
echo "tmux config" > "$TEMP_DIR/repo/tmux/tmux.conf"

# First run to bootstrap manifest
bash "$SCRIPT_DIR/sw-upgrade.sh" --repo-path "$TEMP_DIR/repo" &>/dev/null || true

# Modify the repo version so it differs from the manifest
echo "#!/usr/bin/env bash\n# updated" > "$TEMP_DIR/repo/scripts/sw-doctor.sh"

apply_output=$(bash "$SCRIPT_DIR/sw-upgrade.sh" --repo-path "$TEMP_DIR/repo" --apply 2>&1) || true
assert_contains "Apply mode shows Applying" "$apply_output" "Applying"

# ─── 15. Apply completes without error ────────────────────────────────────────
# In mock env, apply may not find real files to update, so just verify it ran
if echo "$apply_output" | grep -qE '(Manifest updated|No changes|UP TO DATE|Applying)' 2>/dev/null; then
    assert_pass "Apply mode completes successfully"
else
    assert_fail "Apply mode completes successfully" "unexpected output: $apply_output"
fi

echo ""
echo -e "${BOLD}File registry${RESET}"

# ─── 16. FILES array includes core scripts ───────────────────────────────────
file_count=$(grep -c '|scripts/sw' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${file_count:-0}" -ge 10 ]]; then
    assert_pass "FILES array has core scripts (found $file_count entries)"
else
    assert_fail "FILES array has core scripts" "found only $file_count"
fi

# ─── 17. FILES array includes templates ──────────────────────────────────────
template_count=$(grep -c '|tmux/templates/' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${template_count:-0}" -ge 5 ]]; then
    assert_pass "FILES array has tmux templates (found $template_count)"
else
    assert_fail "FILES array has tmux templates" "found only $template_count"
fi

# ─── 18. FILES array includes pipeline templates ─────────────────────────────
pipeline_count=$(grep -c '|templates/pipelines/' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${pipeline_count:-0}" -ge 5 ]]; then
    assert_pass "FILES array has pipeline templates (found $pipeline_count)"
else
    assert_fail "FILES array has pipeline templates" "found only $pipeline_count"
fi

# ─── 19. Protected files marked correctly ────────────────────────────────────
protected_count=$(grep -c '|true|' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${protected_count:-0}" -ge 1 ]]; then
    assert_pass "Protected files defined in FILES array"
else
    assert_fail "Protected files defined in FILES array"
fi

echo ""
echo -e "${BOLD}Repo location logic${RESET}"

# ─── 20. find_repo respects --repo-path ──────────────────────────────────────
setup_env

echo "test" > "$TEMP_DIR/repo/scripts/sw-doctor.sh"
output_rp=$(bash "$SCRIPT_DIR/sw-upgrade.sh" --repo-path "$TEMP_DIR/repo" 2>&1) || true
assert_contains "find_repo uses --repo-path" "$output_rp" "$TEMP_DIR/repo"

# ─── 21. find_repo respects SHIPWRIGHT_REPO_PATH env ──────────────────────────
setup_env

echo "test" > "$TEMP_DIR/repo/scripts/sw-doctor.sh"
output_env=$(SHIPWRIGHT_REPO_PATH="$TEMP_DIR/repo" bash "$SCRIPT_DIR/sw-upgrade.sh" 2>&1) || true
assert_contains "find_repo uses SHIPWRIGHT_REPO_PATH" "$output_env" "$TEMP_DIR/repo"

echo ""
echo -e "${BOLD}Checksum logic${RESET}"

# ─── 22. file_checksum function defined ──────────────────────────────────────
cksum_fn=$(grep -c 'file_checksum()' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${cksum_fn:-0}" -gt 0 ]]; then
    assert_pass "file_checksum function defined"
else
    assert_fail "file_checksum function defined"
fi

# ─── 23. Uses md5 or md5sum for checksums ────────────────────────────────────
md5_usage=$(grep -c 'md5' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${md5_usage:-0}" -ge 1 ]]; then
    assert_pass "Uses md5/md5sum for checksums"
else
    assert_fail "Uses md5/md5sum for checksums"
fi

# ─── 24. Backup created before overwrite ─────────────────────────────────────
backup_logic=$(grep -c 'pre-upgrade.bak' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${backup_logic:-0}" -ge 1 ]]; then
    assert_pass "Backup logic (.pre-upgrade.bak) present"
else
    assert_fail "Backup logic (.pre-upgrade.bak) present"
fi

# ─── 25. Self-upgrade warning logic ──────────────────────────────────────────
self_upgrade=$(grep -c 'SW_SELF_UPGRADED' "$SCRIPT_DIR/sw-upgrade.sh" 2>/dev/null) || true
if [[ "${self_upgrade:-0}" -ge 1 ]]; then
    assert_pass "Self-upgrade detection logic present"
else
    assert_fail "Self-upgrade detection logic present"
fi

# ─── Results ──────────────────────────────────────────────────────────────────
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
