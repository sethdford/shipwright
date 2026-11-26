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
judge_case "new hook settings are refused" add_settings "protected path: .claude/settings.json"
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
print_test_section "build stage wiring (SW_PATCH_HANDOFF=true)"
# ═══════════════════════════════════════════════════════════════════════════════

# A fake `sw` on PATH stands in for the loop: it records its environment and edits the clone.
mkdir -p "$T/bin"
cat > "$T/bin/sw" <<'FAKE'
#!/usr/bin/env bash
repo=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--repo" ]] && repo="$2"; shift; done
env > "$FAKE_SW_ENV"
cd "$repo" || exit 1
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
        SW_PATCH_HANDOFF=true PROJECT_ROOT="$T/trusted" ARTIFACTS_DIR="$T/artifacts" ISSUE_NUMBER=7 GOAL="Fix app"
        local base dir
        base=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
        dir="$(mktemp -d "$T/agent.XXXXXX")/repo"
        handoff_prepare "$PROJECT_ROOT" "$base" "$dir" || exit 3
        _build_run_loop "Fix app" --repo "$dir" || exit 4
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

print_test_results
