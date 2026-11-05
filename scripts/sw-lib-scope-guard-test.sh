#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/scope-guard test — blast-radius guard for the loop (#8644) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# One fixture repo is built once and reset to its base commit before each case, so the suite stays
# fast. Each reviewer repro of the #8662 bypasses is a named regression case (R-A, R-B, ...).
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: scope-guard Tests"

setup_test_env "sw-lib-scope-guard-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

if ! command -v jq >/dev/null 2>&1; then
    assert_pass "jq not installed: scope-guard checks skipped"
    print_test_results
fi

source "$SCRIPT_DIR/lib/scope-guard.sh"
# The guarded push is defined with the delivery stages (definitions only).
source "$SCRIPT_DIR/lib/pipeline-stages-delivery.sh"
# The guard library turns on errexit for its caller; the assertions here count failures instead.
set +e

# ─── Fixture: one repo, reset per case ───────────────────────────────────────

R="$TEST_TEMP_DIR/repo"
EVD="$TEST_TEMP_DIR/evidence"
mkdir -p "$R/docs" "$R/scripts/ci" "$R/scripts/lib" "$R/tools/arch" "$R/config" "$R/src/x" \
    "$R/.claude/hooks" "$R/.claude/rules" "$R/.claude/pipeline-artifacts" "$EVD"
git -C "$R" init -q
git -C "$R" config user.email "t@t"
git -C "$R" config user.name "T"
git -C "$R" symbolic-ref HEAD refs/heads/loop-branch
seq 1 200 > "$R/docs/big.md"
echo "runbook" > "$R/docs/safety-runbook.md"
seq 1 300 > "$R/.claude/hooks/pre-tool-use.sh"
seq 1 50 > "$R/scripts/ci/gate.sh"
seq 1 50 > "$R/scripts/lib/helper.sh"
seq 1 5 > "$R/scripts/demo-test.sh"
seq 1 3 > "$R/tools/arch/baseline.json"
seq 1 5 > "$R/src/x/code.ts"
cp "$(cd "$SCRIPT_DIR/.." && pwd)/config/scope-budgets.json" "$R/config/scope-budgets.json"
printf '.claude/loop-logs/\n.claude/pipeline-artifacts/\n' > "$R/.gitignore"
git -C "$R" add -A
git -C "$R" commit -qm "base"
BASE="$(git -C "$R" rev-parse HEAD)"
UP_URL="$TEST_TEMP_DIR/up.git"
rm -rf "$UP_URL"; git init -q --bare "$UP_URL"
git -C "$UP_URL" fetch -q --no-tags "$R" "+$BASE:refs/heads/main"

# Trusted state, as the loop sets it up: config from the base commit, a clean tree, the loop branch.
scope_load_config "$R" "$BASE" || { echo "config load failed"; exit 1; }
scope_setup_run "$R" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" \
    || { echo "setup failed"; exit 1; }
DOCS_SCOPE="$SCOPE_JSON"
BUG_SCOPE="$(scope_resolve bug "")"

# fresh: reset the fixture to base and clear per-case state. A case may change the scope; it is
# restored by the next call.
fresh() {
    git -C "$R" reset -q --hard "$BASE"
    git -C "$R" clean -fdxq
    # clean removes directories that hold no tracked file; recreate the ones the cases write into.
    mkdir -p "$R/.claude/rules" "$R/.claude/agents" "$R/.claude/hooks" "$R/.claude/pipeline-artifacts" "$R/tools/arch" "$R/scripts/ci" "$R/src/x" "$EVD"
    scope_reset_strikes
    SCOPE_JSON="$DOCS_SCOPE"
    SCOPE_CAN_REVERT=1
    SCOPE_LOOP_BRANCH="refs/heads/loop-branch"
    SCOPE_NOTE=""
    rm -f "$EVD"/* 2>/dev/null || true
}

assert_has() { assert_contains "$1" "$3" "$2"; }

commit_all() { git -C "$R" add -A; git -C "$R" commit -qm "$1" --no-verify; }
head_of() { git -C "$R" rev-parse HEAD; }

# run_guard <pre> <iter> [tag]: sets RC
run_guard() {
    local pre="$1" iter="$2"
    RC=0
    scope_guard_check "$R" "$BASE" "$pre" "$iter" "$EVD" "${3:-}" || RC=$?
}

ev() { jq -r "$2" "$EVD/scope-check-iter-$1${3:-}.json"; }
reasons() { ev "$1" '[.violations[].reason] | join(",")'; }
block_reason() { jq -r '.reason' "$EVD/scope-check-iter-1.json"; }

# ─── Config and type resolution ──────────────────────────────────────────────

echo ""
echo -e "${DIM}  type inference and resolution${RESET}"

assert_eq "type: docs path in goal" "docs" "$(scope_infer_type 'Add a one-line note to docs/safety-runbook.md' '')"
assert_eq "type: bug label" "bug" "$(scope_infer_type 'anything' 'bug,area:loop')"
assert_eq "type: labels beat keywords" "docs" "$(scope_infer_type 'Fix the parser' 'documentation')"
assert_eq "type: unrecognised is unknown" "unknown" "$(scope_infer_type 'frobnicate the widget' '')"
assert_eq "type: alias canonicalised" "docs" "$(scope_canonical_type documentation)"
assert_eq "type: unknown name is the strictest entry" "unknown" "$(scope_canonical_type testing)"

# Labels and intake may only tighten (item 5). A feature label cannot widen a docs goal.
assert_eq "type: docs goal + feature label stays docs" "docs" "$(scope_type_for_run "$TEST_TEMP_DIR/no-artifacts" "Update docs/readme" "feature")"
ART="$TEST_TEMP_DIR/art-intake"; mkdir -p "$ART"
echo '{"type":"feature"}' > "$ART/intake.json"
assert_eq "type: feature goal + intake feature is feature" "feature" "$(scope_type_for_run "$ART" "Add retry support" "")"
echo '{"type":"docs"}' > "$ART/intake.json"
assert_eq "type: feature goal, intake docs (tightens) is docs" "docs" "$(scope_type_for_run "$ART" "Add retry support" "")"
echo '{"type":"bogus-model-output"}' > "$ART/intake.json"
assert_eq "type: unknown model type is no looser than unknown" "unknown" "$(scope_type_for_run "$ART" "Add retry support" "")"

# Config is loaded from the base commit; a working-tree edit does not count (item 4).
printf '{"version":2,"protected_paths":[],"types":{}}' > "$R/config/scope-budgets.json"
scope_load_config "$R" "$BASE"
assert_eq "config: working-tree edit ignored (still has protected list)" "true" \
    "$([[ -n "$SCOPE_PROTECTED_LIST" ]] && echo true || echo false)"
git -C "$R" checkout -q -- config/scope-budgets.json
scope_load_config "$R" "$BASE"

# ─── Glob semantics (item 8) ─────────────────────────────────────────────────

echo ""
echo -e "${DIM}  glob semantics${RESET}"
_g() { _scope_glob_match "$1" "$2" && echo y || echo n; }
assert_eq "glob: *.md matches a root file" "y" "$(_g RUNBOOK.md '*.md')"
assert_eq "glob: *.md does not match src/x/SKILL.md" "n" "$(_g src/x/SKILL.md '*.md')"
assert_eq "glob: * does not cross a slash" "n" "$(_g docs/a/b.md 'docs/*')"
assert_eq "glob: ** crosses a slash" "y" "$(_g docs/a/b.md 'docs/**')"
assert_eq "glob: **/ matches nested test" "y" "$(_g src/a/b/x.test.ts 'src/**/*.test.ts')"
assert_eq "glob: **/ matches zero directories" "y" "$(_g src/x.test.ts 'src/**/*.test.ts')"
assert_eq "glob: **/.gitattributes matches nested" "y" "$(_g docs/.gitattributes '**/.gitattributes')"
assert_eq "glob: dot is literal" "n" "$(_g docsXmd '*.md')"

# ─── Spec clamp and fallbacks ────────────────────────────────────────────────

echo ""
echo -e "${DIM}  spec clamp and fallbacks${RESET}"
WIDE_SPEC="$TEST_TEMP_DIR/wide-spec.json"
cat > "$WIDE_SPEC" <<'JSON'
{"version":"1.0","title":"t","goals":["g"],
 "scope":{"allowed_paths":["docs/safety-runbook.md","scripts/**","docs/adr/**","*","scripts/ci/**"],
          "max_files_changed":99,"max_lines_added":5,"max_lines_deleted":-4}}
JSON
CLAMPED="$(scope_resolve docs "$WIDE_SPEC")"
assert_eq "clamp: model cannot widen files budget" "3" "$(echo "$CLAMPED" | jq -r '.max_files_changed')"
assert_eq "clamp: model may tighten added budget" "5" "$(echo "$CLAMPED" | jq -r '.max_lines_added')"
assert_eq "clamp: invalid negative budget falls back to default" "30" "$(echo "$CLAMPED" | jq -r '.max_lines_deleted')"
assert_eq "clamp: out-of-default path dropped" "false" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "scripts/**"] | any')"
assert_eq "clamp: match-everything glob dropped" "false" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "*"] | any')"
assert_eq "clamp: protected ci path dropped (not literal in default)" "false" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "scripts/ci/**"] | any')"
assert_eq "clamp: in-default narrow path kept" "true" "$(echo "$CLAMPED" | jq -r '[.allowed_paths[] | . == "docs/safety-runbook.md"] | any')"

MISSING_SPEC="$TEST_TEMP_DIR/no-scope.json"
echo '{"version":"1.0","title":"t","goals":["g"]}' > "$MISSING_SPEC"
assert_eq "missing scope: type default" "3" "$(scope_resolve docs "$MISSING_SPEC" | jq -r '.max_files_changed')"
BAD_SPEC="$TEST_TEMP_DIR/bad-spec.json"
echo '{"scope":"not-an-object"' > "$BAD_SPEC"
assert_eq "unparsable spec: type default" "60" "$(scope_resolve docs "$BAD_SPEC" | jq -r '.max_lines_added')"

# ─── Protected paths and bookkeeping (items 2 and 4) ─────────────────────────

echo ""
echo -e "${DIM}  protected paths and runtime bookkeeping${RESET}"
fresh; echo "x" >> "$R/.claude/hooks/pre-tool-use.sh"; commit_all "rewrite hook"
run_guard "$BASE" 1
assert_eq "R-C: hook rewrite is a violation" "1" "$RC"
assert_has "R-C: reason protected_modified" "protected_modified" "$(reasons 1)"

fresh; rm "$R/.claude/hooks/pre-tool-use.sh"; commit_all "delete hook"
run_guard "$BASE" 1
assert_eq "R-C2: hook deletion is a violation" "1" "$RC"
assert_has "R-C2: reason protected_deleted" "protected_deleted" "$(reasons 1)"

fresh; echo "rule" > "$R/.claude/rules/new.md"; commit_all "add rule"
run_guard "$BASE" 1
assert_eq "rules/ is protected" "1" "$RC"

fresh; mkdir -p "$R/.claude/agents" && echo "a" > "$R/.claude/agents/x.md"; commit_all "agent"
run_guard "$BASE" 1
assert_eq "agents/ is protected" "1" "$RC"

fresh; echo "x" > "$R/.claude/pipeline-artifacts/spec.json"; echo "y" > "$R/.claude/loop-state.md"; git -C "$R" add -f .claude/pipeline-artifacts/spec.json .claude/loop-state.md; git -C "$R" commit -qm "runtime" --no-verify
run_guard "$BASE" 1
assert_eq "runtime bookkeeping alone is not a violation" "0" "$RC"

fresh; echo "x" > "$R/tools/arch/extra.json"; commit_all "arch"
run_guard "$BASE" 1
assert_eq "R-tools: tools/arch is protected" "1" "$RC"

fresh; rm "$R/scripts/ci/gate.sh"; commit_all "delete ci gate"
run_guard "$BASE" 1
assert_has "scripts/ci deletion is protected even in a broad scope" "protected_deleted" "$(reasons 1)"

fresh; echo "tamper" >> "$R/scripts/demo-test.sh"; commit_all "edit test"
run_guard "$BASE" 1
assert_has "protected test edit is protected_modified" "protected_modified" "$(reasons 1)"

fresh; jq '.allowed_paths += ["scripts/demo-test.sh"]' <<< "$DOCS_SCOPE" > "$TEST_TEMP_DIR/explicit.json"
SCOPE_JSON="$(cat "$TEST_TEMP_DIR/explicit.json")"
echo "allowed" >> "$R/scripts/demo-test.sh"; commit_all "edit test, explicitly allowed"
run_guard "$BASE" 1
assert_eq "literal allow permits a protected modification" "0" "$RC"

fresh; SCOPE_JSON="$(cat "$TEST_TEMP_DIR/explicit.json")"; rm "$R/scripts/demo-test.sh"; commit_all "delete test, explicitly allowed"
run_guard "$BASE" 1
assert_eq "literal allow still blocks a protected deletion" "1" "$RC"

# R-B: the protected config may not be changed by an agent (item 4), nor the guard itself.
fresh; grep -v '"scripts/\*-test.sh",' "$R/config/scope-budgets.json" > "$R/c.tmp" && mv "$R/c.tmp" "$R/config/scope-budgets.json"
commit_all "drop a protected glob"
run_guard "$BASE" 1
assert_eq "R-config: editing config/scope-budgets.json is a violation" "1" "$RC"

fresh; echo "x" > "$R/scripts/lib/scope-guard.sh"; commit_all "touch guard"
run_guard "$BASE" 1
assert_eq "the guard library itself is protected" "1" "$RC"

# ─── Binary, symlink, submodule, attributes (item 3, R-A, R-B, R-B2, R-G) ─────

echo ""
echo -e "${DIM}  binary, attributes, symlinks${RESET}"
fresh; printf '\0' > "$R/docs/big.md"; commit_all "R-A text to binary"
run_guard "$BASE" 1
assert_eq "R-A: text to binary is a violation" "1" "$RC"
assert_has "R-A: reason binary_file" "binary_file" "$(reasons 1)"

fresh; printf '* binary\n' > "$R/docs/.gitattributes"; : > "$R/docs/big.md"; commit_all "R-B gitattributes plus truncate"
run_guard "$BASE" 1
assert_eq "R-B: .gitattributes change is a violation" "1" "$RC"
assert_has "R-B: .gitattributes is protected_modified" "protected_modified" "$(reasons 1)"

fresh; printf '*.md -diff\n' > "$R/docs/.gitattributes"; : > "$R/docs/big.md"; commit_all "R-B2 -diff"
run_guard "$BASE" 1
assert_eq "R-B2: -diff attribute cannot hide the 200 deleted lines" "1" "$RC"
assert_has "R-B2: budget still reports too_many_lines_deleted" "too_many_lines_deleted" "$(reasons 1)"

fresh; printf '\0\1\2' > "$R/docs/blob.bin"; commit_all "add binary"
run_guard "$BASE" 1
assert_has "added binary file is a violation" "binary_file" "$(reasons 1)"

fresh; ln -s /etc/passwd "$R/docs/passwd.md"; commit_all "R-G symlink"
run_guard "$BASE" 1
assert_has "R-G: symlink is a violation" "symlink" "$(reasons 1)"

fresh; ln -s ../scripts/ci/gate.sh "$R/docs/rel.sh"; commit_all "relative symlink"
run_guard "$BASE" 1
assert_has "relative symlink into a protected path is a violation" "symlink" "$(reasons 1)"

# A deleted binary is counted by its old blob's line count.
fresh; seq 1 120 > "$R/docs/bigbin.txt"; git -C "$R" add -A; git -C "$R" commit -qm "text base" --no-verify
TB="$(head_of)"
rm "$R/docs/bigbin.txt"; commit_all "delete 120-line file"
BASE_SAVED="$BASE"; BASE="$TB"
run_guard "$TB" 1
BASE="$BASE_SAVED"
assert_eq "deleted file counted by old blob lines (120 > 30 deleted budget)" "1" "$RC"
assert_has "deleted file counts as too_many_lines_deleted" "too_many_lines_deleted" "$(reasons 1)"

# ─── Renames and whole-file deletions ────────────────────────────────────────

echo ""
echo -e "${DIM}  renames and deletions${RESET}"
fresh; git -C "$R" mv docs/safety-runbook.md docs/runbook-renamed.md; commit_all "rename inside docs"
run_guard "$BASE" 1
assert_eq "rename within allowed path passes" "0" "$RC"
assert_eq "rename counts as two files" "2" "$(ev 1 '.cumulative.files')"

fresh; git -C "$R" mv scripts/demo-test.sh scripts/demo2.sh; commit_all "rename protected test away"
run_guard "$BASE" 1
assert_has "rename of protected test is protected_deleted" "protected_deleted" "$(reasons 1)"

fresh; echo "a" >> "$R/docs/safety-runbook.md"; commit_all "note"
run_guard "$BASE" 1
assert_eq "evidence records cumulative added" "1" "$(ev 1 '.cumulative.added')"
assert_eq "evidence records scope" "3" "$(ev 1 '.scope.max_files_changed')"

# ─── Path, budget and count violations (regression of the original cases) ───

echo ""
echo -e "${DIM}  budgets and path violations${RESET}"
fresh; for f in a b c d; do seq 1 2 > "$R/docs/new-$f.md"; done; commit_all "four files"
run_guard "$BASE" 1
assert_eq "too many files: reverted" "1" "$RC"
assert_eq "too many files: head reset to pre" "$BASE" "$(head_of)"
assert_has "too many files: reason" "too_many_files" "$(reasons 1)"
assert_eq "strike counted" "1" "$SCOPE_STRIKES"
assert_has "scope note injected" "Scope violation in iteration 1" "$SCOPE_NOTE"

fresh; gen() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) print "added " i }'; }; gen 61 >> "$R/docs/safety-runbook.md"; commit_all "too many added"
run_guard "$BASE" 1
assert_has "too many added lines" "too_many_lines_added" "$(reasons 1)"

fresh; seq 1 5 > "$R/docs/big.md"; commit_all "delete most of big"
run_guard "$BASE" 1
assert_has "too many deleted lines" "too_many_lines_deleted" "$(reasons 1)"

fresh; echo "x" >> "$R/scripts/lib/helper.sh"; commit_all "touch lib"
run_guard "$BASE" 1
assert_has "outside allowed path" "outside_allowed_paths" "$(reasons 1)"

fresh; mkdir -p "$R/src/x"; echo "# skill" > "$R/src/x/SKILL.md"; commit_all "nested md"
run_guard "$BASE" 1
assert_has "R-H: src/x/SKILL.md is not a docs path" "outside_allowed_paths" "$(reasons 1)"

fresh; echo "h" > "$R/notes.md"; commit_all "root md"
run_guard "$BASE" 1
assert_eq "root *.md is in the docs scope" "0" "$RC"

fresh; chmod 755 "$R/scripts/ci/gate.sh"; commit_all "R-F mode only"
run_guard "$BASE" 1
assert_has "R-F: mode-only change of a protected script is a violation" "protected_modified" "$(reasons 1)"

# ─── Strikes, evidence and trust (items 1 and 6) ─────────────────────────────

echo ""
echo -e "${DIM}  strikes and trust${RESET}"
fresh
echo "bad" >> "$R/scripts/lib/helper.sh"; commit_all "bad 1"
run_guard "$BASE" 1
assert_eq "strike 1: reverted (rc 1)" "1" "$RC"
PRE2="$(head_of)"
rm -f "$EVD"/scope-check-iter-1.json
echo "bad again" >> "$R/scripts/lib/helper.sh"; commit_all "bad 2"
run_guard "$PRE2" 2
assert_eq "strike 2: blocked (rc 2)" "2" "$RC"
assert_eq "strike 2: iteration reverted before blocking" "$PRE2" "$(head_of)"
assert_eq "strike count survives deleted evidence" "2" "$SCOPE_STRIKES"

# R-E: an agent that rewrites the evidence or strike files cannot reset the count (item 1).
fresh
echo "bad" >> "$R/scripts/lib/helper.sh"; commit_all "bad 1"
run_guard "$BASE" 1
echo 0 > "$EVD/scope-strikes" 2>/dev/null || true
rm -f "$EVD"/*.json
echo "bad again" >> "$R/scripts/lib/helper.sh"; commit_all "bad 2"
PRE_B="$(head_of)"
run_guard "$BASE" 2
assert_eq "R-E: agent-writable state cannot reset strikes" "2" "$RC"

# R-D: scope in the loop-logs directory is never read back (item 1).
fresh
jq -c '.allowed_paths=["*"]|.max_files_changed=99999|.max_lines_added=99999|.max_lines_deleted=99999' <<< "$DOCS_SCOPE" > "$EVD/scope.json"
echo '{"allowed_paths":["*"],"max_files_changed":99999}' > "$R/.claude/pipeline-artifacts/scope.json"
rm "$R/scripts/lib/helper.sh"; commit_all "outside scope while a wider scope sits on disk"
run_guard "$BASE" 1
assert_eq "R-D: a wider scope on disk is ignored" "1" "$RC"

# The loop's in-memory scope is what counts: a SCOPE_JSON that is missing fails closed.
fresh; SCOPE_JSON=""
echo "x" > "$R/docs/another.md"; commit_all "any change"
run_guard "$BASE" 1
assert_eq "missing in-memory scope fails closed" "2" "$RC"
SCOPE_JSON="$DOCS_SCOPE"

# Missing base commit fails closed (the loop's baseline is uncomputable).
fresh; echo "x" >> "$R/docs/safety-runbook.md"; commit_all "note"
RC=0; scope_guard_check "$R" "" "$BASE" 1 "$EVD" "" || RC=$?
assert_eq "missing LOOP_START_COMMIT: blocked" "2" "$RC"
assert_eq "missing LOOP_START_COMMIT: baseline recorded uncomputable" "baseline_uncomputable" "$(ev 1 '.reason')"

# Revert precondition (item 7): never reset when HEAD is not on the loop's branch.
fresh
echo "bad" >> "$R/scripts/lib/helper.sh"; commit_all "bad on loop branch"
git -C "$R" update-ref --no-deref HEAD "$(head_of)" >/dev/null 2>&1 || true
git -C "$R" symbolic-ref HEAD refs/heads/some-other-branch
SCOPE_LOOP_BRANCH="refs/heads/loop-branch"
BEFORE="$(head_of)"
run_guard "$BASE" 1
assert_eq "head not on loop branch: blocked" "2" "$RC"
assert_eq "head not on loop branch: no reset" "$BEFORE" "$(head_of)"
git -C "$R" symbolic-ref HEAD refs/heads/loop-branch

# Revert precondition (item 7): never reset an unrelated dirty checkout.
fresh; SCOPE_CAN_REVERT=0
echo "bad" >> "$R/scripts/lib/helper.sh"; commit_all "bad with unsafe tree"
BEFORE="$(head_of)"
run_guard "$BASE" 1
assert_eq "unsafe tree: blocked instead of reset" "2" "$RC"
assert_eq "unsafe tree: no reset" "$BEFORE" "$(head_of)"

# ─── Audit cleanup commit (item 6, original case) ────────────────────────────

echo ""
echo -e "${DIM}  cleanup commits${RESET}"
fresh
echo "agent work" >> "$R/docs/safety-runbook.md"; commit_all "agent commit"
AGENT_HEAD="$(head_of)"
run_guard "$BASE" 1
assert_eq "agent commit: clean, rc 0" "0" "$RC"
rm "$R/scripts/demo-test.sh"; commit_all "loop: iteration 1 — post-audit cleanup"
run_guard "$BASE" 1 "-cleanup"
assert_eq "cleanup commit violation: rc 1" "1" "$RC"
assert_eq "cleanup violation reverts to the pre-iteration sha" "$BASE" "$(head_of)"
assert_eq "cleanup evidence is tagged and records the revert" "reverted" "$(ev 1 '.verdict' "-cleanup")"

# ─── Setup: config, scope and tree checks (item 7) ───────────────────────────

echo ""
echo -e "${DIM}  run setup${RESET}"
REFUSE="$TEST_TEMP_DIR/refuse"
git clone -q "$R" "$REFUSE" 2>/dev/null
git -C "$REFUSE" symbolic-ref HEAD refs/heads/loop-branch 2>/dev/null || true
echo "dirty" > "$REFUSE/docs/untracked-work.md"
if scope_setup_run "$REFUSE" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" ""; then
    assert_fail "dirty non-worktree checkout is refused at start"
else
    assert_pass "dirty non-worktree checkout is refused at start"
fi
rm -f "$REFUSE/docs/untracked-work.md"
if scope_setup_run "$REFUSE" "" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" ""; then
    assert_fail "missing base commit is refused at start"
else
    assert_pass "missing base commit is refused at start"
fi

WT="$TEST_TEMP_DIR/wt"
git -C "$R" worktree add -q -b wt-branch "$WT" "$BASE" 2>/dev/null
echo "dirty in wt" > "$WT/docs/untracked-wt.md"
if scope_setup_run "$WT" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" && [[ "$SCOPE_CAN_REVERT" == "1" ]]; then
    assert_pass "a linked worktree may revert even when it has uncommitted files"
else
    assert_fail "a linked worktree may revert even when it has uncommitted files"
fi
git -C "$R" worktree remove --force "$WT" >/dev/null 2>&1 || true

# Config fallback: a base without the file uses the install copy.
scope_load_config "$REFUSE" "" && assert_eq "config: no base uses the install copy" "install" "$SCOPE_CONFIG_SOURCE"
scope_load_config "$R" "$BASE" && assert_eq "config: base commit is the source when present" "base:$BASE" "$SCOPE_CONFIG_SOURCE"

# ─── Worker gate (multi-agent, item 9) ───────────────────────────────────────

echo ""
echo -e "${DIM}  worker gate${RESET}"
fresh
export SW_SCOPE_JSON="$DOCS_SCOPE" SW_SCOPE_CONFIG="$SCOPE_CONFIG" SW_SCOPE_BASE="$BASE"
SCOPE_STRIKES=0
rm "$R/scripts/demo-test.sh"; git -C "$R" add -A
RC=0; scope_worker_precommit "$R" 1 1 "$EVD" "$BASE" || RC=$?
assert_eq "worker: staged protected deletion is discarded (rc 1)" "1" "$RC"
assert_eq "worker: discard restored the test file" "true" "$([[ -f "$R/scripts/demo-test.sh" ]] && echo true || echo false)"
git -C "$R" rm -q --cached scripts/demo-test.sh 2>/dev/null || true
rm -f "$R/scripts/demo-test.sh"; git -C "$R" add -A; RC=0; scope_worker_precommit "$R" 2 1 "$EVD" "$BASE" || RC=$?
assert_eq "worker: a second violation blocks (rc 2)" "2" "$RC"
fresh
export SW_SCOPE_JSON="$DOCS_SCOPE" SW_SCOPE_CONFIG="$SCOPE_CONFIG" SW_SCOPE_BASE="$BASE"
echo "ok" >> "$R/docs/safety-runbook.md"; git -C "$R" add -A
RC=0; scope_worker_precommit "$R" 1 1 "$EVD" "$BASE" || RC=$?
assert_eq "worker: clean staged change passes (rc 0)" "0" "$RC"
unset SW_SCOPE_JSON SW_SCOPE_CONFIG SW_SCOPE_BASE
git -C "$R" reset -q --hard "$BASE"

# ─── Git metadata: B3 (.git/info/attributes, .git/config) ────────────────────

echo ""
echo -e "${DIM}  git metadata and attributes (B3)${RESET}"
# A non-empty .git/info/attributes is refused at setup: it could make a change count as zero lines.
GD="$(git -C "$R" rev-parse --absolute-git-dir)"
fresh
echo "* -diff" > "$GD/info/attributes"
if scope_setup_run "$R" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" 2>/dev/null; then
    assert_fail "B3: non-empty .git/info/attributes refuses the run"
else
    assert_pass "B3: non-empty .git/info/attributes refuses the run"
fi
rm -f "$GD/info/attributes"
scope_setup_run "$R" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" || true

# The loop writes the file during a run: the next check blocks (git_metadata_changed).
fresh
echo "* -diff" > "$GD/info/attributes"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "note"
run_guard "$BASE" 1
assert_eq "B3: attributes written mid-run block the check" "2" "$RC"
assert_eq "B3: reason is git_metadata_changed" "git_metadata_changed" "$(ev 1 '.reason')"
rm -f "$GD/info/attributes"

# A .git/config change mid-run (for example a diff driver) blocks the check too.
fresh
git -C "$R" config diff.zz.binary true
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "note"
run_guard "$BASE" 1
assert_eq "B3: .git/config change mid-run blocks the check" "2" "$RC"
git -C "$R" config --unset diff.zz.binary

# A dash in numstat (git could not count) for a path that is not deleted is a binary violation.
fresh
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "note"
_scope_rows_fn_check="$(declare -f scope_path_violations | head -1)"
printf 'M\t-\t-\tok\tdocs/safety-runbook.md\n' | scope_path_violations "$DOCS_SCOPE" > "$TEST_TEMP_DIR/dash.txt" || true
printf 'M\t0\t0\tbinary\tdocs/safety-runbook.md\n' | scope_path_violations "$DOCS_SCOPE" > "$TEST_TEMP_DIR/dash2.txt" || true
assert_has "uncountable binary change is a violation" "binary_file" "$(cat "$TEST_TEMP_DIR/dash2.txt")"

# ─── Trusted base and ancestry (J) ───────────────────────────────────────────

echo ""
echo -e "${DIM}  trusted base and ancestry (J)${RESET}"
fresh
# The trusted base is never read from the repo: the helper that did that is gone.
if type scope_trusted_base >/dev/null 2>&1; then assert_fail "J: scope_trusted_base is removed"; else assert_pass "J: scope_trusted_base is removed"; fi
git -C "$R" checkout -q -b feature-j "$BASE"
echo "a" >> "$R/docs/safety-runbook.md"; commit_all "agent commit"
# A base that is not an ancestor of HEAD is refused at setup.
git -C "$R" checkout -q -b sibling-j "$BASE"
echo "sib" > "$R/docs/sibling.md"; commit_all "sibling"
SIB="$(head_of)"
git -C "$R" checkout -q feature-j
if scope_setup_run "$R" "$SIB" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" 2>/dev/null; then
    assert_fail "J: a base that is not an ancestor of HEAD is refused"
else
    assert_pass "J: a base that is not an ancestor of HEAD is refused"
fi
git -C "$R" checkout -q loop-branch 2>/dev/null || git -C "$R" checkout -q -f -b loop-branch "$BASE"
git -C "$R" branch -q -D feature-j sibling-j 2>/dev/null || true

# Resume base (item 4): only SW_PIPELINE_BASE_SHA counts; a branch name, an empty value or a
# non-ancestor is refused.
fresh
if (unset SW_PIPELINE_BASE_SHA; scope_resume_base "$R") >/dev/null 2>&1; then assert_fail "resume: no recorded base refuses"; else assert_pass "resume: no recorded base refuses"; fi
if SW_PIPELINE_BASE_SHA=main scope_resume_base "$R" >/dev/null 2>&1; then assert_fail "resume: a branch name is refused"; else assert_pass "resume: a branch name is refused"; fi
if SW_PIPELINE_BASE_SHA="$BASE" scope_resume_base "$R" >/dev/null 2>&1; then assert_pass "resume: the recorded base is accepted"; else assert_fail "resume: the recorded base is accepted"; fi
git -C "$R" checkout -q -b resume-side "$BASE"
echo "side" > "$R/docs/side.md"; commit_all "side"; SIDE="$(head_of)"
git -C "$R" checkout -q loop-branch
if SW_PIPELINE_BASE_SHA="$SIDE" scope_resume_base "$R" >/dev/null 2>&1; then assert_fail "resume: a base that is not an ancestor of HEAD is refused"; else assert_pass "resume: a base that is not an ancestor of HEAD is refused"; fi
git -C "$R" branch -q -D resume-side 2>/dev/null || true

# ─── Round 4 regressions (#8662 review) ──────────────────────────────────────

echo ""
echo -e "${DIM}  round-4 regressions (R1, R2, G1, W1, S1, worker reset)${RESET}"

# R1: a replace ref changes what git shows for an object. The guard compares refs/replace before each check.
fresh
git -C "$R" update-ref refs/replace/"$BASE" "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"
run_guard "$BASE" 1
assert_has "R1: a replace ref created mid-run blocks the check" "git_metadata_changed" "$(block_reason)"
git -C "$R" update-ref -d refs/replace/"$BASE"

# R2: a graft file in the git dir is a metadata change, so the check blocks.
fresh
echo "x" >> "$R/docs/safety-runbook.md"
printf '%s\n' "$BASE" > "$GD/info/grafts"
run_guard "$BASE" 1
assert_has "R2: a grafts file created mid-run blocks the check" "git_metadata_changed" "$(block_reason)"
rm -f "$GD/info/grafts"

# G1: a rewritten .git file that points elsewhere is caught: the recorded git dir no longer matches.
fresh
echo "x" >> "$R/docs/safety-runbook.md"
SAVED_GD="$SCOPE_GIT_DIR"
SCOPE_GIT_DIR="$TEST_TEMP_DIR/elsewhere.git"
run_guard "$BASE" 1
assert_eq "G1: a git dir that no longer matches the recorded one blocks (rc 2)" "2" "$RC"
assert_has "G1: reason names the git dir change" "git_dir_changed" "$(block_reason)"
SCOPE_GIT_DIR="$SAVED_GD"
_scope_establish "$R" || true

# W1: a config.worktree file in the git dir changes the metadata hash.
fresh
echo "x" >> "$R/docs/safety-runbook.md"
printf '[core]\n\tpager = false\n' > "$GD/config.worktree"
run_guard "$BASE" 1
assert_has "W1: a config.worktree written mid-run blocks the check" "git_metadata_changed" "$(block_reason)"
rm -f "$GD/config.worktree"

# S1: a non-empty shared info/attributes refuses the run at setup.
fresh
COMMON="$(git -C "$R" rev-parse --git-common-dir)"
case "$COMMON" in /*) ;; *) COMMON="$R/$COMMON" ;; esac
printf '*.md -diff\n' > "$COMMON/info/attributes"
if scope_setup_run "$R" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" 0 2>/dev/null; then
    assert_fail "S1: a non-empty info/attributes refuses the run"
else
    assert_pass "S1: a non-empty info/attributes refuses the run"
fi
rm -f "$COMMON/info/attributes"
scope_setup_run "$R" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" 0 2>/dev/null || true

# Final check (item 5): the whole base..HEAD diff, including a commit made after the loop, is judged.
fresh
echo "ok" >> "$R/docs/safety-runbook.md"; commit_all "clean final commit"
if scope_final_check "$R" "$BASE" "$EVD" "Add the runbook note" "" "loop-branch" "" "$UP_URL" main; then assert_pass "final: a clean base..HEAD passes"; else assert_fail "final: a clean base..HEAD passes"; fi
fresh
echo "forbidden" >> "$R/scripts/ci/gate.sh"; commit_all "final commit edits a protected file"
RC=0; scope_final_check "$R" "$BASE" "$EVD" "Add the runbook note" "" "loop-branch" "" "$UP_URL" main || RC=$?
assert_eq "final: a protected change in the final commit blocks (rc 2)" "2" "$RC"
RC=0; scope_final_check "$R" "" "$EVD" "Add the runbook note" "" "loop-branch" "" "$UP_URL" main || RC=$?
assert_eq "final: no pipeline base blocks (rc 2)" "2" "$RC"
fresh

# ─── Round 5 regressions (#8662 review: HS1, HS2, H, K, F1, C1) ──────────────

echo ""
echo -e "${DIM}  round-5 regressions (HS1, HS2, H, K, F1, C1)${RESET}"

# HS1: HEAD moved to another branch after the loop branch was damaged. The check judges the loop branch
# and refuses while HEAD names another branch.
fresh
git -C "$R" checkout -q -b hs1-clean "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "hs1 clean"
run_guard "$BASE" 1
assert_eq "HS1: HEAD on another branch than the loop branch blocks (rc 2)" "2" "$RC"
assert_eq "HS1: reason names the branch mismatch" "head_not_on_loop_branch" "$(block_reason)"
git -C "$R" checkout -q -f loop-branch
git -C "$R" branch -q -D hs1-clean 2>/dev/null || true

# HS2: HEAD re-pointed with symbolic-ref to another branch, without a checkout.
fresh
git -C "$R" branch -q hs2-clean "$BASE"
git -C "$R" symbolic-ref HEAD refs/heads/hs2-clean
run_guard "$BASE" 1
assert_eq "HS2: symbolic-ref HEAD to another branch blocks (rc 2)" "2" "$RC"
assert_eq "HS2: reason names the branch mismatch" "head_not_on_loop_branch" "$(block_reason)"
git -C "$R" symbolic-ref HEAD refs/heads/loop-branch
git -C "$R" branch -q -D hs2-clean 2>/dev/null || true

# H: a reference-transaction hook in the repo's hooks dir never runs inside the guard, so it cannot block
# or alter the revert of a protected edit.
fresh
H_MARK="$TEST_TEMP_DIR/h-hook-ran"
rm -f "$H_MARK"
echo "forbidden" >> "$R/scripts/ci/gate.sh"; commit_all "h protected edit"
mkdir -p "$GD/hooks"
printf '#!/bin/sh\ntouch %s\nexit 1\n' "$H_MARK" > "$GD/hooks/reference-transaction"
chmod +x "$GD/hooks/reference-transaction"
run_guard "$BASE" 1
assert_eq "H: a protected edit is reverted despite a failing hook (rc 1)" "1" "$RC"
if [[ -e "$H_MARK" ]]; then assert_fail "H: the repo's reference-transaction hook must not run"; else assert_pass "H: the repo's reference-transaction hook must not run"; fi
rm -f "$GD/hooks/reference-transaction"

# K: a git without --attr-source (older than 2.40) refuses the run at setup.
fresh
KBIN="$TEST_TEMP_DIR/k-oldgit"
mkdir -p "$KBIN"
printf '#!/bin/bash\nfor a in "$@"; do case "$a" in --attr-source*) echo "unknown option: $a" >&2; exit 129;; esac; done\nexec %s "$@"\n' "$(command -v git)" > "$KBIN/git"
chmod +x "$KBIN/git"
if (PATH="$KBIN:$PATH"; scope_setup_run "$R" "$BASE" "$EVD" "Add the runbook note" "" 0) >/dev/null 2>&1; then
    assert_fail "K: a git without --attr-source refuses the run"
else
    assert_pass "K: a git without --attr-source refuses the run"
fi

# F1: a core.fsmonitor hook set in the repo config is never executed by the guard's final check.
fresh
F1_MARK="$TEST_TEMP_DIR/f1-fsmon-ran"
rm -f "$F1_MARK"
printf '#!/bin/sh\ntouch %s\nexit 1\n' "$F1_MARK" > "$TEST_TEMP_DIR/f1-fsmon.sh"
chmod +x "$TEST_TEMP_DIR/f1-fsmon.sh"
git -C "$R" checkout -q -b f1-branch "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "f1 commit"
git -C "$R" config core.fsmonitor "$TEST_TEMP_DIR/f1-fsmon.sh"
RC=0; scope_final_check "$R" "$BASE" "$EVD" "Add the runbook note" "" "f1-branch" "" "$UP_URL" main || RC=$?
if [[ -e "$F1_MARK" ]]; then assert_fail "F1: the agent's core.fsmonitor must not run in the guard"; else assert_pass "F1: the agent's core.fsmonitor must not run in the guard"; fi
assert_eq "F1: the clean change still passes the final check (rc 0)" "0" "$RC"
git -C "$R" config --unset core.fsmonitor
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D f1-branch 2>/dev/null || true

# C1: the push goes to the URL recorded at pipeline start, with hooks disabled, even when the agent has
# rewritten remote.origin.url and installed a pre-push hook.
fresh
C1_REAL="$TEST_TEMP_DIR/c1-real.git"; C1_EVIL="$TEST_TEMP_DIR/c1-evil.git"
rm -rf "$C1_REAL" "$C1_EVIL"; git init -q --bare "$C1_REAL"; git init -q --bare "$C1_EVIL"
git -C "$C1_REAL" fetch -q --no-tags "$R" "+$BASE:refs/heads/main"
git -C "$R" remote add origin "$C1_REAL"
C1_URL="$(git -C "$R" config --get remote.origin.url)"
git -C "$R" config remote.origin.url "$C1_EVIL"
C1_MARK="$TEST_TEMP_DIR/c1-hook-ran"; rm -f "$C1_MARK"
mkdir -p "$TEST_TEMP_DIR/c1-hooks"
printf '#!/bin/sh\ntouch %s\n' "$C1_MARK" > "$TEST_TEMP_DIR/c1-hooks/pre-push"; chmod +x "$TEST_TEMP_DIR/c1-hooks/pre-push"
git -C "$R" config core.hooksPath "$TEST_TEMP_DIR/c1-hooks"
git -C "$R" checkout -q -b c1-branch "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "c1 commit"
C1_SHA="$(git -C "$R" rev-parse HEAD)"
RC=0; scope_push_judged "$R" "$BASE" "$EVD" "Add the runbook note" "" "c1-branch" "c1-branch" "$C1_URL" "" force main || RC=$?
assert_eq "C1: the judged push succeeds (rc 0)" "0" "$RC"
assert_eq "C1: the real remote receives the judged commit" "$C1_SHA" "$(git -C "$C1_REAL" rev-parse -q --verify refs/heads/c1-branch 2>/dev/null || true)"
if git -C "$C1_EVIL" rev-parse -q --verify refs/heads/c1-branch >/dev/null 2>&1; then assert_fail "C1: the evil remote must not receive the push"; else assert_pass "C1: the evil remote must not receive the push"; fi
if [[ -e "$C1_MARK" ]]; then assert_fail "C1: the agent's pre-push hook must not run"; else assert_pass "C1: the agent's pre-push hook must not run"; fi
git -C "$R" config --unset core.hooksPath
git -C "$R" remote remove origin 2>/dev/null || true
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D c1-branch 2>/dev/null || true

# No recorded push URL refuses the push.
fresh
RC=0; scope_push_judged "$R" "$BASE" "$EVD" "Add the runbook note" "" "loop-branch" "loop-branch" "" "" force main || RC=$?
assert_eq "C1: no recorded push URL refuses the push (rc 2)" "2" "$RC"


# UP1: a branch rebased onto a default branch that touched a protected test is judged on its own commits.
# The default branch's change is not counted against the agent (upstream changes are excluded).
fresh
git -C "$R" checkout -q -b up1-main "$BASE"
echo "x" >> "$R/scripts/demo-test.sh"; commit_all "upstream touches a protected test"
UP1_TIP="$(head_of)"
git -C "$UP_URL" fetch -q --no-tags "$R" "+$UP1_TIP:refs/heads/main"
git -C "$R" checkout -q -b up1-feat "$UP1_TIP"
echo "ok" >> "$R/docs/safety-runbook.md"; commit_all "agent docs note on top of main"
RC=0; scope_final_check "$R" "$BASE" "$EVD" "Add the runbook note" "" "up1-feat" "" "$UP_URL" main || RC=$?
assert_eq "UP1: a one-line docs change on top of a main that touched a protected test passes (rc 0)" "0" "$RC"
git -C "$UP_URL" fetch -q --no-tags "$R" "+$BASE:refs/heads/main"
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D up1-main up1-feat 2>/dev/null || true

# P1: a repo url.<x>.pushInsteadOf sends the push to another remote; the guard refuses before it pushes.
fresh
P1_REAL="$TEST_TEMP_DIR/p1-real.git"; P1_EVIL="$TEST_TEMP_DIR/p1-evil.git"
rm -rf "$P1_REAL" "$P1_EVIL"; git init -q --bare "$P1_REAL"; git init -q --bare "$P1_EVIL"
git -C "$P1_REAL" fetch -q --no-tags "$R" "+$BASE:refs/heads/main"
git -C "$R" config "url.$P1_EVIL.pushInsteadOf" "$P1_REAL"
git -C "$R" checkout -q -b p1-branch "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "p1 commit"
RC=0; scope_push_judged "$R" "$BASE" "$EVD" "Add the runbook note" "" "p1-branch" "p1-branch" "$P1_REAL" "" force main || RC=$?
assert_eq "P1: a pushInsteadOf rewrite refuses the push (rc 2)" "2" "$RC"
if git -C "$P1_EVIL" rev-parse -q --verify refs/heads/p1-branch >/dev/null 2>&1; then assert_fail "P1: the rewritten remote must not receive the push"; else assert_pass "P1: the rewritten remote must not receive the push"; fi
if git -C "$P1_REAL" rev-parse -q --verify refs/heads/p1-branch >/dev/null 2>&1; then assert_fail "P1: the real remote must not receive the push either"; else assert_pass "P1: the real remote must not receive the push either"; fi
git -C "$R" config --unset "url.$P1_EVIL.pushInsteadOf"
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D p1-branch 2>/dev/null || true

# H2: a pre-push hook in the repo's own hooks dir never runs on the judged push.
fresh
H2_REAL="$TEST_TEMP_DIR/h2-real.git"; H2_MARK="$TEST_TEMP_DIR/h2-hook-ran"
rm -rf "$H2_REAL" "$H2_MARK"; git init -q --bare "$H2_REAL"
git -C "$H2_REAL" fetch -q --no-tags "$R" "+$BASE:refs/heads/main"
mkdir -p "$GD/hooks"
printf '#!/bin/sh\ntouch %s\n' "$H2_MARK" > "$GD/hooks/pre-push"; chmod +x "$GD/hooks/pre-push"
git -C "$R" checkout -q -b h2-branch "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "h2 commit"
RC=0; scope_push_judged "$R" "$BASE" "$EVD" "Add the runbook note" "" "h2-branch" "h2-branch" "$H2_REAL" "" force main || RC=$?
assert_eq "H2: the judged push succeeds (rc 0)" "0" "$RC"
if [[ -e "$H2_MARK" ]]; then assert_fail "H2: the repo's pre-push hook must not run"; else assert_pass "H2: the repo's pre-push hook must not run"; fi
rm -f "$GD/hooks/pre-push"
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D h2-branch 2>/dev/null || true

# L1: a forced push is a lease on the tip this process last pushed. A human fixup pushed on top is kept.
fresh
L1_REAL="$TEST_TEMP_DIR/l1-real.git"
rm -rf "$L1_REAL"; git init -q --bare "$L1_REAL"
git -C "$L1_REAL" fetch -q --no-tags "$R" "+$BASE:refs/heads/main"
git -C "$R" checkout -q -b l1-branch "$BASE"
echo "one" >> "$R/docs/safety-runbook.md"; commit_all "l1 first"
SCOPE_LAST_PUSH_BRANCH=""; SCOPE_LAST_PUSH_SHA=""
RC=0; scope_push_judged "$R" "$BASE" "$EVD" "Add the runbook note" "" "l1-branch" "l1-branch" "$L1_REAL" "" force main || RC=$?
assert_eq "L1: the first push succeeds (rc 0)" "0" "$RC"
# A human pushes a fixup on top of the agent's commit.
git -C "$R" checkout -q -b l1-human "$(head_of)"
echo "human fixup" >> "$R/docs/safety-runbook.md"; git -C "$R" commit -qam "human fixup" --no-verify
L1_FIX="$(head_of)"
git -C "$L1_REAL" fetch -q --no-tags "$R" "+$L1_FIX:refs/heads/l1-branch"
git -C "$R" checkout -q l1-branch
echo "two" >> "$R/docs/safety-runbook.md"; commit_all "l1 second"
RC=0; scope_push_judged "$R" "$BASE" "$EVD" "Add the runbook note" "" "l1-branch" "l1-branch" "$L1_REAL" "" force main || RC=$?
assert_eq "L1: a forced push over a human fixup is refused (rc 2)" "2" "$RC"
assert_eq "L1: the human fixup survives on the remote" "$L1_FIX" "$(git -C "$L1_REAL" rev-parse -q --verify refs/heads/l1-branch 2>/dev/null || true)"
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D l1-branch l1-human 2>/dev/null || true
SCOPE_LAST_PUSH_BRANCH=""; SCOPE_LAST_PUSH_SHA=""

# PX1: a repo-level url-scoped http.<url>.proxy would route the guard's fetch and the push through an
# agent-controlled proxy. The final check refuses before any network call.
fresh
PX_UP="$TEST_TEMP_DIR/px1-up.git"; PX_MARK="$TEST_TEMP_DIR/px1-proxy-used"
rm -rf "$PX_UP" "$PX_MARK"; git init -q --bare "$PX_UP"
git -C "$PX_UP" fetch -q --no-tags "$R" "+$BASE:refs/heads/main"
git -C "$R" checkout -q -b px1-branch "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "px1 commit"
git -C "$R" config "http.$PX_UP.proxy" "http://127.0.0.1:9/$PX_MARK"
RC=0; scope_final_check "$R" "$BASE" "$EVD" "Add the runbook note" "" "px1-branch" "" "$PX_UP" main || RC=$?
assert_eq "PX1: a repo http.<url>.proxy refuses the final check (rc 2)" "2" "$RC"
if [[ -e "$PX_MARK" ]]; then assert_fail "PX1: no network call may happen through the repo proxy"; else assert_pass "PX1: no network call may happen through the repo proxy"; fi
git -C "$R" config --unset "http.$PX_UP.proxy"
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D px1-branch 2>/dev/null || true

# PX2: a repo http.sslVerify=false (and a url-scoped credential helper) refuse the check.
fresh
git -C "$R" checkout -q -b px2-branch "$BASE"
echo "x" >> "$R/docs/safety-runbook.md"; commit_all "px2 commit"
git -C "$R" config http.sslVerify false
RC=0; scope_final_check "$R" "$BASE" "$EVD" "Add the runbook note" "" "px2-branch" "" "$PX_UP" main || RC=$?
assert_eq "PX2: a repo http.sslVerify=false refuses the final check (rc 2)" "2" "$RC"
git -C "$R" config --unset http.sslVerify
git -C "$R" config "credential.$PX_UP.helper" "!echo hijack"
RC=0; scope_final_check "$R" "$BASE" "$EVD" "Add the runbook note" "" "px2-branch" "" "$PX_UP" main || RC=$?
assert_eq "PX2: a url-scoped credential helper refuses the final check (rc 2)" "2" "$RC"
git -C "$R" config --unset "credential.$PX_UP.helper"
git -C "$R" checkout -q loop-branch
git -C "$R" branch -q -D px2-branch 2>/dev/null || true

# PX3: the same network refusal applies to the rebase step, which does not run without a clean config.
fresh
git -C "$R" config "http.$PX_UP.extraHeader" "X-Evil: 1"
PX3_OUT="$(scope_net_config_refused "$R")"
if [[ "$PX3_OUT" == *extraheader* ]]; then assert_pass "PX3: the rebase guard lists a url-scoped extraHeader"; else assert_fail "PX3: the rebase guard lists a url-scoped extraHeader"; fi
git -C "$R" config --unset "http.$PX_UP.extraHeader"
if [[ -z "$(scope_net_config_refused "$R")" ]]; then assert_pass "PX3: a clean repo has no network refusal"; else assert_fail "PX3: a clean repo has no network refusal"; fi

# Worker: a forbidden change committed by the agent is discarded back to the worker's own start commit.
fresh
WSTART="$BASE"
echo "forbidden" >> "$R/scripts/ci/gate.sh"; commit_all "agent edits a protected file"
SW_SCOPE_JSON="$DOCS_SCOPE"
SW_SCOPE_CONFIG="$(cat "$R/config/scope-budgets.json")"
SW_SCOPE_BASE="$BASE"
SW_SCOPE_UPSTREAM="$BASE"
scope_worker_precommit "$R" 1 1 "$EVD" "$WSTART" || RC=$?
assert_eq "worker: protected-path change is reverted (rc 1)" "1" "${RC:-0}"
assert_eq "worker: HEAD is back at the worker's start commit" "$WSTART" "$(head_of)"
unset SW_SCOPE_JSON SW_SCOPE_CONFIG SW_SCOPE_BASE SW_SCOPE_UPSTREAM
RC=0

# ─── Context restart and git probe (items 4, 5) ─────────────────────────────

echo ""
echo -e "${DIM}  restart and git probe${RESET}"
fresh
echo "dirty mid-run" >> "$R/docs/safety-runbook.md"
if scope_setup_run "$R" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" 0 2>/dev/null; then
    assert_fail "a dirty tree refuses a fresh start"
else
    assert_pass "a dirty tree refuses a fresh start"
fi
if scope_setup_run "$R" "$BASE" "$TEST_TEMP_DIR/no-artifacts" "Add the runbook note" "" 1 2>/dev/null; then
    assert_pass "an in-process restart is not refused for an uncommitted edit"
else
    assert_fail "an in-process restart is not refused for an uncommitted edit"
fi
git -C "$R" checkout -q -- docs/safety-runbook.md

OLDBIN="$TEST_TEMP_DIR/oldgit-bin"
mkdir -p "$OLDBIN"
printf '#!/bin/bash\nfor a in "$@"; do case "$a" in --attr-source=*) echo "unknown option: $a" >&2; exit 129;; esac; done\nexec %s "$@"\n' "$(command -v git)" > "$OLDBIN/git"
chmod +x "$OLDBIN/git"
PROBE_OUT="$(PATH="$OLDBIN:$PATH" scope_require_git "$R" 2>&1)" && PROBE_RC=0 || PROBE_RC=$?
assert_eq "git probe: git without --attr-source is refused" "1" "$PROBE_RC"
assert_has "git probe: the message names the 2.40 requirement" "git >= 2.40" "$PROBE_OUT"
if scope_require_git "$R" 2>/dev/null; then assert_pass "git probe: the installed git passes"; else assert_fail "git probe: the installed git passes"; fi

# ─── Cumulative worker gate (item 6) ─────────────────────────────────────────

echo ""
echo -e "${DIM}  cumulative worker gate${RESET}"
fresh
export SW_SCOPE_JSON="$DOCS_SCOPE" SW_SCOPE_CONFIG="$SCOPE_CONFIG" SW_SCOPE_BASE="$BASE"
SCOPE_STRIKES=0
# Commit 1 is clean. Commit 2 deletes a protected test. The gate must judge the whole tree against
# the base, so a worker cannot spend its budget one commit at a time.
echo "ok" >> "$R/docs/safety-runbook.md"; git -C "$R" add -A; git -C "$R" commit -qm "worker 1" --no-verify
rm "$R/scripts/demo-test.sh"; git -C "$R" add -A
RC=0; scope_worker_precommit "$R" 2 1 "$EVD" "$BASE" || RC=$?
assert_eq "worker: cumulative tree with a protected deletion is discarded" "1" "$RC"
# A worker without the base fails closed.
unset SW_SCOPE_BASE
RC=0; scope_worker_precommit "$R" 3 1 "$EVD" "$BASE" || RC=$?
assert_eq "worker: missing base fails closed (rc 2)" "2" "$RC"
unset SW_SCOPE_JSON SW_SCOPE_CONFIG SW_SCOPE_BASE
git -C "$R" reset -q --hard "$BASE"

print_test_results
