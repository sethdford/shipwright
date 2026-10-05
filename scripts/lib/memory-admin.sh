#!/usr/bin/env bash
# Memory admin — Show, search, forget, export/import memory data
# Depends on: memory-common.sh, memory-query.sh (memory_semantic_search)

[[ -n "${_MEMORY_ADMIN_LOADED:-}" ]] && return 0
_MEMORY_ADMIN_LOADED=1

# memory_show — display memory for current repo
memory_show() {
    local show_global=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) show_global=true; shift ;;
            *)        shift ;;
        esac
    done

    if [[ "$show_global" == "true" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Global Memory ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        if [[ -f "$GLOBAL_MEMORY" ]]; then
            local learning_count
            learning_count=$(jq '.cross_repo_learnings | length' "$GLOBAL_MEMORY" 2>/dev/null || echo 0)
            echo -e "  Cross-repo learnings: ${CYAN}${learning_count}${RESET}"
            echo ""
            if [[ "$learning_count" -gt 0 ]]; then
                jq -r '.cross_repo_learnings[-10:][] |
                    "  \(.repo) — \(.type) (\(.captured_at // "unknown"))"' \
                    "$GLOBAL_MEMORY" 2>/dev/null || true
            fi
        else
            echo -e "  ${DIM}No global memory yet.${RESET}"
        fi
        echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        return 0
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory: ${repo} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # Patterns
    echo -e "${BOLD}  PROJECT${RESET}"
    if [[ -f "$mem_dir/patterns.json" ]]; then
        local proj_type framework lang pkg_mgr test_runner
        proj_type=$(jq -r '.project.type // "unknown"' "$mem_dir/patterns.json" 2>/dev/null)
        framework=$(jq -r '.project.framework // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        lang=$(jq -r '.project.language // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        pkg_mgr=$(jq -r '.project.package_manager // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        test_runner=$(jq -r '.project.test_runner // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        printf "    %-18s %s\n" "Type:" "$proj_type"
        printf "    %-18s %s\n" "Framework:" "$framework"
        printf "    %-18s %s\n" "Language:" "$lang"
        printf "    %-18s %s\n" "Package manager:" "$pkg_mgr"
        printf "    %-18s %s\n" "Test runner:" "$test_runner"
    else
        echo -e "    ${DIM}No patterns captured yet.${RESET}"
    fi
    echo ""

    # Failures
    echo -e "${BOLD}  FAILURE PATTERNS${RESET}"
    if [[ -f "$mem_dir/failures.json" ]]; then
        local failure_count
        failure_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null || echo 0)
        if [[ "$failure_count" -gt 0 ]]; then
            jq -r '.failures | sort_by(-.seen_count) | .[:5][] |
                "    [\(.stage)] \(.pattern[:80]) — seen \(.seen_count)x"' \
                "$mem_dir/failures.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No failures recorded.${RESET}"
        fi
    else
        echo -e "    ${DIM}No failures recorded.${RESET}"
    fi
    echo ""

    # Decisions
    echo -e "${BOLD}  DECISIONS${RESET}"
    if [[ -f "$mem_dir/decisions.json" ]]; then
        local decision_count
        decision_count=$(jq '.decisions | length' "$mem_dir/decisions.json" 2>/dev/null || echo 0)
        if [[ "$decision_count" -gt 0 ]]; then
            jq -r '.decisions[-5:][] |
                "    [\(.type)] \(.summary)"' \
                "$mem_dir/decisions.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No decisions recorded.${RESET}"
        fi
    else
        echo -e "    ${DIM}No decisions recorded.${RESET}"
    fi
    echo ""

    # Metrics
    echo -e "${BOLD}  BASELINES${RESET}"
    if [[ -f "$mem_dir/metrics.json" ]]; then
        local baseline_count
        baseline_count=$(jq '.baselines | length' "$mem_dir/metrics.json" 2>/dev/null || echo 0)
        if [[ "$baseline_count" -gt 0 ]]; then
            jq -r '.baselines | to_entries[] | "    \(.key): \(.value)"' \
                "$mem_dir/metrics.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No baselines tracked yet.${RESET}"
        fi
    else
        echo -e "    ${DIM}No baselines tracked yet.${RESET}"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# memory_search — search memory
memory_search() {
    if [[ "${1:-}" == "--semantic" ]]; then
        shift
        memory_semantic_search "$*" "" 10
        exit 0
    fi

    local keyword="${1:-}"

    if [[ -z "$keyword" ]]; then
        error "Usage: shipwright memory search <keyword>"
        echo -e "  ${DIM}Or: shipwright memory search --semantic <query>${RESET}"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory Search: \"${keyword}\" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    local found=0

    # ── Semantic search via intelligence (if available) ──
    if type intelligence_search_memory >/dev/null 2>&1; then
        local semantic_results
        semantic_results=$(intelligence_search_memory "$keyword" "$mem_dir" 5 2>/dev/null || echo "")
        if [[ -n "$semantic_results" ]] && echo "$semantic_results" | jq -e '.results | length > 0' >/dev/null 2>&1; then
            echo -e "  ${BOLD}${CYAN}Semantic Results (AI-ranked):${RESET}"
            local result_count
            result_count=$(echo "$semantic_results" | jq '.results | length')
            local i=0
            while [[ "$i" -lt "$result_count" ]]; do
                local file rel summary
                file=$(echo "$semantic_results" | jq -r ".results[$i].file // \"\"")
                rel=$(echo "$semantic_results" | jq -r ".results[$i].relevance // 0")
                summary=$(echo "$semantic_results" | jq -r ".results[$i].summary // \"\"")
                echo -e "    ${GREEN}●${RESET} [${rel}%] ${BOLD}${file}${RESET} — ${summary}"
                i=$((i + 1))
            done
            echo ""
            found=$((found + 1))

            # Also run grep search below for completeness
            echo -e "  ${DIM}Grep results (supplemental):${RESET}"
            echo ""
        fi
    fi

    # ── Grep-based search (fallback / supplemental) ──

    # Search patterns
    if [[ -f "$mem_dir/patterns.json" ]]; then
        local pattern_matches
        pattern_matches=$(grep -i "$keyword" "$mem_dir/patterns.json" 2>/dev/null || true)
        if [[ -n "$pattern_matches" ]]; then
            echo -e "  ${BOLD}Patterns:${RESET}"
            echo "$pattern_matches" | head -5 | sed 's/^/    /'
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search failures
    if [[ -f "$mem_dir/failures.json" ]]; then
        local failure_matches
        failure_matches=$(jq -r --arg kw "$keyword" \
            '.failures[] | select(.pattern | test($kw; "i")) |
            "    [\(.stage)] \(.pattern[:80]) — seen \(.seen_count)x"' \
            "$mem_dir/failures.json" 2>/dev/null || true)
        if [[ -n "$failure_matches" ]]; then
            echo -e "  ${BOLD}Failures:${RESET}"
            echo "$failure_matches" | head -5
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search decisions
    if [[ -f "$mem_dir/decisions.json" ]]; then
        local decision_matches
        decision_matches=$(jq -r --arg kw "$keyword" \
            '.decisions[] | select((.summary // "") | test($kw; "i")) |
            "    [\(.type)] \(.summary)"' \
            "$mem_dir/decisions.json" 2>/dev/null || true)
        if [[ -n "$decision_matches" ]]; then
            echo -e "  ${BOLD}Decisions:${RESET}"
            echo "$decision_matches" | head -5
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search global memory
    if [[ -f "$GLOBAL_MEMORY" ]]; then
        local global_matches
        global_matches=$(grep -i "$keyword" "$GLOBAL_MEMORY" 2>/dev/null || true)
        if [[ -n "$global_matches" ]]; then
            echo -e "  ${BOLD}Global Memory:${RESET}"
            echo "$global_matches" | head -3 | sed 's/^/    /'
            echo ""
            found=$((found + 1))
        fi
    fi

    if [[ "$found" -eq 0 ]]; then
        echo -e "  ${DIM}No matches found for \"${keyword}\".${RESET}"
    fi

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# memory_forget — clear memory
memory_forget() {
    local forget_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) forget_all=true; shift ;;
            *)     shift ;;
        esac
    done

    if [[ "$forget_all" == "true" ]]; then
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        if [[ -d "$mem_dir" ]]; then
            rm -rf "$mem_dir"
            success "Cleared all memory for $(repo_name)"
            emit_event "memory.forget" "repo=$(repo_name)" "scope=all"
        else
            warn "No memory found for this repository."
        fi
    else
        error "Usage: shipwright memory forget --all"
        echo -e "  ${DIM}Use --all to confirm clearing memory for this repo.${RESET}"
        return 1
    fi
}

# memory_export — export memory as JSON
memory_export() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Ensure all memory files exist (jq --slurpfile fails on missing files)
    for f in patterns.json failures.json decisions.json metrics.json; do
        [[ -f "$mem_dir/$f" ]] || echo '{}' > "$mem_dir/$f"
    done

    # Merge all memory files into a single JSON export
    local export_json
    export_json=$(jq -n \
        --arg repo "$(repo_name)" \
        --arg hash "$(repo_hash)" \
        --arg ts "$(now_iso)" \
        --slurpfile patterns "$mem_dir/patterns.json" \
        --slurpfile failures "$mem_dir/failures.json" \
        --slurpfile decisions "$mem_dir/decisions.json" \
        --slurpfile metrics "$mem_dir/metrics.json" \
        '{
            exported_at: $ts,
            repo: $repo,
            repo_hash: $hash,
            patterns: $patterns[0],
            failures: $failures[0],
            decisions: $decisions[0],
            metrics: $metrics[0]
        }')

    echo "$export_json"
    emit_event "memory.export" "repo=$(repo_name)"
}

# memory_import — import memory from JSON
memory_import() {
    local import_file="${1:-}"

    if [[ -z "$import_file" || ! -f "$import_file" ]]; then
        error "Usage: shipwright memory import <file.json>"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$import_file" 2>/dev/null; then
        error "Invalid JSON file: $import_file"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Extract and write each section
    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN

    jq '.patterns // {}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/patterns.json"
    jq '.failures // {"failures":[]}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/failures.json"
    jq '.decisions // {"decisions":[]}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/decisions.json"
    jq '.metrics // {"baselines":{}}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/metrics.json"

    success "Imported memory from ${import_file}"
    emit_event "memory.import" "repo=$(repo_name)" "file=${import_file}"
}
