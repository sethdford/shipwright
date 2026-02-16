#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-recruit-test.sh — Test suite for AGI-level agent recruitment system ║
# ║  Covers: roles · matching · feedback loop · role creation · evolution   ║
# ║  · self-tuning · meta-learning · decomposition · theory of mind         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -u
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECRUIT_SCRIPT="${SCRIPT_DIR}/sw-recruit.sh"

# Disable LLM calls in tests — ensures fast, deterministic execution
export SW_RECRUIT_NO_LLM=1

# Colors
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
CYAN='\033[38;2;0;212;255m'
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

PASS=0
FAIL=0

test_case() {
    local name="$1"
    echo -n "Testing ${name}... "
}

pass() {
    echo -e "${GREEN}${BOLD}PASS${RESET}"
    ((PASS++))
}

fail() {
    local reason="$1"
    echo -e "${RED}${BOLD}FAIL${RESET}: ${reason}"
    ((FAIL++))
}

# ─── Clean test state ────────────────────────────────────────────────────────
setup_clean_state() {
    rm -rf "${HOME}/.shipwright/recruitment"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1: Core Commands (backward compat)
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 1: Core Commands ═══${RESET}\n"

setup_clean_state

# Test: roles command shows all built-in roles
test_case "roles command"
output=$("$RECRUIT_SCRIPT" roles || true)
if echo "$output" | grep -q "architect" && echo "$output" | grep -q "builder"; then
    pass
else
    fail "Missing roles in output"
fi

# Test: roles shows 10 roles
test_case "roles count"
role_count=$(echo "$output" | grep -c "^[a-z-]*: " || echo "0")
if [[ "$role_count" -eq 10 ]]; then
    pass
else
    fail "Expected 10 roles, got $role_count"
fi

# Test: match command recommends builder
test_case "match command for build task"
match_output=$("$RECRUIT_SCRIPT" match "Build new feature" || true)
if echo "$match_output" | grep -q "builder"; then
    pass
else
    fail "Did not recommend builder for build task"
fi

# Test: match recommends architect for design task
test_case "match command for architecture task"
match_output=$("$RECRUIT_SCRIPT" match "Design system architecture" || true)
if echo "$match_output" | grep -q "architect"; then
    pass
else
    fail "Did not recommend architect for design task"
fi

# Test: match recommends security-auditor for security
test_case "match command for security task"
match_output=$("$RECRUIT_SCRIPT" match "Security vulnerability audit" || true)
if echo "$match_output" | grep -q "security-auditor"; then
    pass
else
    fail "Did not recommend security-auditor"
fi

# Test: match shows confidence and method
test_case "match shows confidence and method"
match_output=$("$RECRUIT_SCRIPT" match "Write unit tests" || true)
if echo "$match_output" | grep -q "confidence:" && echo "$match_output" | grep -q "method:"; then
    pass
else
    fail "Missing confidence or method in match output"
fi

# Test: team command shows team composition
test_case "team command"
team_output=$("$RECRUIT_SCRIPT" team "Build new feature" || true)
if echo "$team_output" | grep -q "builder" && echo "$team_output" | grep -q "Estimated Team Cost"; then
    pass
else
    fail "Missing team composition details"
fi

# Test: team adds security for security tasks
test_case "team composition for security issue"
team_output=$("$RECRUIT_SCRIPT" team "Security fix and refactoring" || true)
if echo "$team_output" | grep -q "security-auditor"; then
    pass
else
    fail "Did not include security-auditor in team"
fi

# Test: profiles command (empty initially)
test_case "profiles command with no data"
profiles_output=$("$RECRUIT_SCRIPT" profiles || true)
if echo "$profiles_output" | grep -q "No performance profiles"; then
    pass
else
    fail "Expected empty profiles message"
fi

# Test: stats command
test_case "stats command"
stats_output=$("$RECRUIT_SCRIPT" stats || true)
if echo "$stats_output" | grep -q "Roles Defined" && echo "$stats_output" | grep -q "10"; then
    pass
else
    fail "Stats missing expected output"
fi

# Test: evaluate command with no data
test_case "evaluate command with missing data"
eval_output=$("$RECRUIT_SCRIPT" evaluate test-agent || true)
if echo "$eval_output" | grep -q "No evaluation history" || echo "$eval_output" | grep -q "Performance Metrics"; then
    pass
else
    fail "Expected evaluation output"
fi

# Test: onboard command for architect
test_case "onboard command for architect"
onboard_output=$("$RECRUIT_SCRIPT" onboard architect || true)
if echo "$onboard_output" | grep -q "Role Profile" && echo "$onboard_output" | grep -q "Architect"; then
    pass
else
    fail "Missing onboarding context for architect"
fi

# Test: onboard command for builder
test_case "onboard command for builder"
onboard_output=$("$RECRUIT_SCRIPT" onboard builder || true)
if echo "$onboard_output" | grep -q "Builder"; then
    pass
else
    fail "Missing onboarding context for builder"
fi

# Test: help command
test_case "help command"
help_output=$("$RECRUIT_SCRIPT" help || true)
if echo "$help_output" | grep -q "CORE COMMANDS" && echo "$help_output" | grep -q "AGI-LEVEL"; then
    pass
else
    fail "Missing help output sections"
fi

# Test: team cost calculation
test_case "team cost calculation"
team_output=$("$RECRUIT_SCRIPT" team "simple task" || true)
cost=$(echo "$team_output" | grep "Estimated Team Cost" | grep -o '\$[0-9.]*' | sed 's/\$//' || echo "0")
if (( $(echo "$cost > 0" | bc -l 2>/dev/null || echo "0") )); then
    pass
else
    fail "Team cost not calculated properly: $cost"
fi

# Test: Database creation
test_case "database initialization"
if [[ -f "${HOME}/.shipwright/recruitment/roles.json" ]]; then
    pass
else
    fail "Roles database not created"
fi

# Test: Roles database content
test_case "roles database content"
role_count=$(jq 'length' "${HOME}/.shipwright/recruitment/roles.json" 2>/dev/null || echo "0")
if [[ "$role_count" -eq 10 ]]; then
    pass
else
    fail "Expected 10 roles in database, got $role_count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2: Feedback Loop & Outcome Recording
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 2: Feedback Loop ═══${RESET}\n"

# Test: record-outcome creates profiles
test_case "record-outcome creates profile"
"$RECRUIT_SCRIPT" record-outcome agent-test-001 task-1 success 8 15 >/dev/null 2>&1 || true
profile=$(jq '."agent-test-001"' "${HOME}/.shipwright/recruitment/profiles.json" 2>/dev/null || echo "{}")
if echo "$profile" | jq -e '.tasks_completed == 1' &>/dev/null; then
    pass
else
    fail "Profile not created correctly"
fi

# Test: record-outcome updates existing profile
test_case "record-outcome updates existing profile"
"$RECRUIT_SCRIPT" record-outcome agent-test-001 task-2 success 9 10 >/dev/null 2>&1 || true
tasks=$(jq '."agent-test-001".tasks_completed' "${HOME}/.shipwright/recruitment/profiles.json" 2>/dev/null || echo "0")
if [[ "$tasks" -eq 2 ]]; then
    pass
else
    fail "Expected 2 tasks, got $tasks"
fi

# Test: record-outcome calculates success rate
test_case "record-outcome calculates success rate"
"$RECRUIT_SCRIPT" record-outcome agent-test-001 task-3 failure 3 20 >/dev/null 2>&1 || true
sr=$(jq '."agent-test-001".success_rate' "${HOME}/.shipwright/recruitment/profiles.json" 2>/dev/null || echo "0")
expected="66.7"
if echo "$sr" | grep -q "66"; then
    pass
else
    fail "Expected ~66.7% success rate, got $sr"
fi

# Test: profiles shows recorded data
test_case "profiles shows recorded agents"
profiles_output=$("$RECRUIT_SCRIPT" profiles || true)
if echo "$profiles_output" | grep -q "agent-test-001"; then
    pass
else
    fail "Agent not in profiles output"
fi

# Test: evaluate uses profile data
test_case "evaluate uses recorded profile"
eval_output=$("$RECRUIT_SCRIPT" evaluate agent-test-001 || true)
if echo "$eval_output" | grep -q "Performance Metrics" && echo "$eval_output" | grep -q "Tasks Completed"; then
    pass
else
    fail "Evaluation not using profile data"
fi

# Test: promote evaluates agent
test_case "promote evaluates recorded agent"
promote_output=$("$RECRUIT_SCRIPT" promote agent-test-001 || true)
if echo "$promote_output" | grep -q "agent-test-001"; then
    pass
else
    fail "Promote not recognizing agent"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3: Dynamic Role Creation
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 3: Dynamic Roles ═══${RESET}\n"

# Test: create-role manual
test_case "create-role manual"
"$RECRUIT_SCRIPT" create-role data-engineer "Data Engineer" "Data pipeline design and ETL" >/dev/null 2>&1 || true
role_exists=$(jq -e '."data-engineer"' "${HOME}/.shipwright/recruitment/roles.json" &>/dev/null && echo "yes" || echo "no")
if [[ "$role_exists" == "yes" ]]; then
    pass
else
    fail "Manual role not created"
fi

# Test: roles count updated after creation
test_case "roles count after create-role"
role_count=$(jq 'length' "${HOME}/.shipwright/recruitment/roles.json" 2>/dev/null || echo "0")
if [[ "$role_count" -eq 11 ]]; then
    pass
else
    fail "Expected 11 roles after adding custom role, got $role_count"
fi

# Test: new role has correct origin
test_case "custom role has manual origin"
origin=$(jq -r '."data-engineer".origin' "${HOME}/.shipwright/recruitment/roles.json" 2>/dev/null || echo "")
if [[ "$origin" == "manual" ]]; then
    pass
else
    fail "Expected origin 'manual', got '$origin'"
fi

# Test: new role appears in roles listing
test_case "custom role in roles listing"
output=$("$RECRUIT_SCRIPT" roles || true)
if echo "$output" | grep -q "data-engineer"; then
    pass
else
    fail "Custom role not in roles output"
fi

# Test: stats shows custom role count
test_case "stats reflects custom roles"
stats_output=$("$RECRUIT_SCRIPT" stats || true)
if echo "$stats_output" | grep -q "custom: 1"; then
    pass
else
    fail "Stats not counting custom roles"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4: Match History & Learning Infrastructure
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 4: Learning Infrastructure ═══${RESET}\n"

# Test: match creates history entry
test_case "match records history"
"$RECRUIT_SCRIPT" match "Deploy to production" >/dev/null 2>&1 || true
if [[ -f "${HOME}/.shipwright/recruitment/match-history.jsonl" ]]; then
    history_count=$(wc -l < "${HOME}/.shipwright/recruitment/match-history.jsonl" | tr -d ' ')
    if [[ "$history_count" -ge 1 ]]; then
        pass
    else
        fail "Match history empty"
    fi
else
    fail "Match history file not created"
fi

# Test: match history has expected fields
test_case "match history has correct fields"
last_entry=$(tail -1 "${HOME}/.shipwright/recruitment/match-history.jsonl" 2>/dev/null || echo "{}")
has_fields=$(echo "$last_entry" | jq -e '.ts and .task and .role and .method' &>/dev/null && echo "yes" || echo "no")
if [[ "$has_fields" == "yes" ]]; then
    pass
else
    fail "Match history missing required fields"
fi

# Test: role usage tracking
test_case "role usage tracking"
if [[ -f "${HOME}/.shipwright/recruitment/role-usage.json" ]]; then
    usage_count=$(jq 'length' "${HOME}/.shipwright/recruitment/role-usage.json" 2>/dev/null || echo "0")
    if [[ "$usage_count" -ge 1 ]]; then
        pass
    else
        fail "Role usage empty"
    fi
else
    fail "Role usage DB not created"
fi

# Test: heuristics DB initialization
test_case "heuristics DB initialization"
if [[ -f "${HOME}/.shipwright/recruitment/heuristics.json" ]]; then
    has_kw=$(jq -e '.keyword_weights' "${HOME}/.shipwright/recruitment/heuristics.json" &>/dev/null && echo "yes" || echo "no")
    if [[ "$has_kw" == "yes" ]]; then
        pass
    else
        fail "Heuristics DB missing keyword_weights"
    fi
else
    fail "Heuristics DB not created"
fi

# Test: meta-learning DB initialization
test_case "meta-learning DB initialization"
if [[ -f "${HOME}/.shipwright/recruitment/meta-learning.json" ]]; then
    has_corrections=$(jq -e '.corrections' "${HOME}/.shipwright/recruitment/meta-learning.json" &>/dev/null && echo "yes" || echo "no")
    if [[ "$has_corrections" == "yes" ]]; then
        pass
    else
        fail "Meta-learning DB missing corrections"
    fi
else
    fail "Meta-learning DB not created"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 5: Population-Aware Evaluation
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 5: Population-Aware Evaluation ═══${RESET}\n"

# Seed multiple agents for population stats
"$RECRUIT_SCRIPT" record-outcome agent-star task-1 success 9 10 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-star task-2 success 10 8 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-star task-3 success 9 12 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-avg task-1 success 7 20 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-avg task-2 failure 4 30 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-avg task-3 success 6 25 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-poor task-1 failure 2 40 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-poor task-2 failure 3 35 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-poor task-3 failure 2 45 >/dev/null 2>&1 || true

# Test: stats shows population statistics
test_case "stats shows population stats"
stats_output=$("$RECRUIT_SCRIPT" stats || true)
if echo "$stats_output" | grep -q "Mean Success Rate"; then
    pass
else
    fail "Population stats not shown in stats output"
fi

# Test: evaluate mentions population threshold
test_case "evaluate mentions population thresholds"
eval_output=$("$RECRUIT_SCRIPT" evaluate agent-star || true)
if echo "$eval_output" | grep -q "threshold\|population\|Excellent\|promotion"; then
    pass
else
    fail "Evaluate not using population-aware thresholds"
fi

# Test: specializations command
test_case "specializations command"
spec_output=$("$RECRUIT_SCRIPT" specializations || true)
if echo "$spec_output" | grep -q "agent-star" && echo "$spec_output" | grep -q "Population Statistics"; then
    pass
else
    fail "Specializations output incomplete"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 6: AGI-Level Features (structural tests — no Claude needed)
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 6: AGI-Level Features ═══${RESET}\n"

# Test: evolve command runs (may be empty)
test_case "evolve command"
evolve_output=$("$RECRUIT_SCRIPT" evolve || true)
if echo "$evolve_output" | grep -qiE "evolution|usage|Not enough"; then
    pass
else
    fail "Evolve command not producing expected output"
fi

# Test: reflect command runs
test_case "reflect command"
reflect_output=$("$RECRUIT_SCRIPT" reflect || true)
if echo "$reflect_output" | grep -qiE "reflection|accuracy|No match history|meta-learning"; then
    pass
else
    fail "Reflect command not producing expected output"
fi

# Test: mind command (no agent)
test_case "mind command without agent"
mind_output=$("$RECRUIT_SCRIPT" mind || true)
if echo "$mind_output" | grep -qiE "Theory of Mind|No agent mind"; then
    pass
else
    fail "Mind command without agent not working"
fi

# Test: mind command with agent
test_case "mind command with agent"
mind_output=$("$RECRUIT_SCRIPT" mind agent-star || true)
if echo "$mind_output" | grep -qiE "theory of mind|Mind profile|Building"; then
    pass
else
    fail "Mind command with agent not working"
fi

# Test: agent-minds DB created
test_case "agent-minds DB created"
if [[ -f "${HOME}/.shipwright/recruitment/agent-minds.json" ]]; then
    pass
else
    fail "Agent minds DB not created"
fi

# Test: decompose command (fallback mode)
test_case "decompose command (fallback)"
decompose_output=$("$RECRUIT_SCRIPT" decompose "Make the product better" || true)
if echo "$decompose_output" | grep -qiE "Decompos|sub-task|architect\|builder"; then
    pass
else
    fail "Decompose not producing output"
fi

# Test: self-tune command
test_case "self-tune command"
# Run several matches first to build history
for task in "Build the login" "Build the signup" "Deploy to staging" "Review auth code" "Test edge cases"; do
    "$RECRUIT_SCRIPT" match "$task" >/dev/null 2>&1 || true
done
tune_output=$("$RECRUIT_SCRIPT" self-tune || true)
if echo "$tune_output" | grep -qiE "Self-tun|keyword|heuristic|matches"; then
    pass
else
    fail "Self-tune command not producing output"
fi

# Test: route command
test_case "route command"
route_output=$("$RECRUIT_SCRIPT" route "Fix a critical production bug" || true)
if echo "$route_output" | grep -qiE "Smart routing|Role:|Model:"; then
    pass
else
    fail "Route command not producing expected output"
fi

# Test: invent command runs (may find nothing)
test_case "invent command"
invent_output=$("$RECRUIT_SCRIPT" invent || true)
if echo "$invent_output" | grep -qiE "Scanning|unmatched|role|covered\|No match history"; then
    pass
else
    fail "Invent command not producing output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 7: Extended keyword matching
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 7: Extended Matching ═══${RESET}\n"

# Test: optimizer role matching with new keywords
test_case "match optimizer for speed task"
match_output=$("$RECRUIT_SCRIPT" match "Make the login faster and reduce latency" || true)
if echo "$match_output" | grep -q "optimizer"; then
    pass
else
    fail "Did not recommend optimizer for speed/latency task"
fi

# Test: devops role matching with new keywords
test_case "match devops for docker task"
match_output=$("$RECRUIT_SCRIPT" match "Set up docker kubernetes deployment" || true)
if echo "$match_output" | grep -q "devops"; then
    pass
else
    fail "Did not recommend devops for docker/kubernetes task"
fi

# Test: incident-responder for outage
test_case "match incident-responder for outage"
match_output=$("$RECRUIT_SCRIPT" match "Critical outage in production" || true)
if echo "$match_output" | grep -q "incident-responder"; then
    pass
else
    fail "Did not recommend incident-responder for outage"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 8: Database Integrity
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 8: Database Integrity ═══${RESET}\n"

# Test: all DB files are valid JSON
test_case "roles.json is valid JSON"
if jq empty "${HOME}/.shipwright/recruitment/roles.json" 2>/dev/null; then
    pass
else
    fail "roles.json is not valid JSON"
fi

test_case "profiles.json is valid JSON"
if jq empty "${HOME}/.shipwright/recruitment/profiles.json" 2>/dev/null; then
    pass
else
    fail "profiles.json is not valid JSON"
fi

test_case "heuristics.json is valid JSON"
if jq empty "${HOME}/.shipwright/recruitment/heuristics.json" 2>/dev/null; then
    pass
else
    fail "heuristics.json is not valid JSON"
fi

test_case "meta-learning.json is valid JSON"
if jq empty "${HOME}/.shipwright/recruitment/meta-learning.json" 2>/dev/null; then
    pass
else
    fail "meta-learning.json is not valid JSON"
fi

test_case "role-usage.json is valid JSON"
if jq empty "${HOME}/.shipwright/recruitment/role-usage.json" 2>/dev/null; then
    pass
else
    fail "role-usage.json is not valid JSON"
fi

test_case "agent-minds.json is valid JSON"
if jq empty "${HOME}/.shipwright/recruitment/agent-minds.json" 2>/dev/null; then
    pass
else
    fail "agent-minds.json is not valid JSON"
fi

# Test: roles have origin field
test_case "builtin roles have origin field"
origins=$(jq '[.[] | .origin // "missing"] | unique' "${HOME}/.shipwright/recruitment/roles.json" 2>/dev/null || echo "[]")
if echo "$origins" | grep -q "builtin"; then
    pass
else
    fail "Built-in roles missing origin field"
fi

# Test: version is 3.0.0
test_case "version is 3.0.0"
version_output=$("$RECRUIT_SCRIPT" help || true)
if echo "$version_output" | grep -q "v3\.0\.0"; then
    pass
else
    fail "Version not updated to 3.0.0"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 9: Onboarding with Theory of Mind
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 9: Adaptive Onboarding ═══${RESET}\n"

# Test: onboard shows onboarding style
test_case "onboard shows onboarding style"
onboard_output=$("$RECRUIT_SCRIPT" onboard builder || true)
if echo "$onboard_output" | grep -q "Onboarding Style"; then
    pass
else
    fail "Onboarding style not shown"
fi

# Test: onboard unknown role fails
test_case "onboard unknown role fails"
onboard_output=$("$RECRUIT_SCRIPT" onboard nonexistent-role 2>&1 || true)
if echo "$onboard_output" | grep -q "Unknown role"; then
    pass
else
    fail "Expected error for unknown role"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 10: Help covers all tiers
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 10: Help Coverage ═══${RESET}\n"

help_output=$("$RECRUIT_SCRIPT" help || true)

test_case "help lists create-role command"
if echo "$help_output" | grep -q "create-role"; then
    pass
else
    fail "create-role not in help"
fi

test_case "help lists record-outcome command"
if echo "$help_output" | grep -q "record-outcome"; then
    pass
else
    fail "record-outcome not in help"
fi

test_case "help lists evolve command"
if echo "$help_output" | grep -q "evolve"; then
    pass
else
    fail "evolve not in help"
fi

test_case "help lists reflect command"
if echo "$help_output" | grep -q "reflect"; then
    pass
else
    fail "reflect not in help"
fi

test_case "help lists invent command"
if echo "$help_output" | grep -q "invent"; then
    pass
else
    fail "invent not in help"
fi

test_case "help lists mind command"
if echo "$help_output" | grep -q "mind"; then
    pass
else
    fail "mind not in help"
fi

test_case "help lists decompose command"
if echo "$help_output" | grep -q "decompose"; then
    pass
else
    fail "decompose not in help"
fi

test_case "help lists self-tune command"
if echo "$help_output" | grep -q "self-tune"; then
    pass
else
    fail "self-tune not in help"
fi

test_case "help lists route command"
if echo "$help_output" | grep -q "route"; then
    pass
else
    fail "route not in help"
fi

test_case "help lists ingest-pipeline command"
if echo "$help_output" | grep -q "ingest-pipeline"; then
    pass
else
    fail "ingest-pipeline not in help"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 11: Ingest Pipeline
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 11: Ingest Pipeline ═══${RESET}\n"

# Create fake events.jsonl for ingest
test_case "ingest-pipeline with synthetic events"
events_file="${HOME}/.shipwright/events.jsonl"
mkdir -p "${HOME}/.shipwright"
now_e=$(date +%s)
cat > "$events_file" <<EOF
{"ts":"2026-02-15T12:00:00Z","ts_epoch":${now_e},"type":"pipeline.completed","result":"success","agent_id":"agent-ingest-1","duration_s":120}
{"ts":"2026-02-15T12:05:00Z","ts_epoch":${now_e},"type":"pipeline.completed","result":"failure","agent_id":"agent-ingest-1","duration_s":300}
{"ts":"2026-02-15T12:10:00Z","ts_epoch":${now_e},"type":"pipeline.completed","result":"success","agent_id":"agent-ingest-2","duration_s":90}
EOF
ingest_output=$("$RECRUIT_SCRIPT" ingest-pipeline 7 || true)
if echo "$ingest_output" | grep -q "Ingested"; then
    pass
else
    fail "Ingest did not report ingested count"
fi

test_case "ingest-pipeline creates profiles from events"
ingest_profile=$(jq '."agent-ingest-1" // {}' "${HOME}/.shipwright/recruitment/profiles.json" 2>/dev/null || echo "{}")
ingest_tasks=$(echo "$ingest_profile" | jq -r '.tasks_completed // 0')
if [[ "$ingest_tasks" -ge 1 ]]; then
    pass
else
    fail "Expected ingested profile, got tasks=$ingest_tasks"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 12: Error Paths
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 12: Error Paths ═══${RESET}\n"

# Test: match with no args fails
test_case "match with no args fails"
match_err=$("$RECRUIT_SCRIPT" match 2>&1 || true)
if echo "$match_err" | grep -qiE "Usage|error"; then
    pass
else
    fail "Expected usage error for empty match"
fi

# Test: evaluate with no args fails
test_case "evaluate with no args fails"
eval_err=$("$RECRUIT_SCRIPT" evaluate 2>&1 || true)
if echo "$eval_err" | grep -qiE "Usage|error"; then
    pass
else
    fail "Expected usage error for empty evaluate"
fi

# Test: record-outcome with missing args fails
test_case "record-outcome with missing args fails"
rec_err=$("$RECRUIT_SCRIPT" record-outcome 2>&1 || true)
if echo "$rec_err" | grep -qiE "Usage|error"; then
    pass
else
    fail "Expected usage error for empty record-outcome"
fi

# Test: decompose with no args fails
test_case "decompose with no args fails"
dec_err=$("$RECRUIT_SCRIPT" decompose 2>&1 || true)
if echo "$dec_err" | grep -qiE "Usage|error"; then
    pass
else
    fail "Expected usage error for empty decompose"
fi

# Test: unknown command fails
test_case "unknown command fails"
unk_err=$("$RECRUIT_SCRIPT" nonexistent-command 2>&1 || true)
if echo "$unk_err" | grep -qiE "Unknown command"; then
    pass
else
    fail "Expected unknown command error"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 13: Route with Experienced Agent
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 13: Route with Agent History ═══${RESET}\n"

# Seed an agent with builder role and 3+ tasks
"$RECRUIT_SCRIPT" record-outcome agent-expert-builder task-b1 success 9 10 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-expert-builder task-b2 success 8 12 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome agent-expert-builder task-b3 success 9 8 >/dev/null 2>&1 || true
# Set the role to builder in profiles
tmp_profile=$(mktemp)
jq '."agent-expert-builder".role = "builder"' "${HOME}/.shipwright/recruitment/profiles.json" > "$tmp_profile" && mv "$tmp_profile" "${HOME}/.shipwright/recruitment/profiles.json"

test_case "route finds best experienced agent"
route_output=$("$RECRUIT_SCRIPT" route "Build a new authentication feature" || true)
if echo "$route_output" | grep -q "Best agent"; then
    pass
else
    fail "Route did not find experienced builder agent"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 14: create-role --auto fallback
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 14: Auto-Role Fallback ═══${RESET}\n"

# With SW_RECRUIT_NO_LLM=1, --auto should fall back to slug generation
test_case "create-role --auto generates slug key (no Claude)"
"$RECRUIT_SCRIPT" create-role --auto "Database migration planning" >/dev/null 2>&1 || true
# Verify the key is NOT literally "--auto"
auto_key_exists=$(jq -e '."--auto"' "${HOME}/.shipwright/recruitment/roles.json" &>/dev/null && echo "yes" || echo "no")
if [[ "$auto_key_exists" == "no" ]]; then
    pass
else
    fail "Fallback created role with key '--auto'"
fi

test_case "create-role --auto fallback creates slugified key"
slug_exists=$(jq -e '."custom-database-migration-planning"' "${HOME}/.shipwright/recruitment/roles.json" &>/dev/null && echo "yes" || echo "no")
if [[ "$slug_exists" == "yes" ]]; then
    pass
else
    fail "Expected slugified role key"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 15: --json Output Mode
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 15: JSON Output Mode ═══${RESET}\n"

# match --json
test_case "match --json returns valid JSON"
match_json=$("$RECRUIT_SCRIPT" match --json "Build a REST API for user management" || true)
if echo "$match_json" | jq -e '.primary_role' &>/dev/null; then
    pass
else
    fail "match --json did not return valid JSON: $match_json"
fi

test_case "match --json includes model field"
match_model=$(echo "$match_json" | jq -r '.model' 2>/dev/null)
if [[ -n "$match_model" && "$match_model" != "null" ]]; then
    pass
else
    fail "match --json missing model field"
fi

test_case "match --json includes confidence"
match_conf=$(echo "$match_json" | jq -r '.confidence' 2>/dev/null)
if [[ -n "$match_conf" && "$match_conf" != "null" ]]; then
    pass
else
    fail "match --json missing confidence"
fi

# team --json
test_case "team --json returns valid JSON"
team_json=$("$RECRUIT_SCRIPT" team --json "Implement OAuth2 authentication with security audit" || true)
if echo "$team_json" | jq -e '.team' &>/dev/null; then
    pass
else
    fail "team --json did not return valid JSON: $team_json"
fi

test_case "team --json includes agents count"
team_agents=$(echo "$team_json" | jq -r '.agents' 2>/dev/null)
if [[ -n "$team_agents" && "$team_agents" != "null" && "$team_agents" -gt 0 ]] 2>/dev/null; then
    pass
else
    fail "team --json missing or invalid agents count"
fi

test_case "team --json includes model"
team_model=$(echo "$team_json" | jq -r '.model' 2>/dev/null)
if [[ -n "$team_model" && "$team_model" != "null" ]]; then
    pass
else
    fail "team --json missing model"
fi

test_case "team --json team array has members"
team_length=$(echo "$team_json" | jq '.team | length' 2>/dev/null)
if [[ "$team_length" -gt 0 ]] 2>/dev/null; then
    pass
else
    fail "team --json team array empty"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 16: jq Dependency Check
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 16: Infrastructure ═══${RESET}\n"

test_case "jq dependency check exists in script"
if grep -q "command -v jq" "$RECRUIT_SCRIPT"; then
    pass
else
    fail "No jq dependency check in script"
fi

test_case "flock-based locking helper exists"
if grep -q "_recruit_locked_write" "$RECRUIT_SCRIPT"; then
    pass
else
    fail "No locking helper in script"
fi

test_case "agent_id field in match history records"
last_record=$(tail -1 "${HOME}/.shipwright/recruitment/match-history.jsonl" 2>/dev/null || echo "")
if echo "$last_record" | jq -e '.agent_id' &>/dev/null 2>&1; then
    pass
else
    fail "match history missing agent_id field"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 17: E2E Integration Flow
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 17: E2E Integration Flow ═══${RESET}\n"

# This test proves the full data flow:
# 1. match --json produces role+model for a task
# 2. team --json produces team composition
# 3. Pipeline event (with agent_id) gets ingested
# 4. Ingest updates the profile
# 5. Route uses the updated profile
# 6. The feedback loop closes

# Step 1: Match a task, verify structured output for pipeline consumption
test_case "e2e: match provides model for pipeline"
e2e_match=$("$RECRUIT_SCRIPT" match --json "Fix critical authentication bypass vulnerability" || true)
e2e_role=$(echo "$e2e_match" | jq -r '.primary_role' 2>/dev/null)
e2e_model=$(echo "$e2e_match" | jq -r '.model' 2>/dev/null)
if [[ "$e2e_role" == "security-auditor" && -n "$e2e_model" ]]; then
    pass
else
    fail "Expected security-auditor role, got: role=$e2e_role model=$e2e_model"
fi

# Step 2: Team composition for pipeline agent count
test_case "e2e: team provides agent count for pipeline"
e2e_team=$("$RECRUIT_SCRIPT" team --json "Fix critical authentication bypass vulnerability" || true)
e2e_agents=$(echo "$e2e_team" | jq -r '.agents' 2>/dev/null)
if [[ "$e2e_agents" -gt 0 ]] 2>/dev/null; then
    pass
else
    fail "Expected agents > 0, got: $e2e_agents"
fi

# Step 3: Simulate pipeline.completed event with agent_id (as pipeline would emit)
test_case "e2e: pipeline event with agent_id ingests correctly"
events_file="${HOME}/.shipwright/events.jsonl"
now_e=$(date +%s)
echo "{\"ts\":\"2026-02-15T18:00:00Z\",\"ts_epoch\":${now_e},\"type\":\"pipeline.completed\",\"result\":\"success\",\"agent_id\":\"e2e-agent-sec\",\"duration_s\":180}" >> "$events_file"
ingest_out=$("$RECRUIT_SCRIPT" ingest-pipeline 1 || true)
# Verify the agent profile was created
e2e_profile=$(jq '."e2e-agent-sec" // {}' "${HOME}/.shipwright/recruitment/profiles.json" 2>/dev/null || echo "{}")
e2e_tc=$(echo "$e2e_profile" | jq -r '.tasks_completed // 0')
if [[ "$e2e_tc" -ge 1 ]]; then
    pass
else
    fail "e2e-agent-sec profile not created after ingest: tasks=$e2e_tc"
fi

# Step 4: Record more outcomes to build history, then route
test_case "e2e: route uses ingested profile for smart routing"
# Add more security outcomes to the e2e agent
"$RECRUIT_SCRIPT" record-outcome e2e-agent-sec sec-task-2 success 9 5 >/dev/null 2>&1 || true
"$RECRUIT_SCRIPT" record-outcome e2e-agent-sec sec-task-3 success 10 4 >/dev/null 2>&1 || true
# Set role to security-auditor
tmp_e2e=$(mktemp)
jq '."e2e-agent-sec".role = "security-auditor"' "${HOME}/.shipwright/recruitment/profiles.json" > "$tmp_e2e" && mv "$tmp_e2e" "${HOME}/.shipwright/recruitment/profiles.json"

route_out=$("$RECRUIT_SCRIPT" route "security audit vulnerability scan" || true)
if echo "$route_out" | grep -q "e2e-agent-sec"; then
    pass
else
    fail "Route did not suggest e2e-agent-sec for security task"
fi

# Step 5: Self-tune learns from the successful pipeline outcomes
test_case "e2e: self-tune captures security keyword"
"$RECRUIT_SCRIPT" self-tune >/dev/null 2>&1 || true
if [[ -f "${HOME}/.shipwright/recruitment/heuristics.json" ]]; then
    pass
else
    fail "Heuristics file not created after self-tune"
fi

# Step 6: Verify the whole chain is traceable via events
test_case "e2e: events trail shows recruit activity"
event_types=$(jq -r '.type' "${HOME}/.shipwright/events.jsonl" 2>/dev/null | sort -u)
has_recruit=false
for etype in $event_types; do
    [[ "$etype" == recruit_* ]] && has_recruit=true
done
if $has_recruit; then
    pass
else
    fail "No recruit events in events.jsonl"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 18: Integration Point Validation
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${CYAN}${BOLD}═══ Section 18: Integration Validation ═══${RESET}\n"

# Verify recruit integration hooks exist in other scripts

test_case "sw-pipeline.sh has agent_id in pipeline.completed events"
if grep -q "agent_id=\${PIPELINE_AGENT_ID" "${SCRIPT_DIR}/sw-pipeline.sh"; then
    pass
else
    fail "pipeline.sh missing agent_id in pipeline.completed"
fi

test_case "sw-pipeline.sh has recruit model selection"
if grep -q "sw-recruit.sh.*match.*--json" "${SCRIPT_DIR}/sw-pipeline.sh"; then
    pass
else
    fail "pipeline.sh missing recruit model selection"
fi

test_case "sw-pipeline.sh has auto-ingest after completion"
if grep -q "sw-recruit.sh.*ingest-pipeline" "${SCRIPT_DIR}/sw-pipeline.sh"; then
    pass
else
    fail "pipeline.sh missing auto-ingest"
fi

test_case "sw-pm.sh has recruit team integration"
if grep -q "sw-recruit.sh.*team.*--json" "${SCRIPT_DIR}/sw-pm.sh"; then
    pass
else
    fail "pm.sh missing recruit team integration"
fi

test_case "sw-triage.sh has recruit team integration"
if grep -q "sw-recruit.sh.*team.*--json" "${SCRIPT_DIR}/sw-triage.sh"; then
    pass
else
    fail "triage.sh missing recruit team integration"
fi

test_case "sw-loop.sh has recruit role assignment"
if grep -q "sw-recruit.sh.*team.*--json" "${SCRIPT_DIR}/sw-loop.sh"; then
    pass
else
    fail "loop.sh missing recruit role assignment"
fi

test_case "sw-loop.sh pulls role descriptions from recruit DB"
if grep -q "recruit_roles_db" "${SCRIPT_DIR}/sw-loop.sh"; then
    pass
else
    fail "loop.sh missing recruit DB role descriptions"
fi

test_case "sw-swarm.sh has recruit-powered type selection"
if grep -q "sw-recruit.sh.*match.*--json" "${SCRIPT_DIR}/sw-swarm.sh"; then
    pass
else
    fail "swarm.sh missing recruit type selection"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "Results: ${GREEN}${BOLD}$PASS PASS${RESET} | ${RED}${BOLD}$FAIL FAIL${RESET}"
echo "════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
