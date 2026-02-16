# pipeline-intelligence.sh — Skip/adaptive/audits/DoD/security/compound_quality for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires pipeline-quality-checks, state, ARTIFACTS_DIR, PIPELINE_CONFIG.
[[ -n "${_PIPELINE_INTELLIGENCE_LOADED:-}" ]] && return 0
_PIPELINE_INTELLIGENCE_LOADED=1

pipeline_should_skip_stage() {
    local stage_id="$1"
    local reason=""

    # Never skip intake or build — they're always required
    case "$stage_id" in
        intake|build|test|pr|merge) return 1 ;;
    esac

    # ── Signal 1: Triage score (from intelligence analysis) ──
    local triage_score="${INTELLIGENCE_COMPLEXITY:-0}"
    # Convert: high triage score (simple issue) means skip more stages
    # INTELLIGENCE_COMPLEXITY is 1-10 (1=simple, 10=complex)
    # Score >= 70 in daemon means simple → complexity 1-3
    local complexity="${INTELLIGENCE_COMPLEXITY:-5}"

    # ── Signal 2: Issue labels ──
    local labels="${ISSUE_LABELS:-}"

    # Documentation issues: skip test, review, compound_quality
    if echo ",$labels," | grep -qiE ',documentation,|,docs,|,typo,'; then
        case "$stage_id" in
            test|review|compound_quality)
                reason="label:documentation"
                ;;
        esac
    fi

    # Hotfix issues: skip plan, design, compound_quality
    if echo ",$labels," | grep -qiE ',hotfix,|,urgent,|,p0,'; then
        case "$stage_id" in
            plan|design|compound_quality)
                reason="label:hotfix"
                ;;
        esac
    fi

    # ── Signal 3: Intelligence complexity ──
    if [[ -z "$reason" && "$complexity" -gt 0 ]]; then
        # Complexity 1-2: very simple → skip design, compound_quality, review
        if [[ "$complexity" -le 2 ]]; then
            case "$stage_id" in
                design|compound_quality|review)
                    reason="complexity:${complexity}/10"
                    ;;
            esac
        # Complexity 1-3: simple → skip design
        elif [[ "$complexity" -le 3 ]]; then
            case "$stage_id" in
                design)
                    reason="complexity:${complexity}/10"
                    ;;
            esac
        fi
    fi

    # ── Signal 4: Diff size (after build) ──
    if [[ -z "$reason" && "$stage_id" == "compound_quality" ]]; then
        local diff_lines=0
        local _skip_stat
        _skip_stat=$(git diff "${BASE_BRANCH:-main}...HEAD" --stat 2>/dev/null | tail -1) || true
        if [[ -n "${_skip_stat:-}" ]]; then
            local _s_ins _s_del
            _s_ins=$(echo "$_skip_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
            _s_del=$(echo "$_skip_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
            diff_lines=$(( ${_s_ins:-0} + ${_s_del:-0} ))
        fi
        diff_lines="${diff_lines:-0}"
        if [[ "$diff_lines" -gt 0 && "$diff_lines" -lt 20 ]]; then
            reason="diff_size:${diff_lines}_lines"
        fi
    fi

    # ── Signal 5: Mid-pipeline reassessment override ──
    if [[ -z "$reason" && -f "$ARTIFACTS_DIR/reassessment.json" ]]; then
        local skip_stages
        skip_stages=$(jq -r '.skip_stages // [] | .[]' "$ARTIFACTS_DIR/reassessment.json" 2>/dev/null || true)
        if echo "$skip_stages" | grep -qx "$stage_id" 2>/dev/null; then
            reason="reassessment:simpler_than_expected"
        fi
    fi

    if [[ -n "$reason" ]]; then
        emit_event "intelligence.stage_skipped" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "reason=$reason" \
            "complexity=${complexity}" \
            "labels=${labels}"
        echo "$reason"
        return 0
    fi

    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Smart Finding Classification & Routing
# Parses compound quality findings and classifies each as:
#   architecture, security, correctness, style
# Returns JSON with classified findings and routing recommendations.
# ──────────────────────────────────────────────────────────────────────────────
classify_quality_findings() {
    local findings_dir="$ARTIFACTS_DIR"
    local result_file="$ARTIFACTS_DIR/classified-findings.json"

    # Initialize counters
    local arch_count=0 security_count=0 correctness_count=0 performance_count=0 testing_count=0 style_count=0

    # Start building JSON array
    local findings_json="[]"

    # ── Parse adversarial review ──
    if [[ -f "$findings_dir/adversarial-review.md" ]]; then
        local adv_content
        adv_content=$(cat "$findings_dir/adversarial-review.md" 2>/dev/null || true)

        # Architecture findings: dependency violations, layer breaches, circular refs
        local arch_findings
        arch_findings=$(echo "$adv_content" | grep -ciE 'architect|layer.*violation|circular.*depend|coupling|abstraction|design.*flaw|separation.*concern' 2>/dev/null || true)
        arch_count=$((arch_count + ${arch_findings:-0}))

        # Security findings
        local sec_findings
        sec_findings=$(echo "$adv_content" | grep -ciE 'security|vulnerab|injection|XSS|CSRF|auth.*bypass|privilege|sanitiz|escap' 2>/dev/null || true)
        security_count=$((security_count + ${sec_findings:-0}))

        # Correctness findings: bugs, logic errors, edge cases
        local corr_findings
        corr_findings=$(echo "$adv_content" | grep -ciE '\*\*\[?(Critical|Bug|Error|critical|high)\]?\*\*|race.*condition|null.*pointer|off.*by.*one|edge.*case|undefined.*behav' 2>/dev/null || true)
        correctness_count=$((correctness_count + ${corr_findings:-0}))

        # Performance findings
        local perf_findings
        perf_findings=$(echo "$adv_content" | grep -ciE 'latency|slow|memory leak|O\(n|N\+1|cache miss|performance|bottleneck|throughput' 2>/dev/null || true)
        performance_count=$((performance_count + ${perf_findings:-0}))

        # Testing findings
        local test_findings
        test_findings=$(echo "$adv_content" | grep -ciE 'untested|missing test|no coverage|flaky|test gap|test missing|coverage gap' 2>/dev/null || true)
        testing_count=$((testing_count + ${test_findings:-0}))

        # Style findings
        local style_findings
        style_findings=$(echo "$adv_content" | grep -ciE 'naming|convention|format|style|readabil|inconsisten|whitespace|comment' 2>/dev/null || true)
        style_count=$((style_count + ${style_findings:-0}))
    fi

    # ── Parse architecture validation ──
    if [[ -f "$findings_dir/compound-architecture-validation.json" ]]; then
        local arch_json_count
        arch_json_count=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' "$findings_dir/compound-architecture-validation.json" 2>/dev/null || echo "0")
        arch_count=$((arch_count + ${arch_json_count:-0}))
    fi

    # ── Parse security audit ──
    if [[ -f "$findings_dir/security-audit.log" ]]; then
        local sec_audit
        sec_audit=$(grep -ciE 'critical|high' "$findings_dir/security-audit.log" 2>/dev/null || true)
        security_count=$((security_count + ${sec_audit:-0}))
    fi

    # ── Parse negative review ──
    if [[ -f "$findings_dir/negative-review.md" ]]; then
        local neg_corr
        neg_corr=$(grep -ciE '\[Critical\]|\[High\]' "$findings_dir/negative-review.md" 2>/dev/null || true)
        correctness_count=$((correctness_count + ${neg_corr:-0}))
    fi

    # ── Determine routing ──
    # Priority order: security > architecture > correctness > performance > testing > style
    local route="correctness"  # default
    local needs_backtrack=false
    local priority_findings=""

    if [[ "$security_count" -gt 0 ]]; then
        route="security"
        priority_findings="security:${security_count}"
    fi

    if [[ "$arch_count" -gt 0 ]]; then
        if [[ "$route" == "correctness" ]]; then
            route="architecture"
            needs_backtrack=true
        fi
        priority_findings="${priority_findings:+${priority_findings},}architecture:${arch_count}"
    fi

    if [[ "$correctness_count" -gt 0 ]]; then
        priority_findings="${priority_findings:+${priority_findings},}correctness:${correctness_count}"
    fi

    if [[ "$performance_count" -gt 0 ]]; then
        if [[ "$route" == "correctness" && "$correctness_count" -eq 0 ]]; then
            route="performance"
        fi
        priority_findings="${priority_findings:+${priority_findings},}performance:${performance_count}"
    fi

    if [[ "$testing_count" -gt 0 ]]; then
        if [[ "$route" == "correctness" && "$correctness_count" -eq 0 && "$performance_count" -eq 0 ]]; then
            route="testing"
        fi
        priority_findings="${priority_findings:+${priority_findings},}testing:${testing_count}"
    fi

    # Style findings don't affect routing or count toward failure threshold
    local total_blocking=$((arch_count + security_count + correctness_count + performance_count + testing_count))

    # Write classified findings
    local tmp_findings
    tmp_findings="$(mktemp)"
    jq -n \
        --argjson arch "$arch_count" \
        --argjson security "$security_count" \
        --argjson correctness "$correctness_count" \
        --argjson performance "$performance_count" \
        --argjson testing "$testing_count" \
        --argjson style "$style_count" \
        --argjson total_blocking "$total_blocking" \
        --arg route "$route" \
        --argjson needs_backtrack "$needs_backtrack" \
        --arg priority "$priority_findings" \
        '{
            architecture: $arch,
            security: $security,
            correctness: $correctness,
            performance: $performance,
            testing: $testing,
            style: $style,
            total_blocking: $total_blocking,
            route: $route,
            needs_backtrack: $needs_backtrack,
            priority_findings: $priority
        }' > "$tmp_findings" 2>/dev/null && mv "$tmp_findings" "$result_file" || rm -f "$tmp_findings"

    emit_event "intelligence.findings_classified" \
        "issue=${ISSUE_NUMBER:-0}" \
        "architecture=$arch_count" \
        "security=$security_count" \
        "correctness=$correctness_count" \
        "performance=$performance_count" \
        "testing=$testing_count" \
        "style=$style_count" \
        "route=$route" \
        "needs_backtrack=$needs_backtrack"

    echo "$route"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Adaptive Cycle Limits
# Replaces hardcoded max_cycles with convergence-driven limits.
# Takes the base limit, returns an adjusted limit based on:
#   - Learned iteration model
#   - Convergence/divergence signals
#   - Budget constraints
#   - Hard ceiling (2x template max)
# ──────────────────────────────────────────────────────────────────────────────
pipeline_adaptive_cycles() {
    local base_limit="$1"
    local context="${2:-compound_quality}"  # compound_quality or build_test
    local current_issue_count="${3:-0}"
    local prev_issue_count="${4:--1}"

    local adjusted="$base_limit"
    local hard_ceiling=$((base_limit * 2))

    # ── Learned iteration model ──
    local model_file="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$model_file" ]]; then
        local learned
        learned=$(jq -r --arg ctx "$context" '.[$ctx].recommended_cycles // 0' "$model_file" 2>/dev/null || echo "0")
        if [[ "$learned" -gt 0 && "$learned" -le "$hard_ceiling" ]]; then
            adjusted="$learned"
        fi
    fi

    # ── Convergence acceleration ──
    # If issue count drops >50% per cycle, extend limit by 1 (we're making progress)
    if [[ "$prev_issue_count" -gt 0 && "$current_issue_count" -ge 0 ]]; then
        local half_prev=$((prev_issue_count / 2))
        if [[ "$current_issue_count" -le "$half_prev" && "$current_issue_count" -gt 0 ]]; then
            # Rapid convergence — extend by 1
            local new_limit=$((adjusted + 1))
            if [[ "$new_limit" -le "$hard_ceiling" ]]; then
                adjusted="$new_limit"
                emit_event "intelligence.convergence_acceleration" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi

        # ── Divergence detection ──
        # If issue count increases, reduce remaining cycles
        if [[ "$current_issue_count" -gt "$prev_issue_count" ]]; then
            local reduced=$((adjusted - 1))
            if [[ "$reduced" -ge 1 ]]; then
                adjusted="$reduced"
                emit_event "intelligence.divergence_detected" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi
    fi

    # ── Budget gate ──
    if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
        local budget_rc=0
        bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
        if [[ "$budget_rc" -eq 2 ]]; then
            # Budget exhausted — cap at current cycle
            adjusted=0
            emit_event "intelligence.budget_cap" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=$context"
        fi
    fi

    # ── Enforce hard ceiling ──
    if [[ "$adjusted" -gt "$hard_ceiling" ]]; then
        adjusted="$hard_ceiling"
    fi

    echo "$adjusted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Intelligent Audit Selection
# AI-driven audit selection — all audits enabled, intensity varies.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_select_audits() {
    local audit_intensity
    audit_intensity=$(jq -r --arg id "compound_quality" \
        '(.stages[] | select(.id == $id) | .config.audit_intensity) // "auto"' \
        "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$audit_intensity" || "$audit_intensity" == "null" ]] && audit_intensity="auto"

    # Short-circuit for explicit overrides
    case "$audit_intensity" in
        off)
            echo '{"adversarial":"off","architecture":"off","simulation":"off","security":"off","dod":"off"}'
            return 0
            ;;
        full|lightweight)
            jq -n --arg i "$audit_intensity" \
                '{adversarial:$i,architecture:$i,simulation:$i,security:$i,dod:$i}'
            return 0
            ;;
    esac

    # ── Auto mode: data-driven intensity ──
    local default_intensity="targeted"
    local security_intensity="targeted"

    # Read last 5 quality scores for this repo
    local quality_scores_file="${HOME}/.shipwright/optimization/quality-scores.jsonl"
    local repo_name
    repo_name=$(basename "${PROJECT_ROOT:-.}") || true
    if [[ -f "$quality_scores_file" ]]; then
        local recent_scores
        recent_scores=$(grep "\"repo\":\"${repo_name}\"" "$quality_scores_file" 2>/dev/null | tail -5) || true
        if [[ -n "$recent_scores" ]]; then
            # Check for critical findings in recent history
            local has_critical
            has_critical=$(echo "$recent_scores" | jq -s '[.[].findings.critical // 0] | add' 2>/dev/null || echo "0")
            has_critical="${has_critical:-0}"
            if [[ "$has_critical" -gt 0 ]]; then
                security_intensity="full"
            fi

            # Compute average quality score
            local avg_score
            avg_score=$(echo "$recent_scores" | jq -s 'if length > 0 then ([.[].quality_score] | add / length | floor) else 70 end' 2>/dev/null || echo "70")
            avg_score="${avg_score:-70}"

            if [[ "$avg_score" -lt 60 ]]; then
                default_intensity="full"
                security_intensity="full"
            elif [[ "$avg_score" -gt 80 ]]; then
                default_intensity="lightweight"
                [[ "$security_intensity" != "full" ]] && security_intensity="lightweight"
            fi
        fi
    fi

    # Intelligence cache: upgrade targeted→full for complex changes
    local intel_cache="${PROJECT_ROOT}/.claude/intelligence-cache.json"
    if [[ -f "$intel_cache" && "$default_intensity" == "targeted" ]]; then
        local complexity
        complexity=$(jq -r '.complexity // "medium"' "$intel_cache" 2>/dev/null || echo "medium")
        if [[ "$complexity" == "high" || "$complexity" == "very_high" ]]; then
            default_intensity="full"
            security_intensity="full"
        fi
    fi

    emit_event "pipeline.audit_selection" \
        "issue=${ISSUE_NUMBER:-0}" \
        "default_intensity=$default_intensity" \
        "security_intensity=$security_intensity" \
        "repo=$repo_name"

    jq -n \
        --arg adv "$default_intensity" \
        --arg arch "$default_intensity" \
        --arg sim "$default_intensity" \
        --arg sec "$security_intensity" \
        --arg dod "$default_intensity" \
        '{adversarial:$adv,architecture:$arch,simulation:$sim,security:$sec,dod:$dod}'
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Definition of Done Verification
# Strict DoD enforcement after compound quality completes.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_verify_dod() {
    local artifacts_dir="${1:-$ARTIFACTS_DIR}"
    local checks_total=0 checks_passed=0
    local results=""

    # 1. Test coverage: verify changed source files have test counterparts
    local changed_files
    changed_files=$(git diff --name-only "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
    local missing_tests=""
    local files_checked=0

    if [[ -n "$changed_files" ]]; then
        while IFS= read -r src_file; do
            [[ -z "$src_file" ]] && continue
            # Only check source code files
            case "$src_file" in
                *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.sh)
                    # Skip test files themselves and config files
                    case "$src_file" in
                        *test*|*spec*|*__tests__*|*.config.*|*.d.ts) continue ;;
                    esac
                    files_checked=$((files_checked + 1))
                    checks_total=$((checks_total + 1))
                    # Check for corresponding test file
                    local base_name dir_name ext
                    base_name=$(basename "$src_file")
                    dir_name=$(dirname "$src_file")
                    ext="${base_name##*.}"
                    local stem="${base_name%.*}"
                    local test_found=false
                    # Common test file patterns
                    for pattern in \
                        "${dir_name}/${stem}.test.${ext}" \
                        "${dir_name}/${stem}.spec.${ext}" \
                        "${dir_name}/__tests__/${stem}.test.${ext}" \
                        "${dir_name}/${stem}-test.${ext}" \
                        "${dir_name}/test_${stem}.${ext}" \
                        "${dir_name}/${stem}_test.${ext}"; do
                        if [[ -f "$pattern" ]]; then
                            test_found=true
                            break
                        fi
                    done
                    if $test_found; then
                        checks_passed=$((checks_passed + 1))
                    else
                        missing_tests="${missing_tests}${src_file}\n"
                    fi
                    ;;
            esac
        done <<EOF
$changed_files
EOF
    fi

    # 2. Test-added verification: if significant logic added, ensure tests were also added
    local logic_lines=0 test_lines=0
    if [[ -n "$changed_files" ]]; then
        local full_diff
        full_diff=$(git diff "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
        if [[ -n "$full_diff" ]]; then
            # Count added lines matching source patterns (rough heuristic)
            logic_lines=$(echo "$full_diff" | grep -cE '^\+.*(function |class |if |for |while |return |export )' 2>/dev/null || true)
            logic_lines="${logic_lines:-0}"
            # Count added lines in test files
            test_lines=$(echo "$full_diff" | grep -cE '^\+.*(it\(|test\(|describe\(|expect\(|assert|def test_|func Test)' 2>/dev/null || true)
            test_lines="${test_lines:-0}"
        fi
    fi
    checks_total=$((checks_total + 1))
    local test_ratio_passed=true
    if [[ "$logic_lines" -gt 20 && "$test_lines" -eq 0 ]]; then
        test_ratio_passed=false
        warn "DoD verification: ${logic_lines} logic lines added but no test lines detected"
    else
        checks_passed=$((checks_passed + 1))
    fi

    # 3. Behavioral verification: check DoD audit artifacts for evidence
    local dod_audit_file="$artifacts_dir/dod-audit.md"
    local dod_verified=0 dod_total_items=0
    if [[ -f "$dod_audit_file" ]]; then
        # Count items marked as passing
        dod_total_items=$(grep -cE '^\s*-\s*\[x\]' "$dod_audit_file" 2>/dev/null || true)
        dod_total_items="${dod_total_items:-0}"
        local dod_failing
        dod_failing=$(grep -cE '^\s*-\s*\[\s\]' "$dod_audit_file" 2>/dev/null || true)
        dod_failing="${dod_failing:-0}"
        dod_verified=$dod_total_items
        checks_total=$((checks_total + dod_total_items + ${dod_failing:-0}))
        checks_passed=$((checks_passed + dod_total_items))
    fi

    # Compute pass rate
    local pass_rate=100
    if [[ "$checks_total" -gt 0 ]]; then
        pass_rate=$(( (checks_passed * 100) / checks_total ))
    fi

    # Write results
    local tmp_result
    tmp_result=$(mktemp)
    jq -n \
        --argjson checks_total "$checks_total" \
        --argjson checks_passed "$checks_passed" \
        --argjson pass_rate "$pass_rate" \
        --argjson files_checked "$files_checked" \
        --arg missing_tests "$(echo -e "$missing_tests" | head -20)" \
        --argjson logic_lines "$logic_lines" \
        --argjson test_lines "$test_lines" \
        --argjson test_ratio_passed "$test_ratio_passed" \
        --argjson dod_verified "$dod_verified" \
        '{
            checks_total: $checks_total,
            checks_passed: $checks_passed,
            pass_rate: $pass_rate,
            files_checked: $files_checked,
            missing_tests: ($missing_tests | split("\n") | map(select(. != ""))),
            logic_lines: $logic_lines,
            test_lines: $test_lines,
            test_ratio_passed: $test_ratio_passed,
            dod_verified: $dod_verified
        }' > "$tmp_result" 2>/dev/null
    mv "$tmp_result" "$artifacts_dir/dod-verification.json"

    emit_event "pipeline.dod_verification" \
        "issue=${ISSUE_NUMBER:-0}" \
        "checks_total=$checks_total" \
        "checks_passed=$checks_passed" \
        "pass_rate=$pass_rate"

    # Fail if pass rate < 70%
    if [[ "$pass_rate" -lt 70 ]]; then
        warn "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
        return 1
    fi

    success "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Source Code Security Scan
# Grep-based vulnerability pattern matching on changed files.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_security_source_scan() {
    local base_branch="${1:-${BASE_BRANCH:-main}}"
    local findings="[]"
    local finding_count=0

    local changed_files
    changed_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || true)
    [[ -z "$changed_files" ]] && { echo "[]"; return 0; }

    local tmp_findings
    tmp_findings=$(mktemp)
    echo "[]" > "$tmp_findings"

    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue
        # Only scan code files
        case "$file" in
            *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.java|*.rb|*.php|*.sh) ;;
            *) continue ;;
        esac

        # SQL injection patterns
        local sql_matches
        sql_matches=$(grep -nE '(query|execute|sql)\s*\(?\s*[`"'"'"']\s*.*\$\{|\.query\s*\(\s*[`"'"'"'].*\+' "$file" 2>/dev/null || true)
        if [[ -n "$sql_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "sql_injection" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential SQL injection via string concatenation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SQLEOF
$sql_matches
SQLEOF
        fi

        # XSS patterns
        local xss_matches
        xss_matches=$(grep -nE 'innerHTML\s*=|document\.write\s*\(|dangerouslySetInnerHTML' "$file" 2>/dev/null || true)
        if [[ -n "$xss_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "xss" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential XSS via unsafe DOM manipulation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<XSSEOF
$xss_matches
XSSEOF
        fi

        # Command injection patterns
        local cmd_matches
        cmd_matches=$(grep -nE 'eval\s*\(|child_process|os\.system\s*\(|subprocess\.(call|run|Popen)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$cmd_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "command_injection" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential command injection via unsafe execution"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CMDEOF
$cmd_matches
CMDEOF
        fi

        # Hardcoded secrets patterns
        local secret_matches
        secret_matches=$(grep -nEi '(password|api_key|secret|token)\s*=\s*['"'"'"][A-Za-z0-9+/=]{8,}['"'"'"]' "$file" 2>/dev/null || true)
        if [[ -n "$secret_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "hardcoded_secret" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential hardcoded secret or credential"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SECEOF
$secret_matches
SECEOF
        fi

        # Insecure crypto patterns
        local crypto_matches
        crypto_matches=$(grep -nE '(md5|MD5|sha1|SHA1)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$crypto_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "insecure_crypto" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"major","description":"Weak cryptographic function (consider SHA-256+)"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CRYEOF
$crypto_matches
CRYEOF
        fi
    done <<FILESEOF
$changed_files
FILESEOF

    # Write to artifacts and output
    findings=$(cat "$tmp_findings")
    rm -f "$tmp_findings"

    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        local tmp_scan
        tmp_scan=$(mktemp)
        echo "$findings" > "$tmp_scan"
        mv "$tmp_scan" "$ARTIFACTS_DIR/security-source-scan.json"
    fi

    emit_event "pipeline.security_source_scan" \
        "issue=${ISSUE_NUMBER:-0}" \
        "findings=$finding_count"

    echo "$finding_count"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Quality Score Recording
# Writes quality scores to JSONL for learning.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_record_quality_score() {
    local quality_score="${1:-0}"
    local critical="${2:-0}"
    local major="${3:-0}"
    local minor="${4:-0}"
    local dod_pass_rate="${5:-0}"
    local audits_run="${6:-}"

    local scores_dir="${HOME}/.shipwright/optimization"
    local scores_file="${scores_dir}/quality-scores.jsonl"
    mkdir -p "$scores_dir"

    local repo_name
    repo_name=$(basename "${PROJECT_ROOT:-.}") || true

    local tmp_score
    tmp_score=$(mktemp)
    jq -n \
        --arg repo "$repo_name" \
        --arg issue "${ISSUE_NUMBER:-0}" \
        --arg ts "$(now_iso)" \
        --argjson score "$quality_score" \
        --argjson critical "$critical" \
        --argjson major "$major" \
        --argjson minor "$minor" \
        --argjson dod "$dod_pass_rate" \
        --arg template "${PIPELINE_NAME:-standard}" \
        --arg audits "$audits_run" \
        '{
            repo: $repo,
            issue: ($issue | tonumber),
            timestamp: $ts,
            quality_score: $score,
            findings: {critical: $critical, major: $major, minor: $minor},
            dod_pass_rate: $dod,
            template: $template,
            audits_run: ($audits | split(",") | map(select(. != "")))
        }' > "$tmp_score" 2>/dev/null

    cat "$tmp_score" >> "$scores_file"
    rm -f "$tmp_score"

    # Rotate quality scores file to prevent unbounded growth
    type rotate_jsonl &>/dev/null 2>&1 && rotate_jsonl "$scores_file" 5000

    emit_event "pipeline.quality_score_recorded" \
        "issue=${ISSUE_NUMBER:-0}" \
        "quality_score=$quality_score" \
        "critical=$critical" \
        "major=$major" \
        "minor=$minor"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Mid-Pipeline Complexity Re-evaluation
# After build+test completes, compares actual effort to initial estimate.
# Updates skip recommendations and model routing for remaining stages.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_reassess_complexity() {
    local initial_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
    local reassessment_file="$ARTIFACTS_DIR/reassessment.json"

    # ── Gather actual metrics ──
    local files_changed=0 lines_changed=0 first_try_pass=false self_heal_cycles=0

    files_changed=$(git diff "${BASE_BRANCH:-main}...HEAD" --name-only 2>/dev/null | wc -l | tr -d ' ') || files_changed=0
    files_changed="${files_changed:-0}"

    # Count lines changed (insertions + deletions) without pipefail issues
    lines_changed=0
    local _diff_stat
    _diff_stat=$(git diff "${BASE_BRANCH:-main}...HEAD" --stat 2>/dev/null | tail -1) || true
    if [[ -n "${_diff_stat:-}" ]]; then
        local _ins _del
        _ins=$(echo "$_diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
        _del=$(echo "$_diff_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
        lines_changed=$(( ${_ins:-0} + ${_del:-0} ))
    fi

    self_heal_cycles="${SELF_HEAL_COUNT:-0}"
    if [[ "$self_heal_cycles" -eq 0 ]]; then
        first_try_pass=true
    fi

    # ── Compare to expectations ──
    local actual_complexity="$initial_complexity"
    local assessment="as_expected"
    local skip_stages="[]"

    # Simpler than expected: small diff, tests passed first try
    if [[ "$lines_changed" -lt 50 && "$first_try_pass" == "true" && "$files_changed" -lt 5 ]]; then
        actual_complexity=$((initial_complexity > 2 ? initial_complexity - 2 : 1))
        assessment="simpler_than_expected"
        # Mark compound_quality as skippable, simplify review
        skip_stages='["compound_quality"]'
    # Much simpler
    elif [[ "$lines_changed" -lt 20 && "$first_try_pass" == "true" && "$files_changed" -lt 3 ]]; then
        actual_complexity=1
        assessment="much_simpler"
        skip_stages='["compound_quality","review"]'
    # Harder than expected: large diff, multiple self-heal cycles
    elif [[ "$lines_changed" -gt 500 || "$self_heal_cycles" -gt 2 ]]; then
        actual_complexity=$((initial_complexity < 9 ? initial_complexity + 2 : 10))
        assessment="harder_than_expected"
        # Ensure compound_quality runs, possibly upgrade model
        skip_stages='[]'
    # Much harder
    elif [[ "$lines_changed" -gt 1000 || "$self_heal_cycles" -gt 4 ]]; then
        actual_complexity=10
        assessment="much_harder"
        skip_stages='[]'
    fi

    # ── Write reassessment ──
    local tmp_reassess
    tmp_reassess="$(mktemp)"
    jq -n \
        --argjson initial "$initial_complexity" \
        --argjson actual "$actual_complexity" \
        --arg assessment "$assessment" \
        --argjson files_changed "$files_changed" \
        --argjson lines_changed "$lines_changed" \
        --argjson self_heal_cycles "$self_heal_cycles" \
        --argjson first_try "$first_try_pass" \
        --argjson skip_stages "$skip_stages" \
        '{
            initial_complexity: $initial,
            actual_complexity: $actual,
            assessment: $assessment,
            files_changed: $files_changed,
            lines_changed: $lines_changed,
            self_heal_cycles: $self_heal_cycles,
            first_try_pass: $first_try,
            skip_stages: $skip_stages
        }' > "$tmp_reassess" 2>/dev/null && mv "$tmp_reassess" "$reassessment_file" || rm -f "$tmp_reassess"

    # Update global complexity for downstream stages
    PIPELINE_ADAPTIVE_COMPLEXITY="$actual_complexity"

    emit_event "intelligence.reassessment" \
        "issue=${ISSUE_NUMBER:-0}" \
        "initial=$initial_complexity" \
        "actual=$actual_complexity" \
        "assessment=$assessment" \
        "files=$files_changed" \
        "lines=$lines_changed" \
        "self_heals=$self_heal_cycles"

    # ── Store for learning ──
    local learning_file="${HOME}/.shipwright/optimization/complexity-actuals.jsonl"
    mkdir -p "${HOME}/.shipwright/optimization" 2>/dev/null || true
    echo "{\"issue\":\"${ISSUE_NUMBER:-0}\",\"initial\":$initial_complexity,\"actual\":$actual_complexity,\"files\":$files_changed,\"lines\":$lines_changed,\"ts\":\"$(now_iso)\"}" \
        >> "$learning_file" 2>/dev/null || true

    echo "$assessment"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Backtracking Support
# When compound_quality detects architecture-level problems, backtracks to
# the design stage instead of just feeding findings to the build loop.
# Limited to 1 backtrack per pipeline run to prevent infinite loops.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_backtrack_to_stage() {
    local target_stage="$1"
    local reason="${2:-architecture_violation}"

    # Prevent infinite backtracking
    if [[ "$PIPELINE_BACKTRACK_COUNT" -ge "$PIPELINE_MAX_BACKTRACKS" ]]; then
        warn "Max backtracks ($PIPELINE_MAX_BACKTRACKS) reached — cannot backtrack to $target_stage"
        emit_event "intelligence.backtrack_blocked" \
            "issue=${ISSUE_NUMBER:-0}" \
            "target=$target_stage" \
            "reason=max_backtracks_reached" \
            "count=$PIPELINE_BACKTRACK_COUNT"
        return 1
    fi

    PIPELINE_BACKTRACK_COUNT=$((PIPELINE_BACKTRACK_COUNT + 1))

    info "Backtracking to ${BOLD}${target_stage}${RESET} stage (reason: ${reason})"

    emit_event "intelligence.backtrack" \
        "issue=${ISSUE_NUMBER:-0}" \
        "target=$target_stage" \
        "reason=$reason"

    # Gather architecture context from findings
    local arch_context=""
    if [[ -f "$ARTIFACTS_DIR/compound-architecture-validation.json" ]]; then
        arch_context=$(jq -r '[.[] | select(.severity == "critical" or .severity == "high") | .message // .description // ""] | join("\n")' \
            "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || true)
    fi
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
        local arch_lines
        arch_lines=$(grep -iE 'architect|layer.*violation|circular.*depend|coupling|design.*flaw' \
            "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
        if [[ -n "$arch_lines" ]]; then
            arch_context="${arch_context}
${arch_lines}"
        fi
    fi

    # Reset stages from target onward
    set_stage_status "$target_stage" "pending"
    set_stage_status "build" "pending"
    set_stage_status "test" "pending"

    # Augment goal with architecture context for re-run
    local original_goal="$GOAL"
    if [[ -n "$arch_context" ]]; then
        GOAL="$GOAL

IMPORTANT — Architecture violations were detected during quality review. Redesign to fix:
$arch_context

Update the design to address these violations, then rebuild."
    fi

    # Re-run design stage
    info "Re-running ${BOLD}${target_stage}${RESET} with architecture context..."
    if "stage_${target_stage}" 2>/dev/null; then
        mark_stage_complete "$target_stage"
        success "Backtrack: ${target_stage} re-run complete"
    else
        GOAL="$original_goal"
        error "Backtrack: ${target_stage} re-run failed"
        return 1
    fi

    # Re-run build+test
    info "Re-running build→test after backtracked ${target_stage}..."
    if self_healing_build_test; then
        success "Backtrack: build→test passed after ${target_stage} redesign"
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        error "Backtrack: build→test failed after ${target_stage} redesign"
        return 1
    fi
}

compound_rebuild_with_feedback() {
    local feedback_file="$ARTIFACTS_DIR/quality-feedback.md"

    # ── Intelligence: classify findings and determine routing ──
    local route="correctness"
    route=$(classify_quality_findings 2>/dev/null) || route="correctness"

    # ── Build structured findings JSON alongside markdown ──
    local structured_findings="[]"
    local s_total_critical=0 s_total_major=0 s_total_minor=0

    if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
        s_total_critical=$(jq -r '.security // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_major=$(jq -r '.correctness // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_minor=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
    fi

    local tmp_qf
    tmp_qf="$(mktemp)"
    jq -n \
        --arg route "$route" \
        --argjson total_critical "$s_total_critical" \
        --argjson total_major "$s_total_major" \
        --argjson total_minor "$s_total_minor" \
        '{route: $route, total_critical: $total_critical, total_major: $total_major, total_minor: $total_minor}' \
        > "$tmp_qf" 2>/dev/null && mv "$tmp_qf" "$ARTIFACTS_DIR/quality-findings.json" || rm -f "$tmp_qf"

    # ── Architecture route: backtrack to design instead of rebuild ──
    if [[ "$route" == "architecture" ]]; then
        info "Architecture-level findings detected — attempting backtrack to design"
        if pipeline_backtrack_to_stage "design" "architecture_violation" 2>/dev/null; then
            return 0
        fi
        # Backtrack failed or already used — fall through to standard rebuild
        warn "Backtrack unavailable — falling through to standard rebuild"
    fi

    # Collect all findings (prioritized by classification)
    {
        echo "# Quality Feedback — Issues to Fix"
        echo ""

        # Security findings first (highest priority)
        if [[ "$route" == "security" || -f "$ARTIFACTS_DIR/security-audit.log" ]] && grep -qiE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null; then
            echo "## 🔴 PRIORITY: Security Findings (fix these first)"
            cat "$ARTIFACTS_DIR/security-audit.log"
            echo ""
            echo "Security issues MUST be resolved before any other changes."
            echo ""
        fi

        # Correctness findings
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
            echo "## Adversarial Review Findings"
            cat "$ARTIFACTS_DIR/adversarial-review.md"
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]]; then
            echo "## Negative Prompting Concerns"
            cat "$ARTIFACTS_DIR/negative-review.md"
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/dod-audit.md" ]]; then
            echo "## DoD Audit Failures"
            grep "❌" "$ARTIFACTS_DIR/dod-audit.md" 2>/dev/null || true
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/api-compat.log" ]] && grep -qi 'BREAKING' "$ARTIFACTS_DIR/api-compat.log" 2>/dev/null; then
            echo "## API Breaking Changes"
            cat "$ARTIFACTS_DIR/api-compat.log"
            echo ""
        fi

        # Style findings last (deprioritized, informational)
        if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
            local style_count
            style_count=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
            if [[ "$style_count" -gt 0 ]]; then
                echo "## Style Notes (non-blocking, address if time permits)"
                echo "${style_count} style suggestions found. These do not block the build."
                echo ""
            fi
        fi
    } > "$feedback_file"

    # Validate feedback file has actual content
    if [[ ! -s "$feedback_file" ]]; then
        warn "No quality feedback collected — skipping rebuild"
        return 1
    fi

    # Reset build/test stages
    set_stage_status "build" "pending"
    set_stage_status "test" "pending"
    set_stage_status "review" "pending"

    # Augment GOAL with quality feedback (route-specific instructions)
    local original_goal="$GOAL"
    local feedback_content
    feedback_content=$(cat "$feedback_file")

    local route_instruction=""
    case "$route" in
        security)
            route_instruction="SECURITY PRIORITY: Fix all security vulnerabilities FIRST, then address other issues. Security issues are BLOCKING."
            ;;
        performance)
            route_instruction="PERFORMANCE PRIORITY: Address performance regressions and optimizations. Check for N+1 queries, memory leaks, and algorithmic complexity."
            ;;
        testing)
            route_instruction="TESTING PRIORITY: Add missing test coverage and fix flaky tests before addressing other issues."
            ;;
        correctness)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
        architecture)
            route_instruction="ARCHITECTURE: Fix structural issues. Check dependency direction, layer boundaries, and separation of concerns."
            ;;
        *)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
    esac

    GOAL="$GOAL

IMPORTANT — Compound quality review found issues (route: ${route}). Fix ALL of these:
$feedback_content

${route_instruction}"

    # Re-run self-healing build→test
    info "Rebuilding with quality feedback (route: ${route})..."
    if self_healing_build_test; then
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        return 1
    fi
}

stage_compound_quality() {
    CURRENT_STAGE_ID="compound_quality"

    # Pre-check: verify meaningful changes exist before running expensive quality checks
    local _cq_real_changes
    _cq_real_changes=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" \
        -- . ':!.claude/loop-state.md' ':!.claude/pipeline-state.md' \
        ':!.claude/pipeline-artifacts/*' ':!**/progress.md' \
        ':!**/error-summary.json' 2>/dev/null | wc -l | xargs || echo "0")
    if [[ "${_cq_real_changes:-0}" -eq 0 ]]; then
        error "Compound quality: no meaningful code changes found — failing quality gate"
        return 1
    fi

    # Read config
    local max_cycles adversarial_enabled negative_enabled e2e_enabled dod_enabled strict_quality
    max_cycles=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.max_cycles) // 3' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_cycles" || "$max_cycles" == "null" ]] && max_cycles=3
    adversarial_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.adversarial) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    negative_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.negative) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    e2e_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.e2e) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    dod_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.dod_audit) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    strict_quality=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.strict_quality) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$strict_quality" || "$strict_quality" == "null" ]] && strict_quality="false"

    # Intelligent audit selection
    local audit_plan='{"adversarial":"targeted","architecture":"targeted","simulation":"targeted","security":"targeted","dod":"targeted"}'
    if type pipeline_select_audits &>/dev/null 2>&1; then
        local _selected
        _selected=$(pipeline_select_audits 2>/dev/null) || true
        if [[ -n "$_selected" && "$_selected" != "null" ]]; then
            audit_plan="$_selected"
            info "Audit plan: $(echo "$audit_plan" | jq -c '.' 2>/dev/null || echo "$audit_plan")"
        fi
    fi

    # Track findings for quality score
    local total_critical=0 total_major=0 total_minor=0
    local audits_run_list=""

    # ── HARDENED QUALITY GATES (RUN BEFORE CYCLES) ──
    # These checks must pass before we even start the audit cycles
    echo ""
    info "Running hardened quality gate checks..."

    # 1. Bash 3.2 compatibility check
    local bash_violations=0
    bash_violations=$(run_bash_compat_check 2>/dev/null) || bash_violations=0
    bash_violations="${bash_violations:-0}"

    if [[ "$strict_quality" == "true" && "$bash_violations" -gt 0 ]]; then
        error "STRICT QUALITY: Bash 3.2 incompatibilities found — blocking"
        emit_event "quality.bash_compat_failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "violations=$bash_violations"
        return 1
    fi

    if [[ "$bash_violations" -gt 0 ]]; then
        warn "Bash 3.2 incompatibilities detected: ${bash_violations} (will impact quality score)"
        total_minor=$((total_minor + bash_violations))
    else
        success "Bash 3.2 compatibility: clean"
    fi

    # 2. Test coverage check
    local coverage_pct=0
    coverage_pct=$(run_test_coverage_check 2>/dev/null) || coverage_pct=0
    coverage_pct="${coverage_pct:-0}"

    if [[ "$coverage_pct" != "skip" ]]; then
        if [[ "$coverage_pct" -lt "${PIPELINE_COVERAGE_THRESHOLD:-60}" ]]; then
            if [[ "$strict_quality" == "true" ]]; then
                error "STRICT QUALITY: Test coverage below ${PIPELINE_COVERAGE_THRESHOLD:-60}% (${coverage_pct}%) — blocking"
                emit_event "quality.coverage_failed" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "coverage=$coverage_pct"
                return 1
            else
                warn "Test coverage below ${PIPELINE_COVERAGE_THRESHOLD:-60}% threshold (${coverage_pct}%) — quality penalty applied"
                total_major=$((total_major + 2))
            fi
        fi
    fi

    # 3. New functions without tests check
    local untested_functions=0
    untested_functions=$(run_new_function_test_check 2>/dev/null) || untested_functions=0
    untested_functions="${untested_functions:-0}"

    if [[ "$untested_functions" -gt 0 ]]; then
        if [[ "$strict_quality" == "true" ]]; then
            error "STRICT QUALITY: ${untested_functions} new function(s) without tests — blocking"
            emit_event "quality.untested_functions" \
                "issue=${ISSUE_NUMBER:-0}" \
                "count=$untested_functions"
            return 1
        else
            warn "New functions without corresponding tests: ${untested_functions}"
            total_major=$((total_major + untested_functions))
        fi
    fi

    # 4. Atomic write violations (optional, informational in most modes)
    local atomic_violations=0
    atomic_violations=$(run_atomic_write_check 2>/dev/null) || atomic_violations=0
    atomic_violations="${atomic_violations:-0}"

    if [[ "$atomic_violations" -gt 0 ]]; then
        warn "Atomic write violations: ${atomic_violations} (state/config file patterns)"
        total_minor=$((total_minor + atomic_violations))
    fi

    # Vitals-driven adaptive cycle limit (preferred)
    local base_max_cycles="$max_cycles"
    if type pipeline_adaptive_limit &>/dev/null 2>&1; then
        local _cq_vitals=""
        if type pipeline_compute_vitals &>/dev/null 2>&1; then
            _cq_vitals=$(pipeline_compute_vitals "$STATE_FILE" "$ARTIFACTS_DIR" "${ISSUE_NUMBER:-}" 2>/dev/null) || true
        fi
        local vitals_cq_limit
        vitals_cq_limit=$(pipeline_adaptive_limit "compound_quality" "$_cq_vitals" 2>/dev/null) || true
        if [[ -n "$vitals_cq_limit" && "$vitals_cq_limit" =~ ^[0-9]+$ && "$vitals_cq_limit" -gt 0 ]]; then
            max_cycles="$vitals_cq_limit"
            if [[ "$max_cycles" != "$base_max_cycles" ]]; then
                info "Vitals-driven cycles: ${base_max_cycles} → ${max_cycles} (compound_quality)"
            fi
        fi
    else
        # Fallback: adaptive cycle limits from optimization data
        local _cq_iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
        if [[ -f "$_cq_iter_model" ]]; then
            local adaptive_limit
            adaptive_limit=$(pipeline_adaptive_cycles "$max_cycles" "compound_quality" "0" "-1" 2>/dev/null) || true
            if [[ -n "$adaptive_limit" && "$adaptive_limit" =~ ^[0-9]+$ && "$adaptive_limit" -gt 0 ]]; then
                max_cycles="$adaptive_limit"
                if [[ "$max_cycles" != "$base_max_cycles" ]]; then
                    info "Adaptive cycles: ${base_max_cycles} → ${max_cycles} (compound_quality)"
                fi
            fi
        fi
    fi

    # Convergence tracking
    local prev_issue_count=-1

    local cycle=0
    while [[ "$cycle" -lt "$max_cycles" ]]; do
        cycle=$((cycle + 1))
        local all_passed=true

        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Compound Quality — Cycle ${cycle}/${max_cycles} ━━━${RESET}"

        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "🔬 **Compound quality** — cycle ${cycle}/${max_cycles}" 2>/dev/null || true
        fi

        # 1. Adversarial Review
        local _adv_intensity
        _adv_intensity=$(echo "$audit_plan" | jq -r '.adversarial // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$adversarial_enabled" == "true" && "$_adv_intensity" != "off" ]]; then
            echo ""
            info "Running adversarial review (${_adv_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}adversarial"
            if ! run_adversarial_review; then
                all_passed=false
            fi
        fi

        # 2. Negative Prompting
        if [[ "$negative_enabled" == "true" ]]; then
            echo ""
            info "Running negative prompting..."
            if ! run_negative_prompting; then
                all_passed=false
            fi
        fi

        # 3. Developer Simulation (intelligence module)
        if type simulation_review &>/dev/null 2>&1; then
            local sim_enabled
            sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
            local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
            if [[ "$sim_enabled" != "true" && -f "$daemon_cfg" ]]; then
                sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
            fi
            if [[ "$sim_enabled" == "true" ]]; then
                echo ""
                info "Running developer simulation review..."
                local sim_diff
                sim_diff=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$sim_diff" ]]; then
                    local sim_result
                    sim_result=$(simulation_review "$sim_diff" "${GOAL:-}" 2>/dev/null || echo "[]")
                    if [[ -n "$sim_result" && "$sim_result" != "[]" && "$sim_result" != *'"error"'* ]]; then
                        echo "$sim_result" > "$ARTIFACTS_DIR/compound-simulation-review.json"
                        local sim_critical
                        sim_critical=$(echo "$sim_result" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                        local sim_total
                        sim_total=$(echo "$sim_result" | jq 'length' 2>/dev/null || echo "0")
                        if [[ "$sim_critical" -gt 0 ]]; then
                            warn "Developer simulation: ${sim_critical} critical/high concerns (${sim_total} total)"
                            all_passed=false
                        else
                            success "Developer simulation: ${sim_total} concerns (none critical/high)"
                        fi
                        emit_event "compound.simulation" \
                            "issue=${ISSUE_NUMBER:-0}" \
                            "cycle=$cycle" \
                            "total=$sim_total" \
                            "critical=$sim_critical"
                    else
                        success "Developer simulation: no concerns"
                    fi
                fi
            fi
        fi

        # 4. Architecture Enforcer (intelligence module)
        if type architecture_validate_changes &>/dev/null 2>&1; then
            local arch_enabled
            arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
            local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
            if [[ "$arch_enabled" != "true" && -f "$daemon_cfg" ]]; then
                arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
            fi
            if [[ "$arch_enabled" == "true" ]]; then
                echo ""
                info "Running architecture validation..."
                local arch_diff
                arch_diff=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$arch_diff" ]]; then
                    local arch_result
                    arch_result=$(architecture_validate_changes "$arch_diff" "" 2>/dev/null || echo "[]")
                    if [[ -n "$arch_result" && "$arch_result" != "[]" && "$arch_result" != *'"error"'* ]]; then
                        echo "$arch_result" > "$ARTIFACTS_DIR/compound-architecture-validation.json"
                        local arch_violations
                        arch_violations=$(echo "$arch_result" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                        local arch_total
                        arch_total=$(echo "$arch_result" | jq 'length' 2>/dev/null || echo "0")
                        if [[ "$arch_violations" -gt 0 ]]; then
                            warn "Architecture validation: ${arch_violations} critical/high violations (${arch_total} total)"
                            all_passed=false
                        else
                            success "Architecture validation: ${arch_total} violations (none critical/high)"
                        fi
                        emit_event "compound.architecture" \
                            "issue=${ISSUE_NUMBER:-0}" \
                            "cycle=$cycle" \
                            "total=$arch_total" \
                            "violations=$arch_violations"
                    else
                        success "Architecture validation: no violations"
                    fi
                fi
            fi
        fi

        # 5. E2E Validation
        if [[ "$e2e_enabled" == "true" ]]; then
            echo ""
            info "Running E2E validation..."
            if ! run_e2e_validation; then
                all_passed=false
            fi
        fi

        # 6. DoD Audit
        local _dod_intensity
        _dod_intensity=$(echo "$audit_plan" | jq -r '.dod // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$dod_enabled" == "true" && "$_dod_intensity" != "off" ]]; then
            echo ""
            info "Running Definition of Done audit (${_dod_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}dod"
            if ! run_dod_audit; then
                all_passed=false
            fi
        fi

        # 6b. Security Source Scan
        local _sec_intensity
        _sec_intensity=$(echo "$audit_plan" | jq -r '.security // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$_sec_intensity" != "off" ]]; then
            echo ""
            info "Running security source scan (${_sec_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}security"
            local sec_finding_count=0
            sec_finding_count=$(pipeline_security_source_scan 2>/dev/null) || true
            sec_finding_count="${sec_finding_count:-0}"
            if [[ "$sec_finding_count" -gt 0 ]]; then
                warn "Security source scan: ${sec_finding_count} finding(s)"
                total_critical=$((total_critical + sec_finding_count))
                all_passed=false
            else
                success "Security source scan: clean"
            fi
        fi

        # 7. Multi-dimensional quality checks
        echo ""
        info "Running multi-dimensional quality checks..."
        local quality_failures=0

        if ! quality_check_security; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_coverage; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_perf_regression; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_bundle_size; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_api_compat; then
            quality_failures=$((quality_failures + 1))
        fi

        if [[ "$quality_failures" -gt 0 ]]; then
            if [[ "$strict_quality" == "true" ]]; then
                warn "Multi-dimensional quality: ${quality_failures} check(s) failed (strict mode — blocking)"
                all_passed=false
            else
                warn "Multi-dimensional quality: ${quality_failures} check(s) failed (non-blocking)"
            fi
        else
            success "Multi-dimensional quality: all checks passed"
        fi

        # ── Convergence Detection ──
        # Count critical/high issues from all review artifacts
        local current_issue_count=0
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
            local adv_issues
            adv_issues=$(grep -ciE '\*\*\[?(Critical|Bug|critical|high)\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
            current_issue_count=$((current_issue_count + ${adv_issues:-0}))
        fi
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.json" ]]; then
            local adv_json_issues
            adv_json_issues=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
            current_issue_count=$((current_issue_count + ${adv_json_issues:-0}))
        fi
        if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]]; then
            local neg_issues
            neg_issues=$(grep -ciE '\[Critical\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
            current_issue_count=$((current_issue_count + ${neg_issues:-0}))
        fi
        current_issue_count=$((current_issue_count + quality_failures))

        emit_event "compound.cycle" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cycle=$cycle" \
            "max_cycles=$max_cycles" \
            "passed=$all_passed" \
            "critical_issues=$current_issue_count" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Early exit: zero critical/high issues
        if [[ "$current_issue_count" -eq 0 ]] && $all_passed; then
            success "Compound quality passed on cycle ${cycle} — zero critical/high issues"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "✅ **Compound quality passed** — cycle ${cycle}/${max_cycles}

All quality checks clean:
- Adversarial review: ✅
- Negative prompting: ✅
- Developer simulation: ✅
- Architecture validation: ✅
- E2E validation: ✅
- DoD audit: ✅
- Security audit: ✅
- Coverage: ✅
- Performance: ✅
- Bundle size: ✅
- API compat: ✅" 2>/dev/null || true
            fi

            log_stage "compound_quality" "Passed on cycle ${cycle}/${max_cycles}"

            # DoD verification on successful pass
            local _dod_pass_rate=100
            if type pipeline_verify_dod &>/dev/null 2>&1; then
                pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
                if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
                    _dod_pass_rate=$(jq -r '.pass_rate // 100' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "100")
                fi
            fi

            pipeline_record_quality_score 100 0 0 0 "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true
            return 0
        fi

        if $all_passed; then
            success "Compound quality passed on cycle ${cycle}"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "✅ **Compound quality passed** — cycle ${cycle}/${max_cycles}" 2>/dev/null || true
            fi

            log_stage "compound_quality" "Passed on cycle ${cycle}/${max_cycles}"

            # DoD verification on successful pass
            local _dod_pass_rate=100
            if type pipeline_verify_dod &>/dev/null 2>&1; then
                pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
                if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
                    _dod_pass_rate=$(jq -r '.pass_rate // 100' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "100")
                fi
            fi

            pipeline_record_quality_score 95 0 "$total_major" "$total_minor" "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true
            return 0
        fi

        # Check for plateau: issue count unchanged between cycles
        if [[ "$prev_issue_count" -ge 0 && "$current_issue_count" -eq "$prev_issue_count" && "$cycle" -gt 1 ]]; then
            warn "Convergence: quality plateau — ${current_issue_count} issues unchanged between cycles"
            emit_event "compound.plateau" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle" \
                "issue_count=$current_issue_count"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "⚠️ **Compound quality plateau** — ${current_issue_count} issues unchanged after cycle ${cycle}. Stopping early." 2>/dev/null || true
            fi

            log_stage "compound_quality" "Plateau at cycle ${cycle}/${max_cycles} (${current_issue_count} issues)"
            return 1
        fi
        prev_issue_count="$current_issue_count"

        info "Convergence: ${current_issue_count} critical/high issues remaining"

        # Intelligence: re-evaluate adaptive cycle limit based on convergence (only after first cycle)
        if [[ "$prev_issue_count" -ge 0 ]]; then
            local updated_limit
            updated_limit=$(pipeline_adaptive_cycles "$max_cycles" "compound_quality" "$current_issue_count" "$prev_issue_count" 2>/dev/null) || true
            if [[ -n "$updated_limit" && "$updated_limit" =~ ^[0-9]+$ && "$updated_limit" -gt 0 && "$updated_limit" != "$max_cycles" ]]; then
                info "Adaptive cycles: ${max_cycles} → ${updated_limit} (convergence signal)"
                max_cycles="$updated_limit"
            fi
        fi

        # Not all passed — rebuild if we have cycles left
        if [[ "$cycle" -lt "$max_cycles" ]]; then
            warn "Quality checks failed — rebuilding with feedback (cycle $((cycle + 1))/${max_cycles})"

            if ! compound_rebuild_with_feedback; then
                error "Rebuild with feedback failed"
                log_stage "compound_quality" "Rebuild failed on cycle ${cycle}"
                return 1
            fi

            # Re-run review stage too (since code changed)
            info "Re-running review after rebuild..."
            stage_review 2>/dev/null || true
        fi
    done

    # ── Quality Score Computation ──
    # Starting score: 100, deductions based on findings
    local quality_score=100

    # Count findings from artifact files
    if [[ -f "$ARTIFACTS_DIR/security-source-scan.json" ]]; then
        local _sec_critical
        _sec_critical=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || echo "0")
        local _sec_major
        _sec_major=$(jq '[.[] | select(.severity == "major")] | length' "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || echo "0")
        total_critical=$((total_critical + ${_sec_critical:-0}))
        total_major=$((total_major + ${_sec_major:-0}))
    fi
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.json" ]]; then
        local _adv_crit
        _adv_crit=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        local _adv_major
        _adv_major=$(jq '[.[] | select(.severity == "high" or .severity == "major")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        local _adv_minor
        _adv_minor=$(jq '[.[] | select(.severity == "low" or .severity == "minor")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        total_critical=$((total_critical + ${_adv_crit:-0}))
        total_major=$((total_major + ${_adv_major:-0}))
        total_minor=$((total_minor + ${_adv_minor:-0}))
    fi
    if [[ -f "$ARTIFACTS_DIR/compound-architecture-validation.json" ]]; then
        local _arch_crit
        _arch_crit=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || echo "0")
        local _arch_major
        _arch_major=$(jq '[.[] | select(.severity == "high" or .severity == "major")] | length' "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || echo "0")
        total_major=$((total_major + ${_arch_crit:-0} + ${_arch_major:-0}))
    fi

    # Apply deductions
    quality_score=$((quality_score - (total_critical * 20) - (total_major * 10) - (total_minor * 2)))
    [[ "$quality_score" -lt 0 ]] && quality_score=0

    # DoD verification
    local _dod_pass_rate=0
    if type pipeline_verify_dod &>/dev/null 2>&1; then
        pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
        if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
            _dod_pass_rate=$(jq -r '.pass_rate // 0' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "0")
        fi
    fi

    # Record quality score
    pipeline_record_quality_score "$quality_score" "$total_critical" "$total_major" "$total_minor" "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true

    # ── Quality Gate (HARDENED) ──
    local compound_quality_blocking
    compound_quality_blocking=$(jq -r --arg id "compound_quality" \
        '(.stages[] | select(.id == $id) | .config.compound_quality_blocking) // true' \
        "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$compound_quality_blocking" || "$compound_quality_blocking" == "null" ]] && compound_quality_blocking="true"

    # HARDENED THRESHOLD: quality_score must be >= 60 (non-strict) or policy threshold (strict) to pass
    local min_threshold=60
    if [[ "$strict_quality" == "true" ]]; then
        min_threshold="${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"
        # Strict mode: require score >= threshold and ZERO critical issues
        if [[ "$total_critical" -gt 0 ]]; then
            error "STRICT QUALITY: ${total_critical} critical issue(s) found — BLOCKING (strict mode)"
            emit_event "pipeline.quality_gate_failed_strict" \
                "issue=${ISSUE_NUMBER:-0}" \
                "reason=critical_issues" \
                "critical=$total_critical"
            log_stage "compound_quality" "Quality gate failed (strict mode): critical issues"
            return 1
        fi
        min_threshold=70
    fi

    # Hard floor: score must be >= 40, regardless of other settings
    if [[ "$quality_score" -lt 40 ]]; then
        error "HARDENED GATE: Quality score ${quality_score}/100 below hard floor (40) — BLOCKING"
        emit_event "quality.hard_floor_failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "quality_score=$quality_score"
        log_stage "compound_quality" "Quality gate failed: score below hard floor (40)"
        return 1
    fi

    if [[ "$quality_score" -lt "$min_threshold" && "$compound_quality_blocking" == "true" ]]; then
        emit_event "pipeline.quality_gate_failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "quality_score=$quality_score" \
            "threshold=$min_threshold" \
            "critical=$total_critical" \
            "major=$total_major"

        error "Quality gate FAILED: score ${quality_score}/100 (threshold: ${min_threshold}/100, critical: ${total_critical}, major: ${total_major}, minor: ${total_minor})"

        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Quality gate failed** — score ${quality_score}/${min_threshold}

| Finding Type | Count | Deduction |
|---|---|---|
| Critical | ${total_critical} | -$((total_critical * 20)) |
| Major | ${total_major} | -$((total_major * 10)) |
| Minor | ${total_minor} | -$((total_minor * 2)) |

DoD pass rate: ${_dod_pass_rate}%
Quality issues remain after ${max_cycles} cycles. Check artifacts for details." 2>/dev/null || true
        fi

        log_stage "compound_quality" "Quality gate failed: ${quality_score}/${min_threshold} after ${max_cycles} cycles"
        return 1
    fi

    # Exhausted all cycles but quality score is at or above threshold
    if [[ "$quality_score" -ge "$min_threshold" ]]; then
        if [[ "$quality_score" -eq 100 ]]; then
            success "Compound quality PERFECT: 100/100"
        elif [[ "$quality_score" -ge 80 ]]; then
            success "Compound quality EXCELLENT: ${quality_score}/100"
        elif [[ "$quality_score" -ge 70 ]]; then
            success "Compound quality GOOD: ${quality_score}/100"
        else
            warn "Compound quality ACCEPTABLE: ${quality_score}/${min_threshold} after ${max_cycles} cycles"
        fi

        if [[ -n "$ISSUE_NUMBER" ]]; then
            local quality_emoji="✅"
            [[ "$quality_score" -lt 70 ]] && quality_emoji="⚠️"
            gh_comment_issue "$ISSUE_NUMBER" "${quality_emoji} **Compound quality passed** — score ${quality_score}/${min_threshold} after ${max_cycles} cycles

| Finding Type | Count |
|---|---|
| Critical | ${total_critical} |
| Major | ${total_major} |
| Minor | ${total_minor} |

DoD pass rate: ${_dod_pass_rate}%" 2>/dev/null || true
        fi

        log_stage "compound_quality" "Passed with score ${quality_score}/${min_threshold} after ${max_cycles} cycles"
        return 0
    fi

    error "Compound quality exhausted after ${max_cycles} cycles with insufficient score"

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "❌ **Compound quality failed** after ${max_cycles} cycles

Quality issues remain. Check artifacts for details." 2>/dev/null || true
    fi

    log_stage "compound_quality" "Failed after ${max_cycles} cycles"
    return 1
}

# ─── Error Classification ──────────────────────────────────────────────────
