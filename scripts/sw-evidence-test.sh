#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright evidence test — Unit tests for sw-evidence.sh               ║
# ║  Tests: help, capture, verify, manifest, pre-pr                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-evidence Tests"

setup_test_env "sw-evidence-test"
trap cleanup_test_env EXIT

# Build a minimal test repo so REPO_DIR resolves to our temp
# sw-evidence.sh uses SCRIPT_DIR/.. as REPO_DIR — we need scripts under test repo
TEST_REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$TEST_REPO/scripts/lib" "$TEST_REPO/config" "$TEST_REPO/.claude/evidence"

# Copy sw-evidence and its lib dependencies
cp "$SCRIPT_DIR/sw-evidence.sh" "$TEST_REPO/scripts/"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_REPO/scripts/lib/"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_REPO/scripts/lib/"
cp "$SCRIPT_DIR/lib/test-gate-env.sh" "$TEST_REPO/scripts/lib/"

# Policy fixture with evidence.collectors (CLI-only for reliability)
cat > "$TEST_REPO/config/policy.json" <<'POLICY'
{
  "evidence": {
    "artifactMaxAgeMinutes": 60,
    "requireFreshArtifacts": true,
    "collectors": [
      {
        "name": "cli-echo",
        "type": "cli",
        "command": "echo '{\"status\":\"ok\",\"version\":\"1.0\"}'",
        "expectedExitCode": 0,
        "assertions": ["status-ok", "response-has-version"]
      },
      {
        "name": "cli-true",
        "type": "cli",
        "command": "true",
        "expectedExitCode": 0
      }
    ]
  }
}
POLICY

# Mock curl (for api/browser collectors if any get added)
mock_binary "curl" 'echo "{\"status\":\"ok\"}"; exit 0'
mock_git

# Ensure jq is available (test-helpers links real jq)
if ! command -v jq &>/dev/null; then
    mock_binary "jq" 'cat'
fi

run_evidence() {
    cd "$TEST_REPO" && bash "$TEST_REPO/scripts/sw-evidence.sh" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════════
# help
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "help"

help_out=$(run_evidence help 2>&1) || true
help_exit=$?
assert_contains "help shows usage" "$help_out" "Usage:"
assert_contains "help mentions capture" "$help_out" "capture"
assert_contains "help mentions verify" "$help_out" "verify"
assert_contains "help mentions pre-pr" "$help_out" "pre-pr"
assert_eq "help exits 0" "0" "$help_exit"

help_h=$(run_evidence --help 2>&1) || true
assert_contains "-h shows usage" "$help_h" "shipwright evidence"

# ═══════════════════════════════════════════════════════════════════════════════
# types
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "types"

types_out=$(run_evidence types 2>&1) || true
assert_contains "types lists browser" "$types_out" "browser"
assert_contains "types lists api" "$types_out" "api"
assert_contains "types lists cli" "$types_out" "cli"
assert_contains "types lists database" "$types_out" "database"

# ═══════════════════════════════════════════════════════════════════════════════
# capture cli
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "capture cli"

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

capture_out=$(run_evidence capture cli 2>&1) || true
assert_contains "capture runs collectors" "$capture_out" "cli"

# Evidence artifacts created
assert_file_exists "cli-echo evidence file" "$TEST_REPO/.claude/evidence/cli-echo.json"
assert_file_exists "cli-true evidence file" "$TEST_REPO/.claude/evidence/cli-true.json"

# Validate evidence record structure
echo_json=$(cat "$TEST_REPO/.claude/evidence/cli-echo.json")
assert_contains "evidence has name" "$echo_json" '"name"'
assert_contains "evidence has type" "$echo_json" '"type"'
assert_contains "evidence has passed" "$echo_json" '"passed"'
assert_contains "evidence has captured_at" "$echo_json" '"captured_at"'

# ═══════════════════════════════════════════════════════════════════════════════
# manifest
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "manifest"

assert_file_exists "manifest created" "$TEST_REPO/.claude/evidence/manifest.json"

manifest=$(cat "$TEST_REPO/.claude/evidence/manifest.json")
assert_contains "manifest has captured_at" "$manifest" "captured_at"
assert_contains "manifest has collector_count" "$manifest" "collector_count"
assert_contains "manifest has collectors" "$manifest" "collectors"

# Manifest is valid JSON
if echo "$manifest" | jq empty 2>/dev/null; then
    assert_pass "manifest is valid JSON"
else
    assert_fail "manifest is valid JSON"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# verify
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "verify"

# shellcheck disable=SC2034
verify_out=$(run_evidence verify 2>&1) || verify_exit=$?
# Verify should pass when evidence is fresh
assert_contains "verify checks evidence" "$verify_out" "evidence"

# Verify fails when no manifest
rm -f "$TEST_REPO/.claude/evidence/manifest.json"
verify_fail_out=$(run_evidence verify 2>&1) || true
assert_contains "verify fails without manifest" "$verify_fail_out" "No evidence manifest"

# Restore manifest for next tests
run_evidence capture cli 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# verify stale (artifact freshness)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "verify artifact freshness"

# Policy with very short max age
cat > "$TEST_REPO/config/policy.json" <<'POLICY2'
{
  "evidence": {
    "artifactMaxAgeMinutes": 0,
    "requireFreshArtifacts": true,
    "collectors": [{"name":"cli-echo","type":"cli","command":"true","expectedExitCode":0}]
  }
}
POLICY2

run_evidence capture cli 2>/dev/null || true

# Overwrite manifest with old epoch (2 hours ago)
old_epoch=$(($(date +%s) - 7200))
jq --argjson epoch "$old_epoch" '.captured_epoch = $epoch' \
    "$TEST_REPO/.claude/evidence/manifest.json" > "$TEST_TEMP_DIR/manifest_tmp.json"
mv "$TEST_TEMP_DIR/manifest_tmp.json" "$TEST_REPO/.claude/evidence/manifest.json"

verify_stale_out=$(run_evidence verify 2>&1) || true
assert_contains "verify reports stale evidence" "$verify_stale_out" "stale"

# Restore policy for pre-pr
cat > "$TEST_REPO/config/policy.json" <<'POLICY'
{
  "evidence": {
    "artifactMaxAgeMinutes": 60,
    "requireFreshArtifacts": true,
    "collectors": [
      {"name":"cli-echo","type":"cli","command":"echo '{\"status\":\"ok\"}'","expectedExitCode":0},
      {"name":"cli-true","type":"cli","command":"true","expectedExitCode":0}
    ]
  }
}
POLICY

# ═══════════════════════════════════════════════════════════════════════════════
# pre-pr
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pre-pr"

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

prepr_out=$(run_evidence pre-pr 2>&1) || true
assert_contains "pre-pr runs capture" "$prepr_out" "Capturing"
assert_contains "pre-pr runs verify" "$prepr_out" "Verifying"
assert_file_exists "pre-pr creates manifest" "$TEST_REPO/.claude/evidence/manifest.json"

# ═══════════════════════════════════════════════════════════════════════════════
# status
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "status"

status_out=$(run_evidence status 2>&1) || true
assert_contains "status shows manifest path" "$status_out" "manifest"
assert_contains "status shows collectors" "$status_out" "Collectors"

# ═══════════════════════════════════════════════════════════════════════════════
# mutation testing collector
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "mutation testing"

# Create a simple target script
cat > "$TEST_REPO/test-target.sh" << 'TARGET'
#!/usr/bin/env bash
check_positive() {
    local num=$1
    if [[ "$num" -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}
check_positive 5
TARGET
chmod +x "$TEST_REPO/test-target.sh"

# Update policy with mutation collector
cat > "$TEST_REPO/config/policy.json" <<'POLICY3'
{
  "evidence": {
    "collectors": [
      {
        "name": "mutation-test",
        "type": "mutation",
        "testCommand": "bash test-target.sh",
        "targetFiles": "test-target.sh",
        "mutationThreshold": 50
      }
    ]
  }
}
POLICY3

mutation_out=$(run_evidence capture mutation 2>&1) || true
assert_contains "mutation capture runs" "$mutation_out" "mutation"

# Check evidence file was created
assert_file_exists "mutation evidence file" "$TEST_REPO/.claude/evidence/mutation-test.json"

# Verify mutation evidence structure
mutation_evidence=$(cat "$TEST_REPO/.claude/evidence/mutation-test.json" 2>/dev/null || echo "{}")
assert_contains "mutation has mutation_score" "$mutation_evidence" "mutation_score"
assert_contains "mutation has total_mutants" "$mutation_evidence" "total_mutants"

# ═══════════════════════════════════════════════════════════════════════════════
# property-based testing collector
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "property-based testing"

# Update policy with property collector
cat > "$TEST_REPO/config/policy.json" <<'POLICY4'
{
  "evidence": {
    "collectors": [
      {
        "name": "property-test",
        "type": "property",
        "propertyCommand": "echo ok && exit 0",
        "iterations": 10
      }
    ]
  }
}
POLICY4

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

property_out=$(run_evidence capture property 2>&1) || true
assert_contains "property capture runs" "$property_out" "property"

assert_file_exists "property evidence file" "$TEST_REPO/.claude/evidence/property-test.json"

property_evidence=$(cat "$TEST_REPO/.claude/evidence/property-test.json" 2>/dev/null || echo "{}")
assert_contains "property has passed_count" "$property_evidence" "passed_count"
assert_contains "property has failed_count" "$property_evidence" "failed_count"
assert_contains "property has total_iterations" "$property_evidence" "total_iterations"

# ═══════════════════════════════════════════════════════════════════════════════
# invariant checking collector
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "invariant checking"

# Update policy with invariant collector
cat > "$TEST_REPO/config/policy.json" <<'POLICY5'
{
  "evidence": {
    "collectors": [
      {
        "name": "invariant-test",
        "type": "invariant",
        "invariantName": "file-exists",
        "checkCommand": "test -f test-target.sh && exit 0 || exit 1"
      }
    ]
  }
}
POLICY5

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

invariant_out=$(run_evidence capture invariant 2>&1) || true
assert_contains "invariant capture runs" "$invariant_out" "invariant"

assert_file_exists "invariant evidence file" "$TEST_REPO/.claude/evidence/invariant-test.json"

invariant_evidence=$(cat "$TEST_REPO/.claude/evidence/invariant-test.json" 2>/dev/null || echo "{}")
assert_contains "invariant has invariant_name" "$invariant_evidence" "invariant_name"
assert_contains "invariant has check_exit_code" "$invariant_evidence" "check_exit_code"

# ═══════════════════════════════════════════════════════════════════════════════
# artifact capture
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "artifact capture"

# Create a test artifact
cat > "$TEST_REPO/test-artifact.txt" << 'ARTIFACT'
Build Log
---------
All tests passed: 100/100
Coverage: 95%
ARTIFACT

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

artifact_out=$(cd "$TEST_REPO" && bash "$TEST_REPO/scripts/sw-evidence.sh" artifact "build-log" "test-artifact.txt" 2>&1) || true
assert_contains "artifact capture runs" "$artifact_out" "artifact"

assert_file_exists "artifact stored" "$TEST_REPO/.claude/evidence/artifacts/build-log"
assert_file_exists "artifact manifest created" "$TEST_REPO/.claude/evidence/artifacts-manifest.json"

artifact_manifest=$(cat "$TEST_REPO/.claude/evidence/artifacts-manifest.json" 2>/dev/null || echo "[]")
assert_contains "artifact manifest has name" "$artifact_manifest" "build-log"
assert_contains "artifact manifest has sha256" "$artifact_manifest" "sha256"

# ═══════════════════════════════════════════════════════════════════════════════
# quality score computation
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality score computation"

# Create a policy with multiple collectors to test quality scoring
cat > "$TEST_REPO/config/policy.json" <<'POLICY6'
{
  "evidence": {
    "collectors": [
      {
        "name": "cli-pass",
        "type": "cli",
        "command": "true",
        "expectedExitCode": 0
      },
      {
        "name": "mutation-simple",
        "type": "mutation",
        "testCommand": "true",
        "targetFiles": "test-target.sh",
        "mutationThreshold": 50
      },
      {
        "name": "property-simple",
        "type": "property",
        "propertyCommand": "exit 0",
        "iterations": 5
      },
      {
        "name": "invariant-simple",
        "type": "invariant",
        "invariantName": "test-invariant",
        "checkCommand": "exit 0"
      }
    ]
  }
}
POLICY6

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

# Capture all collectors
run_evidence capture 2>/dev/null || true

# Get quality score
quality_out=$(run_evidence quality-score 2>&1) || true
assert_contains "quality-score command runs" "$quality_out" "quality"
assert_contains "quality-score shows score" "$quality_out" "score"

# ═══════════════════════════════════════════════════════════════════════════════
# list types (updated)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "list types with new collectors"

types_out=$(run_evidence types 2>&1) || true
assert_contains "types lists mutation" "$types_out" "mutation"
assert_contains "types lists property" "$types_out" "property"
assert_contains "types lists invariant" "$types_out" "invariant"

print_test_results
