# pipeline-quality-gates.sh — Quality gate checks for pipeline-quality-checks.sh

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh"
# Source from pipeline-quality-checks.sh. Requires ARTIFACTS_DIR, SCRIPT_DIR.
[[ -n "${_PIPELINE_QUALITY_GATES_LOADED:-}" ]] && return 0
_PIPELINE_QUALITY_GATES_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
TEST_CMD="${TEST_CMD:-}"

quality_check_security() {
    info "Security audit..."
    local audit_log="$ARTIFACTS_DIR/security-audit.log"
    local audit_exit=0
    local tool_found=false

    # Try npm audit
    if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
        tool_found=true
        npm audit --production 2>&1 | tee "$audit_log" || audit_exit=$?
    # Try pip-audit
    elif [[ -f "requirements.txt" || -f "pyproject.toml" ]] && command -v pip-audit >/dev/null 2>&1; then
        tool_found=true
        pip-audit 2>&1 | tee "$audit_log" || audit_exit=$?
    # Try cargo audit
    elif [[ -f "Cargo.toml" ]] && command -v cargo-audit >/dev/null 2>&1; then
        tool_found=true
        cargo audit 2>&1 | tee "$audit_log" || audit_exit=$?
    fi

    if [[ "$tool_found" != "true" ]]; then
        info "No security audit tool found — skipping"
        echo "No audit tool available" > "$audit_log"
        return 0
    fi

    # Parse results for critical/high severity
    local critical_count high_count
    critical_count=$(grep -ciE 'critical' "$audit_log" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    high_count=$(grep -ciE 'high' "$audit_log" 2>/dev/null || true)
    high_count="${high_count:-0}"

    emit_event "quality.security" \
        "issue=${ISSUE_NUMBER:-0}" \
        "critical=$critical_count" \
        "high=$high_count"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Security audit: ${critical_count} critical, ${high_count} high"
        return 1
    fi

    success "Security audit: clean"
    return 0
}

quality_check_bundle_size() {
    info "Bundle size check..."
    local metrics_log="$ARTIFACTS_DIR/bundle-metrics.log"
    local bundle_size=0
    local bundle_dir=""

    # Find build output directory — check config files first, then common dirs
    # Parse tsconfig.json outDir
    if [[ -z "$bundle_dir" && -f "tsconfig.json" ]]; then
        local ts_out
        ts_out=$(jq -r '.compilerOptions.outDir // empty' tsconfig.json 2>/dev/null || true)
        [[ -n "$ts_out" && -d "$ts_out" ]] && bundle_dir="$ts_out"
    fi
    # Parse package.json build script for output hints
    if [[ -z "$bundle_dir" && -f "package.json" ]]; then
        local build_script
        build_script=$(jq -r '.scripts.build // ""' package.json 2>/dev/null || true)
        if [[ -n "$build_script" ]]; then
            # Check for common output flags: --outDir, -o, --out-dir
            local parsed_out
            parsed_out=$(echo "$build_script" | grep -oE '(--outDir|--out-dir|-o)\s+[^ ]+' 2>/dev/null | awk '{print $NF}' | head -1 || true)
            [[ -n "$parsed_out" && -d "$parsed_out" ]] && bundle_dir="$parsed_out"
        fi
    fi
    # Fallback: check common directories
    if [[ -z "$bundle_dir" ]]; then
        for dir in dist build out .next target; do
            if [[ -d "$dir" ]]; then
                bundle_dir="$dir"
                break
            fi
        done
    fi

    if [[ -z "$bundle_dir" ]]; then
        info "No build output directory found — skipping bundle check"
        echo "No build directory" > "$metrics_log"
        return 0
    fi

    bundle_size=$(du -sk "$bundle_dir" 2>/dev/null | cut -f1 || echo "0")
    local bundle_size_human
    bundle_size_human=$(du -sh "$bundle_dir" 2>/dev/null | cut -f1 || echo "unknown")

    echo "Bundle directory: $bundle_dir" > "$metrics_log"
    echo "Size: ${bundle_size}KB (${bundle_size_human})" >> "$metrics_log"

    emit_event "quality.bundle" \
        "issue=${ISSUE_NUMBER:-0}" \
        "size_kb=$bundle_size" \
        "directory=$bundle_dir"

    # Adaptive bundle size check: statistical deviation from historical mean
    local repo_hash_bundle
    repo_hash_bundle=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local bundle_baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_bundle}"
    local bundle_history_file="${bundle_baselines_dir}/bundle-history.json"

    local bundle_history="[]"
    if [[ -f "$bundle_history_file" ]]; then
        bundle_history=$(jq '.sizes // []' "$bundle_history_file" 2>/dev/null || echo "[]")
    fi

    local bundle_hist_count
    bundle_hist_count=$(echo "$bundle_history" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$bundle_hist_count" -ge 3 ]]; then
        # Statistical check: alert on growth > 2σ from historical mean
        local mean_size stddev_size
        mean_size=$(echo "$bundle_history" | jq 'add / length' 2>/dev/null || echo "0")
        stddev_size=$(echo "$bundle_history" | jq '
            (add / length) as $mean |
            (map(. - $mean | . * .) | add / length | sqrt)
        ' 2>/dev/null || echo "0")

        # Adaptive tolerance: small repos (<1MB mean) get wider tolerance (3σ), large repos get 2σ
        local sigma_mult
        sigma_mult=$(awk -v mean="$mean_size" 'BEGIN{ print (mean < 1024 ? 3 : 2) }')
        local adaptive_max
        adaptive_max=$(awk -v mean="$mean_size" -v sd="$stddev_size" -v mult="$sigma_mult" \
            'BEGIN{ t = mean + mult*sd; min_t = mean * 1.1; printf "%.0f", (t > min_t ? t : min_t) }')

        echo "History: ${bundle_hist_count} runs | Mean: ${mean_size}KB | StdDev: ${stddev_size}KB | Max: ${adaptive_max}KB (${sigma_mult}σ)" >> "$metrics_log"

        if [[ "$bundle_size" -gt "$adaptive_max" ]] 2>/dev/null; then
            local growth_pct
            growth_pct=$(awk -v cur="$bundle_size" -v mean="$mean_size" 'BEGIN{printf "%d", ((cur - mean) / mean) * 100}')
            warn "Bundle size ${growth_pct}% above average (${mean_size}KB → ${bundle_size}KB, ${sigma_mult}σ threshold: ${adaptive_max}KB)"
            return 1
        fi
    else
        # Fallback: legacy memory baseline (not enough history for statistical check)
        local bundle_growth_limit
        bundle_growth_limit=$(_config_get_int "quality.bundle_growth_legacy_pct" 20 2>/dev/null || echo 20)
        local baseline_size=""
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            baseline_size=$(bash "$SCRIPT_DIR/sw-memory.sh" get "bundle_size_kb" 2>/dev/null) || true
        fi
        if [[ -n "$baseline_size" && "$baseline_size" -gt 0 ]] 2>/dev/null; then
            local growth_pct
            growth_pct=$(awk -v cur="$bundle_size" -v base="$baseline_size" 'BEGIN{printf "%d", ((cur - base) / base) * 100}')
            echo "Baseline: ${baseline_size}KB | Growth: ${growth_pct}%" >> "$metrics_log"
            if [[ "$growth_pct" -gt "$bundle_growth_limit" ]]; then
                warn "Bundle size grew ${growth_pct}% (${baseline_size}KB → ${bundle_size}KB)"
                return 1
            fi
        fi
    fi

    # Append current size to rolling history (keep last 10)
    mkdir -p "$bundle_baselines_dir"
    local updated_bundle_hist
    updated_bundle_hist=$(echo "$bundle_history" | jq --arg sz "$bundle_size" '
        . + [($sz | tonumber)] | .[-10:]
    ' 2>/dev/null || echo "[$bundle_size]")
    local tmp_bundle_hist
    tmp_bundle_hist=$(mktemp "${bundle_baselines_dir}/bundle-history.json.XXXXXX")
    jq -n --argjson sizes "$updated_bundle_hist" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{sizes: $sizes, updated: $updated}' > "$tmp_bundle_hist" 2>/dev/null
    mv "$tmp_bundle_hist" "$bundle_history_file" 2>/dev/null || true

    # Intelligence: identify top dependency bloaters
    if type intelligence_search_memory >/dev/null 2>&1 && [[ -f "package.json" ]] && command -v jq >/dev/null 2>&1; then
        local dep_sizes=""
        local deps
        deps=$(jq -r '.dependencies // {} | keys[]' package.json 2>/dev/null || true)
        if [[ -n "$deps" ]]; then
            while IFS= read -r dep; do
                [[ -z "$dep" ]] && continue
                local dep_dir="node_modules/${dep}"
                if [[ -d "$dep_dir" ]]; then
                    local dep_size
                    dep_size=$(du -sk "$dep_dir" 2>/dev/null | cut -f1 || echo "0")
                    dep_sizes="${dep_sizes}${dep_size} ${dep}
"
                fi
            done <<< "$deps"
            if [[ -n "$dep_sizes" ]]; then
                local top_bloaters
                top_bloaters=$(echo "$dep_sizes" | sort -rn | head -3)
                if [[ -n "$top_bloaters" ]]; then
                    echo "" >> "$metrics_log"
                    echo "Top 3 dependency sizes:" >> "$metrics_log"
                    echo "$top_bloaters" | while IFS=' ' read -r sz nm; do
                        [[ -z "$nm" ]] && continue
                        echo "  ${nm}: ${sz}KB" >> "$metrics_log"
                    done
                    info "Top bloaters: $(echo "$top_bloaters" | head -1 | awk '{print $2 ": " $1 "KB"}')"
                fi
            fi
        fi
    fi

    info "Bundle size: ${bundle_size_human}${bundle_hist_count:+ (${bundle_hist_count} historical samples)}"
    return 0
}

quality_check_perf_regression() {
    info "Performance regression check..."
    local metrics_log="$ARTIFACTS_DIR/perf-metrics.log"
    local test_log="$ARTIFACTS_DIR/test-results.log"

    if [[ ! -f "$test_log" ]]; then
        info "No test results — skipping perf check"
        echo "No test results available" > "$metrics_log"
        return 0
    fi

    # Extract test suite duration — multi-framework patterns
    local duration_ms=""
    # Jest/Vitest: "Time: 12.34 s" or "Duration  12.34s"
    duration_ms=$(grep -oE 'Time:\s*[0-9.]+\s*s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'Duration\s+[0-9.]+\s*s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # pytest: "passed in 12.34s" or "====== 5 passed in 12.34 seconds ======"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'passed in [0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Go test: "ok  pkg  12.345s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE '^ok\s+\S+\s+[0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+s' | grep -oE '[0-9.]+' | tail -1 || true)
    # Cargo test: "test result: ok. ... finished in 12.34s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'finished in [0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Generic: "12.34 seconds" or "12.34s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE '[0-9.]+ ?s(econds?)?' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)

    # Claude fallback: parse test output when no pattern matches
    if [[ -z "$duration_ms" ]]; then
        local intel_enabled="false"
        local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
        if [[ -f "$daemon_cfg" ]]; then
            intel_enabled=$(jq -r '.intelligence.enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$intel_enabled" == "true" ]] && command -v claude >/dev/null 2>&1; then
            local tail_output
            tail_output=$(tail -30 "$test_log" 2>/dev/null || true)
            if [[ -n "$tail_output" ]]; then
                duration_ms=$("$SW_AGENT_EXEC" claude --print -p "Extract ONLY the total test suite duration in seconds from this output. Reply with ONLY a number (e.g. 12.34). If no duration found, reply NONE.

$tail_output" < /dev/null 2>/dev/null | grep -oE '^[0-9.]+$' | head -1 || true)
                [[ "$duration_ms" == "NONE" ]] && duration_ms=""
            fi
        fi
    fi

    if [[ -z "$duration_ms" ]]; then
        info "Could not extract test duration — skipping perf check"
        echo "Duration not parseable" > "$metrics_log"
        return 0
    fi

    echo "Test duration: ${duration_ms}s" > "$metrics_log"

    emit_event "quality.perf" \
        "issue=${ISSUE_NUMBER:-0}" \
        "duration_s=$duration_ms"

    # Adaptive performance check: 2σ from rolling 10-run average
    local repo_hash_perf
    repo_hash_perf=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local perf_baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_perf}"
    local perf_history_file="${perf_baselines_dir}/perf-history.json"

    # Read historical durations (rolling window of last 10 runs)
    local history_json="[]"
    if [[ -f "$perf_history_file" ]]; then
        history_json=$(jq '.durations // []' "$perf_history_file" 2>/dev/null || echo "[]")
    fi

    local history_count
    history_count=$(echo "$history_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$history_count" -ge 3 ]]; then
        # Calculate mean and standard deviation from history
        local mean_dur stddev_dur
        mean_dur=$(echo "$history_json" | jq 'add / length' 2>/dev/null || echo "0")
        stddev_dur=$(echo "$history_json" | jq '
            (add / length) as $mean |
            (map(. - $mean | . * .) | add / length | sqrt)
        ' 2>/dev/null || echo "0")

        # Threshold: mean + 2σ (but at least 10% above mean)
        local adaptive_threshold
        adaptive_threshold=$(awk -v mean="$mean_dur" -v sd="$stddev_dur" \
            'BEGIN{ t = mean + 2*sd; min_t = mean * 1.1; printf "%.2f", (t > min_t ? t : min_t) }')

        echo "History: ${history_count} runs | Mean: ${mean_dur}s | StdDev: ${stddev_dur}s | Threshold: ${adaptive_threshold}s" >> "$metrics_log"

        if awk -v cur="$duration_ms" -v thresh="$adaptive_threshold" 'BEGIN{exit !(cur > thresh)}' 2>/dev/null; then
            local slowdown_pct
            slowdown_pct=$(awk -v cur="$duration_ms" -v mean="$mean_dur" 'BEGIN{printf "%d", ((cur - mean) / mean) * 100}')
            warn "Tests ${slowdown_pct}% slower than rolling average (${mean_dur}s → ${duration_ms}s, threshold: ${adaptive_threshold}s)"
            return 1
        fi
    else
        # Fallback: legacy memory baseline (not enough history for statistical check)
        local perf_regression_limit
        perf_regression_limit=$(_config_get_int "quality.perf_regression_legacy_pct" 30 2>/dev/null || echo 30)
        local baseline_dur=""
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            baseline_dur=$(bash "$SCRIPT_DIR/sw-memory.sh" get "test_duration_s" 2>/dev/null) || true
        fi
        if [[ -n "$baseline_dur" ]] && awk -v cur="$duration_ms" -v base="$baseline_dur" 'BEGIN{exit !(base > 0)}' 2>/dev/null; then
            local slowdown_pct
            slowdown_pct=$(awk -v cur="$duration_ms" -v base="$baseline_dur" 'BEGIN{printf "%d", ((cur - base) / base) * 100}')
            echo "Baseline: ${baseline_dur}s | Slowdown: ${slowdown_pct}%" >> "$metrics_log"
            if [[ "$slowdown_pct" -gt "$perf_regression_limit" ]]; then
                warn "Tests ${slowdown_pct}% slower (${baseline_dur}s → ${duration_ms}s)"
                return 1
            fi
        fi
    fi

    # Append current duration to rolling history (keep last 10)
    mkdir -p "$perf_baselines_dir"
    local updated_history
    updated_history=$(echo "$history_json" | jq --arg dur "$duration_ms" '
        . + [($dur | tonumber)] | .[-10:]
    ' 2>/dev/null || echo "[$duration_ms]")
    local tmp_perf_hist
    tmp_perf_hist=$(mktemp "${perf_baselines_dir}/perf-history.json.XXXXXX")
    jq -n --argjson durations "$updated_history" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{durations: $durations, updated: $updated}' > "$tmp_perf_hist" 2>/dev/null
    mv "$tmp_perf_hist" "$perf_history_file" 2>/dev/null || true

    info "Test duration: ${duration_ms}s${history_count:+ (${history_count} historical samples)}"
    return 0
}

quality_check_api_compat() {
    info "API compatibility check..."
    local compat_log="$ARTIFACTS_DIR/api-compat.log"

    # Look for OpenAPI/Swagger specs — search beyond hardcoded paths
    local spec_file=""
    for candidate in openapi.json openapi.yaml swagger.json swagger.yaml api/openapi.json docs/openapi.yaml; do
        if [[ -f "$candidate" ]]; then
            spec_file="$candidate"
            break
        fi
    done
    # Broader search if nothing found at common paths
    if [[ -z "$spec_file" ]]; then
        spec_file=$(find . -maxdepth 4 \( -name "openapi*.json" -o -name "openapi*.yaml" -o -name "openapi*.yml" -o -name "swagger*.json" -o -name "swagger*.yaml" -o -name "swagger*.yml" \) -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$spec_file" ]]; then
        info "No OpenAPI/Swagger spec found — skipping API compat check"
        echo "No API spec found" > "$compat_log"
        return 0
    fi

    # Check if spec was modified in this branch
    local spec_changed
    spec_changed=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null | grep -c "$(basename "$spec_file")" || true)
    spec_changed="${spec_changed:-0}"

    if [[ "$spec_changed" -eq 0 ]]; then
        info "API spec unchanged"
        echo "Spec unchanged" > "$compat_log"
        return 0
    fi

    # Diff the spec against base branch
    local old_spec new_spec
    old_spec=$(git show "${BASE_BRANCH}:${spec_file}" 2>/dev/null || true)
    new_spec=$(cat "$spec_file" 2>/dev/null || true)

    if [[ -z "$old_spec" ]]; then
        info "New API spec — no baseline to compare"
        echo "New spec, no baseline" > "$compat_log"
        return 0
    fi

    # Check for breaking changes: removed endpoints, changed methods
    local removed_endpoints=""
    if command -v jq >/dev/null 2>&1 && [[ "$spec_file" == *.json ]]; then
        local old_paths new_paths
        old_paths=$(echo "$old_spec" | jq -r '.paths | keys[]' 2>/dev/null | sort || true)
        new_paths=$(jq -r '.paths | keys[]' "$spec_file" 2>/dev/null | sort || true)
        removed_endpoints=$(comm -23 <(echo "$old_paths") <(echo "$new_paths") 2>/dev/null || true)
    fi

    # Enhanced schema diff: parameter changes, response schema, auth changes
    local param_changes="" schema_changes=""
    if command -v jq >/dev/null 2>&1 && [[ "$spec_file" == *.json ]]; then
        # Detect parameter changes on existing endpoints
        local common_paths
        common_paths=$(comm -12 <(echo "$old_spec" | jq -r '.paths | keys[]' 2>/dev/null | sort) <(jq -r '.paths | keys[]' "$spec_file" 2>/dev/null | sort) 2>/dev/null || true)
        if [[ -n "$common_paths" ]]; then
            while IFS= read -r path; do
                [[ -z "$path" ]] && continue
                local old_params new_params
                old_params=$(echo "$old_spec" | jq -r --arg p "$path" '.paths[$p] | to_entries[] | .value.parameters // [] | .[].name' 2>/dev/null | sort || true)
                new_params=$(jq -r --arg p "$path" '.paths[$p] | to_entries[] | .value.parameters // [] | .[].name' "$spec_file" 2>/dev/null | sort || true)
                local removed_params
                removed_params=$(comm -23 <(echo "$old_params") <(echo "$new_params") 2>/dev/null || true)
                [[ -n "$removed_params" ]] && param_changes="${param_changes}${path}: removed params: ${removed_params}
"
            done <<< "$common_paths"
        fi
    fi

    # Intelligence: semantic API diff for complex changes
    local semantic_diff=""
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local spec_git_diff
        spec_git_diff=$(git diff "${BASE_BRANCH}...HEAD" -- "$spec_file" 2>/dev/null | head -200 || true)
        if [[ -n "$spec_git_diff" ]]; then
            semantic_diff=$("$SW_AGENT_EXEC" claude --print --output-format text -p "Analyze this API spec diff for breaking changes. List: removed endpoints, changed parameters, altered response schemas, auth changes. Be concise.

${spec_git_diff}" --model "$(_smart_model validation haiku)" < /dev/null 2>/dev/null || true)
        fi
    fi

    {
        echo "Spec: $spec_file"
        echo "Changed: yes"
        if [[ -n "$removed_endpoints" ]]; then
            echo "BREAKING — Removed endpoints:"
            echo "$removed_endpoints"
        fi
        if [[ -n "$param_changes" ]]; then
            echo "BREAKING — Parameter changes:"
            echo "$param_changes"
        fi
        if [[ -n "$semantic_diff" ]]; then
            echo ""
            echo "Semantic analysis:"
            echo "$semantic_diff"
        fi
        if [[ -z "$removed_endpoints" && -z "$param_changes" ]]; then
            echo "No breaking changes detected"
        fi
    } > "$compat_log"

    if [[ -n "$removed_endpoints" || -n "$param_changes" ]]; then
        local issue_count=0
        [[ -n "$removed_endpoints" ]] && issue_count=$((issue_count + $(echo "$removed_endpoints" | wc -l | xargs)))
        [[ -n "$param_changes" ]] && issue_count=$((issue_count + $(echo "$param_changes" | grep -c '.' 2>/dev/null || true)))
        warn "API breaking changes: ${issue_count} issue(s) found"
        return 1
    fi

    success "API compatibility: no breaking changes"
    return 0
}

quality_check_coverage() {
    info "Coverage analysis..."
    local test_log="$ARTIFACTS_DIR/test-results.log"

    if [[ ! -f "$test_log" ]]; then
        info "No test results — skipping coverage check"
        return 0
    fi

    # Extract coverage percentage using shared parser
    local coverage=""
    coverage=$(parse_coverage_from_output "$test_log")

    # Claude fallback: parse test output when no pattern matches
    if [[ -z "$coverage" ]]; then
        local intel_enabled_cov="false"
        local daemon_cfg_cov="${PROJECT_ROOT}/.claude/daemon-config.json"
        if [[ -f "$daemon_cfg_cov" ]]; then
            intel_enabled_cov=$(jq -r '.intelligence.enabled // false' "$daemon_cfg_cov" 2>/dev/null || echo "false")
        fi
        if [[ "$intel_enabled_cov" == "true" ]] && command -v claude >/dev/null 2>&1; then
            local tail_cov_output
            tail_cov_output=$(tail -40 "$test_log" 2>/dev/null || true)
            if [[ -n "$tail_cov_output" ]]; then
                coverage=$("$SW_AGENT_EXEC" claude --print -p "Extract ONLY the overall code coverage percentage from this test output. Reply with ONLY a number (e.g. 85.5). If no coverage found, reply NONE.

$tail_cov_output" < /dev/null 2>/dev/null | grep -oE '^[0-9.]+$' | head -1 || true)
                [[ "$coverage" == "NONE" ]] && coverage=""
            fi
        fi
    fi

    if [[ -z "$coverage" ]]; then
        info "Could not extract coverage — skipping"
        return 0
    fi

    emit_event "quality.coverage" \
        "issue=${ISSUE_NUMBER:-0}" \
        "coverage=$coverage"

    # Check against pipeline config minimum
    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    # Adaptive baseline: read from baselines file, enforce no-regression (>= baseline - 2%)
    local repo_hash_cov
    repo_hash_cov=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_cov}"
    local coverage_baseline_file="${baselines_dir}/coverage.json"

    local baseline_coverage=""
    if [[ -f "$coverage_baseline_file" ]]; then
        baseline_coverage=$(jq -r '.baseline // empty' "$coverage_baseline_file" 2>/dev/null) || true
    fi
    # Fallback: try legacy memory baseline
    if [[ -z "$baseline_coverage" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        baseline_coverage=$(bash "$SCRIPT_DIR/sw-memory.sh" get "coverage_pct" 2>/dev/null) || true
    fi

    local dropped=false
    if [[ -n "$baseline_coverage" && "$baseline_coverage" != "0" ]] && awk -v cur="$coverage" -v base="$baseline_coverage" 'BEGIN{exit !(base > 0)}' 2>/dev/null; then
        # Adaptive: allow 2% regression tolerance from baseline
        local min_allowed
        min_allowed=$(awk -v base="$baseline_coverage" 'BEGIN{printf "%d", base - 2}')
        if awk -v cur="$coverage" -v min="$min_allowed" 'BEGIN{exit !(cur < min)}' 2>/dev/null; then
            warn "Coverage regression: ${baseline_coverage}% → ${coverage}% (adaptive min: ${min_allowed}%)"
            dropped=true
        fi
    fi

    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null && awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
        warn "Coverage ${coverage}% below minimum ${coverage_min}%"
        return 1
    fi

    if $dropped; then
        return 1
    fi

    # Update baseline on success (first run or improvement)
    if [[ -z "$baseline_coverage" ]] || awk -v cur="$coverage" -v base="$baseline_coverage" 'BEGIN{exit !(cur >= base)}' 2>/dev/null; then
        mkdir -p "$baselines_dir"
        local tmp_cov_baseline
        tmp_cov_baseline=$(mktemp "${baselines_dir}/coverage.json.XXXXXX")
        jq -n --arg baseline "$coverage" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{baseline: ($baseline | tonumber), updated: $updated}' > "$tmp_cov_baseline" 2>/dev/null
        mv "$tmp_cov_baseline" "$coverage_baseline_file" 2>/dev/null || true
    fi

    info "Coverage: ${coverage}%${baseline_coverage:+ (baseline: ${baseline_coverage}%)}"
    return 0
}

# ─── Compound Quality Checks ──────────────────────────────────────────────
# Adversarial review, negative prompting, E2E validation, and DoD audit.
# Feeds findings back into a self-healing rebuild loop for automatic fixes.

