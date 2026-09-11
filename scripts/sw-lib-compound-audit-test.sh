#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  compound-audit test suite                                              ║
# ║  Tests adaptive cascade audit: agents, dedup, escalation, convergence   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: compound-audit Tests"

setup_test_env "sw-lib-compound-audit-test"
trap cleanup_test_env EXIT

mock_claude

# Source dependencies
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"
export LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"

_AUDIT_TRAIL_LOADED=""
source "$SCRIPT_DIR/lib/audit-trail.sh"
audit_init --issue 99 --goal "Test compound audit"

_COMPOUND_AUDIT_LOADED=""
source "$SCRIPT_DIR/lib/compound-audit.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_build_prompt
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_build_prompt"

# Test: logic auditor prompt contains specialization
result=$(compound_audit_build_prompt "logic" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Logic auditor prompt mentions bugs" "$result" "off-by-one"

# Test: integration auditor prompt contains specialization
result=$(compound_audit_build_prompt "integration" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Integration auditor prompt mentions wiring" "$result" "Wiring"

# Test: completeness auditor prompt mentions spec
result=$(compound_audit_build_prompt "completeness" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Completeness auditor prompt mentions spec" "$result" "spec"

# Test: prompt includes previous findings when provided
result=$(compound_audit_build_prompt "logic" "diff" "plan" '[{"description":"known bug"}]')
assert_contains "Prompt includes previous findings" "$result" "known bug"

# Test: prompt includes diff content
result=$(compound_audit_build_prompt "logic" "diff --git a/foo.sh" "plan" "[]")
assert_contains "Prompt includes diff" "$result" "diff --git a/foo.sh"

# Test: prompt includes plan summary
result=$(compound_audit_build_prompt "logic" "diff" "My plan summary here" "[]")
assert_contains "Prompt includes plan" "$result" "My plan summary here"

# Test: specialist prompts work
result=$(compound_audit_build_prompt "security" "diff" "plan" "[]")
assert_contains "Security prompt mentions injection" "$result" "injection"

result=$(compound_audit_build_prompt "error_handling" "diff" "plan" "[]")
assert_contains "Error handling prompt mentions catch" "$result" "catch"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_parse_findings
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_parse_findings"

# Test: parses valid JSON findings
agent_output='{"findings":[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off-by-one","evidence":"i < n","suggestion":"Use i <= n"}]}'
result=$(compound_audit_parse_findings "$agent_output")
count=$(echo "$result" | jq 'length')
assert_eq "Parses one finding" "1" "$count"

# Test: extracts severity correctly
sev=$(echo "$result" | jq -r '.[0].severity')
assert_eq "Severity is high" "high" "$sev"

# Test: handles empty findings array
result=$(compound_audit_parse_findings '{"findings":[]}')
count=$(echo "$result" | jq 'length')
assert_eq "Empty findings returns empty array" "0" "$count"

# Test: handles malformed output gracefully
result=$(compound_audit_parse_findings "This is not JSON at all")
count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
assert_eq "Malformed output returns empty" "0" "$count"

# Test: handles output with markdown wrapping
result=$(compound_audit_parse_findings '```json
{"findings":[{"severity":"low","category":"completeness","file":"bar.sh","line":5,"description":"Missing test","evidence":"no test file","suggestion":"Add test"}]}
```')
count=$(echo "$result" | jq 'length')
assert_eq "Markdown-wrapped JSON parsed" "1" "$count"

# Test: handles multiple findings
agent_output='{"findings":[
  {"severity":"high","category":"logic","file":"a.sh","line":1,"description":"Bug 1","evidence":"x","suggestion":"y"},
  {"severity":"low","category":"logic","file":"b.sh","line":2,"description":"Bug 2","evidence":"x","suggestion":"y"}
]}'
result=$(compound_audit_parse_findings "$agent_output")
count=$(echo "$result" | jq 'length')
assert_eq "Parses multiple findings" "2" "$count"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_dedup_structural
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_dedup_structural"

# Test: same file + category + nearby lines = duplicate
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"foo.sh","line":12,"description":"Bug B","evidence":"code","suggestion":"fix"},
  {"severity":"medium","category":"integration","file":"bar.sh","line":50,"description":"Wiring gap","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Structural dedup merges nearby same-file same-category" "2" "$count"

# Test: different files are NOT deduped
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"bar.sh","line":10,"description":"Bug B","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Different files not deduped" "2" "$count"

# Test: different categories are NOT deduped
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"security","file":"foo.sh","line":10,"description":"Bug B","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Different categories not deduped" "2" "$count"

# Test: empty input returns empty
result=$(compound_audit_dedup_structural "[]")
count=$(echo "$result" | jq 'length')
assert_eq "Empty input returns empty" "0" "$count"

# Test: lines far apart are NOT deduped
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"foo.sh","line":100,"description":"Bug B","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Distant lines not deduped" "2" "$count"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_escalate
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_escalate"

# Test: security keyword triggers security specialist
findings='[{"severity":"high","category":"logic","file":"auth.sh","line":10,"description":"Missing input validation allows injection","evidence":"eval $input","suggestion":"Sanitize"}]'
result=$(compound_audit_escalate "$findings")
assert_contains "Injection triggers security" "$result" "security"

# Test: error handling keyword triggers error_handling specialist
findings='[{"severity":"high","category":"integration","file":"foo.sh","line":10,"description":"Empty catch block silently swallows errors","evidence":".catch(() => {})","suggestion":"Log error"}]'
result=$(compound_audit_escalate "$findings")
assert_contains "Silent catch triggers error_handling" "$result" "error_handling"

# Test: no trigger keywords returns empty
findings='[{"severity":"low","category":"completeness","file":"readme.md","line":1,"description":"Missing section in docs","evidence":"no API section","suggestion":"Add it"}]'
result=$(compound_audit_escalate "$findings")
assert_eq "No triggers returns empty" "" "$result"

# Test: multiple triggers return unique list
findings='[
  {"severity":"high","category":"logic","file":"auth.sh","line":10,"description":"SQL injection in query","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"api.sh","line":20,"description":"Missing auth check allows bypass","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_escalate "$findings")
# Should contain security but only once
count=$(echo "$result" | tr ' ' '\n' | grep -c "security" || true)
assert_eq "Security appears once even with multiple triggers" "1" "$count"

# Test: empty findings returns empty
result=$(compound_audit_escalate "[]")
assert_eq "Empty findings returns empty" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_converged
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_converged"

# Test: no critical/high findings = converged
result=$(compound_audit_converged "[]" "[]" 1 3)
assert_eq "No findings = converged" "no_criticals" "$result"

# Test: only low/medium findings = converged
new='[{"severity":"low","category":"logic","file":"foo.sh","line":1,"description":"Minor","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "Only low findings = converged" "no_criticals" "$result"

# Test: critical finding = NOT converged
new='[{"severity":"critical","category":"logic","file":"foo.sh","line":1,"description":"Major bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "Critical finding = not converged" "" "$result"

# Test: max cycles reached = converged regardless
new='[{"severity":"critical","category":"logic","file":"foo.sh","line":1,"description":"Major bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 3 3)
assert_eq "Max cycles = converged" "max_cycles" "$result"

# Test: all findings are duplicates of previous = converged (dup rate)
prev='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug","evidence":"x","suggestion":"y"}]'
new='[{"severity":"high","category":"logic","file":"foo.sh","line":11,"description":"Same bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "$prev" 1 3)
assert_eq "All dupes = converged" "dup_rate" "$result"

# Test: high finding = NOT converged
new='[{"severity":"high","category":"logic","file":"foo.sh","line":1,"description":"Important bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "High finding = not converged" "" "$result"

# Test: mixed severity with critical = NOT converged
new='[
  {"severity":"low","category":"logic","file":"foo.sh","line":1,"description":"Minor","evidence":"x","suggestion":"y"},
  {"severity":"critical","category":"logic","file":"bar.sh","line":5,"description":"Major","evidence":"x","suggestion":"y"}
]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "Mixed with critical = not converged" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_run_cycle
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_run_cycle"

# Mock claude to return predictable findings based on stdin content
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Read stdin to get the prompt
input=$(cat)
if echo "$input" | grep "Logic Auditor" >/dev/null; then
    echo '{"findings":[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"i < n","suggestion":"Use <="}]}'
elif echo "$input" | grep "Integration Auditor" >/dev/null; then
    echo '{"findings":[]}'
elif echo "$input" | grep "Completeness Auditor" >/dev/null; then
    echo '{"findings":[{"severity":"low","category":"completeness","file":"bar.sh","line":5,"description":"Missing test","evidence":"no test","suggestion":"Add test"}]}'
else
    echo '{"findings":[]}'
fi
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Test: run_cycle with core agents returns merged findings
export COMPOUND_AUDIT_MODEL="haiku"
result=$(compound_audit_run_cycle "logic integration completeness" "diff content" "plan summary" "[]" 1)
count=$(echo "$result" | jq 'length')
assert_eq "Core cycle returns 2 findings" "2" "$count"

# Test: findings include correct categories
cats=$(echo "$result" | jq -r '.[].category' | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "Categories are logic and completeness" "completeness logic" "$cats"

# Test: audit trail events emitted
if [[ -f "$ARTIFACTS_DIR/pipeline-audit.jsonl" ]]; then
    cycle_start_count=$(grep -c '"compound.cycle_start"' "$ARTIFACTS_DIR/pipeline-audit.jsonl" || true)
    assert_gt "Cycle start event emitted" "$cycle_start_count" 0

    finding_count=$(grep -c '"compound.finding"' "$ARTIFACTS_DIR/pipeline-audit.jsonl" || true)
    assert_gt "Finding events emitted" "$finding_count" 0
else
    assert_fail "Audit trail JSONL exists" "File not found"
fi

# Test: single agent returns just its findings
result=$(compound_audit_run_cycle "logic" "diff content" "plan" "[]" 1)
count=$(echo "$result" | jq 'length')
assert_eq "Single agent returns its findings" "1" "$count"

print_test_results
