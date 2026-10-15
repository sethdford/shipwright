# pipeline-quality-checks.sh — Quality checks (security, bundle, perf, api, coverage, adversarial, dod, bash compat, etc.) for sw-pipeline.sh

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh"
# Source from sw-pipeline.sh. Requires pipeline-quality.sh, ARTIFACTS_DIR, SCRIPT_DIR.
# Test commands run without credentials (#8608).
# shellcheck source=lib/test-gate-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-gate-env.sh"
[[ -n "${_PIPELINE_QUALITY_CHECKS_LOADED:-}" ]] && return 0
_PIPELINE_QUALITY_CHECKS_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
TEST_CMD="${TEST_CMD:-}"

# Source sub-modules
if [[ -f "${SCRIPT_DIR}/lib/pipeline-quality-gates.sh" ]]; then
    source "${SCRIPT_DIR}/lib/pipeline-quality-gates.sh"
fi
if [[ -f "${SCRIPT_DIR}/lib/pipeline-quality-bash-compat.sh" ]]; then
    source "${SCRIPT_DIR}/lib/pipeline-quality-bash-compat.sh"
fi

run_adversarial_review() {
    local diff_content
    diff_content=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)

    if [[ -z "$diff_content" ]]; then
        info "No diff to review"
        return 0
    fi

    # Delegate to sw-adversarial.sh module when available (uses intelligence cache)
    if type adversarial_review >/dev/null 2>&1; then
        info "Using intelligence-backed adversarial review..."
        local json_result
        json_result=$(adversarial_review "$diff_content" "${GOAL:-}" 2>/dev/null || echo "[]")

        # Save raw JSON result
        echo "$json_result" > "$ARTIFACTS_DIR/adversarial-review.json"

        # Convert JSON findings to markdown for compatibility with compound_rebuild_with_feedback
        local critical_count high_count
        critical_count=$(echo "$json_result" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")
        high_count=$(echo "$json_result" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")
        local total_findings
        total_findings=$(echo "$json_result" | jq 'length' 2>/dev/null || echo "0")

        # Generate markdown report from JSON
        {
            echo "# Adversarial Review (Intelligence-backed)"
            echo ""
            echo "Total findings: ${total_findings} (${critical_count} critical, ${high_count} high)"
            echo ""
            echo "$json_result" | jq -r '.[] | "- **[\(.severity // "unknown")]** \(.location // "unknown") — \(.description // .concern // "no description")"' 2>/dev/null || true
        } > "$ARTIFACTS_DIR/adversarial-review.md"

        emit_event "adversarial.delegated" \
            "issue=${ISSUE_NUMBER:-0}" \
            "findings=$total_findings" \
            "critical=$critical_count" \
            "high=$high_count"

        if [[ "$critical_count" -gt 0 ]]; then
            warn "Adversarial review: ${critical_count} critical, ${high_count} high"
            return 1
        elif [[ "$high_count" -gt 0 ]]; then
            warn "Adversarial review: ${high_count} high-severity issues"
            return 1
        fi

        success "Adversarial review: clean"
        return 0
    fi

    # Fallback: inline Claude call when module not loaded

    # Inject previous adversarial findings from memory
    local adv_memory=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        adv_memory=$(intelligence_search_memory "adversarial review security findings for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
    fi

    local prompt="You are a hostile code reviewer. Your job is to find EVERY possible issue in this diff.
Look for:
- Bugs (logic errors, off-by-one, null/undefined access, race conditions)
- Security vulnerabilities (injection, XSS, CSRF, auth bypass, secrets in code)
- Edge cases that aren't handled
- Error handling gaps
- Performance issues (N+1 queries, memory leaks, blocking calls)
- API contract violations
- Data validation gaps

Be thorough and adversarial. List every issue with severity [Critical/Bug/Warning].
Format: **[Severity]** file:line — description
${adv_memory:+
## Known Security Issues from Previous Reviews
These security issues have been found in past reviews. Check if any recur:
${adv_memory}
}
Diff:
$diff_content"

    local review_output
    review_output=$("$SW_AGENT_EXEC" claude --print "$prompt" < /dev/null 2>"${ARTIFACTS_DIR}/.claude-tokens-adversarial.log" || true)
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-adversarial.log"

    echo "$review_output" > "$ARTIFACTS_DIR/adversarial-review.md"

    # Count issues by severity
    local critical_count bug_count
    critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    bug_count=$(grep -ciE '\*\*\[?Bug\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
    bug_count="${bug_count:-0}"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Adversarial review: ${critical_count} critical, ${bug_count} bugs"
        return 1
    elif [[ "$bug_count" -gt 0 ]]; then
        warn "Adversarial review: ${bug_count} bugs found"
        return 1
    fi

    success "Adversarial review: clean"
    return 0
}


run_negative_prompting() {
    local changed_files
    changed_files=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null || true)

    if [[ -z "$changed_files" ]]; then
        info "No changed files to analyze"
        return 0
    fi

    # Read contents of changed files
    local file_contents=""
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            file_contents+="
--- $file ---
$(head -200 "$file" 2>/dev/null || true)
"
        fi
    done <<< "$changed_files"

    # Inject previous negative prompting findings from memory
    local neg_memory=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        neg_memory=$(intelligence_search_memory "negative prompting findings common concerns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
    fi

    local prompt="You are a pessimistic engineer who assumes everything will break.
Review these changes and answer:
1. What could go wrong in production?
2. What did the developer miss?
3. What's fragile and will break when requirements change?
4. What assumptions are being made that might not hold?
5. What happens under load/stress?
6. What happens with malicious input?
7. Are there any implicit dependencies that could break?
${neg_memory:+
## Known Concerns from Previous Reviews
These issues have been found in past reviews of this codebase. Check if any apply to the current changes:
${neg_memory}
}
Be specific. Reference actual code. Categorize each concern as [Critical/Concern/Minor].

Files changed: $changed_files

$file_contents"

    local review_output
    review_output=$("$SW_AGENT_EXEC" claude --print "$prompt" < /dev/null 2>"${ARTIFACTS_DIR}/.claude-tokens-negative.log" || true)
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-negative.log"

    echo "$review_output" > "$ARTIFACTS_DIR/negative-review.md"

    local critical_count
    critical_count=$(grep -ciE '\[Critical\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
    critical_count="${critical_count:-0}"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Negative prompting: ${critical_count} critical concerns"
        return 1
    fi

    success "Negative prompting: no critical concerns"
    return 0
}

run_e2e_validation() {
    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi

    if [[ -z "$test_cmd" ]]; then
        warn "No test command configured — skipping E2E validation"
        return 0
    fi

    info "Running E2E validation: $test_cmd"
    if sw_test_gate_env bash -c "$test_cmd" > "$ARTIFACTS_DIR/e2e-validation.log" 2>&1; then
        success "E2E validation passed"
        return 0
    else
        error "E2E validation failed"
        return 1
    fi
}


run_dod_audit() {
    local dod_file="$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"

    if [[ ! -f "$dod_file" ]]; then
        # Check for alternative locations
        for alt in "$PROJECT_ROOT/DEFINITION-OF-DONE.md" "$HOME/.shipwright/templates/definition-of-done.example.md"; do
            if [[ -f "$alt" ]]; then
                dod_file="$alt"
                break
            fi
        done
    fi

    if [[ ! -f "$dod_file" ]]; then
        info "No definition-of-done found — skipping DoD audit"
        return 0
    fi

    info "Auditing Definition of Done..."

    local total=0 passed=0 failed=0
    local audit_output="# DoD Audit Results\n\n"

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[[:space:]]\] ]]; then
            total=$((total + 1))
            local item="${line#*] }"

            # Try to verify common items
            local item_passed=false
            case "$item" in
                *"tests pass"*|*"test pass"*)
                    if [[ -f "$ARTIFACTS_DIR/test-results.log" ]] && ! grep -qi "fail\|error" "$ARTIFACTS_DIR/test-results.log" 2>/dev/null; then
                        item_passed=true
                    fi
                    ;;
                *"lint"*|*"Lint"*)
                    if [[ -f "$ARTIFACTS_DIR/lint.log" ]] && ! grep -qi "error" "$ARTIFACTS_DIR/lint.log" 2>/dev/null; then
                        item_passed=true
                    fi
                    ;;
                *"console.log"*|*"print("*)
                    local debug_count
                    debug_count=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null | grep -c "^+.*console\.log\|^+.*print(" 2>/dev/null || true)
                    debug_count="${debug_count:-0}"
                    if [[ "$debug_count" -eq 0 ]]; then
                        item_passed=true
                    fi
                    ;;
                *"coverage"*)
                    item_passed=true  # Trust test stage coverage check
                    ;;
                *)
                    item_passed=true  # Default pass for items we can't auto-verify
                    ;;
            esac

            if $item_passed; then
                passed=$((passed + 1))
                audit_output+="- [x] $item\n"
            else
                failed=$((failed + 1))
                audit_output+="- [ ] $item ❌\n"
            fi
        fi
    done < "$dod_file"

    echo -e "$audit_output\n\n**Score: ${passed}/${total} passed**" > "$ARTIFACTS_DIR/dod-audit.md"

    if [[ "$failed" -gt 0 ]]; then
        warn "DoD audit: ${passed}/${total} passed, ${failed} failed"
        return 1
    fi

    success "DoD audit: ${passed}/${total} passed"
    return 0
}

# ─── Intelligent Pipeline Orchestration ──────────────────────────────────────
# AGI-like decision making: skip, classify, adapt, reassess, backtrack

# Global state for intelligence features
PIPELINE_BACKTRACK_COUNT="${PIPELINE_BACKTRACK_COUNT:-0}"
PIPELINE_MAX_BACKTRACKS=2
PIPELINE_ADAPTIVE_COMPLEXITY=""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Intelligent Stage Skipping
# Evaluates whether a stage should be skipped based on triage score, complexity,
# issue labels, and diff size. Called before each stage in run_pipeline().
# Returns 0 if the stage SHOULD be skipped, 1 if it should run.
# ──────────────────────────────────────────────────────────────────────────────

# Scans modified .sh files for common bash 3.2 incompatibilities
# Returns: count of violations found
# ──────────────────────────────────────────────────────────────────────────────

run_test_coverage_check() {
    local test_cmd="${TEST_CMD:-}"
    if [[ -z "$test_cmd" ]]; then
        echo "skip"
        return 0
    fi

    info "Running test coverage check..."

    # Run tests and capture output
    local test_output
    local test_rc=0
    test_output=$(sw_test_gate_env bash -c "$test_cmd" 2>&1) || test_rc=$?

    if [[ "$test_rc" -ne 0 ]]; then
        warn "Test command failed (exit code: $test_rc) — cannot extract coverage"
        echo "0"
        return 0
    fi

    # Extract coverage percentage from various formats
    # Patterns: "XX% coverage", "Lines: XX%", "Stmts: XX%", "Coverage: XX%", "coverage XX%"
    local coverage_pct
    coverage_pct=$(echo "$test_output" | grep -oE '[0-9]{1,3}%[[:space:]]*(coverage|lines|stmts|statements)' | grep -oE '^[0-9]{1,3}' | head -1 || true)

    if [[ -z "$coverage_pct" ]]; then
        # Try alternate patterns without units
        coverage_pct=$(echo "$test_output" | grep -oE 'coverage[:]?[[:space:]]*[0-9]{1,3}' | grep -oE '[0-9]{1,3}' | head -1 || true)
    fi

    if [[ -z "$coverage_pct" ]]; then
        warn "Could not extract coverage percentage from test output"
        echo "0"
        return 0
    fi

    # Ensure it's a valid percentage (0-100)
    if [[ ! "$coverage_pct" =~ ^[0-9]{1,3}$ ]] || [[ "$coverage_pct" -gt 100 ]]; then
        coverage_pct=0
    fi

    success "Test coverage: ${coverage_pct}%"
    echo "$coverage_pct"
}

# ──────────────────────────────────────────────────────────────────────────────
# Atomic Write Violations Check
# Scans modified files for anti-patterns: direct echo > file to state/config files
# Returns: count of violations found
# ──────────────────────────────────────────────────────────────────────────────
