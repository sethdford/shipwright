#!/usr/bin/env bash
# Memory query — Searches and injects relevant memories into pipeline contexts
# Depends on: memory-common.sh (repo_memory_dir, ensure_memory_dir, _expand_domain_keywords, _memory_content_hash)

[[ -n "${_MEMORY_QUERY_LOADED:-}" ]] && return 0
_MEMORY_QUERY_LOADED=1

# TF-IDF-like ranked search across failures, patterns, decisions
# Returns JSON array of {source_type, content_text} for injection compatibility
memory_ranked_search() {
    local query="$1"
    local memory_dir="$2"
    local max_results="${3:-5}"

    # Use repo memory dir when not specified
    if [[ -z "$memory_dir" ]] && type repo_memory_dir &>/dev/null 2>&1; then
        memory_dir="$(repo_memory_dir)"
    fi
    memory_dir="${memory_dir:-$HOME/.shipwright/memory}"
    if [[ ! -d "$memory_dir" ]]; then
        info "Memory dir not found at ${memory_dir} — auto-creating"
        mkdir -p "$memory_dir"
        emit_event "memory.not_available" "path=$memory_dir" "action=auto_created"
        echo "[]"
        return 0
    fi

    # Extract and expand query keywords
    local keywords
    keywords=$(echo "$query" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | \
        grep -vxE '^.{1,2}$|^(the|and|for|not|with|this|that|from)$' || true)
    keywords=$(_expand_domain_keywords "$keywords" 2>/dev/null || echo "$keywords")

    local results_file
    results_file=$(mktemp)

    # Search failures.json
    if [[ -f "$memory_dir/failures.json" ]]; then
        jq -c '.failures[]? // empty' "$memory_dir/failures.json" 2>/dev/null | while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local entry_text
            entry_text=$(echo "$entry" | jq -r '(.pattern // "") + " " + (.root_cause // "") + " " + (.fix // "")' 2>/dev/null)
            local score=0
            while IFS= read -r kw; do
                [[ -z "$kw" ]] && continue
                if echo "$entry_text" | grep -qiF "$kw" 2>/dev/null; then
                    score=$((score + 1))
                fi
            done <<< "$keywords"

            # Boost by effectiveness
            local effectiveness
            effectiveness=$(echo "$entry" | jq -r '.fix_effectiveness_rate // 0' 2>/dev/null)
            if [[ "$effectiveness" =~ ^[0-9]+$ ]] && [[ "$effectiveness" -gt 50 ]]; then
                score=$((score + 2))
            fi

            if [[ "$score" -gt 0 ]]; then
                local content
                content=$(echo "$entry" | jq -r '(.pattern // "") + " | " + (.root_cause // "") + " | " + (.fix // "")' 2>/dev/null)
                echo "${score}|{\"source_type\":\"failure\",\"content_text\":$(echo "$content" | jq -Rs .)}" >> "$results_file"
            fi
        done
    fi

    # Search decisions.json
    if [[ -f "$memory_dir/decisions.json" ]]; then
        jq -c '.decisions[]? // empty' "$memory_dir/decisions.json" 2>/dev/null | while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local entry_text
            entry_text=$(echo "$entry" | jq -r '(.summary // "") + " " + (.detail // "") + " " + (.type // "")' 2>/dev/null)
            local score=0
            while IFS= read -r kw; do
                [[ -z "$kw" ]] && continue
                echo "$entry_text" | grep -qiF "$kw" 2>/dev/null && score=$((score + 1))
            done <<< "$keywords"
            if [[ "$score" -gt 0 ]]; then
                local content
                content=$(echo "$entry" | jq -r '(.summary // "") + " | " + (.detail // "")' 2>/dev/null)
                echo "${score}|{\"source_type\":\"decision\",\"content_text\":$(echo "$content" | jq -Rs .)}" >> "$results_file"
            fi
        done
    fi

    # Search patterns.json (project, conventions, known_issues as text)
    if [[ -f "$memory_dir/patterns.json" ]]; then
        local entry_text
        entry_text=$(jq -r 'to_entries | map(select(.key != "known_issues")) | from_entries | tostring' "$memory_dir/patterns.json" 2>/dev/null || echo "")
        entry_text="$entry_text $(jq -r '.known_issues[]? // empty' "$memory_dir/patterns.json" 2>/dev/null | tr '\n' ' ')"
        local score=0
        while IFS= read -r kw; do
            [[ -z "$kw" ]] && continue
            echo "$entry_text" | grep -qiF "$kw" 2>/dev/null && score=$((score + 1))
        done <<< "$keywords"
        if [[ "$score" -gt 0 ]]; then
            local content
            content=$(jq -r 'to_entries | map("\(.key): \(.value)") | join(" | ")' "$memory_dir/patterns.json" 2>/dev/null | head -c 500)
            echo "${score}|{\"source_type\":\"pattern\",\"content_text\":$(echo "$content" | jq -Rs .)}" >> "$results_file"
        fi
    fi

    # Sort by score and output as JSON array
    local output
    if [[ -s "$results_file" ]]; then
        output=$(sort -t'|' -k1 -rn "$results_file" | head -"$max_results" | cut -d'|' -f2- | jq -s '.' 2>/dev/null || echo "[]")
    else
        output="[]"
    fi
    rm -f "$results_file" 2>/dev/null || true
    echo "$output"
}

# Semantic search: embeddings when available, else TF-IDF-like ranked keyword search
memory_semantic_search() {
    local query="$1" repo_hash="${2:-}" limit="${3:-5}"

    if _has_embeddings 2>/dev/null; then
        # Future: _search_embeddings "$query" "$repo_hash" "$limit"
        :
    fi

    # Fall back to ranked keyword search (better than SQL LIKE or grep)
    local mem_dir
    mem_dir=""
    if type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    fi
    memory_ranked_search "$query" "$mem_dir" "$limit"
}

# Inject relevant memories into agent prompts (goal-based)
memory_inject_goal_context() {
    # shellcheck disable=SC2034
    local goal="$1" repo_hash="${2:-}" max_tokens="${3:-2000}"

    local memories
    memories=$(memory_semantic_search "$goal" "$repo_hash" 5 2>/dev/null || echo "[]")

    if [[ "$memories" == "[]" || -z "$memories" ]]; then
        return
    fi

    echo "## Relevant Past Context"
    echo ""
    echo "$memories" | jq -r '.[] | "- [\(.source_type)] \(.content_text | .[0:200])"' 2>/dev/null || true
    echo ""
}

# memory_query_fix_for_error <error_pattern>
# Searches failure memory for known fixes matching the given error pattern.
# Returns JSON with the best fix (highest effectiveness rate) or empty.
memory_query_fix_for_error() {
    local error_pattern="$1"
    [[ -z "$error_pattern" ]] && return 0

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    [[ ! -f "$failures_file" ]] && return 0

    # Search for matching failures with successful fixes
    local matches
    matches=$(jq -r --arg pat "$error_pattern" '
        [.failures[]
        | select(.pattern != null and .pattern != "")
        | select(.pattern | test($pat; "i") // false)
        | select(.fix != null and .fix != "")
        | select((.fix_effectiveness_rate // 0) > 30)
        | {fix, fix_effectiveness_rate, seen_count, category, stage, pattern}]
        | sort_by(-.fix_effectiveness_rate)
        | .[0] // null
    ' "$failures_file" 2>/dev/null) || true

    if [[ -n "$matches" && "$matches" != "null" ]]; then
        echo "$matches"
    fi
}

# memory_closed_loop_inject <error_sig>
# Combines error → memory → fix into injectable text for build retries.
# Returns a one-line summary suitable for goal augmentation.
memory_closed_loop_inject() {
    local error_sig="$1"
    [[ -z "$error_sig" ]] && return 0

    local fix_json
    fix_json=$(memory_query_fix_for_error "$error_sig") || true
    [[ -z "$fix_json" || "$fix_json" == "null" ]] && return 0

    local fix_text success_rate category
    fix_text=$(echo "$fix_json" | jq -r '.fix // ""')
    success_rate=$(echo "$fix_json" | jq -r '.fix_effectiveness_rate // 0')
    category=$(echo "$fix_json" | jq -r '.category // "unknown"')

    [[ -z "$fix_text" ]] && return 0

    echo "[$category, ${success_rate}% success rate] $fix_text"
}

# memory_inject_context <stage_id>
# Returns a text block of relevant memory for a given pipeline stage.
# When intelligence engine is available, uses AI-ranked search for better relevance.
memory_inject_context() {
    local stage_id="${1:-}"

    # Try intelligence-ranked search first
    if type intelligence_search_memory >/dev/null 2>&1; then
        local config="${REPO_DIR:-.}/.claude/daemon-config.json"
        local intel_enabled="false"
        if [[ -f "$config" ]]; then
            intel_enabled=$(jq -r '.intelligence.enabled // false' "$config" 2>/dev/null || echo "false")
        fi
        if [[ "$intel_enabled" == "true" ]]; then
            local ranked_result
            ranked_result=$(intelligence_search_memory "$stage_id stage context" "$(repo_memory_dir)" 5 2>/dev/null || echo "")
            if [[ -n "$ranked_result" ]] && [[ "$ranked_result" != *'"error"'* ]]; then
                echo "$ranked_result"
                return 0
            fi
        fi
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Check that we have memory to inject
    local has_memory=false
    for f in "$mem_dir/patterns.json" "$mem_dir/failures.json" "$mem_dir/decisions.json"; do
        if [[ -f "$f" ]] && [[ "$(wc -c < "$f")" -gt 5 ]]; then
            has_memory=true
            break
        fi
    done

    if [[ "$has_memory" == "false" ]]; then
        info "No memory available for repo (${mem_dir}) — first pipeline run will seed it"
        echo "# No memory available for this repository yet."
        return 0
    fi

    echo "# Shipwright Memory Context"
    echo "# Injected at: $(now_iso)"
    echo "# Stage: ${stage_id}"
    echo ""

    case "$stage_id" in
        plan|design)
            # Past design decisions + codebase patterns
            echo "## Codebase Patterns"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                local proj_type framework lang
                proj_type=$(jq -r '.project.type // "unknown"' "$mem_dir/patterns.json" 2>/dev/null)
                framework=$(jq -r '.project.framework // ""' "$mem_dir/patterns.json" 2>/dev/null)
                lang=$(jq -r '.project.language // ""' "$mem_dir/patterns.json" 2>/dev/null)
                echo "- Project: ${proj_type} / ${framework:-no framework} / ${lang:-unknown}"

                local src_dir test_pat
                src_dir=$(jq -r '.conventions.source_dir // ""' "$mem_dir/patterns.json" 2>/dev/null)
                test_pat=$(jq -r '.conventions.test_pattern // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$src_dir" ]] && echo "- Source directory: ${src_dir}"
                [[ -n "$test_pat" ]] && echo "- Test file pattern: ${test_pat}"
            fi

            echo ""
            echo "## Past Design Decisions"
            if [[ -f "$mem_dir/decisions.json" ]]; then
                jq -r '.decisions[-5:][] | "- [\(.type // "decision")] \(.summary // .description // "no description")"' \
                    "$mem_dir/decisions.json" 2>/dev/null || echo "- No decisions recorded yet."
            fi

            echo ""
            echo "## Known Issues"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                jq -r '.known_issues // [] | .[] | "- \(.)"' "$mem_dir/patterns.json" 2>/dev/null || true
            fi
            ;;

        build)
            # Failure patterns to avoid — ranked by relevance (recency + effectiveness + frequency)
            echo "## Failure Patterns to Avoid"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r 'now as $now |
                    .failures | map(. +
                        { relevance_score:
                            ((.seen_count // 1) * 1) +
                            (if .fix_effectiveness_rate then (.fix_effectiveness_rate / 10) else 0 end) +
                            (if .last_seen then
                                (($now - ((.last_seen | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) // 0)) |
                                 if . < 86400 then 5
                                 elif . < 604800 then 3
                                 elif . < 2592000 then 1
                                 else 0 end)
                            else 0 end)
                        }
                    ) | sort_by(-.relevance_score) | .[:10][] |
                    "- [\(.stage)] \(.pattern) (seen \(.seen_count)x)" +
                    if .fix != "" then
                        "\n  Fix: \(.fix)" +
                        if .fix_effectiveness_rate then " (effectiveness: \(.fix_effectiveness_rate)%)" else "" end
                    else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No failures recorded."
            fi

            echo ""
            echo "## Known Fixes"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.root_cause != "" and .fix != "" and .stage == "build") |
                    "- [\(.category // "unknown")] \(.root_cause)\n  Fix: \(.fix)" +
                    if .fix_effectiveness_rate then " (effectiveness: \(.fix_effectiveness_rate)%)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No analyzed fixes yet."
            else
                echo "- No analyzed fixes yet."
            fi

            echo ""
            echo "## Code Conventions"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                local import_style
                import_style=$(jq -r '.conventions.import_style // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$import_style" ]] && echo "- Import style: ${import_style}"
                local test_runner
                test_runner=$(jq -r '.project.test_runner // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$test_runner" ]] && echo "- Test runner: ${test_runner}"
            fi
            ;;

        test)
            # Known flaky tests + coverage baselines
            echo "## Known Test Failures"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.stage == "test") |
                    "- \(.pattern) (seen \(.seen_count)x)" +
                    if .fix != "" then "\n  Fix: \(.fix)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No test failures recorded."
            fi

            echo ""
            echo "## Known Fixes"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.root_cause != "" and .fix != "" and .stage == "test") |
                    "- [\(.category // "unknown")] \(.root_cause)\n  Fix: \(.fix)"' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No analyzed fixes yet."
            else
                echo "- No analyzed fixes yet."
            fi

            echo ""
            echo "## Performance Baselines"
            if [[ -f "$mem_dir/metrics.json" ]]; then
                local test_dur coverage
                test_dur=$(jq -r '.baselines.test_duration_s // "not tracked"' "$mem_dir/metrics.json" 2>/dev/null)
                coverage=$(jq -r '.baselines.coverage_pct // "not tracked"' "$mem_dir/metrics.json" 2>/dev/null)
                echo "- Test duration baseline: ${test_dur}s"
                echo "- Coverage baseline: ${coverage}%"
            fi
            ;;

        review|compound_quality)
            # Past review feedback patterns
            echo "## Common Review Feedback"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.stage == "review") |
                    "- \(.pattern)"' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No review patterns recorded."
            fi

            echo ""
            echo "## Cross-Repo Learnings"
            if [[ -f "$GLOBAL_MEMORY" ]]; then
                jq -r '.cross_repo_learnings[-5:][] |
                    "- [\(.repo)] \(.type): \(.bugs // 0) bugs, \(.warnings // 0) warnings"' \
                    "$GLOBAL_MEMORY" 2>/dev/null || true
            fi
            ;;

        *)
            # Generic context — use ranked semantic search when intelligence unavailable
            if ! type intelligence_search_memory &>/dev/null 2>&1; then
                local ranked_json
                ranked_json=$(memory_ranked_search "${stage_id} stage context" "$mem_dir" 5 2>/dev/null || echo "[]")
                if [[ -n "$ranked_json" && "$ranked_json" != "[]" ]]; then
                    echo "## Ranked Relevant Memory"
                    echo "$ranked_json" | jq -r '.[]? | "- [\(.source_type)] \(.content_text[0:200])"' 2>/dev/null || true
                    echo ""
                fi
            fi

            echo "## Repository Patterns"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                jq -r 'to_entries | map(select(.key != "known_issues")) | from_entries' \
                    "$mem_dir/patterns.json" 2>/dev/null || true
            fi

            # Inject top failures regardless of category (ranked by relevance)
            echo ""
            echo "## Relevant Failure Patterns"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r --arg stg "$stage_id" \
                    '.failures |
                     map(. + { stage_match: (if .stage == $stg then 10 else 0 end) }) |
                     sort_by(-(.seen_count + .stage_match + (.fix_effectiveness_rate // 0) / 10)) |
                     .[:5][] |
                     "- [\(.stage)] \(.pattern[:80]) (seen \(.seen_count)x)" +
                     if .fix != "" then "\n  Fix: \(.fix)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- None recorded."
            fi

            # Inject recent decisions
            echo ""
            echo "## Recent Decisions"
            if [[ -f "$mem_dir/decisions.json" ]]; then
                jq -r '.decisions[-3:][] |
                    "- [\(.type // "decision")] \(.summary // "no description")"' \
                    "$mem_dir/decisions.json" 2>/dev/null || echo "- None recorded."
            fi
            ;;
    esac

    # ── Cross-repo memory injection (global learnings) ──
    if [[ -f "$GLOBAL_MEMORY" ]]; then
        local global_patterns
        global_patterns=$(jq -r --arg stage "$stage_id" '
            .common_patterns // [] | .[] |
            select(.category == $stage or .category == "general" or .category == null) |
            .summary // .description // empty
        ' "$GLOBAL_MEMORY" 2>/dev/null | head -5 || true)

        local cross_repo_learnings
        cross_repo_learnings=$(jq -r '
            .cross_repo_learnings // [] | .[-5:][] |
            "- [\(.repo // "unknown")] \(.type // "learning"): bugs=\(.bugs // 0), warnings=\(.warnings // 0)"
        ' "$GLOBAL_MEMORY" 2>/dev/null | head -5 || true)

        if [[ -n "$global_patterns" || -n "$cross_repo_learnings" ]]; then
            echo ""
            echo "## Cross-Repo Learnings (Global)"
            [[ -n "$global_patterns" ]] && echo "$global_patterns"
            [[ -n "$cross_repo_learnings" ]] && echo "$cross_repo_learnings"
        fi
    fi

    echo ""
    emit_event "memory.inject" "stage=${stage_id}"
}

# memory_get_actionable_failures [threshold]
# Returns JSON array of failure patterns with seen_count >= threshold.
# Used by daemon patrol to detect recurring failures worth fixing.
memory_get_actionable_failures() {
    local threshold="${1:-3}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    if [[ ! -f "$failures_file" ]]; then
        echo "[]"
        return 0
    fi

    jq --argjson t "$threshold" \
        '[.failures[] | select(.seen_count >= $t)] | sort_by(-.seen_count)' \
        "$failures_file" 2>/dev/null || echo "[]"
}

# memory_get_baseline <metric_name>
# Output baseline value for a metric (bundle_size_kb, test_duration_s, coverage_pct, etc.).
# Used by pipeline for regression checks. Outputs nothing if not set.
memory_get_baseline() {
    local metric_name="${1:-}"
    [[ -z "$metric_name" ]] && return 1
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local metrics_file="$mem_dir/metrics.json"
    [[ ! -f "$metrics_file" ]] && return 0
    jq -r --arg m "$metric_name" '.baselines[$m] // empty' "$metrics_file" 2>/dev/null || true
}

# ─── Weighted Search (RL integration) ──────────────────────────────────────

# Search memory with recency + success weighting.
# Args: $1=query, $2=memory_dir (optional), $3=max_results (default 5)
# Returns JSON array of results with recency_weight applied.
memory_search_weighted() {
    local query="${1:-}"
    local memory_dir="${2:-}"
    local max_results="${3:-5}"

    if [[ -z "$memory_dir" ]] && type repo_memory_dir >/dev/null 2>&1; then
        memory_dir="$(repo_memory_dir)"
    fi
    memory_dir="${memory_dir:-$HOME/.shipwright/memory}"

    if [[ ! -d "$memory_dir" ]]; then
        echo "[]"
        return 0
    fi

    # Get base ranked results
    local base_results
    base_results="$(memory_ranked_search "$query" "$memory_dir" "$max_results" 2>/dev/null || echo "[]")"

    if [[ "$base_results" == "[]" ]] || [[ -z "$base_results" ]]; then
        echo "[]"
        return 0
    fi

    # Apply recency weighting: boost results from files modified recently
    local now_epoch
    now_epoch="$(date +%s)"

    echo "$base_results" | jq --argjson now "$now_epoch" '
        [.[] | . + {
            recency_weight: (
                if .timestamp then
                    (($now - (.timestamp // $now)) / 86400) as $age |
                    if $age <= 7 then 1.5
                    elif $age <= 30 then 1.0
                    elif $age <= 90 then 0.7
                    else 0.4 end
                else 0.8 end
            )
        }] |
        [.[] | .combined_score = ((.relevance // 50) * .recency_weight)] |
        sort_by(-.combined_score)
    ' 2>/dev/null || echo "$base_results"
}
