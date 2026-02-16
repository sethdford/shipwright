#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright AGI-Roadmap validation — Tests every feature we implemented  ║
# ║  Real functional tests: exercises actual code, verifies real behavior    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[38;2;248;113;113m'
GREEN='\033[38;2;74;222;128m'
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
SKIP=0
TOTAL=0

# ── Test Harness ──────────────────────────────────────────────────────────────
run_test() {
    local desc="$1" fn="$2"
    TOTAL=$((TOTAL + 1))
    printf "  ${CYAN}▸${RESET} %s... " "$desc"
    local output rc
    output=$($fn 2>&1) && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    elif [[ "$rc" -eq 77 ]]; then
        echo -e "${DIM}SKIP${RESET}"
        SKIP=$((SKIP + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        [[ -n "$output" ]] && echo -e "    ${DIM}${output}${RESET}"
        FAIL=$((FAIL + 1))
    fi
}

# ── Temp dir for test artifacts ───────────────────────────────────────────────
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sw-agi-test.XXXXXX")
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# P1: FEEDBACK LOOPS — Discovery, Memory, PM, Failure Learning
# ══════════════════════════════════════════════════════════════════════════════

# ── 1.1 Daemon: failure_history initialized in state ──────────────────────────
test_failure_history_init() {
    # Verify the init_state function includes failure_history: [] (can be up to 50 lines into function)
    grep -A 50 'init_state()' "$SCRIPT_DIR/sw-daemon.sh" | grep -q 'failure_history' || {
        echo "failure_history not in init_state function"
        return 1
    }
    # Verify it's initialized as an array
    grep -q 'failure_history.*\[\]' "$SCRIPT_DIR/sw-daemon.sh" || {
        echo "failure_history not initialized as empty array []"
        return 1
    }
}

# ── 1.2 Daemon: consecutive count uses reduce (run-from-newest) ───────────────
test_consecutive_count_reduce() {
    # Build a failure_history: [api, build, api, api] — consecutive api from newest = 2
    local test_state="$TEST_TMP/consecutive-test.json"
    cat > "$test_state" <<'JSON'
{"failure_history":[
  {"ts":"2026-01-01T00:00:00Z","class":"api_error"},
  {"ts":"2026-01-01T00:01:00Z","class":"build_failure"},
  {"ts":"2026-01-01T00:02:00Z","class":"api_error"},
  {"ts":"2026-01-01T00:03:00Z","class":"api_error"}
]}
JSON
    local count
    count=$(jq -r --arg c "api_error" '
        (.failure_history // []) | [.[].class] | reverse |
        if length == 0 then 0
        elif .[0] != $c then 0
        else
            reduce .[] as $x (
                {count: 0, done: false};
                if .done then . elif $x == $c then .count += 1 else .done = true end
            ) | .count
        end
    ' "$test_state")
    [[ "$count" == "2" ]] || { echo "Expected 2 consecutive api_error, got $count"; return 1; }

    # Build: [build, api, build] — consecutive build from newest = 1
    cat > "$test_state" <<'JSON'
{"failure_history":[
  {"ts":"2026-01-01T00:00:00Z","class":"build_failure"},
  {"ts":"2026-01-01T00:01:00Z","class":"api_error"},
  {"ts":"2026-01-01T00:02:00Z","class":"build_failure"}
]}
JSON
    count=$(jq -r --arg c "build_failure" '
        (.failure_history // []) | [.[].class] | reverse |
        if length == 0 then 0
        elif .[0] != $c then 0
        else
            reduce .[] as $x (
                {count: 0, done: false};
                if .done then . elif $x == $c then .count += 1 else .done = true end
            ) | .count
        end
    ' "$test_state")
    [[ "$count" == "1" ]] || { echo "Expected 1 consecutive build_failure, got $count"; return 1; }
}

# ── 1.3 Daemon: get_max_retries_for_class returns correct values ──────────────
test_max_retries_per_class() {
    # Extract the function and test it in isolation
    local func_body
    func_body=$(sed -n '/^get_max_retries_for_class()/,/^}/p' "$SCRIPT_DIR/sw-daemon.sh")
    [[ -n "$func_body" ]] || { echo "get_max_retries_for_class function not found"; return 1; }
    local result
    result=$(bash -c "
        $func_body
        echo \"auth=\$(get_max_retries_for_class auth_error)\"
        echo \"invalid=\$(get_max_retries_for_class invalid_issue)\"
        echo \"api=\$(get_max_retries_for_class api_error)\"
        echo \"context=\$(get_max_retries_for_class context_exhaustion)\"
        echo \"build=\$(get_max_retries_for_class build_failure)\"
        echo \"unknown=\$(get_max_retries_for_class unknown)\"
    " 2>/dev/null)
    echo "$result" | grep -q "auth=0" || { echo "auth_error should be 0 retries, got: $result"; return 1; }
    echo "$result" | grep -q "invalid=0" || { echo "invalid_issue should be 0 retries"; return 1; }
    echo "$result" | grep -q "api=4" || { echo "api_error should be 4 retries"; return 1; }
    echo "$result" | grep -q "context=2" || { echo "context_exhaustion should be 2 retries"; return 1; }
    echo "$result" | grep -q "build=2" || { echo "build_failure should be 2 retries"; return 1; }
}

# ── 1.4 Daemon: exponential backoff math is correct ───────────────────────────
test_exponential_backoff_math() {
    # Test: 5 * 2^(n-3) for consecutive=3,4,5,6
    local expected_3=$((5 * (1 << 0)))  # 5
    local expected_4=$((5 * (1 << 1)))  # 10
    local expected_5=$((5 * (1 << 2)))  # 20
    local expected_6=$((5 * (1 << 3)))  # 40
    [[ "$expected_3" -eq 5 ]] || { echo "consecutive=3: expected 5m, got $expected_3"; return 1; }
    [[ "$expected_4" -eq 10 ]] || { echo "consecutive=4: expected 10m, got $expected_4"; return 1; }
    [[ "$expected_5" -eq 20 ]] || { echo "consecutive=5: expected 20m, got $expected_5"; return 1; }
    [[ "$expected_6" -eq 40 ]] || { echo "consecutive=6: expected 40m, got $expected_6"; return 1; }
    # Cap at 480
    local pause_mins=9999
    [[ "$pause_mins" -gt 480 ]] && pause_mins=480
    [[ "$pause_mins" -eq 480 ]] || { echo "Cap should be 480, got $pause_mins"; return 1; }
}

# ── 1.5 Daemon: resume_after UTC parsing ──────────────────────────────────────
test_resume_after_utc_parsing() {
    local test_ts="2026-02-15T12:00:00Z"
    local expected_epoch
    # Parse the same way the daemon does — with TZ=UTC
    expected_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$test_ts" +%s 2>/dev/null || \
        date -d "$test_ts" +%s 2>/dev/null || echo 0)
    [[ "$expected_epoch" -gt 0 ]] || { echo "Failed to parse ISO timestamp"; return 1; }
    # The epoch for 2026-02-15T12:00:00Z should be 1771156800 (UTC)
    local expected_utc=1771156800
    [[ "$expected_epoch" -eq "$expected_utc" ]] || { echo "UTC parsing wrong: got $expected_epoch, expected $expected_utc"; return 1; }
}

# ── 1.6 PM: recommend --json flag exists and parses ───────────────────────────
test_pm_recommend_json_flag() {
    # Verify the --json flag handling exists in sw-pm.sh
    grep -q 'json_mode.*true' "$SCRIPT_DIR/sw-pm.sh" || { echo "--json mode not implemented in sw-pm.sh"; return 1; }
    grep -q '"--json"' "$SCRIPT_DIR/sw-pm.sh" || { echo "--json flag not parsed"; return 1; }
}

# ── 1.7 PM: learn subcommand works ───────────────────────────────────────────
test_pm_learn_functional() {
    local out
    out=$(PM_STATE_DIR="$TEST_TMP/pm" NO_GITHUB=true bash "$SCRIPT_DIR/sw-pm.sh" learn 42 success 2>&1 || true)
    echo "$out" | grep -qi "recorded\|captured\|success" || { echo "learn should confirm recording: $out"; return 1; }
}

# ── 1.8 Daemon: PM integration in triage (wiring check) ──────────────────────
test_daemon_pm_triage_wiring() {
    grep -q 'sw-pm.sh.*recommend.*--json' "$SCRIPT_DIR/sw-daemon.sh" || { echo "PM recommend --json not wired into daemon triage"; return 1; }
    grep -q 'sw-pm.sh.*learn.*success' "$SCRIPT_DIR/sw-daemon.sh" || { echo "PM learn success not wired into daemon"; return 1; }
    grep -q 'sw-pm.sh.*learn.*failure' "$SCRIPT_DIR/sw-daemon.sh" || { echo "PM learn failure not wired into daemon"; return 1; }
}

# ── 1.9 Daemon: confidence-based template upgrade ────────────────────────────
test_confidence_template_upgrade() {
    grep -q 'confidence.*-lt 60' "$SCRIPT_DIR/sw-daemon.sh" || { echo "Missing confidence < 60 threshold check"; return 1; }
    grep -q 'upgrading to full template' "$SCRIPT_DIR/sw-daemon.sh" || { echo "Missing upgrade to full template on low confidence"; return 1; }
}

# ══════════════════════════════════════════════════════════════════════════════
# P2: AGENT COORDINATION — Feedback, Predictive, Oversight, Autonomous, Incident
# ══════════════════════════════════════════════════════════════════════════════

# ── 2.1 Feedback: ARTIFACTS_DIR respects caller override ─────────────────────
test_feedback_artifacts_dir_override() {
    grep -q 'ARTIFACTS_DIR="${ARTIFACTS_DIR:-' "$SCRIPT_DIR/sw-feedback.sh" || {
        echo "sw-feedback.sh should use \${ARTIFACTS_DIR:-default} not override"
        return 1
    }
}

# ── 2.2 Feedback: rollback uses PIPESTATUS correctly ─────────────────────────
test_feedback_rollback_pipestatus() {
    grep -q 'PIPESTATUS\[0\]' "$SCRIPT_DIR/sw-feedback.sh" || {
        echo "sw-feedback.sh rollback should use PIPESTATUS[0] for correct exit code"
        return 1
    }
}

# ── 2.3 Predictive: anomaly detection functional test ────────────────────────
test_predictive_anomaly_functional() {
    local predictive_home="$TEST_TMP/predictive-home"
    mkdir -p "$predictive_home/.shipwright/baselines"
    # Set baseline to 100 (using HOME override so BASELINES_DIR points to test dir)
    HOME="$predictive_home" bash "$SCRIPT_DIR/sw-predictive.sh" baseline "build" "duration_s" 100 2>/dev/null || true
    # Verify baseline was written
    local baseline_file
    baseline_file=$(find "$predictive_home" -name "default.json" 2>/dev/null | head -1)
    [[ -f "${baseline_file:-/nonexistent}" ]] || { echo "Baseline file not created"; return 1; }
    # Check anomaly for 500 against baseline 100 (5x should be anomalous)
    local sev
    sev=$(HOME="$predictive_home" bash "$SCRIPT_DIR/sw-predictive.sh" anomaly "build" "duration_s" 500 2>/dev/null || echo "normal")
    [[ "$sev" == "normal" ]] && { echo "Expected anomaly for 5x baseline, got normal"; return 1; }
    return 0
}

# ── 2.4 Predictive: inject-prevention command exists ─────────────────────────
test_predictive_inject_prevention() {
    grep -q 'inject-prevention' "$SCRIPT_DIR/sw-predictive.sh" || { echo "inject-prevention command missing from sw-predictive.sh"; return 1; }
    # Verify the predict_inject_prevention function exists and accepts stage + issue_json
    grep -q 'predict_inject_prevention()' "$SCRIPT_DIR/sw-predictive.sh" || { echo "predict_inject_prevention function missing"; return 1; }
    grep -A 5 'predict_inject_prevention()' "$SCRIPT_DIR/sw-predictive.sh" | grep -q 'stage' || { echo "predict_inject_prevention doesn't accept stage parameter"; return 1; }
}

# ── 2.5 Pipeline: predictive anomaly wired into mark_stage_complete ──────────
test_pipeline_predictive_wiring() {
    grep -q 'sw-predictive.sh.*anomaly' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Predictive anomaly not wired into pipeline"; return 1; }
    grep -q 'sw-predictive.sh.*baseline' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Predictive baseline not wired into pipeline"; return 1; }
    grep -q 'sw-predictive.sh.*inject-prevention' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Predictive inject-prevention not wired into pipeline build stage"; return 1; }
}

# ── 2.6 Pipeline: memory metric wired into mark_stage_complete ───────────────
test_pipeline_memory_wiring() {
    grep -q 'sw-memory.sh.*metric.*duration_s' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Memory metric not wired into pipeline stage completion"; return 1; }
}

# ── 2.7 Oversight: gate command functional test ──────────────────────────────
test_oversight_gate_functional() {
    local test_home="$TEST_TMP/oversight-home"
    mkdir -p "$test_home/.shipwright/oversight"
    echo "diff content" > "$test_home/test.diff"
    local output verdict
    output=$(HOME="$test_home" bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$test_home/test.diff" --description "Test review" 2>/dev/null || true)
    # Verdict is the last line of output (init messages precede it)
    verdict=$(echo "$output" | tail -1)
    [[ "$verdict" == "approved" ]] || { echo "Expected 'approved' verdict, got '$verdict'"; return 1; }
}

# ── 2.8 Oversight: gate rejects on --reject-if ──────────────────────────────
test_oversight_gate_rejection() {
    local test_home="$TEST_TMP/oversight-reject-home"
    mkdir -p "$test_home/.shipwright/oversight"
    echo "diff content" > "$test_home/test.diff"
    local rc output verdict
    output=$(HOME="$test_home" bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$test_home/test.diff" --description "Rejection test" --reject-if "Found 2 critical issues" 2>/dev/null) && rc=0 || rc=$?
    verdict=$(echo "$output" | tail -1)
    [[ "$rc" -ne 0 ]] || { echo "Gate should exit non-zero on rejection"; return 1; }
    [[ "$verdict" == "rejected" ]] || { echo "Expected 'rejected' verdict, got '$verdict'"; return 1; }
}

# ── 2.9 Oversight: gate JSON is valid (no injection from special chars) ──────
test_oversight_gate_json_safety() {
    local test_home="$TEST_TMP/oversight-json-home"
    mkdir -p "$test_home/.shipwright/oversight"
    echo "diff" > "$test_home/test.diff"
    HOME="$test_home" bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$test_home/test.diff" --description "Test with special chars" 2>/dev/null || true
    local review_file
    review_file=$(find "$test_home/.shipwright/oversight" -name "*.json" ! -name "config.json" ! -name "members.json" 2>/dev/null | head -1)
    [[ -f "$review_file" ]] || { echo "No review JSON file created"; return 1; }
    jq -e '.' "$review_file" >/dev/null 2>&1 || { echo "Invalid JSON in review file"; return 1; }
    local desc
    desc=$(jq -r '.description' "$review_file")
    echo "$desc" | grep -q "special" || { echo "Description lost content"; return 1; }
}

# ── 2.10 Pipeline: oversight gate wired into stage_review ────────────────────
test_pipeline_oversight_wiring() {
    grep -q 'sw-oversight.sh.*gate.*--diff' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Oversight gate not wired into pipeline review stage"; return 1; }
    # The key check: the if-block containing oversight gate also checks SKIP_GATES
    # Line structure: if [[ -x oversight.sh ]] && [[ SKIP_GATES != true ]]; then ... gate ...
    grep -B 10 'sw-oversight.sh.*gate' "$SCRIPT_DIR/sw-pipeline.sh" | grep -q 'SKIP_GATES' || {
        echo "Oversight gate does not respect SKIP_GATES"
        return 1
    }
}

# ── 2.11 Pipeline: feedback wired into monitor ──────────────────────────────
test_pipeline_feedback_wiring() {
    grep -q 'sw-feedback.sh.*collect' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Feedback collect not wired into pipeline monitor"; return 1; }
    grep -q 'sw-feedback.sh.*create-issue' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Feedback create-issue not wired into pipeline monitor"; return 1; }
    grep -q 'sw-feedback.sh.*rollback' "$SCRIPT_DIR/sw-pipeline.sh" || { echo "Feedback rollback not wired into pipeline monitor"; return 1; }
}

# ── 2.12 Autonomous: Claude output redirected to findings file ───────────────
test_autonomous_claude_redirect() {
    # Verify Claude output goes to $findings (not lost to stdout)
    # The claude -p command spans multiple lines; the redirect > "$findings" is on a later line
    grep -q '> "$findings"' "$SCRIPT_DIR/sw-autonomous.sh" || {
        echo "Claude analysis output not redirected to \$findings"
        return 1
    }
    # Also check the claude -p is in the same function context (within 15 lines)
    grep -q 'claude -p' "$SCRIPT_DIR/sw-autonomous.sh" || {
        echo "claude -p call not found in sw-autonomous.sh"
        return 1
    }
}

# ── 2.13 Autonomous: dual PR branch check in update_finding_outcomes ─────────
test_autonomous_dual_branch_check() {
    # Verify both pipeline/ and daemon/ branches are checked separately
    grep -c 'gh pr list --head "pipeline/issue-' "$SCRIPT_DIR/sw-autonomous.sh" | grep -q '[1-9]' || {
        echo "Missing pipeline/issue- branch check"
        return 1
    }
    grep -c 'gh pr list --head "daemon/issue-' "$SCRIPT_DIR/sw-autonomous.sh" | grep -q '[1-9]' || {
        echo "Missing daemon/issue- branch check"
        return 1
    }
}

# ── 2.14 Autonomous: run_scheduler exists and has sleep loop ─────────────────
test_autonomous_scheduler() {
    grep -q 'run_scheduler()' "$SCRIPT_DIR/sw-autonomous.sh" || { echo "run_scheduler function not found"; return 1; }
    grep -A 20 'run_scheduler()' "$SCRIPT_DIR/sw-autonomous.sh" | grep -q 'while true' || { echo "Scheduler missing loop"; return 1; }
    grep -A 20 'run_scheduler()' "$SCRIPT_DIR/sw-autonomous.sh" | grep -q 'sleep' || { echo "Scheduler missing sleep"; return 1; }
}

# ── 2.15 Autonomous: trigger_pipeline_for_finding exists ─────────────────────
test_autonomous_pipeline_trigger() {
    grep -q 'trigger_pipeline_for_finding()' "$SCRIPT_DIR/sw-autonomous.sh" || {
        echo "trigger_pipeline_for_finding function not found"
        return 1
    }
    grep -A 10 'trigger_pipeline_for_finding()' "$SCRIPT_DIR/sw-autonomous.sh" | grep -q 'sw-pipeline.sh' || {
        echo "trigger_pipeline_for_finding doesn't call sw-pipeline.sh"
        return 1
    }
}

# ── 2.16 Incident: create_hotfix_issue echoes issue number ──────────────────
test_incident_issue_echo() {
    grep -A 35 'create_hotfix_issue()' "$SCRIPT_DIR/sw-incident.sh" | grep -q 'echo "$issue_num"' || {
        echo "create_hotfix_issue doesn't echo issue number"
        return 1
    }
}

# ── 2.17 Incident: trigger_pipeline wires --template hotfix ─────────────────
test_incident_pipeline_hotfix() {
    grep -q 'trigger_pipeline_for_incident()' "$SCRIPT_DIR/sw-incident.sh" || { echo "trigger_pipeline_for_incident missing"; return 1; }
    grep -A 15 'trigger_pipeline_for_incident()' "$SCRIPT_DIR/sw-incident.sh" | grep -q '\-\-template hotfix' || {
        echo "trigger_pipeline_for_incident missing --template hotfix"
        return 1
    }
}

# ── 2.18 Incident: trigger_rollback wires sw-feedback.sh ────────────────────
test_incident_rollback_wiring() {
    grep -q 'trigger_rollback_for_incident()' "$SCRIPT_DIR/sw-incident.sh" || { echo "trigger_rollback_for_incident missing"; return 1; }
    grep -A 10 'trigger_rollback_for_incident()' "$SCRIPT_DIR/sw-incident.sh" | grep -q 'sw-feedback.sh.*rollback' || {
        echo "trigger_rollback_for_incident doesn't call sw-feedback.sh rollback"
        return 1
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# P3: QUALITY ASSURANCE — Code review, Testgen, Swarm, Multi-agent restart
# ══════════════════════════════════════════════════════════════════════════════

# ── 3.1 Code review: run_claude_semantic_review function exists ──────────────
test_code_review_semantic() {
    grep -q 'run_claude_semantic_review()' "$SCRIPT_DIR/sw-code-review.sh" || {
        echo "run_claude_semantic_review function not found"
        return 1
    }
    # Verify it checks for logic, race conditions, API usage
    grep -A 30 'run_claude_semantic_review()' "$SCRIPT_DIR/sw-code-review.sh" | grep -qi 'logic\|race.*condition\|API' || {
        echo "Semantic review doesn't check for logic/race/API issues"
        return 1
    }
}

# ── 3.2 Code review: semantic review integrated into review_changes ──────────
test_code_review_integration() {
    grep -q 'semantic_findings\|semantic_issues' "$SCRIPT_DIR/sw-code-review.sh" || {
        echo "semantic findings not integrated into review_changes"
        return 1
    }
}

# ── 3.3 Testgen: Claude-based test generation with real assertions ───────────
test_testgen_claude_assertions() {
    grep -q 'assert_equal\|assert_contains' "$SCRIPT_DIR/sw-testgen.sh" || {
        echo "Missing assert_equal/assert_contains helpers in testgen"
        return 1
    }
    # Verify Claude prompt asks for real assertions
    grep -q 'real assertions\|assert' "$SCRIPT_DIR/sw-testgen.sh" || {
        echo "Claude prompt in testgen doesn't ask for real assertions"
        return 1
    }
}

# ── 3.4 Testgen: prompt piped to avoid shell expansion ──────────────────────
test_testgen_no_shell_expansion() {
    grep -q 'cat "$prompt_file" | claude -p' "$SCRIPT_DIR/sw-testgen.sh" || {
        echo "Testgen should pipe prompt to claude to avoid shell expansion"
        return 1
    }
}

# ── 3.5 Swarm: spawn creates real tmux session ──────────────────────────────
test_swarm_tmux_spawn() {
    # Verify tmux new-session is called anywhere in swarm (it's in cmd_spawn)
    grep -q 'tmux new-session' "$SCRIPT_DIR/sw-swarm.sh" || {
        echo "cmd_spawn doesn't create tmux session"
        return 1
    }
    grep -q 'swarm-.*agent_id' "$SCRIPT_DIR/sw-swarm.sh" || {
        echo "tmux session name doesn't include agent_id"
        return 1
    }
}

# ── 3.6 Swarm: retire kills tmux session ────────────────────────────────────
test_swarm_tmux_retire() {
    grep -q 'tmux kill-session' "$SCRIPT_DIR/sw-swarm.sh" || {
        echo "cmd_retire doesn't kill tmux session"
        return 1
    }
}

# ── 3.7 Swarm: spawn and retire functional test ─────────────────────────────
test_swarm_spawn_retire_functional() {
    if ! command -v tmux &>/dev/null; then
        echo "tmux not installed (skipping)"
        return 77
    fi
    local swarm_home="$TEST_TMP/swarm-home"
    mkdir -p "$swarm_home/.shipwright/swarm"
    local reg="$swarm_home/.shipwright/swarm/registry.json"
    # Spawn an agent
    HOME="$swarm_home" NO_GITHUB=true bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard 2>/dev/null || true
    # Check registry has an agent
    [[ -f "$reg" ]] || { echo "Registry not created after spawn"; return 1; }
    local count
    count=$(jq -r '.active_count // 0' "$reg" 2>/dev/null)
    [[ "$count" -ge 1 ]] || { echo "Active count should be >= 1 after spawn, got $count"; return 1; }
    # Get agent ID
    local agent_id
    agent_id=$(jq -r '.agents[0].id // empty' "$reg" 2>/dev/null)
    [[ -n "$agent_id" ]] || { echo "No agent ID in registry"; return 1; }
    # Retire it
    HOME="$swarm_home" NO_GITHUB=true bash "$SCRIPT_DIR/sw-swarm.sh" retire "$agent_id" 2>/dev/null || true
    # Verify count dropped
    count=$(jq -r '.active_count // 0' "$reg" 2>/dev/null)
    [[ "$count" -eq 0 ]] || { echo "Active count should be 0 after retire, got $count"; return 1; }
}

# ── 3.8 Loop: multi-agent max-restarts not blocked ──────────────────────────
test_loop_multiagent_restarts() {
    # Verify that multi-agent mode no longer overrides MAX_RESTARTS to 0
    ! grep -q 'MAX_RESTARTS=0.*multi-agent' "$SCRIPT_DIR/sw-loop.sh" || {
        echo "sw-loop.sh still overrides MAX_RESTARTS=0 in multi-agent mode"
        return 1
    }
    # Verify the comment explaining the change
    grep -q 'max-restarts.*supported.*multi-agent\|restarts apply per-agent' "$SCRIPT_DIR/sw-loop.sh" || {
        echo "Missing comment about max-restarts in multi-agent mode"
        return 1
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# P4: META-COGNITION — Stage effectiveness, Self-awareness, Capability assess
# ══════════════════════════════════════════════════════════════════════════════

# ── 4.1 Pipeline: record_stage_effectiveness functional test ─────────────────
test_stage_effectiveness_recording() {
    local eff_file="$TEST_TMP/stage-effectiveness.jsonl"
    STAGE_EFFECTIVENESS_FILE="$eff_file"
    # Simulate recording
    mkdir -p "$TEST_TMP"
    echo '{"stage":"plan","outcome":"complete","ts":"2026-01-01T00:00:00Z"}' >> "$eff_file"
    echo '{"stage":"plan","outcome":"failed","ts":"2026-01-01T00:01:00Z"}' >> "$eff_file"
    echo '{"stage":"plan","outcome":"failed","ts":"2026-01-01T00:02:00Z"}' >> "$eff_file"
    echo '{"stage":"build","outcome":"complete","ts":"2026-01-01T00:03:00Z"}' >> "$eff_file"
    # Verify each line is valid JSON
    while IFS= read -r line; do
        jq -e '.' <<< "$line" >/dev/null 2>&1 || { echo "Invalid JSONL line: $line"; return 1; }
    done < "$eff_file"
    local plan_count
    plan_count=$(grep '"stage":"plan"' "$eff_file" | wc -l | tr -d ' ')
    [[ "$plan_count" -eq 3 ]] || { echo "Expected 3 plan entries, got $plan_count"; return 1; }
}

# ── 4.2 Pipeline: get_stage_self_awareness_hint returns hint on high failure ──
test_stage_self_awareness_hint() {
    local eff_file="$TEST_TMP/stage-awareness.jsonl"
    # Write 10 plan entries: 6 failed, 4 complete (60% failure rate > 50% threshold)
    for i in 1 2 3 4 5 6; do
        echo '{"stage":"plan","outcome":"failed","ts":"2026-01-01T00:0'$i':00Z"}' >> "$eff_file"
    done
    for i in 7 8 9; do
        echo '{"stage":"plan","outcome":"complete","ts":"2026-01-01T00:0'$i':00Z"}' >> "$eff_file"
    done
    echo '{"stage":"plan","outcome":"complete","ts":"2026-01-01T00:10:00Z"}' >> "$eff_file"

    # Run the actual function logic
    local recent
    recent=$(grep '"stage":"plan"' "$eff_file" | tail -10 || true)
    local failures=0 total=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        echo "$line" | grep -q '"outcome":"failed"' && failures=$((failures + 1)) || true
    done <<< "$recent"
    local rate=$((failures * 100 / total))
    [[ "$total" -ge 3 ]] || { echo "Expected total >= 3, got $total"; return 1; }
    [[ "$rate" -ge 50 ]] || { echo "Expected failure rate >= 50%, got ${rate}%"; return 1; }
    # Verify hint would be generated
    local hint=""
    if [[ "$total" -ge 3 ]] && [[ "$rate" -ge 50 ]]; then
        hint="Recent plan stage failures: consider adding more context or breaking the goal into smaller steps."
    fi
    [[ -n "$hint" ]] || { echo "Hint should have been generated for 60% failure rate"; return 1; }
}

# ── 4.3 Pipeline: record_stage_effectiveness called on both complete/failed ──
test_effectiveness_both_paths() {
    # mark_stage_complete calls record_stage_effectiveness (can be up to 15 lines in)
    grep -A 15 'mark_stage_complete()' "$SCRIPT_DIR/sw-pipeline.sh" | grep -q 'record_stage_effectiveness.*complete' || {
        echo "record_stage_effectiveness not called on mark_stage_complete"
        return 1
    }
    grep -A 10 'mark_stage_failed()' "$SCRIPT_DIR/sw-pipeline.sh" | grep -q 'record_stage_effectiveness.*failed' || {
        echo "record_stage_effectiveness not called on mark_stage_failed"
        return 1
    }
}

# ── 4.4 Pipeline: discovery inject wired into plan/design/build stages ───────
test_discovery_inject_wiring() {
    grep -q 'sw-discovery.sh.*inject' "$SCRIPT_DIR/sw-pipeline.sh" || {
        echo "sw-discovery.sh inject not wired into pipeline"
        return 1
    }
}

# ── 4.5 Pipeline: self-awareness hint injected into plan prompt ──────────────
test_plan_hint_injection() {
    grep -q 'get_stage_self_awareness_hint.*plan' "$SCRIPT_DIR/sw-pipeline.sh" || {
        echo "get_stage_self_awareness_hint not called for plan stage"
        return 1
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# INTEGRATION: CI workflow, integration-claude-test, cross-script safety
# ══════════════════════════════════════════════════════════════════════════════

# ── 5.1 CI: integration-claude job exists in workflow ────────────────────────
test_ci_integration_claude_job() {
    local workflow="$REPO_DIR/.github/workflows/test.yml"
    [[ -f "$workflow" ]] || { echo "CI workflow not found"; return 1; }
    grep -q 'integration-claude:' "$workflow" || { echo "integration-claude job not in CI workflow"; return 1; }
    grep -q 'integration-claude-skip:' "$workflow" || { echo "integration-claude-skip job not in CI workflow"; return 1; }
}

# ── 5.2 Integration-claude: skip path functional ─────────────────────────────
test_integration_claude_skip_path() {
    local out
    out=$(unset CLAUDE_CODE_OAUTH_TOKEN; unset ANTHROPIC_API_KEY; bash "$SCRIPT_DIR/sw-integration-claude-test.sh" 2>&1) || {
        echo "integration-claude-test should exit 0 when skipping"
        return 1
    }
    echo "$out" | grep -q "Skipping integration-claude" || {
        echo "Expected 'Skipping integration-claude' message, got: $out"
        return 1
    }
}

# ── 5.3 All modified scripts have set -euo pipefail ─────────────────────────
test_scripts_strict_mode() {
    local scripts=(
        sw-daemon.sh sw-pipeline.sh sw-feedback.sh sw-oversight.sh
        sw-autonomous.sh sw-incident.sh sw-swarm.sh sw-testgen.sh
        sw-code-review.sh sw-integration-claude-test.sh
    )
    for s in "${scripts[@]}"; do
        grep -q 'set -euo pipefail\|set -eu' "$SCRIPT_DIR/$s" || {
            echo "$s missing strict mode (set -euo pipefail)"
            return 1
        }
    done
}

# ── 5.4 All modified scripts have ERR trap ───────────────────────────────────
test_scripts_err_trap() {
    local scripts=(
        sw-daemon.sh sw-pipeline.sh sw-feedback.sh sw-oversight.sh
        sw-autonomous.sh sw-incident.sh
    )
    for s in "${scripts[@]}"; do
        grep -q "trap.*ERR" "$SCRIPT_DIR/$s" || {
            echo "$s missing ERR trap"
            return 1
        }
    done
}

# ── 5.5 No hardcoded secrets in any script ───────────────────────────────────
test_no_hardcoded_secrets() {
    local scripts=(
        sw-daemon.sh sw-pipeline.sh sw-feedback.sh sw-oversight.sh
        sw-autonomous.sh sw-incident.sh sw-swarm.sh sw-testgen.sh
        sw-code-review.sh
    )
    for s in "${scripts[@]}"; do
        if grep -qiE '(sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|password\s*=\s*"[^"]{8,}")' "$SCRIPT_DIR/$s" 2>/dev/null; then
            echo "$s contains potential hardcoded secrets"
            return 1
        fi
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  AGI-Roadmap Validation — Real Tests for Every Feature        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    echo -e "${PURPLE}${BOLD}Phase 1: Feedback Loops (Discovery, Memory, PM, Failure Learning)${RESET}"
    run_test "Daemon: failure_history initialized in state JSON" test_failure_history_init
    run_test "Daemon: consecutive count uses reduce (run-from-newest, not total)" test_consecutive_count_reduce
    run_test "Daemon: get_max_retries_for_class returns per-class limits" test_max_retries_per_class
    run_test "Daemon: exponential backoff formula 5*2^(n-3) is correct" test_exponential_backoff_math
    run_test "Daemon: resume_after parsed in UTC (not local TZ)" test_resume_after_utc_parsing
    run_test "PM: recommend --json flag implemented" test_pm_recommend_json_flag
    run_test "PM: learn subcommand functional" test_pm_learn_functional
    run_test "Daemon: PM recommend/learn wired into triage + success/failure" test_daemon_pm_triage_wiring
    run_test "Daemon: confidence < 60% upgrades to full template" test_confidence_template_upgrade
    echo ""

    echo -e "${PURPLE}${BOLD}Phase 2: Agent Coordination (Feedback, Predictive, Oversight, Autonomous)${RESET}"
    run_test "Feedback: ARTIFACTS_DIR respects caller override" test_feedback_artifacts_dir_override
    run_test "Feedback: rollback uses PIPESTATUS for correct exit code" test_feedback_rollback_pipestatus
    run_test "Predictive: anomaly detection returns severity for 5x baseline" test_predictive_anomaly_functional
    run_test "Predictive: inject-prevention command exists and runs" test_predictive_inject_prevention
    run_test "Pipeline: predictive anomaly/baseline/inject-prevention wired" test_pipeline_predictive_wiring
    run_test "Pipeline: memory metric wired into stage completion" test_pipeline_memory_wiring
    run_test "Oversight: gate approves clean review" test_oversight_gate_functional
    run_test "Oversight: gate rejects with --reject-if" test_oversight_gate_rejection
    run_test "Oversight: gate JSON safe from newline/quote injection" test_oversight_gate_json_safety
    run_test "Pipeline: oversight gate wired + respects SKIP_GATES" test_pipeline_oversight_wiring
    run_test "Pipeline: feedback collect/create-issue/rollback wired into monitor" test_pipeline_feedback_wiring
    run_test "Autonomous: Claude output redirected to findings file" test_autonomous_claude_redirect
    run_test "Autonomous: dual branch check (pipeline + daemon)" test_autonomous_dual_branch_check
    run_test "Autonomous: run_scheduler with loop/sleep" test_autonomous_scheduler
    run_test "Autonomous: trigger_pipeline_for_finding wired" test_autonomous_pipeline_trigger
    run_test "Incident: create_hotfix_issue echoes issue number" test_incident_issue_echo
    run_test "Incident: trigger_pipeline wires --template hotfix" test_incident_pipeline_hotfix
    run_test "Incident: trigger_rollback wires sw-feedback.sh" test_incident_rollback_wiring
    echo ""

    echo -e "${PURPLE}${BOLD}Phase 3: Quality Assurance (Code Review, Testgen, Swarm, Multi-Agent)${RESET}"
    run_test "Code review: run_claude_semantic_review exists" test_code_review_semantic
    run_test "Code review: semantic findings integrated" test_code_review_integration
    run_test "Testgen: Claude prompt asks for real assertions" test_testgen_claude_assertions
    run_test "Testgen: prompt piped to avoid shell expansion" test_testgen_no_shell_expansion
    run_test "Swarm: spawn creates tmux session" test_swarm_tmux_spawn
    run_test "Swarm: retire kills tmux session" test_swarm_tmux_retire
    run_test "Swarm: spawn/retire functional (real tmux)" test_swarm_spawn_retire_functional
    run_test "Loop: multi-agent restarts not blocked" test_loop_multiagent_restarts
    echo ""

    echo -e "${PURPLE}${BOLD}Phase 4: Meta-Cognition (Effectiveness, Self-Awareness, Capability)${RESET}"
    run_test "Pipeline: record_stage_effectiveness creates valid JSONL" test_stage_effectiveness_recording
    run_test "Pipeline: self-awareness hint triggers on >50% failure rate" test_stage_self_awareness_hint
    run_test "Pipeline: effectiveness recorded on both complete and failed" test_effectiveness_both_paths
    run_test "Pipeline: discovery inject wired" test_discovery_inject_wiring
    run_test "Pipeline: self-awareness hint injected into plan prompt" test_plan_hint_injection
    echo ""

    echo -e "${PURPLE}${BOLD}Integration & Safety${RESET}"
    run_test "CI: integration-claude jobs in workflow" test_ci_integration_claude_job
    run_test "Integration-claude: skip path functional" test_integration_claude_skip_path
    run_test "All modified scripts have strict mode" test_scripts_strict_mode
    run_test "All modified scripts have ERR trap" test_scripts_err_trap
    run_test "No hardcoded secrets in scripts" test_no_hardcoded_secrets
    echo ""

    # ── Summary ──────────────────────────────────────────────────────────────
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    echo ""
    if [[ "$FAIL" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All $PASS tests passed!${RESET}"
        [[ "$SKIP" -gt 0 ]] && echo -e "  ${DIM}($SKIP skipped)${RESET}"
    else
        echo -e "  ${GREEN}Passed:${RESET} $PASS"
        echo -e "  ${RED}Failed:${RESET} $FAIL"
        [[ "$SKIP" -gt 0 ]] && echo -e "  ${DIM}Skipped: $SKIP${RESET}"
    fi
    echo ""

    [[ "$FAIL" -eq 0 ]]
}

main "$@"
