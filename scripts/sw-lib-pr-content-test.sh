#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pr-content test — PR titles, bodies and artifact scrubbing ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Fixtures are the titles and diffs of real pipeline PRs that closed unmerged
# (#7, #8, #10, #37, #40, #195, #241, #358, #363, #663).
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: pr-content Tests"

setup_test_env "lib-pr-content"
trap 'cleanup_test_env; sw_test_teardown' EXIT

source "$SCRIPT_DIR/lib/pr-content.sh"

yes_no() { if "$@"; then echo yes; else echo no; fi; }

# ─── pr_is_chatter ───────────────────────────────────────────────────────────
print_test_section "pr_is_chatter rejects model output seen in past PR titles"

assert_eq "#7 analysis text" yes "$(yes_no pr_is_chatter 'The implementation is **already complete**. Here'"'"'s my analysis:')"
assert_eq "#8 already on main" yes "$(yes_no pr_is_chatter 'The implementation is already on main. The feature branch is at the sa')"
assert_eq "#10 already implemented" yes "$(yes_no pr_is_chatter 'This feature is **already fully implemented**. Here'"'"'s what I found:')"
assert_eq "#37/#40 API error" yes "$(yes_no pr_is_chatter 'Invalid API key · Fix external API key')"
assert_eq "#195 plan heading" yes "$(yes_no pr_is_chatter '**Plan: Add `shipwright ping` command**')"
assert_eq "I'll narration" yes "$(yes_no pr_is_chatter "I'll start by reading the pipeline code")"
assert_eq "Empty is chatter" yes "$(yes_no pr_is_chatter '')"
assert_eq "Issue title kept" no "$(yes_no pr_is_chatter 'Add --json output flag to shipwright status command')"
assert_eq "Issue title starting with The kept" no "$(yes_no pr_is_chatter 'The code review stage ignores review.json')"
assert_eq "Issue title with Summary kept" no "$(yes_no pr_is_chatter 'Summary view for fleet status')"

# ─── pr_build_title ──────────────────────────────────────────────────────────
print_test_section "pr_build_title"

t=$(pr_build_title 'Add --json output flag to shipwright status command' feature 4)
assert_eq "Feature gets feat prefix and issue ref" 'feat: add --json output flag to shipwright status command (#4)' "$t"

t=$(pr_build_title 'Misleading jq not available warning' bug 242)
assert_eq "Bug gets fix prefix" 'fix: misleading jq not available warning (#242)' "$t"

t=$(pr_build_title 'fix(loop): handle JSON object output' bug 242)
assert_eq "Existing conventional prefix kept" 'fix(loop): handle JSON object output (#242)' "$t"

t=$(pr_build_title 'Invalid API key · Fix external API key' feature 33)
assert_eq "Error text falls back to issue ref" 'feat: resolve #33' "$t"

t=$(pr_build_title '' docs 0)
assert_eq "No goal, no issue" 'docs: pipeline changes' "$t"

t=$(pr_build_title 'Issue #12: CLI help is out of date' docs 12)
assert_eq "Issue prefix stripped, no duplicate ref" 'docs: CLI help is out of date (#12)' "$t"

long='Add a minimal pipeline template for trivial single-file fixes that skips plan design and review stages entirely'
t=$(pr_build_title "$long" feature 122)
assert_eq "Long title fits in 72 chars" yes "$( [[ ${#t} -le 72 ]] && echo yes || echo no)"
assert_contains "Long title keeps issue ref" "$t" "(#122)"
words=" ${long} "
last_word="${t% (#122)}"; last_word="${last_word##* }"
assert_contains "Long title cut at a word boundary" "$words" " ${last_word} "

# ─── pr_is_noise_path / pr_real_files ────────────────────────────────────────
print_test_section "noise paths"

assert_eq "Loop log is noise" yes "$(yes_no pr_is_noise_path .claude/loop-logs/tests-iter-2.log)"
assert_eq "Loop state is noise" yes "$(yes_no pr_is_noise_path .claude/loop-state.md)"
assert_eq "Daemon config churn is noise" yes "$(yes_no pr_is_noise_path .claude/daemon-config.json)"
assert_eq "#663 plan file is noise" yes "$(yes_no pr_is_noise_path .claude/IMPLEMENTATION_PLAN.md)"
assert_eq "Agent rules are not noise" no "$(yes_no pr_is_noise_path .claude/rules/bash.md)"
assert_eq "Hooks are not noise" no "$(yes_no pr_is_noise_path .claude/hooks/pre-tool-use.sh)"
assert_eq "Source is not noise" no "$(yes_no pr_is_noise_path scripts/sw-ping.sh)"

real=$(printf '%s\n' .claude/loop-state.md docs/plans/2026-03-02-add-ping-command.md .github/workflows/x.yml | pr_real_files)
assert_eq "Plan doc + artifacts are not a change" "" "$real"
real=$(printf '%s\n' .claude/loop-state.md scripts/sw-ping.sh docs/plans/port/progress.json | pr_real_files)
assert_eq "Real files survive" "scripts/sw-ping.sh
docs/plans/port/progress.json" "$real"

# ─── pr_scrub_noise ──────────────────────────────────────────────────────────
print_test_section "pr_scrub_noise"

repo="$TEST_TEMP_DIR/repo"
mkdir -p "$repo/.claude/loop-logs" "$repo/scripts"
(
    cd "$repo"
    git init -q -b main
    git config user.email t@t.com && git config user.name T
    echo '{"a":1}' > .claude/daemon-config.json
    echo base > scripts/tool.sh
    git add -A && git commit -q -m init
    git checkout -q -b feat/x
    echo '{"a":2}' > .claude/daemon-config.json
    echo log > .claude/loop-logs/tests-iter-1.log
    echo plan > .claude/IMPLEMENTATION_PLAN.md
    echo changed > scripts/tool.sh
    git add -A && git commit -q -m work
)
n=$(cd "$repo" && pr_scrub_noise main)
assert_eq "Three artifact paths scrubbed" 3 "$n"
files=$(cd "$repo" && git diff --name-only main...HEAD)
assert_eq "Only the real change remains in the diff" "scripts/tool.sh" "$files"
assert_file_exists "Scrubbed log stays on disk" "$repo/.claude/loop-logs/tests-iter-1.log"
cfg=$(cd "$repo" && git show HEAD:.claude/daemon-config.json)
assert_eq "Tracked config restored to base" '{"a":1}' "$cfg"
n=$(cd "$repo" && pr_scrub_noise main)
assert_eq "Second scrub is a no-op" 0 "$n"

# ─── pr_base_ref ─────────────────────────────────────────────────────────────
print_test_section "pr_base_ref"
assert_eq "Local base when no remote" main "$(cd "$repo" && pr_base_ref main)"
(cd "$repo" && git update-ref refs/remotes/origin/main main)
assert_eq "Remote base when present" origin/main "$(cd "$repo" && pr_base_ref main)"

# ─── pr_test_summary ─────────────────────────────────────────────────────────
print_test_section "pr_test_summary"
log="$TEST_TEMP_DIR/tests.log"
printf '\033[38;2;0;212;255m▸\033[0m GET /api/db/health returns status... ✓\n\033[1m  All 37 tests passed ✓\033[0m\n═══════\n' > "$log"
assert_eq "Picks the pass line, strips ANSI" "All 37 tests passed ✓" "$(pr_test_summary "$log")"
assert_eq "Empty log gives nothing" "" "$(pr_test_summary "$TEST_TEMP_DIR/missing.log")"

# ─── pr_changed_files_md ─────────────────────────────────────────────────────
print_test_section "pr_changed_files_md"
md=$(cd "$repo" && pr_changed_files_md main 25)
assert_contains "Lists the real file" "$md" '`scripts/tool.sh` (+1 −1)'

print_test_results
