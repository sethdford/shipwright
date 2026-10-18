#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/scope-guard test — blast-radius guard for the loop (#8644) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: scope-guard Tests"

setup_test_env "sw-lib-scope-guard-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

source "$SCRIPT_DIR/lib/scope-guard.sh"

if ! command -v jq >/dev/null 2>&1; then
    assert_pass "jq not installed: scope-guard checks skipped"
    print_test_results
fi

# ─── Fixtures ────────────────────────────────────────────────────────────────

# gen_lines <count> <prefix>: count lines of text
gen_lines() {
    awk -v n="$1" -v p="$2" 'BEGIN { for (i = 1; i <= n; i++) print p " " i }'
}

# make_repo: a git repo with docs, scripts (one protected test), a lib, arch baseline, settings.
make_repo() {
    local r
    r="$(mktemp -d "$TEST_TEMP_DIR/repo.XXXXXX")"
    mkdir -p "$r/docs" "$r/scripts/lib" "$r/tools/arch" "$r/.claude"
    git init -q "$r"
    git -C "$r" config user.email "t@t"
    git -C "$r" config user.name "T"
    gen_lines 5 "runbook" > "$r/docs/safety-runbook.md"
    gen_lines 40 "big" > "$r/docs/big.md"
    gen_lines 5 "demo test" > "$r/scripts/demo-test.sh"
    gen_lines 5 "helper" > "$r/scripts/lib/helper.sh"
    gen_lines 3 "arch" > "$r/tools/arch/findings-baseline.json"
    gen_lines 3 "settings" > "$r/.claude/settings.json"
    git -C "$r" add -A
    git -C "$r" commit -qm "base" >/dev/null
    echo "$r"
}

commit_all() {
    git -C "$1" add -A
    git -C "$1" commit -qm "$2" >/dev/null
}

head_of() { git -C "$1" rev-parse HEAD; }

# Scope files: the docs default, and a feature default.
DOCS_SCOPE="$TEST_TEMP_DIR/docs-scope.json"
scope_resolve docs "" > "$DOCS_SCOPE"

# run_guard <repo> <base> <pre> <iter> <scope> <evidence-dir>: sets RC
run_guard() {
    RC=0
    scope_guard_check "$@" || RC=$?
}

evidence_field() {
    # evidence_field <evidence-dir> <iter> <jq-expr>
    jq -r "$3" "$1/scope-check-iter-$2.json"
}

# assert_has <desc> <needle> <haystack>
assert_has() { assert_contains "$1" "$3" "$2"; }

# ─── Scope resolution: type inference ────────────────────────────────────────

echo ""
echo -e "${DIM}  type inference${RESET}"

assert_eq "type: docs path in goal" "docs" "$(scope_infer_type 'Add a one-line note to docs/safety-runbook.md' '')"
assert_eq "type: bug label" "bug" "$(scope_infer_type 'anything' 'bug,area:loop')"
assert_eq "type: labels beat keywords" "docs" "$(scope_infer_type 'Fix the parser' 'documentation')"
assert_eq "type: feature keyword" "feature" "$(scope_infer_type 'Add retry support' '')"
assert_eq "type: refactor keyword" "refactor" "$(scope_infer_type 'Refactor the queue' '')"
assert_eq "type: unrecognised is unknown" "unknown" "$(scope_infer_type 'frobnicate the widget' '')"
assert_eq "type: alias canonicalised" "docs" "$(scope_canonical_type documentation)"
assert_eq "type: unknown name is the strictest entry" "unknown" "$(scope_canonical_type testing)"

# ─── Scope resolution: model clamp and fallbacks ─────────────────────────────

echo ""
echo -e "${DIM}  scope resolution${RESET}"

WIDE_SPEC="$TEST_TEMP_DIR/wide-spec.json"
cat > "$WIDE_SPEC" <<'JSON'
{"version":"1.0","title":"t","goals":["g"],
 "scope":{"allowed_paths":["docs/safety-runbook.md","scripts/**","docs/adr/**","*"],
          "max_files_changed":99,"max_lines_added":5,"max_lines_deleted":-4}}
JSON
CLAMPED="$(scope_resolve docs "$WIDE_SPEC")"
assert_eq "clamp: model cannot widen files budget" "3" "$(echo "$CLAMPED" | jq -r '.max_files_changed')"
assert_eq "clamp: model may tighten added budget" "5" "$(echo "$CLAMPED" | jq -r '.max_lines_added')"
assert_eq "clamp: invalid negative budget falls back to default" "30" "$(echo "$CLAMPED" | jq -r '.max_lines_deleted')"
assert_eq "clamp: out-of-default path dropped" "false" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "scripts/**"] | any')"
assert_eq "clamp: match-everything glob dropped" "false" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "*"] | any')"
assert_eq "clamp: protected adr path dropped (not literal in default)" "false" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "docs/adr/**"] | any')"
assert_eq "clamp: in-default narrow path kept" "true" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "docs/safety-runbook.md"] | any')"

MISSING_SCOPE="$TEST_TEMP_DIR/no-scope.json"
echo '{"version":"1.0","title":"t","goals":["g"]}' > "$MISSING_SCOPE"
assert_eq "missing scope: type default" "3" "$(scope_resolve docs "$MISSING_SCOPE" | jq -r '.max_files_changed')"
assert_eq "missing scope: source is default" "default" "$(scope_resolve docs "$MISSING_SCOPE" | jq -r '.source')"

BAD_SPEC="$TEST_TEMP_DIR/bad-spec.json"
echo '{"scope":"not-an-object"' > "$BAD_SPEC"
assert_eq "unparsable spec: type default" "60" "$(scope_resolve docs "$BAD_SPEC" | jq -r '.max_lines_added')"

ATTACH="$TEST_TEMP_DIR/attach-spec.json"
cp "$MISSING_SCOPE" "$ATTACH"
if scope_attach_to_spec "$ATTACH" docs; then
    assert_pass "attach: writes scope into spec"
else
    assert_fail "attach: writes scope into spec"
fi
assert_eq "attach: recorded max files" "3" "$(jq -r '.scope.max_files_changed' "$ATTACH")"
assert_eq "attach: spec title kept" "t" "$(jq -r '.title' "$ATTACH")"

# ─── Guard: pass, budgets, paths, protected files ────────────────────────────

echo ""
echo -e "${DIM}  guard: within budget and budget overruns${RESET}"

# 1. within budget passes
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-1"; mkdir -p "$EVD"
echo "one more line" >> "$R/docs/safety-runbook.md"
commit_all "$R" "docs note"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "within budget: rc 0" "0" "$RC"
assert_eq "within budget: verdict pass" "pass" "$(evidence_field "$EVD" 1 '.verdict')"
if [[ "$(head_of "$R")" != "$BASE" ]]; then assert_pass "within budget: commit kept (not reverted)"; else assert_fail "within budget: commit kept"; fi

# 2. too many files: reverted and strike
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-2"; mkdir -p "$EVD"
for f in a b c d; do gen_lines 2 "$f" > "$R/docs/new-$f.md"; done
commit_all "$R" "four files"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "too many files: rc 1 (reverted)" "1" "$RC"
assert_eq "too many files: head reset to pre" "$BASE" "$(head_of "$R")"
assert_eq "too many files: new files removed" "false" "$([[ -e "$R/docs/new-a.md" ]] && echo true || echo false)"
assert_has "too many files: reason recorded" "too_many_files" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"
assert_eq "too many files: strike counted" "1" "$(cat "$EVD/scope-strikes")"
assert_has "too many files: scope note injected" "Scope violation in iteration 1" "$SCOPE_NOTE"

# 3. too many added lines
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-3"; mkdir -p "$EVD"
gen_lines 61 "added" >> "$R/docs/safety-runbook.md"
commit_all "$R" "too many added"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "too many added lines: rc 1" "1" "$RC"
assert_has "too many added lines: reason" "too_many_lines_added" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"
assert_eq "too many added lines: reverted" "$BASE" "$(head_of "$R")"

# 4. too many deleted lines (stricter than additions)
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-4"; mkdir -p "$EVD"
gen_lines 5 "kept" > "$R/docs/big.md"
commit_all "$R" "delete most of big"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "too many deleted lines: rc 1" "1" "$RC"
assert_has "too many deleted lines: reason" "too_many_lines_deleted" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"
assert_eq "too many deleted lines: reverted" "$BASE" "$(head_of "$R")"

# 5. path outside allowed_paths
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-5"; mkdir -p "$EVD"
echo "changed" >> "$R/scripts/lib/helper.sh"
commit_all "$R" "touch lib"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "outside allowed path: rc 1" "1" "$RC"
assert_has "outside allowed path: reason" "outside_allowed_paths" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"
assert_eq "outside allowed path: reverted" "$BASE" "$(head_of "$R")"

echo ""
echo -e "${DIM}  guard: protected paths${RESET}"

# 6. protected test deletion blocked even within budget
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-6"; mkdir -p "$EVD"
rm "$R/scripts/demo-test.sh"
commit_all "$R" "delete test"
BUG_SCOPE="$TEST_TEMP_DIR/bug-scope.json"
scope_resolve bug "" > "$BUG_SCOPE"
run_guard "$R" "$BASE" "$BASE" 1 "$BUG_SCOPE" "$EVD"
assert_eq "protected deletion within budget: rc 1" "1" "$RC"
assert_has "protected deletion: reason" "protected_deleted" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"
assert_eq "protected deletion: test file restored" "true" "$([[ -f "$R/scripts/demo-test.sh" ]] && echo true || echo false)"

# 7. protected modification blocked unless listed literally
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-7"; mkdir -p "$EVD"
echo "tamper" >> "$R/.claude/settings.json"
commit_all "$R" "tamper settings"
run_guard "$R" "$BASE" "$BASE" 1 "$BUG_SCOPE" "$EVD"
assert_eq "protected settings edit: rc 1" "1" "$RC"
assert_has "protected settings edit: reason" "protected_modified" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"

# 8. explicit literal allow permits a protected modification, but never a deletion
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-8"; mkdir -p "$EVD"
echo "allowed edit" >> "$R/scripts/demo-test.sh"
commit_all "$R" "edit test"
EXPLICIT="$TEST_TEMP_DIR/explicit-scope.json"
jq '.allowed_paths += ["scripts/demo-test.sh"]' "$DOCS_SCOPE" > "$EXPLICIT"
run_guard "$R" "$BASE" "$BASE" 1 "$EXPLICIT" "$EVD"
assert_eq "explicit literal allow: modification passes" "0" "$RC"
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-8b"; mkdir -p "$EVD"
rm "$R/scripts/demo-test.sh"
commit_all "$R" "delete test"
run_guard "$R" "$BASE" "$BASE" 1 "$EXPLICIT" "$EVD"
assert_eq "explicit literal allow: deletion still blocked" "1" "$RC"

# ─── Guard: renames, binaries, strikes, audit cleanup ────────────────────────

echo ""
echo -e "${DIM}  guard: renames, binaries, strikes, cleanup commits${RESET}"

# 9. rename inside an allowed path passes
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-9"; mkdir -p "$EVD"
git -C "$R" mv docs/safety-runbook.md docs/runbook-renamed.md
commit_all "$R" "rename runbook"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "rename within allowed path: rc 0" "0" "$RC"
assert_eq "rename within allowed path: counted as two files" "2" "$(evidence_field "$EVD" 1 '.cumulative.files')"

# 10. rename of a protected test is a protected deletion
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-10"; mkdir -p "$EVD"
git -C "$R" mv scripts/demo-test.sh scripts/demo2.sh
commit_all "$R" "rename test away"
run_guard "$R" "$BASE" "$BASE" 1 "$BUG_SCOPE" "$EVD"
assert_eq "rename of protected test: rc 1" "1" "$RC"
assert_has "rename of protected test: protected_deleted" "protected_deleted" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"

# 11. binary file inside an allowed path passes; a binary outside it is caught
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-11"; mkdir -p "$EVD"
printf '\000\001\002\003' > "$R/docs/diagram.bin"
commit_all "$R" "binary in docs"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "binary in allowed path: rc 0" "0" "$RC"
assert_eq "binary in allowed path: flagged binary" "1" "$(evidence_field "$EVD" 1 '.cumulative.binary')"
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-11b"; mkdir -p "$EVD"
printf '\000\001' > "$R/scripts/blob.bin"
commit_all "$R" "binary outside"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_has "binary outside allowed path: reason" "outside_allowed_paths" "$(evidence_field "$EVD" 1 '[.violations[].reason] | join(",")')"

# 12. two strikes fail closed
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-12"; mkdir -p "$EVD"
echo "bad" >> "$R/scripts/lib/helper.sh"
commit_all "$R" "bad 1"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "strike 1: rc 1 (reverted, loop continues)" "1" "$RC"
PRE2="$(head_of "$R")"
echo "bad again" >> "$R/scripts/lib/helper.sh"
commit_all "$R" "bad 2"
run_guard "$R" "$BASE" "$PRE2" 2 "$DOCS_SCOPE" "$EVD"
assert_eq "strike 2: rc 2 (blocked)" "2" "$RC"
assert_eq "strike 2: verdict blocked" "blocked" "$(evidence_field "$EVD" 2 '.verdict')"
assert_eq "strike 2: two strikes recorded" "2" "$(cat "$EVD/scope-strikes")"
assert_eq "strike 2: iteration reverted before blocking" "$PRE2" "$(head_of "$R")"

# 13. audit-cleanup commit (after a clean agent commit) is judged like any loop commit
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-13"; mkdir -p "$EVD"
echo "agent work" >> "$R/docs/safety-runbook.md"
commit_all "$R" "agent commit"
AGENT_HEAD="$(head_of "$R")"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "agent commit: clean, rc 0" "0" "$RC"
rm "$R/scripts/demo-test.sh"
commit_all "$R" "loop: iteration 1 — post-audit cleanup"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "audit cleanup violation: rc 1" "1" "$RC"
assert_eq "audit cleanup violation: reverted to pre-iteration sha" "$BASE" "$(head_of "$R")"
assert_eq "audit cleanup violation: agent commit also undone" "true" "$([[ "$(head_of "$R")" != "$AGENT_HEAD" ]] && echo true || echo false)"

# 14. evidence: clean pass records the cumulative diff
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-14"; mkdir -p "$EVD"
echo "note" >> "$R/docs/safety-runbook.md"
commit_all "$R" "note"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "evidence: cumulative added recorded" "1" "$(evidence_field "$EVD" 1 '.cumulative.added')"
assert_eq "evidence: scope recorded" "3" "$(evidence_field "$EVD" 1 '.scope.max_files_changed')"

# ─── Guard: fail closed on missing inputs ────────────────────────────────────

echo ""
echo -e "${DIM}  guard: fail closed${RESET}"

R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-15"; mkdir -p "$EVD"
run_guard "$R" "" "" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "missing LOOP_START_COMMIT: rc 2" "2" "$RC"
assert_eq "missing LOOP_START_COMMIT: baseline recorded uncomputable" "baseline_uncomputable" "$(evidence_field "$EVD" 1 '.reason')"

EVD="$TEST_TEMP_DIR/evd-16"; mkdir -p "$EVD"
run_guard "$R" "$BASE" "$BASE" 1 "$TEST_TEMP_DIR/no-such-scope.json" "$EVD"
assert_eq "missing scope file: rc 2" "2" "$RC"

# 17. a strike that cannot be recorded fails closed
R="$(make_repo)"; BASE="$(head_of "$R")"; EVD="$TEST_TEMP_DIR/evd-17"; mkdir -p "$EVD"
mkdir "$EVD/scope-strikes"
echo "bad" >> "$R/scripts/lib/helper.sh"
commit_all "$R" "bad, strike unrecordable"
run_guard "$R" "$BASE" "$BASE" 1 "$DOCS_SCOPE" "$EVD"
assert_eq "unrecordable strike: rc 2 (fails closed)" "2" "$RC"

# 18. a fresh run resets strikes; the reset is a no-op on an empty directory
EVD="$TEST_TEMP_DIR/evd-18"; mkdir -p "$EVD"
echo 2 > "$EVD/scope-strikes"
scope_reset_strikes "$EVD"
assert_eq "fresh run: strikes reset" "false" "$([[ -e "$EVD/scope-strikes" ]] && echo true || echo false)"
scope_reset_strikes "$TEST_TEMP_DIR/no-such-dir"
assert_eq "fresh run: reset with no dir does not fail" "0" "$?"

# ─── Config sanity ───────────────────────────────────────────────────────────

echo ""
echo -e "${DIM}  config${RESET}"

CONFIG="$SCRIPT_DIR/../config/scope-budgets.json"
assert_eq "config: unknown type is no looser than docs" "true" "$(jq -r '
    (.types.unknown.max_files_changed <= .types.docs.max_files_changed)
    and (.types.unknown.max_lines_added <= .types.docs.max_lines_added)
    and (.types.unknown.max_lines_deleted <= .types.docs.max_lines_deleted)' "$CONFIG")"
assert_eq "config: deletion budget stricter than addition (docs)" "true" "$(jq -r '.types.docs.max_lines_deleted < .types.docs.max_lines_added' "$CONFIG")"
assert_eq "config: protected list covers workflows" "true" "$(jq -r '[.protected_paths[] | . == ".github/workflows/**"] | any' "$CONFIG")"

print_test_results
