#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-recruit-test.sh — Test suite for agent recruitment system           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -u
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECRUIT_SCRIPT="${SCRIPT_DIR}/sw-recruit.sh"

# Colors
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
RESET='\033[0m'
BOLD='\033[1m'

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
if echo "$eval_output" | grep -q "Performance Metrics"; then
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
if echo "$help_output" | grep -q "COMMANDS" && echo "$help_output" | grep -q "roles"; then
    pass
else
    fail "Missing help output"
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

# Print summary
echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "Results: ${GREEN}${BOLD}$PASS PASS${RESET} | ${RED}${BOLD}$FAIL FAIL${RESET}"
echo "════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
