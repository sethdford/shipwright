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

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Hygiene Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright hygiene"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits 1" "1" "$rc"
assert_contains "unknown subcommand shows error" "$output" "Unknown subcommand"

# ─── Test 4: report subcommand ────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}report subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0" "0" "$rc"
assert_contains "report shows generating" "$output" "Generating"

# ─── Test 5: report creates JSON file ─────────────────────────────────────
# The report command saves JSON to .claude/hygiene-report.json (not stdout)
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0" "0" "$rc"
report_file="$TEST_TEMP_DIR/repo/.claude/hygiene-report.json"
if [[ -f "$report_file" ]]; then
    assert_pass "report creates JSON file"
else
    # Script may write to the real REPO_DIR; check there
    report_file2="$(cd scripts/.. && pwd)/.claude/hygiene-report.json"
    if [[ -f "$report_file2" ]]; then
        report_file="$report_file2"
        assert_pass "report creates JSON file"
    else
        assert_fail "report creates JSON file"
    fi
fi

# ─── Test 6: report JSON is valid and has expected fields ─────────────────
if [[ -f "$report_file" ]] && jq . "$report_file" >/dev/null 2>&1; then
    assert_pass "report JSON is valid"
    file_content=$(cat "$report_file")
    assert_contains "report JSON has timestamp" "$file_content" "timestamp"
    assert_contains "report JSON has sections" "$file_content" "sections"
else
    assert_fail "report JSON is valid" "file not found or invalid JSON"
    assert_fail "report JSON has timestamp"
    assert_fail "report JSON has sections"
fi

# ─── Test 7: structure subcommand ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}structure subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" structure 2>&1) && rc=0 || rc=$?
assert_eq "structure exits 0" "0" "$rc"
assert_contains "structure reports validating" "$output" "Validating"

# ─── Test 8: naming subcommand ────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}naming subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" naming 2>&1) && rc=0 || rc=$?
assert_eq "naming exits 0" "0" "$rc"
assert_contains "naming shows checking" "$output" "Checking naming"

# ─── Test 9: dead-code subcommand ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}dead-code subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" dead-code 2>&1) && rc=0 || rc=$?
assert_eq "dead-code exits 0" "0" "$rc"
assert_contains "dead-code shows scanning" "$output" "Scanning"

# ─── Test 10: dependencies subcommand ─────────────────────────────────────
echo ""
echo -e "  ${CYAN}dependencies subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-hygiene.sh" dependencies 2>&1) && rc=0 || rc=$?
assert_eq "dependencies exits 0" "0" "$rc"
assert_contains "dependencies shows auditing" "$output" "Auditing"

# ─── Test 11: platform-refactor subcommand (AGI-level self-improvement) ───
# Scans the fixture repo so the test never writes into the real repo's .claude/
echo ""
echo -e "  ${CYAN}platform-refactor subcommand${RESET}"
output=$(SW_HYGIENE_REPO_DIR="$TEST_TEMP_DIR/repo" bash "$SCRIPT_DIR/sw-hygiene.sh" platform-refactor 2>&1) && rc=0 || rc=$?
assert_eq "platform-refactor exits 0" "0" "$rc"
assert_contains "platform-refactor scans for hardcoded/fallback" "$output" "hardcoded"
platform_hygiene_file="$TEST_TEMP_DIR/repo/.claude/platform-hygiene.json"
if [[ -f "$platform_hygiene_file" ]] && jq -e '.counts' "$platform_hygiene_file" >/dev/null 2>&1; then
    assert_pass "platform-refactor creates platform-hygiene.json with counts"
else
    assert_fail "platform-refactor creates platform-hygiene.json with counts"
fi

# ─── Test 11b: "hardcoded" counts numeric thresholds, not the word (#5846) ───
echo ""
echo -e "  ${CYAN}platform-refactor counts numeric literals, not the word${RESET}"
hc_fx=$(mktemp -d "${TMPDIR:-/tmp}/sw-hygiene-hc.XXXXXX")
mkdir -p "$hc_fx/scripts/lib"
cat > "$hc_fx/scripts/a.sh" <<'FIXTURE'
#!/usr/bin/env bash
# hardcoded values here
echo "no hardcoded thresholds"
if [[ "$n" -ge 3 ]]; then echo big; fi
(( retries > 5 )) && echo many
[[ $rc -eq 124 ]] && echo timeout
[[ $? -ne 2 ]] && echo odd
[[ $# -lt 2 ]] && echo usage
[[ "$x" -eq 0 ]] && echo zero
[[ "$y" -gt 1 ]] && echo more
[[ "$z" -gt 2.5 ]] && echo decimal
#   [[ "$n" -ge 7 ]] commented-out code
local t="${LIMIT:-30}"
FIXTURE
printf '[[ "$n" -ge 9 ]]\n' > "$hc_fx/scripts/a-test.sh"
printf 'echo nothing to see\n' > "$hc_fx/scripts/lib/empty.sh"
hc_scan() { SW_HYGIENE_REPO_DIR="$hc_fx" bash "$SCRIPT_DIR/sw-hygiene.sh" platform-refactor >/dev/null 2>&1; }
hc_count() { jq -r ".counts.$1" "$hc_fx/.claude/platform-hygiene.json" 2>/dev/null; }

hc_scan && rc=0 || rc=$?
assert_eq "fixture scan exits 0" "0" "$rc"
assert_eq "hardcoded counts only threshold literals >=2 (-ge 3, > 5)" "2" "$(hc_count hardcoded)"
assert_eq "literal_defaults counts \${VAR:-N} defaults" "1" "$(hc_count literal_defaults)"
assert_eq "hardcoded_mentions keeps the word count" "2" "$(hc_count hardcoded_mentions)"
sample_len=$(jq '.findings_sample | length' "$hc_fx/.claude/platform-hygiene.json" 2>/dev/null)
assert_eq "findings_sample lists the literal lines" "2" "$sample_len"
assert_eq "findings_sample entries carry no line content" "0" \
    "$(jq '[.findings_sample[] | select(has("content") or has("text"))] | length' "$hc_fx/.claude/platform-hygiene.json" 2>/dev/null)"
assert_eq "findings_sample entries are tagged kind=literal" "literal" \
    "$(jq -r '.findings_sample[0].kind' "$hc_fx/.claude/platform-hygiene.json" 2>/dev/null)"

# Mentioning the word must not move the metric
echo '# more hardcoded prose, still not a literal' >> "$hc_fx/scripts/a.sh"
hc_scan || true
assert_eq "adding the word 'hardcoded' leaves hardcoded unchanged" "2" "$(hc_count hardcoded)"
assert_eq "adding the word 'hardcoded' raises hardcoded_mentions" "3" "$(hc_count hardcoded_mentions)"

# Migrating a literal to an env-overridable default must lower the metric
sed 's/"\$n" -ge 3/"$n" -ge "${LIMIT_N:-3}"/' "$hc_fx/scripts/a.sh" > "$hc_fx/scripts/a.sh.new"
mv "$hc_fx/scripts/a.sh.new" "$hc_fx/scripts/a.sh"
hc_scan || true
assert_eq "migrating -ge 3 to \${LIMIT_N:-3} lowers hardcoded" "1" "$(hc_count hardcoded)"
assert_eq "migrating -ge 3 to \${LIMIT_N:-3} raises literal_defaults" "2" "$(hc_count literal_defaults)"

# No matches at all: pipefail must not abort the scan
rm -f "$hc_fx/scripts/a.sh" "$hc_fx/scripts/a-test.sh"
hc_scan && rc=0 || rc=$?
assert_eq "scan with no matches exits 0" "0" "$rc"
assert_eq "scan with no matches reports hardcoded=0" "0" "$(hc_count hardcoded)"
assert_eq "scan with no matches reports an empty findings_sample" "0" \
    "$(jq '.findings_sample | length' "$hc_fx/.claude/platform-hygiene.json" 2>/dev/null)"

# Sample is capped at 25 and keeps room for markers when literals abound
for i in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf '[[ "$v" -gt %s ]] && echo x\n' "$i"
done > "$hc_fx/scripts/many.sh"
printf '# TODO: one\n# FIXME: two\n' > "$hc_fx/scripts/markers.sh"
hc_scan || true
assert_eq "hardcoded counts all 30 literal lines" "30" "$(hc_count hardcoded)"
assert_eq "findings_sample is capped at 25" "25" \
    "$(jq '.findings_sample | length' "$hc_fx/.claude/platform-hygiene.json" 2>/dev/null)"
assert_eq "findings_sample keeps the TODO/FIXME markers" "2" \
    "$(jq '[.findings_sample[] | select(.kind == "marker")] | length' "$hc_fx/.claude/platform-hygiene.json" 2>/dev/null)"
rm -rf "$hc_fx"

# ─── Test 12: policy read (config/policy.json via policy_get) ───
echo ""
echo -e "  ${CYAN}policy read (policy_get from config)${RESET}"
policy_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-test.XXXXXX")
mkdir -p "$policy_tmp/config"
echo '{"hygiene":{"artifact_age_days":14}}' > "$policy_tmp/config/policy.json"
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$policy_tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
rm -rf "$policy_tmp"
assert_eq "policy_get returns value from config" "14" "$got"
# Default when key missing
policy_tmp2=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-test.XXXXXX")
mkdir -p "$policy_tmp2/config"
echo '{}' > "$policy_tmp2/config/policy.json"
# shellcheck disable=SC2097,SC2098
got_default=$(REPO_DIR="$policy_tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
rm -rf "$policy_tmp2"
assert_eq "policy_get returns default when key missing" "7" "$got_default"

echo ""
echo ""
print_test_results
