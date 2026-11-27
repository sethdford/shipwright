#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/state-sync.sh test — shipwright-data restore and merge-persist ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: the remote is a local bare repository; no network, no GitHub.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "CI: state-sync Tests"

setup_test_env "ci-state-sync"
trap 'cleanup_test_env; sw_test_teardown' EXIT

SYNC="$SCRIPT_DIR/ci/state-sync.sh"
export STATE_REMOTE="$TEST_TEMP_DIR/remote.git"
export STATE_SYNC_MAX_SLEEP=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init --quiet --bare "$STATE_REMOTE"

# run_home <name> — a fresh state home for one simulated CI run.
run_home() { local h="$TEST_TEMP_DIR/run-$1"; rm -rf "$h"; mkdir -p "$h"; echo "$h"; }

# add_cost <home> <stage> <epoch> — appends one ledger row the way sw-cost.sh does.
add_cost() {
    local f="$1/costs.json" tmp
    [[ -f "$f" ]] || echo '{"entries":[],"summary":{}}' > "$f"
    tmp=$(mktemp)
    jq --arg s "$2" --argjson e "$3" '.entries += [{stage: $s, cost_usd: 0.5, ts_epoch: $e}]' "$f" > "$tmp"
    mv "$tmp" "$f"
}

branch_file() { git --git-dir="$STATE_REMOTE" show "shipwright-data:$1" 2>/dev/null; }
stages() { branch_file costs.json | jq -r '[.entries[].stage] | join(",")'; }

expect_exit() { # <desc> <code> <cmd...>
    local desc="$1" want="$2" rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "$desc" "$want" "$rc"
}

print_test_section "first persist and restore"
A=$(run_home a)
SW_STATE_HOME="$A" "$SYNC" restore memory >/dev/null 2>&1
assert_eq "restore with no branch creates the memory dir" "yes" "$([[ -d "$A/memory" ]] && echo yes)"
add_cost "$A" plan 100
echo '{"type":"a1"}' > "$A/events.jsonl"
mkdir -p "$A/baselines" && echo base > "$A/baselines/x.json"
expect_exit "persist creates the branch" 0 env SW_STATE_HOME="$A" "$SYNC" persist pipeline baselines
assert_eq "the branch has run A's cost entry" "plan" "$(stages)"
assert_contains "the branch has a README" "$(branch_file README.md)" "Persistent State"
assert_eq "named directories persist" "base" "$(branch_file baselines/x.json)"

R=$(run_home r)
SW_STATE_HOME="$R" "$SYNC" restore baselines >/dev/null 2>&1
assert_eq "restore copies costs.json" "1" "$(jq '.entries | length' "$R/costs.json")"
assert_eq "restore copies named directories" "base" "$(cat "$R/baselines/x.json")"

print_test_section "concurrent runs do not overwrite each other"
B=$(run_home b); C=$(run_home c)
SW_STATE_HOME="$B" "$SYNC" restore >/dev/null 2>&1
SW_STATE_HOME="$C" "$SYNC" restore >/dev/null 2>&1
add_cost "$B" build 200
add_cost "$C" test 300
echo '{"type":"b1"}' >> "$B/events.jsonl"
echo '{"type":"c1"}' >> "$C/events.jsonl"
SW_STATE_HOME="$B" "$SYNC" persist pipeline >/dev/null 2>&1
SW_STATE_HOME="$C" "$SYNC" persist pipeline >/dev/null 2>&1
assert_eq "both runs' entries survive, ordered by time, the shared one once" "plan,build,test" "$(stages)"
assert_eq "events are the union, each line once" '{"type":"a1"}|{"type":"b1"}|{"type":"c1"}' \
    "$(branch_file events.jsonl | paste -sd'|' -)"

print_test_section "no change, no commit"
before=$(git --git-dir="$STATE_REMOTE" rev-parse shipwright-data)
SW_STATE_HOME="$C" "$SYNC" persist pipeline >/dev/null 2>&1
assert_eq "a re-persist with nothing new makes no commit" "$before" "$(git --git-dir="$STATE_REMOTE" rev-parse shipwright-data)"

print_test_section "a rejected push merges onto the new head"
# The hook lands another run's entry and rejects the push, once, the way a concurrent winner does.
D=$(run_home d)
SW_STATE_HOME="$D" "$SYNC" restore >/dev/null 2>&1
add_cost "$D" review 500
OTHER=$(run_home other)
SW_STATE_HOME="$OTHER" "$SYNC" restore >/dev/null 2>&1
add_cost "$OTHER" deploy 400
cat > "$STATE_REMOTE/hooks/pre-receive" <<HOOK
#!/usr/bin/env bash
[[ -f "$TEST_TEMP_DIR/rejected" ]] && exit 0
touch "$TEST_TEMP_DIR/rejected"
exit 1
HOOK
chmod +x "$STATE_REMOTE/hooks/pre-receive"
# The other run wins the race: its push goes in first (after the hook's one rejection is spent on it).
touch "$TEST_TEMP_DIR/rejected"
SW_STATE_HOME="$OTHER" "$SYNC" persist pipeline >/dev/null 2>&1
rm -f "$TEST_TEMP_DIR/rejected"
out=$(SW_STATE_HOME="$D" "$SYNC" persist pipeline 2>&1)
assert_contains "the first push was rejected and retried" "$out" "attempt 2"
assert_eq "the retry kept the winner's entry and added its own" "plan,build,test,deploy,review" "$(stages)"
rm -f "$STATE_REMOTE/hooks/pre-receive"
count=$(git --git-dir="$STATE_REMOTE" rev-list --count shipwright-data)
assert_eq "history is linear: one commit per persist, nothing force-pushed away" "5" "$count"

print_test_section "every push rejected"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STATE_REMOTE/hooks/pre-receive"
chmod +x "$STATE_REMOTE/hooks/pre-receive"
add_cost "$D" extra 600
before=$(git --git-dir="$STATE_REMOTE" rev-parse shipwright-data)
expect_exit "persist fails when every attempt is rejected" 1 env SW_STATE_HOME="$D" STATE_SYNC_ATTEMPTS=2 "$SYNC" persist pipeline
assert_eq "and the branch is untouched" "$before" "$(git --git-dir="$STATE_REMOTE" rev-parse shipwright-data)"
rm -f "$STATE_REMOTE/hooks/pre-receive"

print_test_section "malformed and capped ledgers"
E=$(run_home e)
echo 'not json' > "$E/costs.json"
SW_STATE_HOME="$E" "$SYNC" persist pipeline >/dev/null 2>&1 || true
assert_eq "a malformed local costs.json keeps the branch's entries" "5" "$(branch_file costs.json | jq '.entries | length')"

F=$(run_home f)
jq -n '{entries: [range(0; 1200) | {stage: "s\(.)", ts_epoch: (1000 + .)}], summary: {}}' > "$F/costs.json"
SW_STATE_HOME="$F" "$SYNC" persist pipeline >/dev/null 2>&1
assert_eq "the ledger keeps the newest 1000 entries" "1000" "$(branch_file costs.json | jq '.entries | length')"
assert_eq "the newest entry is last" "s1199" "$(branch_file costs.json | jq -r '.entries[-1].stage')"

print_test_section "input validation"
expect_exit "persist needs a label" 2 "$SYNC" persist
expect_exit "a directory with a slash is refused" 2 "$SYNC" persist pipeline ../etc
expect_exit "an unknown command is refused" 2 "$SYNC" frobnicate
expect_exit "an unreadable remote: restore warns and continues" 0 env STATE_REMOTE="$TEST_TEMP_DIR/missing.git" SW_STATE_HOME="$E" "$SYNC" restore
expect_exit "an unreadable remote: persist fails" 1 env STATE_REMOTE="$TEST_TEMP_DIR/missing.git" SW_STATE_HOME="$E" STATE_SYNC_ATTEMPTS=1 "$SYNC" persist pipeline

print_test_results
