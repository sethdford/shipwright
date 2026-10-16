# pipeline-intelligence-skip.sh — Intelligence-driven stage skipping and findings classification
# Source from pipeline-intelligence.sh. Requires ARTIFACTS_DIR, ISSUE_LABELS.
[[ -n "${_PIPELINE_INTELLIGENCE_SKIP_LOADED:-}" ]] && return 0
_PIPELINE_INTELLIGENCE_SKIP_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
ISSUE_LABELS="${ISSUE_LABELS:-}"
INTELLIGENCE_COMPLEXITY="${INTELLIGENCE_COMPLEXITY:-5}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# ─── classify_quality_findings ────────────────────────────────────────────
# Analyzes adversarial review and other audit artifacts to classify findings.
# Returns a routing decision (security, performance, architecture, correctness).
# Creates classified-findings.json with breakdown by category.

classify_quality_findings() {
    local adversarial_file="$ARTIFACTS_DIR/adversarial-review.md"
    local security_audit="$ARTIFACTS_DIR/security-audit.log"
    local arch_validation="$ARTIFACTS_DIR/compound-architecture-validation.json"
    local negative_review="$ARTIFACTS_DIR/negative-review.md"

    # Initialize counts
    local security_count=0
    local performance_count=0
    local arch_count=0
    local testing_count=0
    local correctness_count=0
    local style_count=0

    # Parse adversarial review
    if [[ -f "$adversarial_file" ]]; then
        # Count security-related findings
        local sec_tmp=0
        sec_tmp=$(grep -ciE 'security|vulnerability|injection|xss|csrf|auth|crypt' "$adversarial_file" 2>/dev/null) || sec_tmp=0
        security_count=$((security_count + sec_tmp))

        # Count performance findings
        local perf_tmp=0
        perf_tmp=$(grep -ciE 'performance|bottleneck|n\+1|memory|leak|slow|timeout|hang' "$adversarial_file" 2>/dev/null) || perf_tmp=0
        performance_count=$((performance_count + perf_tmp))

        # Count architecture findings
        local arch_tmp=0
        arch_tmp=$(grep -ciE 'architecture|circular|dependency|coupling|layer|module|violation' "$adversarial_file" 2>/dev/null) || arch_tmp=0
        arch_count=$((arch_count + arch_tmp))

        # Count testing findings
        local testing_tmp=0
        testing_tmp=$(grep -ciE 'test|coverage|flaky|mock|assertion|stub' "$adversarial_file" 2>/dev/null) || testing_tmp=0
        testing_count=$((testing_count + testing_tmp))

        # Count correctness findings
        local correct_tmp=0
        correct_tmp=$(grep -ciE 'bug|logic|error|broken|fail' "$adversarial_file" 2>/dev/null) || correct_tmp=0
        correctness_count=$((correctness_count + correct_tmp))

        # Count style findings
        local style_tmp=0
        style_tmp=$(grep -ciE 'style|convention|naming|format|whitespace|comment' "$adversarial_file" 2>/dev/null) || style_tmp=0
        style_count=$((style_count + style_tmp))
    fi

    # Parse security audit if present
    if [[ -f "$security_audit" ]]; then
        local sec_audit_findings=0
        sec_audit_findings=$(grep -ciE 'critical|high|vulnerability' "$security_audit" 2>/dev/null) || sec_audit_findings=0
        security_count=$((security_count + sec_audit_findings))
    fi

    # Parse architecture validation JSON if present
    if [[ -f "$arch_validation" ]]; then
        local arch_json_count=0
        arch_json_count=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' "$arch_validation" 2>/dev/null) || arch_json_count=0
        arch_count=$((arch_count + arch_json_count))
    fi

    # Parse negative review
    if [[ -f "$negative_review" ]]; then
        local neg_critical=0
        neg_critical=$(grep -ciE '\[Critical\]' "$negative_review" 2>/dev/null) || neg_critical=0
        correctness_count=$((correctness_count + neg_critical))

        local neg_security=0
        neg_security=$(grep -ciE 'security|vulnerability' "$negative_review" 2>/dev/null) || neg_security=0
        security_count=$((security_count + neg_security))
    fi

    # Create classified findings JSON (safely, handling jq failure)
    local tmp_findings
    tmp_findings=$(mktemp)
    {
        echo "{"
        echo "  \"security\": $security_count,"
        echo "  \"performance\": $performance_count,"
        echo "  \"architecture\": $arch_count,"
        echo "  \"testing\": $testing_count,"
        echo "  \"correctness\": $correctness_count,"
        echo "  \"style\": $style_count"
        echo "}"
    } > "$tmp_findings"
    mv "$tmp_findings" "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || rm -f "$tmp_findings"

    # Determine routing based on severity
    if [[ "$security_count" -gt 0 ]]; then
        echo "security"
    elif [[ "$performance_count" -gt 0 ]]; then
        echo "performance"
    elif [[ "$arch_count" -gt 0 ]]; then
        echo "architecture"
    elif [[ "$testing_count" -gt 0 ]]; then
        echo "testing"
    elif [[ "$correctness_count" -gt 0 ]]; then
        echo "correctness"
    else
        echo "correctness"
    fi
}

# ─── pipeline_should_skip_stage ────────────────────────────────────────
# Determines if a pipeline stage should be skipped based on:
# - Issue labels (documentation, hotfix, etc.)
# - Complexity assessment
# - Reassessment overrides

pipeline_should_skip_stage() {
    local stage="$1"

    # Check for skip overrides in reassessment
    local reassessment_file="$ARTIFACTS_DIR/reassessment.json"
    if [[ -f "$reassessment_file" ]]; then
        # Validate JSON before parsing to prevent jq errors
        if ! jq empty "$reassessment_file" 2>/dev/null; then
            # File exists but is not valid JSON — skip it
            return 1
        fi
        local skip_stages
        skip_stages=$(jq -r '.skip_stages[]?' "$reassessment_file" 2>/dev/null) || true
        while IFS= read -r skip_stage; do
            [[ -z "$skip_stage" ]] && continue
            [[ "$skip_stage" == "$stage" ]] && echo "reassessment" && return 0
        done <<< "$skip_stages"
    fi

    # Check labels for skip signals
    case "$stage" in
        compound_quality)
            if echo "$ISSUE_LABELS" | grep >/dev/null -iE 'documentation|typo|docs'; then
                echo "label:documentation"
                return 0
            fi
            if echo "$ISSUE_LABELS" | grep >/dev/null -iE 'hotfix|urgent'; then
                echo "label:hotfix"
                return 0
            fi
            ;;
        design)
            # Low complexity skips design
            if [[ "${INTELLIGENCE_COMPLEXITY:-5}" -lt 3 ]]; then
                echo "complexity"
                return 0
            fi
            ;;
        review)
            # Documentation labels skip review
            if echo "$ISSUE_LABELS" | grep >/dev/null -iE 'docs?|documentation'; then
                echo "label"
                return 0
            fi
            ;;
        plan)
            # Hotfix labels skip plan
            if echo "$ISSUE_LABELS" | grep >/dev/null -iE 'hotfix|p0|urgent'; then
                echo "label:hotfix"
                return 0
            fi
            ;;
    esac

    return 1
}
