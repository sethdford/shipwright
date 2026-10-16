# decide-signals.sh — Signal collection for the decision engine
# Source from sw-decide.sh. Requires helpers.sh, policy.sh.
[[ -n "${_DECIDE_SIGNALS_LOADED:-}" ]] && return 0
_DECIDE_SIGNALS_LOADED=1

# ─── State ────────────────────────────────────────────────────────────────────
SIGNALS_DIR="${HOME}/.shipwright/signals"
SIGNALS_PENDING_FILE="${SIGNALS_DIR}/pending.jsonl"

_ensure_signals_dir() {
    mkdir -p "$SIGNALS_DIR"
}

# ─── Candidate builder ───────────────────────────────────────────────────────
# Usage: _build_candidate "id" "signal" "category" "title" "description" "risk" "confidence" "dedup_key" [evidence_json]
_build_candidate() {
    local id="$1" signal="$2" category="$3" title="$4" description="$5"
    local risk="${6:-50}" confidence="${7:-0.80}" dedup_key="$8" evidence="${9:-{}}"
    jq -n \
        --arg id "$id" \
        --arg signal "$signal" \
        --arg category "$category" \
        --arg title "$title" \
        --arg desc "$description" \
        --argjson risk "$risk" \
        --arg conf "$confidence" \
        --arg dedup "$dedup_key" \
        --argjson ev "$evidence" \
        --arg ts "$(now_iso)" \
        '{id:$id, signal:$signal, category:$category, title:$title, description:$desc, evidence:$ev, risk_score:$risk, confidence:$conf, dedup_key:$dedup, collected_at:$ts}'
}

# ─── Collectors ───────────────────────────────────────────────────────────────

signals_collect_security() {
    # npm audit — critical/high only
    if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
        local audit_json
        audit_json=$(npm audit --json 2>/dev/null || echo '{}')
        local audit_version
        audit_version=$(echo "$audit_json" | jq -r '.auditReportVersion // 1')

        local vuln_list
        if [[ "$audit_version" == "2" ]]; then
            vuln_list=$(echo "$audit_json" | jq -c '[.vulnerabilities | to_entries[] | .value | {name: .name, severity: .severity, url: (.via[0].url // "N/A"), title: (.via[0].title // .name)}]' 2>/dev/null || echo '[]')
        else
            vuln_list=$(echo "$audit_json" | jq -c '[.advisories | to_entries[] | .value | {name: .module_name, severity: .severity, url: .url, title: .title}]' 2>/dev/null || echo '[]')
        fi

        if [[ -n "$vuln_list" && "$vuln_list" != "[]" ]]; then
            while IFS= read -r vuln; do
                local severity name title adv_url
                severity=$(echo "$vuln" | jq -r '.severity // "unknown"')
                name=$(echo "$vuln" | jq -r '.name // "unknown"')
                title=$(echo "$vuln" | jq -r '.title // "vulnerability"')
                adv_url=$(echo "$vuln" | jq -r '.url // ""')

                [[ "$severity" != "critical" && "$severity" != "high" ]] && continue

                local risk=50 category="security_patch"
                [[ "$severity" == "critical" ]] && risk=80 && category="security_critical"

                local evidence
                evidence=$(jq -n --arg sev "$severity" --arg pkg "$name" --arg url "$adv_url" \
                    '{severity:$sev, package:$pkg, advisory_url:$url}')

                _build_candidate \
                    "sec-${name}-$(echo "$title" | tr ' ' '-' | cut -c1-30)" \
                    "security" "$category" \
                    "Security: ${title} in ${name}" \
                    "Fix ${severity} vulnerability in ${name}. Advisory: ${adv_url}" \
                    "$risk" "0.95" "security:${name}:${title}" "$evidence"
            done < <(echo "$vuln_list" | jq -c '.[]' 2>/dev/null)
        fi
    fi

    # pip-audit
    if [[ -f "requirements.txt" ]] && command -v pip-audit >/dev/null 2>&1; then
        local pip_json
        pip_json=$(pip-audit --format=json 2>/dev/null || true)
        if [[ -n "$pip_json" ]]; then
            while IFS= read -r dep; do
                local pkg vuln_id
                pkg=$(echo "$dep" | jq -r '.name // "unknown"')
                vuln_id=$(echo "$dep" | jq -r '.vulns[0].id // "unknown"')
                _build_candidate \
                    "sec-pip-${pkg}-${vuln_id}" "security" "security_patch" \
                    "Security: ${vuln_id} in ${pkg}" \
                    "Python dependency ${pkg} has vulnerability ${vuln_id}" \
                    60 "0.90" "security:pip:${pkg}:${vuln_id}"
            done < <(echo "$pip_json" | jq -c '.dependencies[] | select(.vulns | length > 0)' 2>/dev/null)
        fi
    fi

    # cargo audit
    if [[ -f "Cargo.toml" ]] && command -v cargo-audit >/dev/null 2>&1; then
        local cargo_json
        cargo_json=$(cargo audit --json 2>/dev/null || true)
        local vuln_count
        vuln_count=$(echo "$cargo_json" | jq '.vulnerabilities.found' 2>/dev/null || echo "0")
        if [[ "${vuln_count:-0}" -gt 0 ]]; then
            _build_candidate \
                "sec-cargo-vulns" "security" "security_patch" \
                "Security: ${vuln_count} Cargo vulnerability(ies)" \
                "cargo audit found ${vuln_count} vulnerability(ies)" \
                60 "0.90" "security:cargo:vulns"
        fi
    fi
}

signals_collect_deps() {
    [[ ! -f "package.json" ]] && return 0
    command -v npm >/dev/null 2>&1 || return 0

    local outdated_json
    outdated_json=$(npm outdated --json 2>/dev/null || true)
    [[ -z "$outdated_json" || "$outdated_json" == "{}" ]] && return 0

    while IFS= read -r pkg; do
        local name current latest current_major latest_major
        name=$(echo "$pkg" | jq -r '.key')
        current=$(echo "$pkg" | jq -r '.value.current // "0.0.0"')
        latest=$(echo "$pkg" | jq -r '.value.latest // "0.0.0"')
        current_major="${current%%.*}"
        latest_major="${latest%%.*}"

        [[ ! "$latest_major" =~ ^[0-9]+$ ]] && continue
        [[ ! "$current_major" =~ ^[0-9]+$ ]] && continue

        local diff=$((latest_major - current_major))
        local category="deps_patch" risk=15
        if [[ "$diff" -ge 2 ]]; then
            category="deps_major"
            risk=45
        elif [[ "$diff" -ge 1 ]]; then
            category="deps_minor"
            risk=25
        else
            # Only minor/patch version difference — still flag as patch
            category="deps_patch"
            risk=10
        fi

        # Only emit for >= 1 major behind or if category is explicitly patch
        [[ "$diff" -lt 1 ]] && continue

        local evidence
        evidence=$(jq -n --arg pkg "$name" --arg cur "$current" --arg lat "$latest" --argjson diff "$diff" \
            '{package:$pkg, current:$cur, latest:$lat, major_versions_behind:$diff}')

        _build_candidate \
            "deps-${name}" "deps" "$category" \
            "Update ${name}: ${current} -> ${latest}" \
            "Package ${name} is ${diff} major version(s) behind (${current} -> ${latest})" \
            "$risk" "0.90" "deps:${name}" "$evidence"
    done < <(echo "$outdated_json" | jq -c 'to_entries[]' 2>/dev/null)
}

signals_collect_coverage() {
    local coverage_file=""
    for candidate in \
        ".claude/pipeline-artifacts/coverage/coverage-summary.json" \
        "coverage/coverage-summary.json" \
        ".coverage/coverage-summary.json"; do
        [[ -f "$candidate" ]] && coverage_file="$candidate" && break
    done
    [[ -z "$coverage_file" ]] && return 0

    local low_files=""
    local count=0
    while IFS= read -r entry; do
        local file_path line_pct
        file_path=$(echo "$entry" | jq -r '.key')
        line_pct=$(echo "$entry" | jq -r '.value.lines.pct // 100')
        [[ "$file_path" == "total" ]] && continue
        if awk "BEGIN{exit !($line_pct >= 50)}" 2>/dev/null; then continue; fi
        count=$((count + 1))
        low_files="${low_files}${file_path} (${line_pct}%), "
    done < <(jq -c 'to_entries[]' "$coverage_file" 2>/dev/null)

    [[ "$count" -eq 0 ]] && return 0

    _build_candidate \
        "cov-gaps-${count}" "coverage" "test_coverage" \
        "Improve test coverage for ${count} file(s)" \
        "Files with < 50% line coverage: ${low_files%%, }" \
        20 "0.85" "coverage:gaps:${count}"
}

signals_collect_docs() {
    local findings=0
    local details=""

    if [[ -f "README.md" ]]; then
        local readme_epoch src_epoch
        readme_epoch=$(git log -1 --format=%ct -- README.md 2>/dev/null || echo "0")
        src_epoch=$(git log -1 --format=%ct -- "*.ts" "*.js" "*.py" "*.go" "*.rs" "*.sh" 2>/dev/null || echo "0")
        if [[ "$src_epoch" -gt 0 && "$readme_epoch" -gt 0 ]]; then
            local drift=$((src_epoch - readme_epoch))
            if [[ "$drift" -gt 2592000 ]]; then
                findings=$((findings + 1))
                local days=$((drift / 86400))
                details="${details}README.md: ${days} days behind; "
            fi
        fi
    fi

    # Check AUTO section freshness
    if [[ -x "${SCRIPT_DIR:-}/sw-docs.sh" ]]; then
        bash "${SCRIPT_DIR}/sw-docs.sh" check >/dev/null 2>&1 || {
            findings=$((findings + 1))
            details="${details}AUTO sections stale; "
        }
    fi

    [[ "$findings" -eq 0 ]] && return 0

    _build_candidate \
        "docs-stale-${findings}" "docs" "doc_sync" \
        "Sync stale documentation (${findings} item(s))" \
        "Documentation drift detected: ${details%%; }" \
        15 "0.85" "docs:stale"
}

signals_collect_dead_code() {
    [[ ! -f "package.json" && ! -f "tsconfig.json" ]] && return 0

    local count=0
    local dead_files=""
    local src_dirs=("src" "lib" "app")
    for dir in "${src_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r file; do
            local basename_no_ext
            basename_no_ext=$(basename "$file" | sed 's/\.\(ts\|js\|tsx\|jsx\)$//')
            [[ "$basename_no_ext" == "index" ]] && continue
            [[ "$basename_no_ext" =~ \.(test|spec)$ ]] && continue

            local import_count
            import_count=$(grep -rlE "(from|require).*['\"].*${basename_no_ext}['\"]" \
                --include="*.ts" --include="*.js" --include="*.tsx" --include="*.jsx" \
                . 2>/dev/null | grep -cv "$file" || true)
            import_count=${import_count:-0}

            if [[ "$import_count" -eq 0 ]]; then
                count=$((count + 1))
                dead_files="${dead_files}${file}, "
            fi
        done < <(find "$dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" \) \
            ! -name "*.test.*" ! -name "*.spec.*" ! -name "*.d.ts" 2>/dev/null)
    done

    [[ "$count" -eq 0 ]] && return 0

    _build_candidate \
        "dead-code-${count}" "dead_code" "dead_code" \
        "Dead code candidates (${count} files)" \
        "Files with no importers: ${dead_files%%, }" \
        25 "0.70" "dead_code:${count}"
}

signals_collect_performance() {
    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"
    [[ ! -f "$events_file" ]] && return 0

    local baseline_file="${HOME}/.shipwright/patrol-perf-baseline.json"
    [[ ! -f "$baseline_file" ]] && return 0

    local recent_test_dur
    recent_test_dur=$(tail -500 "$events_file" | \
        jq -s '[.[] | select(.type == "stage.completed" and .stage == "test") | .duration_s] | if length > 0 then .[-1] else null end' \
        2>/dev/null || echo "null")
    [[ "$recent_test_dur" == "null" || -z "$recent_test_dur" ]] && return 0

    local baseline_dur
    baseline_dur=$(jq -r '.test_duration_s // 0' "$baseline_file" 2>/dev/null || echo "0")
    [[ "$baseline_dur" -le 0 ]] && return 0

    local threshold=$(( baseline_dur * 130 / 100 ))
    [[ "$recent_test_dur" -le "$threshold" ]] && return 0

    local pct_slower=$(( (recent_test_dur - baseline_dur) * 100 / baseline_dur ))

    local evidence
    evidence=$(jq -n --argjson base "$baseline_dur" --argjson cur "$recent_test_dur" --argjson pct "$pct_slower" \
        '{baseline_s:$base, current_s:$cur, regression_pct:$pct}')

    _build_candidate \
        "perf-test-regression" "performance" "performance_regression" \
        "Test suite performance regression (${pct_slower}% slower)" \
        "Test suite: ${baseline_dur}s -> ${recent_test_dur}s (${pct_slower}% regression)" \
        40 "0.85" "performance:test_suite" "$evidence"
}

signals_collect_failures() {
    local memory_script="${SCRIPT_DIR:-}/sw-memory.sh"
    [[ ! -f "$memory_script" ]] && return 0

    local failures_json
    failures_json=$(
        (
            source "$memory_script" > /dev/null 2>&1 || true
            if command -v memory_get_actionable_failures >/dev/null 2>&1; then
                memory_get_actionable_failures 3
            else
                echo "[]"
            fi
        )
    )

    local count
    count=$(echo "$failures_json" | jq 'length' 2>/dev/null || echo "0")
    [[ "${count:-0}" -eq 0 ]] && return 0

    while IFS= read -r failure; do
        local pattern stage seen_count
        pattern=$(echo "$failure" | jq -r '.pattern // "unknown"')
        stage=$(echo "$failure" | jq -r '.stage // "unknown"')
        seen_count=$(echo "$failure" | jq -r '.seen_count // 0')

        local short_pattern
        short_pattern=$(echo "$pattern" | cut -c1-60)

        _build_candidate \
            "fail-${stage}-$(echo "$short_pattern" | tr ' /' '-_' | cut -c1-30)" \
            "failures" "recurring_failure" \
            "Fix recurring: ${short_pattern}" \
            "Pattern in ${stage}: ${pattern} (seen ${seen_count}x)" \
            35 "0.80" "failure:${stage}:${short_pattern}"
    done < <(echo "$failures_json" | jq -c '.[]' 2>/dev/null)
}

signals_collect_dora() {
    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"
    [[ ! -f "$events_file" ]] && return 0

    local now_e
    now_e=$(now_epoch)
    local current_start=$((now_e - 604800))
    local prev_start=$((now_e - 1209600))

    local current_events prev_events
    current_events=$(jq -s --argjson start "$current_start" \
        '[.[] | select(.ts_epoch >= $start)]' "$events_file" 2>/dev/null || echo "[]")
    prev_events=$(jq -s --argjson start "$prev_start" --argjson end "$current_start" \
        '[.[] | select(.ts_epoch >= $start and .ts_epoch < $end)]' "$events_file" 2>/dev/null || echo "[]")

    local prev_total curr_total
    prev_total=$(echo "$prev_events" | jq '[.[] | select(.type == "pipeline.completed")] | length' 2>/dev/null || echo "0")
    curr_total=$(echo "$current_events" | jq '[.[] | select(.type == "pipeline.completed")] | length' 2>/dev/null || echo "0")

    [[ "${prev_total:-0}" -lt 3 || "${curr_total:-0}" -lt 3 ]] && return 0

    # Compare CFR
    local prev_failures curr_failures
    prev_failures=$(echo "$prev_events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length' 2>/dev/null || echo "0")
    curr_failures=$(echo "$current_events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length' 2>/dev/null || echo "0")

    local prev_cfr=0 curr_cfr=0
    [[ "$prev_total" -gt 0 ]] && prev_cfr=$(echo "$prev_failures $prev_total" | awk '{printf "%.0f", ($1 / $2) * 100}')
    [[ "$curr_total" -gt 0 ]] && curr_cfr=$(echo "$curr_failures $curr_total" | awk '{printf "%.0f", ($1 / $2) * 100}')

    # Flag if CFR increased by > 5 percentage points
    local cfr_diff=$((curr_cfr - prev_cfr))
    if [[ "$cfr_diff" -gt 5 ]]; then
        local evidence
        evidence=$(jq -n --argjson prev "$prev_cfr" --argjson curr "$curr_cfr" --argjson diff "$cfr_diff" \
            '{prev_cfr_pct:$prev, curr_cfr_pct:$curr, increase_pct:$diff}')

        _build_candidate \
            "dora-cfr-regression" "dora" "dora_regression" \
            "DORA regression: CFR increased ${cfr_diff}pp" \
            "Change failure rate: ${prev_cfr}% -> ${curr_cfr}% (7-day window)" \
            45 "0.80" "dora:cfr_regression" "$evidence"
    fi
}

signals_collect_architecture() {
    local arch_script="${SCRIPT_DIR:-}/sw-architecture-enforcer.sh"
    [[ ! -f "$arch_script" ]] && return 0

    local arch_model="${HOME}/.shipwright/memory/architecture.json"
    [[ ! -f "$arch_model" ]] && return 0

    local violations
    violations=$(bash "$arch_script" check --json 2>/dev/null || echo '{"violations":0}')
    local count
    count=$(echo "$violations" | jq '.violations // 0' 2>/dev/null || echo "0")
    [[ "${count:-0}" -eq 0 ]] && return 0

    _build_candidate \
        "arch-drift-${count}" "architecture" "architecture_drift" \
        "Architecture drift: ${count} violation(s)" \
        "Architecture enforcer found ${count} violation(s)" \
        50 "0.75" "architecture:drift"
}

signals_collect_intelligence() {
    local cache_file="${SHIPWRIGHT_INTELLIGENCE_CACHE:-.claude/intelligence-cache.json}"
    [[ ! -f "$cache_file" ]] && return 0

    # Check for high-churn hotspot files
    local hotspots
    hotspots=$(jq -c '.hotspots // [] | [.[] | select(.churn_score > 80)]' "$cache_file" 2>/dev/null || echo '[]')
    local count
    count=$(echo "$hotspots" | jq 'length' 2>/dev/null || echo "0")
    [[ "${count:-0}" -eq 0 ]] && return 0

    _build_candidate \
        "intel-hotspots-${count}" "intelligence" "refactor_hotspot" \
        "Refactor ${count} high-churn hotspot(s)" \
        "Intelligence cache shows ${count} file(s) with churn score > 80" \
        40 "0.70" "intelligence:hotspots"
}

signals_collect_external() {
    local collectors_dir="${_REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo '.')}/scripts/signals"
    [[ ! -d "$collectors_dir" ]] && return 0

    while IFS= read -r collector; do
        [[ ! -x "$collector" ]] && continue
        local output
        output=$(bash "$collector" 2>/dev/null || true)
        [[ -z "$output" ]] && continue
        # Each line should be a valid JSON candidate
        while IFS= read -r line; do
            echo "$line" | jq empty 2>/dev/null && echo "$line"
        done <<< "$output"
    done < <(find "$collectors_dir" -maxdepth 1 -name "*.sh" -type f 2>/dev/null | sort)
}

# ─── Pending signal file (for patrol integration) ────────────────────────────

signals_read_pending() {
    [[ ! -f "$SIGNALS_PENDING_FILE" ]] && return 0
    cat "$SIGNALS_PENDING_FILE"
}

signals_clear_pending() {
    [[ -f "$SIGNALS_PENDING_FILE" ]] && : > "$SIGNALS_PENDING_FILE"
}

# ─── Orchestrator ─────────────────────────────────────────────────────────────

signals_collect_all() {
    _ensure_signals_dir

    {
        signals_collect_security
        signals_collect_deps
        signals_collect_coverage
        signals_collect_docs
        signals_collect_dead_code
        signals_collect_performance
        signals_collect_failures
        signals_collect_dora
        signals_collect_architecture
        signals_collect_intelligence
        signals_collect_external
        signals_read_pending
    } | jq -s '.' 2>/dev/null || echo '[]'
}
