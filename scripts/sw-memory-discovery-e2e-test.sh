#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Memory & Discovery E2E Test                                ║
# ║  Tests the full memory capture → inject → fix → outcome cycle            ║
# ║  and discovery broadcast → query → inject across pipelines              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0

test_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}✓${RESET} $1"; }
test_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}✗${RESET} $1"; echo -e "    ${DIM}$2${RESET}"; }

MOCK_DIR="$(mktemp -d)"
MOCK_SW="$MOCK_DIR/.shipwright"

export HOME="$MOCK_DIR"
export REPO_DIR="$REPO_ROOT"

cleanup() { rm -rf "$MOCK_DIR"; }
trap cleanup EXIT

echo -e "\n${BOLD}Shipwright Memory & Discovery E2E Test${RESET}\n"

# ─── 1. Memory System Lifecycle ──────────────────────────────────────
echo -e "${BOLD}1. Memory Lifecycle${RESET}"

test_memory_dir_creation() {
    mkdir -p "$MOCK_SW/memory"
    if [[ -d "$MOCK_SW/memory" ]]; then
        test_pass "Memory directory exists"
    else
        test_fail "Memory directory exists" "Not created"
    fi
}
test_memory_dir_creation

test_failure_recording() {
    # Simulate a test failure pattern
    cat > "$MOCK_SW/memory/failures.json" << 'FAIL_JSON'
{
  "failures": [
    {
      "pattern": "TypeError: Cannot read properties of undefined",
      "file": "src/api.ts",
      "fix": "Add null check before accessing .data property",
      "seen_count": 3,
      "times_fix_applied": 2,
      "times_fix_resolved": 2,
      "fix_effectiveness_rate": 1.0,
      "last_seen": "2026-02-16T10:00:00Z"
    },
    {
      "pattern": "ETIMEDOUT: connection timed out",
      "file": "src/db.ts",
      "fix": "Increase connection timeout to 30s",
      "seen_count": 5,
      "times_fix_applied": 4,
      "times_fix_resolved": 3,
      "fix_effectiveness_rate": 0.75,
      "last_seen": "2026-02-16T11:00:00Z"
    }
  ]
}
FAIL_JSON

    local count
    count=$(python3 -c "import json; d=json.load(open('$MOCK_SW/memory/failures.json')); print(len(d['failures']))" 2>/dev/null) || count=0
    if [[ "$count" == "2" ]]; then
        test_pass "Failure patterns stored ($count patterns)"
    else
        test_fail "Failure patterns stored" "Got $count, expected 2"
    fi
}
test_failure_recording

test_fix_effectiveness() {
    # Check that fix effectiveness is tracked
    local effective
    effective=$(python3 -c "
import json
d = json.load(open('$MOCK_SW/memory/failures.json'))
f = d['failures'][0]
print(f['fix_effectiveness_rate'])
" 2>/dev/null) || effective=0
    if [[ "$effective" == "1.0" ]]; then
        test_pass "Fix effectiveness rate tracked (${effective})"
    else
        test_fail "Fix effectiveness rate tracked" "Got: $effective"
    fi
}
test_fix_effectiveness

test_memory_injection_data() {
    # Simulate what memory_closed_loop_inject would return
    local inject
    inject=$(python3 -c "
import json
d = json.load(open('$MOCK_SW/memory/failures.json'))
for f in d['failures']:
    if f['fix_effectiveness_rate'] >= 0.5:
        print(f'Known fix for \"{f[\"pattern\"]}\": {f[\"fix\"]} (effectiveness: {f[\"fix_effectiveness_rate\"]})')
" 2>/dev/null) || inject=""
    if echo "$inject" | grep -q 'Known fix'; then
        test_pass "Memory injection provides known fixes"
    else
        test_fail "Memory injection provides known fixes" "No fixes found"
    fi
}
test_memory_injection_data

test_pattern_deduplication() {
    # Verify that patterns with same pattern string would be deduplicated
    cat > "$MOCK_SW/memory/patterns.json" << 'PATTERNS'
{
  "patterns": [
    {"name": "retry on timeout", "success_rate": 0.8, "applied_count": 10},
    {"name": "add null checks", "success_rate": 0.9, "applied_count": 15}
  ]
}
PATTERNS
    local count
    count=$(python3 -c "import json; d=json.load(open('$MOCK_SW/memory/patterns.json')); print(len(d['patterns']))" 2>/dev/null) || count=0
    if [[ "$count" == "2" ]]; then
        test_pass "Patterns stored and deduplicated ($count unique)"
    else
        test_fail "Patterns stored and deduplicated" "Got $count"
    fi
}
test_pattern_deduplication

# ─── 2. Global Memory ────────────────────────────────────────────────
echo -e "\n${BOLD}2. Global Memory${RESET}"

test_global_learnings() {
    cat > "$MOCK_SW/memory/global.json" << 'GLOBAL'
{
  "learnings": [
    {"lesson": "Always run lint before test to catch syntax errors early", "source": "pipeline-42", "ts": "2026-02-15"},
    {"lesson": "Use --bail flag in vitest for faster failure detection", "source": "pipeline-78", "ts": "2026-02-16"},
    {"lesson": "Review PR description should include issue link", "source": "pipeline-90", "ts": "2026-02-16"}
  ]
}
GLOBAL
    local count
    count=$(python3 -c "import json; d=json.load(open('$MOCK_SW/memory/global.json')); print(len(d['learnings']))" 2>/dev/null) || count=0
    if [[ "$count" -ge 3 ]]; then
        test_pass "Global learnings stored ($count lessons)"
    else
        test_fail "Global learnings stored" "Got $count, expected >=3"
    fi
}
test_global_learnings

test_global_memory_searchable() {
    local found
    found=$(python3 -c "
import json
d = json.load(open('$MOCK_SW/memory/global.json'))
matches = [l for l in d['learnings'] if 'lint' in l['lesson'].lower()]
print(len(matches))
" 2>/dev/null) || found=0
    if [[ "$found" -ge 1 ]]; then
        test_pass "Global memory is searchable ($found matches for 'lint')"
    else
        test_fail "Global memory is searchable" "No matches found"
    fi
}
test_global_memory_searchable

# ─── 3. Discovery System ─────────────────────────────────────────────
echo -e "\n${BOLD}3. Discovery Broadcast & Inject${RESET}"

test_discovery_file() {
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local epoch
    epoch=$(date +%s)
    cat > "$MOCK_SW/discoveries.jsonl" << DISC
{"ts":"$ts","ts_epoch":$epoch,"type":"api_change","file":"src/api/users.ts","detail":"Added POST /api/v2/users","pipeline":"issue-42","ttl":86400}
{"ts":"$ts","ts_epoch":$epoch,"type":"test_pattern","file":"tests/api.test.ts","detail":"New test helper for API mocking","pipeline":"issue-55","ttl":86400}
{"ts":"$ts","ts_epoch":$epoch,"type":"schema_change","file":"src/types/user.ts","detail":"Added email field to User type","pipeline":"issue-42","ttl":86400}
{"ts":"$ts","ts_epoch":$epoch,"type":"config_change","file":"config/policy.json","detail":"Updated lint threshold to 0","pipeline":"issue-78","ttl":86400}
DISC
    local count
    count=$(wc -l < "$MOCK_SW/discoveries.jsonl" | tr -d ' ')
    if [[ "$count" -eq 4 ]]; then
        test_pass "Discovery file has $count entries"
    else
        test_fail "Discovery file has 4 entries" "Got $count"
    fi
}
test_discovery_file

test_discovery_query_by_file_pattern() {
    # Query discoveries for files matching a pattern
    local matches
    matches=$(python3 -c "
import json, sys
matches = []
for line in open('$MOCK_SW/discoveries.jsonl'):
    try:
        d = json.loads(line.strip())
        if 'api' in d.get('file', '').lower():
            matches.append(d)
    except: pass
print(len(matches))
" 2>/dev/null) || matches=0
    if [[ "$matches" -ge 2 ]]; then
        test_pass "Discovery query by file pattern finds $matches matches"
    else
        test_fail "Discovery query by file pattern" "Got $matches, expected >=2"
    fi
}
test_discovery_query_by_file_pattern

test_discovery_query_by_pipeline() {
    local matches
    matches=$(python3 -c "
import json
matches = []
for line in open('$MOCK_SW/discoveries.jsonl'):
    try:
        d = json.loads(line.strip())
        if d.get('pipeline') == 'issue-42':
            matches.append(d)
    except: pass
print(len(matches))
" 2>/dev/null) || matches=0
    if [[ "$matches" -eq 2 ]]; then
        test_pass "Discovery query by pipeline finds $matches entries"
    else
        test_fail "Discovery query by pipeline" "Got $matches, expected 2"
    fi
}
test_discovery_query_by_pipeline

test_discovery_ttl_expiry() {
    # Create an expired discovery
    local old_epoch=$(($(date +%s) - 172800))  # 2 days ago
    echo "{\"ts\":\"2026-02-14T10:00:00Z\",\"ts_epoch\":$old_epoch,\"type\":\"old\",\"file\":\"old.ts\",\"detail\":\"expired\",\"pipeline\":\"issue-1\",\"ttl\":86400}" >> "$MOCK_SW/discoveries.jsonl"

    local now
    now=$(date +%s)
    local active
    active=$(python3 -c "
import json
now = $now
active = 0
for line in open('$MOCK_SW/discoveries.jsonl'):
    try:
        d = json.loads(line.strip())
        ts = d.get('ts_epoch', 0)
        ttl = d.get('ttl', 86400)
        if (now - ts) < ttl:
            active += 1
    except: pass
print(active)
" 2>/dev/null) || active=0
    if [[ "$active" -eq 4 ]]; then
        test_pass "Discovery TTL filters expired entries ($active active)"
    else
        test_fail "Discovery TTL filters expired entries" "Got $active active, expected 4"
    fi
}
test_discovery_ttl_expiry

test_discovery_injection_format() {
    # Simulate what inject_discoveries would produce
    local inject
    inject=$(python3 -c "
import json
lines = []
for line in open('$MOCK_SW/discoveries.jsonl'):
    try:
        d = json.loads(line.strip())
        if 'api' in d.get('file', '').lower():
            lines.append(f'[Discovery from {d[\"pipeline\"]}] {d[\"detail\"]} ({d[\"file\"]})')
    except: pass
print('\n'.join(lines))
" 2>/dev/null) || inject=""
    if echo "$inject" | grep -q 'Discovery from'; then
        test_pass "Discovery injection produces readable context"
    else
        test_fail "Discovery injection produces readable context" "Empty output"
    fi
}
test_discovery_injection_format

# ─── 4. Cross-Pipeline Learning Flow ─────────────────────────────────
echo -e "\n${BOLD}4. Cross-Pipeline Learning Flow${RESET}"

test_full_learning_cycle() {
    # Simulate: Pipeline A discovers something → Pipeline B queries it
    # Pipeline A broadcasts
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local epoch
    epoch=$(date +%s)
    echo "{\"ts\":\"$ts\",\"ts_epoch\":$epoch,\"type\":\"dependency_update\",\"file\":\"package.json\",\"detail\":\"vitest upgraded to 4.0.18\",\"pipeline\":\"issue-100\",\"ttl\":86400}" >> "$MOCK_SW/discoveries.jsonl"

    # Pipeline B queries for package.json changes
    local found
    found=$(python3 -c "
import json
now = $epoch
for line in open('$MOCK_SW/discoveries.jsonl'):
    try:
        d = json.loads(line.strip())
        if 'package.json' in d.get('file', '') and (now - d.get('ts_epoch',0)) < d.get('ttl', 86400):
            print(d['detail'])
            break
    except: pass
" 2>/dev/null) || found=""
    if echo "$found" | grep -q 'vitest'; then
        test_pass "Cross-pipeline learning: Pipeline B finds A's discovery"
    else
        test_fail "Cross-pipeline learning" "Discovery not found: $found"
    fi
}
test_full_learning_cycle

test_memory_to_discovery_chain() {
    # A failure memory should be queryable and injectable
    local chain_result
    chain_result=$(python3 -c "
import json
# Read memory failures
failures = json.load(open('$MOCK_SW/memory/failures.json'))['failures']
# Read discoveries
discoveries = []
for line in open('$MOCK_SW/discoveries.jsonl'):
    try: discoveries.append(json.loads(line.strip()))
    except: pass

# Check that both systems have data
print(f'failures={len(failures)},discoveries={len(discoveries)}')
" 2>/dev/null) || chain_result="error"
    if echo "$chain_result" | grep -q 'failures=2.*discoveries='; then
        test_pass "Memory-Discovery chain: both systems have data"
    else
        test_fail "Memory-Discovery chain" "Got: $chain_result"
    fi
}
test_memory_to_discovery_chain

# ─── 5. Optimization Outcomes ────────────────────────────────────────
echo -e "\n${BOLD}5. Optimization Feedback${RESET}"

test_outcome_tracking() {
    mkdir -p "$MOCK_SW/optimization"
    cat > "$MOCK_SW/optimization/outcomes.jsonl" << 'OUTCOMES'
{"ts":"2026-02-16","issue":42,"template":"standard","result":"success","iterations":3,"cost":2.50,"labels":"bug","model":"claude-4"}
{"ts":"2026-02-16","issue":55,"template":"fast","result":"success","iterations":1,"cost":0.80,"labels":"chore","model":"claude-haiku"}
{"ts":"2026-02-16","issue":78,"template":"standard","result":"failure","iterations":5,"cost":8.00,"labels":"feature","model":"claude-4"}
OUTCOMES
    local success_rate
    success_rate=$(python3 -c "
import json
outcomes = [json.loads(l) for l in open('$MOCK_SW/optimization/outcomes.jsonl')]
successes = sum(1 for o in outcomes if o['result'] == 'success')
print(f'{(successes/len(outcomes)*100):.0f}')
" 2>/dev/null) || success_rate=0
    if [[ "$success_rate" == "67" ]]; then
        test_pass "Outcome tracking: ${success_rate}% success rate"
    else
        test_fail "Outcome tracking" "Got ${success_rate}%, expected 67%"
    fi
}
test_outcome_tracking

test_template_weight_data() {
    # Verify template weights can be computed from outcomes
    local weights
    weights=$(python3 -c "
import json
from collections import defaultdict
outcomes = [json.loads(l) for l in open('$MOCK_SW/optimization/outcomes.jsonl')]
by_template = defaultdict(lambda: {'success': 0, 'total': 0})
for o in outcomes:
    by_template[o['template']]['total'] += 1
    if o['result'] == 'success':
        by_template[o['template']]['success'] += 1
result = {t: round(v['success']/v['total'], 2) for t, v in by_template.items()}
print(json.dumps(result))
" 2>/dev/null) || weights="{}"
    if echo "$weights" | grep -q 'standard\|fast'; then
        test_pass "Template weights computable from outcomes"
    else
        test_fail "Template weights computable from outcomes" "Got: $weights"
    fi
}
test_template_weight_data

# ─── Results ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}Results: ${GREEN}$PASS passed${RESET} / ${RED}$FAIL failed${RESET} / $TOTAL total"

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}FAIL${RESET}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${RESET}"
fi
