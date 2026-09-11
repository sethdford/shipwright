#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright policy e2e test — Verify config/policy.json is honored     ║
# ║  Pipeline thresholds · Daemon defaults · Policy get · Schema          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"



assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}${BOLD}✓${RESET} $label"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label")
        echo -e "  ${RED}${BOLD}✗${RESET} $label"
        echo -e "    ${DIM}expected: $expected${RESET}"
        echo -e "    ${DIM}actual:   $actual${RESET}"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep "$needle" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}${BOLD}✓${RESET} $label"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label")
        echo -e "  ${RED}${BOLD}✗${RESET} $label"
        echo -e "    ${DIM}output missing: $needle${RESET}"
    fi
}

assert_ge() {
    local label="$1" min="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$actual" -ge "$min" ]]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}${BOLD}✓${RESET} $label"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label")
        echo -e "  ${RED}${BOLD}✗${RESET} $label"
        echo -e "    ${DIM}expected >= $min, got $actual${RESET}"
    fi
}

echo ""
echo -e "  ${CYAN}${BOLD}shipwright policy e2e test${RESET}"
echo -e "  ${DIM}══════════════════════════════════════════${RESET}"

# ═══════════════════════════════════════════════════════════════════════
# Test 1: policy.json is valid JSON
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Policy File Validity${RESET}"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$REPO_DIR/config/policy.json" ]]; then
    if jq empty "$REPO_DIR/config/policy.json" 2>/dev/null; then
        assert_eq "policy.json is valid JSON" "0" "0"
    else
        assert_eq "policy.json is valid JSON" "valid" "invalid"
    fi
else
    assert_eq "policy.json exists" "exists" "missing"
fi

# Test: all required top-level keys present
for key in daemon pipeline quality strategic sweep hygiene recruit; do
    val=$(jq -r ".$key // \"missing\"" "$REPO_DIR/config/policy.json" 2>/dev/null)
    if [[ "$val" != "missing" && "$val" != "null" ]]; then
        assert_eq "policy has .$key section" "present" "present"
    else
        assert_eq "policy has .$key section" "present" "missing"
    fi
done

# ═══════════════════════════════════════════════════════════════════════
# Test 2: policy_get reads correct values from mock policy
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}policy_get Function${RESET}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp/config"
cat > "$tmp/config/policy.json" <<'POLICY'
{
  "pipeline": {
    "coverage_threshold_percent": 85,
    "quality_gate_score_threshold": 90,
    "max_iterations_default": 15,
    "max_cycles_convergence_cap": 42
  },
  "daemon": {
    "poll_interval_seconds": 120,
    "health_heartbeat_timeout": 300
  },
  "hygiene": {
    "artifact_age_days": 21
  }
}
POLICY

# Read coverage threshold (expect 85, not default 60)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".pipeline.coverage_threshold_percent\" \"60\"")
assert_eq "policy_get reads pipeline.coverage_threshold_percent" "85" "$got"

# Read daemon poll interval (expect 120)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.poll_interval_seconds\" \"60\"")
assert_eq "policy_get reads daemon.poll_interval_seconds" "120" "$got"

# Read hygiene artifact age (expect 21)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
assert_eq "policy_get reads hygiene.artifact_age_days" "21" "$got"

# Read missing key (expect default)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".nonexistent.key\" \"fallback_val\"")
assert_eq "policy_get returns default for missing key" "fallback_val" "$got"

# Read with empty policy (expect default)
echo '{}' > "$tmp/config/policy.json"
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".pipeline.coverage_threshold_percent\" \"60\"")
assert_eq "policy_get returns default from empty policy" "60" "$got"

rm -rf "$tmp"

# ═══════════════════════════════════════════════════════════════════════
# Test 3: pipeline-quality.sh reads policy thresholds
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Pipeline Quality Thresholds from Policy${RESET}"

tmp2=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp2/config"
cat > "$tmp2/config/policy.json" <<'POLICY'
{
  "pipeline": {
    "coverage_threshold_percent": 75,
    "quality_gate_score_threshold": 80
  },
  "quality": {
    "coverage_threshold": 75,
    "gate_score_threshold": 80
  }
}
POLICY

# Source pipeline-quality.sh in a subshell with our mock policy
# shellcheck disable=SC2097,SC2098
got_cov=$(REPO_DIR="$tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset _PIPELINE_QUALITY_LOADED POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/pipeline-quality.sh"
  echo "$PIPELINE_COVERAGE_THRESHOLD"
')
assert_eq "pipeline-quality reads coverage threshold from policy" "75" "$got_cov"

# shellcheck disable=SC2097,SC2098
got_gate=$(REPO_DIR="$tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset _PIPELINE_QUALITY_LOADED POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/pipeline-quality.sh"
  echo "$PIPELINE_QUALITY_GATE_THRESHOLD"
')
assert_eq "pipeline-quality reads gate threshold from policy" "80" "$got_gate"

# Verify pipeline_quality_min_threshold function
# shellcheck disable=SC2097,SC2098
got_min=$(REPO_DIR="$tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset _PIPELINE_QUALITY_LOADED POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/pipeline-quality.sh"
  pipeline_quality_min_threshold
')
assert_eq "pipeline_quality_min_threshold returns policy value" "80" "$got_min"

rm -rf "$tmp2"

# ═══════════════════════════════════════════════════════════════════════
# Test 4: daemon policy_get integration (poll interval, stage timeouts)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Daemon Policy Integration${RESET}"

tmp3=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp3/config"
cat > "$tmp3/config/policy.json" <<'POLICY'
{
  "daemon": {
    "poll_interval_seconds": 45,
    "health_heartbeat_timeout": 200,
    "stage_timeouts": {
      "build": 600,
      "test": 300
    },
    "auto_scale_interval_cycles": 3,
    "optimize_interval_cycles": 7,
    "stale_reaper_interval_cycles": 8
  }
}
POLICY

# poll interval
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.poll_interval_seconds\" \"60\"")
assert_eq "daemon poll_interval from policy" "45" "$got"

# heartbeat timeout
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.health_heartbeat_timeout\" \"120\"")
assert_eq "daemon heartbeat_timeout from policy" "200" "$got"

# stage timeout for build
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.stage_timeouts.build\" \"300\"")
assert_eq "daemon stage_timeouts.build from policy" "600" "$got"

# auto_scale_interval from policy
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.auto_scale_interval_cycles\" \"5\"")
assert_eq "daemon auto_scale_interval from policy" "3" "$got"

rm -rf "$tmp3"

# ═══════════════════════════════════════════════════════════════════════
# Test 5: real policy.json values match expectations
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Real Policy Values Sanity${RESET}"

# Verify real config/policy.json has sane values
real_poll=$(jq -r '.daemon.poll_interval_seconds' "$REPO_DIR/config/policy.json")
assert_ge "daemon.poll_interval_seconds >= 10" "10" "$real_poll"

real_cov=$(jq -r '.pipeline.coverage_threshold_percent' "$REPO_DIR/config/policy.json")
assert_ge "pipeline.coverage_threshold >= 1" "1" "$real_cov"

real_gate=$(jq -r '.pipeline.quality_gate_score_threshold' "$REPO_DIR/config/policy.json")
assert_ge "pipeline.quality_gate_score >= 1" "1" "$real_gate"

real_max_iter=$(jq -r '.pipeline.max_iterations_default' "$REPO_DIR/config/policy.json")
assert_ge "pipeline.max_iterations_default >= 1" "1" "$real_max_iter"

real_strat=$(jq -r '.strategic.max_issues_per_cycle' "$REPO_DIR/config/policy.json")
assert_ge "strategic.max_issues_per_cycle >= 1" "1" "$real_strat"

# ═══════════════════════════════════════════════════════════════════════
# Test 6: policy_get with HOME-based fallback
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}HOME-Based Policy Fallback${RESET}"

tmp4=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp4/home/.shipwright"
cat > "$tmp4/home/.shipwright/policy.json" <<'POLICY'
{"hygiene":{"artifact_age_days":30}}
POLICY
# No config/policy.json in REPO_DIR — should fall back to HOME
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp4/norepo" HOME="$tmp4/home" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
assert_eq "policy_get falls back to HOME policy.json" "30" "$got"

rm -rf "$tmp4"

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${DIM}──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}${FAIL} of ${TOTAL} tests failed${RESET}"
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
    exit 1
else
    echo -e "  ${GREEN}${BOLD}All ${TOTAL} tests passed${RESET}"
fi
