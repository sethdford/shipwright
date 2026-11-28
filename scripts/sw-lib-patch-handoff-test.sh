#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/patch-handoff test — agent output crosses only as a patch ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: patch-handoff Tests"

setup_test_env "sw-lib-patch-handoff-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

_PATCH_HANDOFF_LOADED=""
source "$SCRIPT_DIR/lib/patch-handoff.sh"

# Plain git for building fixtures: isolated from the user's config.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T="$TEST_TEMP_DIR"
PWNED="$T/PWNED"

new_trusted() {
    local repo="$1"
    rm -rf "$repo"
    git init -q -b main "$repo"
    (
        cd "$repo"
        mkdir -p src .github/workflows docs
        printf 'one\ntwo\nthree\n' > src/app.txt
        printf 'keep\n' > src/old.txt
        printf 'name: ci\n' > .github/workflows/ci.yml
        seq 1 2000 > docs/big.txt
        git add -A && git commit -q -m base
    )
    git -C "$repo" rev-parse HEAD
}

expect_ok() { if "${@:2}"; then assert_pass "$1"; else assert_fail "$1"; fi; }
expect_fail() { if "${@:2}" 2>/dev/null; then assert_fail "$1"; else assert_pass "$1"; fi; }

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_prepare"
# ═══════════════════════════════════════════════════════════════════════════════

BASE=$(new_trusted "$T/trusted")
expect_ok "prepares a disposable clone at the base" handoff_prepare "$T/trusted" "$BASE" "$T/agent"
assert_eq "agent clone is at the base sha" "$BASE" "$(git -C "$T/agent" rev-parse HEAD)"
assert_eq "agent clone has no remote" "" "$(git -C "$T/agent" remote)"
assert_eq "agent clone is detached" "HEAD" "$(git -C "$T/agent" rev-parse --abbrev-ref HEAD)"
if [[ "$(cd "$T/agent/.git" && pwd -P)" != "$(cd "$T/trusted/.git" && pwd -P)"* ]]; then
    assert_pass "agent clone has its own git dir"
else
    assert_fail "agent clone has its own git dir"
fi
expect_fail "refuses an existing agent dir" handoff_prepare "$T/trusted" "$BASE" "$T/agent"
expect_fail "refuses a branch name as base" handoff_prepare "$T/trusted" "main" "$T/agent2"
expect_fail "refuses an unknown sha" handoff_prepare "$T/trusted" "$(printf 'a%.0s' {1..40})" "$T/agent3"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_export: committed and uncommitted work"
# ═══════════════════════════════════════════════════════════════════════════════

(
    cd "$T/agent"
    printf 'one\nTWO\nthree\n' > src/app.txt
    git add -A && git commit -q -m "agent commit"
    printf 'new\n' > src/new.txt          # untracked, never committed
    rm src/old.txt                         # deleted, uncommitted
)
expect_ok "exports a patch" handoff_export "$T/agent" "$BASE" "$T/trusted" "$T/p1.patch"
patch=$(cat "$T/p1.patch")
assert_contains "patch has the committed edit" "$patch" "+TWO"
assert_contains "patch has the untracked new file" "$patch" "b/src/new.txt"
assert_contains "patch has the deletion" "$patch" "deleted file mode"
expect_ok "a small source change passes the judge" handoff_judge "$T/p1.patch"
mkdir -p "$T/agent/.claude/loop-logs" && echo log > "$T/agent/.claude/loop-logs/x.log"
handoff_export "$T/agent" "$BASE" "$T/trusted" "$T/p1b.patch"
if grep -q '\.claude/' "$T/p1b.patch"; then assert_fail ".claude/ runtime state is never in the patch"; else assert_pass ".claude/ runtime state is never in the patch"; fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_export ignores everything in the agent's .git"
# ═══════════════════════════════════════════════════════════════════════════════

BASE=$(new_trusted "$T/trusted")
rm -rf "$T/agent"; handoff_prepare "$T/trusted" "$BASE" "$T/agent"
(
    cd "$T/agent"
    # Every one of these would run code, or change the diff, if the pipeline used this git dir.
    git config core.fsmonitor "touch '$PWNED.fsmonitor'; false"
    git config core.hooksPath "$T/agent/hooks"
    mkdir -p hooks && printf '#!/bin/sh\ntouch "%s.hook"\n' "$PWNED" > hooks/pre-commit && chmod +x hooks/pre-commit
    git config filter.evil.clean "touch '$PWNED.filter'; cat"
    git config filter.evil.smudge "cat"
    git config diff.external "$T/agent/hooks/pre-commit"
    git config core.sshCommand "touch '$PWNED.ssh'"
    printf '* filter=evil\n*.txt -diff\n' > .gitattributes
    # A replace ref that swaps the base commit's tree.
    fake=$(git commit-tree -m fake "$(git mktree < /dev/null)")
    git replace "$(git rev-parse HEAD)" "$fake"
    git checkout -q -b decoy
    printf 'one\ntwo\nthree\nfour\n' > src/app.txt
)
# The agent's own git calls above may trigger its traps; only the pipeline's export counts.
rm -f "$PWNED".*
expect_ok "exports despite a hostile agent git config" handoff_export "$T/agent" "$BASE" "$T/trusted" "$T/p2.patch"
pwned=$(find "$T" -maxdepth 1 -name 'PWNED*' | wc -l | tr -d ' ')
assert_eq "no fsmonitor, hook, filter, external diff or ssh command ran" "0" "${pwned:-0}"
# Control: the same traps fire for plain git in the agent's dir, so the assertion above means something.
(cd "$T/agent" && git add -A >/dev/null 2>&1 && git status >/dev/null 2>&1) || true
live=$(find "$T" -maxdepth 1 -name 'PWNED*' | wc -l | tr -d ' ')
if [[ "${live:-0}" -gt 0 ]]; then assert_pass "control: the traps are live for plain git"; else assert_fail "control: the traps are live for plain git"; fi
rm -f "$PWNED".*
patch=$(cat "$T/p2.patch")
assert_contains "the in-tree '-diff' attribute does not hide the text change" "$patch" "+four"
if grep -q "^deleted file mode" "$T/p2.patch"; then
    assert_fail "the replace ref does not change the base (no phantom deletions)"
else
    assert_pass "the replace ref does not change the base (no phantom deletions)"
fi
assert_contains "the agent's .gitattributes is a protected path in the patch" "$(handoff_judge "$T/p2.patch" || true)" "protected path: .gitattributes"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_carry_over (earlier stages' edits)"
# ═══════════════════════════════════════════════════════════════════════════════

BASE=$(new_trusted "$T/trusted")
rm -rf "$T/agent"; handoff_prepare "$T/trusted" "$BASE" "$T/agent"
printf 'planner edit\n' >> "$T/trusted/src/app.txt"
printf 'x\n' >> "$T/trusted/.github/workflows/ci.yml"
printf 'planned\n' > "$T/trusted/src/planned.txt"
mkdir -p "$T/trusted/.claude/pipeline-artifacts" && echo state > "$T/trusted/.claude/pipeline-artifacts/plan.md"
expect_ok "carries edits over" handoff_carry_over "$T/trusted" "$BASE" "$T/agent" "$T/pre.patch"
assert_eq "the trusted checkout is clean again" "" "$(git -C "$T/trusted" status --porcelain --untracked-files=no)"
assert_eq "the edit is now in the agent clone" "planner edit" "$(tail -1 "$T/agent/src/app.txt")"
assert_file_exists "an untracked file moved to the agent clone" "$T/agent/src/planned.txt"
assert_file_not_exists "and out of the trusted checkout" "$T/trusted/src/planned.txt"
assert_contains "the move is listed" "$(cat "$T/pre.patch.moved")" "src/planned.txt"
assert_file_exists "pipeline state under .claude/ stays in the trusted checkout" "$T/trusted/.claude/pipeline-artifacts/plan.md"
assert_file_not_exists "and is not copied to the agent" "$T/agent/.claude/pipeline-artifacts/plan.md"
handoff_export "$T/agent" "$BASE" "$T/trusted" "$T/carried.patch"
assert_contains "and it is judged with the build (workflow edit refused)" "$(handoff_judge "$T/carried.patch" || true)" "protected path: .github/workflows/ci.yml"
rm -f "$T/pre.patch"
expect_ok "a clean checkout carries nothing" handoff_carry_over "$T/trusted" "$BASE" "$T/agent" "$T/pre.patch"
assert_eq "and writes an empty patch" "0" "$(wc -c < "$T/pre.patch" | tr -d ' ')"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_judge (blast radius)"
# ═══════════════════════════════════════════════════════════════════════════════

judge_case() {
    local name="$1" setup="$2" expect="$3"
    BASE=$(new_trusted "$T/trusted")
    rm -rf "$T/agent"; handoff_prepare "$T/trusted" "$BASE" "$T/agent"
    (cd "$T/agent" && "$setup")
    handoff_export "$T/agent" "$BASE" "$T/trusted" "$T/j.patch"
    local out rc=0
    out=$(handoff_judge "$T/j.patch") || rc=$?
    if [[ "$expect" == "ok" ]]; then
        assert_eq "$name" "0" "$rc"
    else
        assert_contains "$name" "$out" "$expect"
    fi
}

edit_workflow() { printf 'x\n' >> .github/workflows/ci.yml; }
add_settings() { mkdir -p .claude && echo '{}' > .claude/settings.json; }
add_symlink() { ln -s /etc/passwd src/link; }
add_binary() { printf '\000\001\002' > src/blob.bin; }
delete_big() { rm docs/big.txt; }
many_files() { local i; for i in $(seq 1 70); do echo x > "src/f$i.txt"; done; }
newline_path() { printf x > "$(printf 'src/a\nb')"; }
ordinary() { printf 'z\n' >> src/app.txt; echo doc > docs/new.md; }

judge_case "workflow edit is refused" edit_workflow "protected path: .github/workflows/ci.yml"
judge_case "agent settings under .claude/ are dropped, not delivered" add_settings "ok"
judge_case "symlink is refused" add_symlink "symlink or submodule"
judge_case "binary file is refused" add_binary "binary change: src/blob.bin"
judge_case "mass deletion is refused" delete_big "deleted lines 2000 > budget"
judge_case "too many files is refused" many_files "files 70 > budget"
judge_case "a newline in a path is refused" newline_path "unusual path"
judge_case "an ordinary change passes" ordinary "ok"
HANDOFF_MAX_DELETED=5000 judge_case "budgets come from the caller" delete_big "ok"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_apply"
# ═══════════════════════════════════════════════════════════════════════════════

BASE=$(new_trusted "$T/trusted")
rm -rf "$T/agent"; handoff_prepare "$T/trusted" "$BASE" "$T/agent"
(cd "$T/agent" && printf 'one\ntwo\nthree\nfour\n' > src/app.txt && echo n > src/n.txt && git config core.hooksPath /nonexistent)
handoff_export "$T/agent" "$BASE" "$T/trusted" "$T/a.patch"
cfg_before=$(cat "$T/trusted/.git/config")
mkdir -p "$T/trusted/.git/hooks"
printf '#!/bin/sh\ntouch "%s.trusted-hook"\n' "$PWNED" > "$T/trusted/.git/hooks/pre-commit"
chmod +x "$T/trusted/.git/hooks/pre-commit"
sha=$(handoff_apply "$T/trusted" "$BASE" "$T/a.patch" "build: issue 42") || sha=""
assert_eq "apply commits on the trusted checkout" "$sha" "$(git -C "$T/trusted" rev-parse HEAD)"
assert_eq "the commit's parent is the base" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD~1)"
assert_eq "the trusted checkout has the agent's change" "four" "$(tail -1 "$T/trusted/src/app.txt")"
assert_eq "the commit is authored by the pipeline" "shipwright-pipeline" "$(git -C "$T/trusted" log -1 --format=%an)"
assert_eq "the trusted checkout is clean afterwards" "" "$(git -C "$T/trusted" status --porcelain)"
assert_eq "the trusted git config is unchanged" "$cfg_before" "$(cat "$T/trusted/.git/config")"
assert_file_not_exists "no repo hook ran during the pipeline's commit" "$PWNED.trusted-hook"

expect_fail "refuses when the trusted checkout moved off the base" handoff_apply "$T/trusted" "$BASE" "$T/a.patch" "again"

BASE=$(new_trusted "$T/trusted")
echo dirty >> "$T/trusted/src/app.txt"
expect_fail "refuses a dirty trusted checkout" handoff_apply "$T/trusted" "$BASE" "$T/a.patch" "m"

BASE=$(new_trusted "$T/trusted")
rm -rf "$T/agent"; handoff_prepare "$T/trusted" "$BASE" "$T/agent"
(cd "$T/agent" && printf "x\n" >> .github/workflows/ci.yml)
handoff_export "$T/agent" "$BASE" "$T/trusted" "$T/bad.patch"
expect_fail "refuses a patch the judge refuses" handoff_apply "$T/trusted" "$BASE" "$T/bad.patch" "m"
assert_eq "a refused patch leaves the trusted checkout at the base" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD)"
assert_eq "and clean" "" "$(git -C "$T/trusted" status --porcelain)"

: > "$T/empty.patch"
expect_fail "refuses an empty patch (nothing to deliver)" handoff_apply "$T/trusted" "$BASE" "$T/empty.patch" "m"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "build stage wiring (patch handoff on by default)"
# ═══════════════════════════════════════════════════════════════════════════════

# A fake `sw` on PATH stands in for the loop: it records its environment and edits the clone.
mkdir -p "$T/bin"
cat > "$T/bin/sw" <<'FAKE'
#!/usr/bin/env bash
repo=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--repo" ]] && repo="$2"; shift; done
env > "$FAKE_SW_ENV"
cd "$repo" || exit 1
[[ -n "${FAKE_SW_NOOP:-}" ]] && exit 0
printf 'one\ntwo\nthree\nloop\n' > src/app.txt
mkdir -p .claude/loop-logs && echo '{"input_tokens":5}' > .claude/loop-logs/loop-tokens.json
[[ -n "${FAKE_SW_EVIL:-}" ]] && printf 'x\n' >> .github/workflows/ci.yml
git config core.hooksPath /tmp/evil-hooks
exit 0
FAKE
chmod +x "$T/bin/sw"

run_build_handoff() {
    (
        set +e
        BOLD="" DIM="" RESET="" CYAN=""
        info() { :; }; success() { :; }; warn() { :; }; error() { echo "ERROR $*" >&2; }
        emit_event() { echo "$*" >> "$T/events"; }
        _PIPELINE_STAGES_BUILD_LOADED=""
        source "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null
        info() { :; }; success() { :; }; warn() { :; }; error() { echo "ERROR $*" >&2; }
        emit_event() { echo "$*" >> "$T/events"; }
        export PATH="$T/bin:$PATH" FAKE_SW_ENV="$T/sw-env"
        export GH_TOKEN=secret-gh GITHUB_TOKEN=secret-gha SHIPWRIGHT_FLEET_TOKEN=secret-fleet
        unset SW_PATCH_HANDOFF
        PROJECT_ROOT="$T/trusted" ARTIFACTS_DIR="$T/artifacts" ISSUE_NUMBER=7 GOAL="Fix app"
        local base dir
        base=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
        dir="$(mktemp -d "$T/agent.XXXXXX")/repo"
        handoff_prepare "$PROJECT_ROOT" "$base" "$dir" || exit 3
        _build_run_loop "$T/bin/sw" "Fix app" --repo "$dir" || exit 4
        _build_handoff_return "$dir" "$base" || exit 5
        exit 0
    )
}

BASE=$(new_trusted "$T/trusted"); rm -rf "$T/artifacts" "$T/events"
rc=0; run_build_handoff 2>/dev/null || rc=$?
assert_exit_code "a clean build is applied" "0" "$rc"
assert_eq "the trusted checkout has the loop's change as one pipeline commit" "loop" "$(tail -1 "$T/trusted/src/app.txt")"
assert_eq "on top of the base" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD~1)"
assert_eq "the agent's git config did not reach the trusted repo" "" "$(git -C "$T/trusted" config --get core.hooksPath || true)"
assert_file_exists "the patch is kept as an artifact" "$T/artifacts/agent.patch"
assert_file_exists "loop logs come back as artifacts" "$T/artifacts/agent-loop-logs/loop-tokens.json"
assert_contains "the apply is an event" "$(cat "$T/events")" "build.patch_applied issue=7"
if grep -q 'secret-' "$T/sw-env"; then
    assert_fail "the loop runs without GitHub or fleet tokens"
else
    assert_pass "the loop runs without GitHub or fleet tokens"
fi

BASE=$(new_trusted "$T/trusted"); rm -rf "$T/artifacts" "$T/events"
rc=0; FAKE_SW_EVIL=1 run_build_handoff 2>/dev/null || rc=$?
assert_exit_code "a build that edits a workflow fails" "5" "$rc"
assert_eq "and the trusted checkout stays at the base" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD)"
assert_contains "the reason is kept" "$(cat "$T/artifacts/agent.patch.refused")" "protected path: .github/workflows/ci.yml"
assert_contains "the refusal is an event" "$(cat "$T/events")" "build.patch_refused issue=7"

BASE=$(new_trusted "$T/trusted"); rm -rf "$T/artifacts" "$T/events"
rc=0; FAKE_SW_NOOP=1 run_build_handoff 2>/dev/null || rc=$?
assert_exit_code "a build with no changes succeeds without a commit" "0" "$rc"
assert_eq "the trusted checkout stays at the base" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD)"
assert_contains "the empty result is an event" "$(cat "$T/events")" "build.patch_empty issue=7"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_commit_dirty (leftovers at the PR stage)"
# ═══════════════════════════════════════════════════════════════════════════════

BASE=$(new_trusted "$T/trusted")
out=$(handoff_commit_dirty "$T/trusted" "cleanup" "$T/left.patch") && rc=0 || rc=$?
assert_exit_code "a clean checkout: nothing to do" "0" "$rc"
assert_eq "and no commit" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD)"

printf 'four\n' >> "$T/trusted/src/app.txt"; echo new > "$T/trusted/src/new.txt"
mkdir -p "$T/trusted/.claude/pipeline-artifacts" && echo plan > "$T/trusted/.claude/pipeline-artifacts/plan.md"
out=$(handoff_commit_dirty "$T/trusted" "cleanup" "$T/left.patch") && rc=0 || rc=$?
assert_exit_code "ordinary leftovers are committed" "0" "$rc"
assert_eq "as one commit on the base" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD~1)"
assert_eq "including new files" "new" "$(git -C "$T/trusted" show HEAD:src/new.txt)"
assert_eq "the checkout is clean afterwards" "" "$(git -C "$T/trusted" status --porcelain -- src)"
assert_file_exists ".claude/ is never part of it and stays in place" "$T/trusted/.claude/pipeline-artifacts/plan.md"

BASE=$(new_trusted "$T/trusted")
printf 'x\n' >> "$T/trusted/.github/workflows/ci.yml"; git -C "$T/trusted" add -A
rc=0; handoff_commit_dirty "$T/trusted" "cleanup" "$T/left.patch" >/dev/null 2>&1 || rc=$?
assert_exit_code "a leftover workflow edit is refused" "1" "$rc"
assert_eq "nothing is committed" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD)"
assert_eq "and the edit is gone from the checkout" "" "$(git -C "$T/trusted" status --porcelain)"
assert_contains "but kept in the patch file" "$(cat "$T/left.patch")" ".github/workflows/ci.yml"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "handoff_export with paths reads only those paths"
# ═══════════════════════════════════════════════════════════════════════════════

BASE=$(new_trusted "$T/trusted")
mkdir -p "$T/trusted/tests"; echo ok > "$T/trusted/tests/a.test.sh"; echo other > "$T/trusted/other.txt"
echo '*' > "$T/trusted/tests/[x].sh"
handoff_export "$T/trusted" "$BASE" "$T/trusted" "$T/only.patch" "tests/a.test.sh" 2>/dev/null
assert_contains "the named file is in the patch" "$(cat "$T/only.patch")" "tests/a.test.sh"
assert_eq "other changes are left out" "0" "$(grep -c 'other.txt\|\[x\]' "$T/only.patch" || true)"
handoff_export "$T/trusted" "$BASE" "$T/trusted" "$T/lit.patch" "tests/[x].sh" 2>/dev/null
assert_eq "paths are literal, not globs" "1" "$(grep -c '^diff --git' "$T/lit.patch" || true)"
rm -rf "$T/trusted/tests" "$T/trusted/other.txt"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "agent stages in the trusted checkout cannot commit"
# ═══════════════════════════════════════════════════════════════════════════════

run_pinned() {
    local stage="$1"
    (
        set +e
        source "$SCRIPT_DIR/lib/pipeline-execution.sh" 2>/dev/null
        info() { :; }; warn() { :; }; error() { :; }
        emit_event() { echo "$*" >> "$T/events"; }
        PROJECT_ROOT="$T/trusted" ISSUE_NUMBER=7
        stage_plan() { (cd "$PROJECT_ROOT" && echo evil > src/evil.txt && git add -A && git commit -qm sneaky); }
        stage_build() { (cd "$PROJECT_ROOT" && echo ok > src/built.txt && git add -A && git commit -qm build); }
        _run_stage_pinned "$stage"
    )
}
BASE=$(new_trusted "$T/trusted"); rm -f "$T/events"
rc=0; run_pinned plan || rc=$?
assert_exit_code "the stage itself still succeeds" "0" "$rc"
assert_eq "a commit made by the plan agent is undone" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD)"
assert_eq "its content stays as unstaged work for the build's judge" "?? src/evil.txt" \
    "$(git -C "$T/trusted" status --porcelain)"
assert_contains "the undo is an event" "$(cat "$T/events")" "stage.head_moved issue=7 stage=plan"

BASE=$(new_trusted "$T/trusted")
run_pinned build || true
assert_eq "the build stage's own commit is kept" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD~1)"

BASE=$(new_trusted "$T/trusted")
( SW_PATCH_HANDOFF=false run_pinned plan ) || true
assert_eq "with handoff off, nothing changes" "$BASE" "$(git -C "$T/trusted" rev-parse HEAD~1)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "persist_artifacts commits only the artifact paths"
# ═══════════════════════════════════════════════════════════════════════════════

BASE=$(new_trusted "$T/trusted")
(
    set +e
    cd "$T/trusted" || exit 1
    source "$SCRIPT_DIR/lib/pipeline-state.sh" 2>/dev/null
    info() { :; }; warn() { :; }; emit_event() { :; }
    git() { if [[ "$1" == "push" ]]; then return 0; fi; command git "$@"; }
    ARTIFACTS_DIR="$T/trusted/.claude/pipeline-artifacts" ISSUE_NUMBER=7 CI_MODE=true
    mkdir -p "$ARTIFACTS_DIR" && echo plan > "$ARTIFACTS_DIR/plan.md"
    echo evil > src/evil.txt && command git add src/evil.txt
    persist_artifacts plan plan.md >/dev/null 2>&1
) || true
assert_eq "the artifact commit holds only the artifact" ".claude/pipeline-artifacts/plan.md" \
    "$(git -C "$T/trusted" show --name-only --format= HEAD)"
assert_eq "what an agent staged stays out of it" "A  src/evil.txt" "$(git -C "$T/trusted" status --porcelain -- src)"

print_test_section "an abort stops the build loop"
# A SIGTERM to the pipeline must stop the running loop and its children at once (#8711 looped
# for 10 hours after an abort). Without handoff and with it.
cat > "$T/slow-loop" <<'SLOW'
#!/usr/bin/env bash
sleep 120 &
echo "$!" > "$ABORT_DIR/grandchild.pid"
echo "$$" > "$ABORT_DIR/loop.pid"
wait
SLOW
chmod +x "$T/slow-loop"
# A zombie counts as stopped: where PID 1 does not reap, a killed process stays as <defunct>.
proc_alive() { kill -0 "$1" 2>/dev/null && ! ps -p "$1" -o stat= 2>/dev/null | grep Z >/dev/null; }
for mode in false true; do
    export ABORT_DIR="$T/abort-$mode"; mkdir -p "$ABORT_DIR"
    (
        set +e
        info() { :; }; success() { :; }; warn() { :; }; error() { :; }; emit_event() { :; }
        _PIPELINE_STAGES_BUILD_LOADED=""
        source "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null
        source "$SCRIPT_DIR/lib/pipeline-util.sh" 2>/dev/null
        trap '_pipeline_stop_children; exit 143' TERM
        SW_PATCH_HANDOFF="$mode" _build_run_loop "$T/slow-loop"
    ) &
    runner=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$ABORT_DIR/grandchild.pid" ]] && break; sleep 0.5; done
    started=$(date +%s)
    kill -TERM "$runner" 2>/dev/null
    wait "$runner" 2>/dev/null || true
    took=$(( $(date +%s) - started ))
    sleep 1
    loop_pid=$(cat "$ABORT_DIR/loop.pid" 2>/dev/null); gc_pid=$(cat "$ABORT_DIR/grandchild.pid" 2>/dev/null)
    [[ -n "$loop_pid" ]] && ! proc_alive "$loop_pid" \
        && assert_pass "handoff=$mode: the loop is stopped" || assert_fail "handoff=$mode: the loop is stopped"
    [[ -n "$gc_pid" ]] && ! proc_alive "$gc_pid" \
        && assert_pass "handoff=$mode: the loop's children are stopped" || assert_fail "handoff=$mode: the loop's children are stopped"
    [[ "$took" -lt 10 ]] && assert_pass "handoff=$mode: the abort takes effect at once" \
        || assert_fail "handoff=$mode: the abort takes effect at once" "took ${took}s"
    [[ -n "$gc_pid" ]] && kill "$gc_pid" 2>/dev/null || true
done


print_test_section "a failed loop shows why it stopped"
printf '{"tokens":1}\nERROR: /x/sw-loop.sh:1042 exited with status 1\nnoise\nlast line\n' > "$T/loop-stderr.log"
shown=$(
    error() { printf '%s\n' "$*"; }
    _PIPELINE_STAGES_BUILD_LOADED=""
    source "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null
    _build_loop_failure_lines "$T/loop-stderr.log"
    _build_loop_failure_lines "$T/missing.log"
)
assert_contains "the loop's ERR-trap line is shown" "$shown" "loop: ERROR: /x/sw-loop.sh:1042 exited with status 1"
assert_contains "the loop's last stderr line is shown" "$shown" "loop: last line"
assert_eq "a line is shown once" "1" "$(printf '%s\n' "$shown" | grep -c 'sw-loop.sh:1042' || true)"
assert_eq "a missing log adds nothing" "4" "$(printf '%s\n' "$shown" | grep -c 'loop: ' || true)"


print_test_section "a failed test stage shows the failing suites in the job log"
printf '  ✓ a-test  1s\n  ✗ b-test  exit 1 0s\n\n━━━ b-test (FAIL:1) — last 25 lines ━━━\n    \033[31m✗\033[0m b broke\n\n  FAILING SUITES\n    b-test  FAIL:1\n' > "$T/test-results.log"
shown=$(
    _PIPELINE_STAGES_BUILD_LOADED=""
    source "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null
    _stage_test_show_failures "$T/test-results.log"
)
assert_contains "the failing suite's section is shown" "$shown" "━━━ b-test (FAIL:1)"
assert_contains "its failing line is shown without colour codes" "$shown" "    ✗ b broke"
assert_eq "passing suites are left out" "0" "$(printf '%s\n' "$shown" | grep -c 'a-test' || true)"

print_test_results
