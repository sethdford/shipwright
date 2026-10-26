#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_CAUSAL_GRAPH_LOADED:-}" ]] && return 0
_CAUSAL_GRAPH_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright causal-graph — Causal Dependency Graph for Root-Cause        ║
# ║  Builds entity-relationship graph from pipeline context                  ║
# ║  Traces failure chains: test → function → variable → config             ║
# ║  Enables causal debugging instead of blind pattern matching              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="4.0.0"

# ─── Output Helpers ──────────────────────────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi

# ─── Configuration ───────────────────────────────────────────────────────────

CAUSAL_GRAPH_FILE="${CAUSAL_GRAPH_FILE:-.claude/causal-graph.json}"
CAUSAL_MAX_DEPTH="${CAUSAL_MAX_DEPTH:-5}"

# ─── Node ID Generation ─────────────────────────────────────────────────────

# ─── Build Graph ─────────────────────────────────────────────────────────────
# Build entity-relationship graph from current pipeline state.
# Analyzes: changed files, functions defined/called, test files, configs.

causal_build_graph() {
    local project_dir="${1:-.}"
    local base_ref="${2:-HEAD~1}"

    info "Building causal dependency graph..."

    # Get changed files
    local changed_files
    changed_files=$(git -C "$project_dir" diff --name-only "$base_ref" 2>/dev/null || true)

    if [[ -z "$changed_files" ]]; then
        changed_files=$(git -C "$project_dir" diff --cached --name-only 2>/dev/null || true)
    fi

    if [[ -z "$changed_files" ]]; then
        warn "No changed files detected — building minimal graph"
    fi

    local nodes=""
    local edges=""
    local node_count=0
    local edge_count=0

    # ─── Pass 1: Create file nodes ───────────────────────────────────────
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "${project_dir}/${file}" ]] && continue

        local file_type="source"
        if echo "$file" | grep >/dev/null -iE '(test|spec)'; then
            file_type="test"
        elif echo "$file" | grep >/dev/null -iE '(config|\.json$|\.ya?ml$|\.toml$|\.env)'; then
            file_type="config"
        fi

        local node
        node=$(printf '{"id":"file:%s","type":"file","subtype":"%s","name":"%s"}' \
            "$file" "$file_type" "$file")

        if [[ -n "$nodes" ]]; then
            nodes="${nodes},${node}"
        else
            nodes="${node}"
        fi
        node_count=$((node_count + 1))
    done <<< "$changed_files"

    # ─── Pass 2: Extract functions from changed files ────────────────────
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "${project_dir}/${file}" ]] && continue

        local ext="${file##*.}"
        local func_pattern=""

        case "$ext" in
            sh|bash)
                func_pattern='^\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)'
                ;;
            ts|js|tsx|jsx)
                func_pattern='(function\s+[a-zA-Z_]\w*|const\s+[a-zA-Z_]\w*\s*=\s*(async\s+)?\(|export\s+(async\s+)?function)'
                ;;
            py)
                func_pattern='^\s*def\s+[a-zA-Z_]\w*'
                ;;
            go)
                func_pattern='^\s*func\s+[a-zA-Z_]\w*'
                ;;
            rs)
                func_pattern='^\s*(pub\s+)?fn\s+[a-zA-Z_]\w*'
                ;;
            *)
                continue
                ;;
        esac

        local funcs
        funcs=$(grep -oE "$func_pattern" "${project_dir}/${file}" 2>/dev/null | \
            sed 's/.*function\s\+//' | sed 's/.*def\s\+//' | sed 's/.*func\s\+//' | \
            sed 's/.*fn\s\+//' | sed 's/.*const\s\+//' | \
            sed 's/\s*[=(].*//' | tr -d '(){}' | sort -u | head -20 || true)

        while IFS= read -r func; do
            [[ -z "$func" ]] && continue
            func=$(echo "$func" | tr -d ' ')
            [[ -z "$func" ]] && continue

            local node
            node=$(printf '{"id":"func:%s:%s","type":"function","name":"%s","file":"%s"}' \
                "$file" "$func" "$func" "$file")
            nodes="${nodes},${node}"
            node_count=$((node_count + 1))

            # Edge: file contains function
            local edge
            edge=$(printf '{"from":"file:%s","to":"func:%s:%s","type":"defines"}' \
                "$file" "$file" "$func")
            if [[ -n "$edges" ]]; then
                edges="${edges},${edge}"
            else
                edges="${edge}"
            fi
            edge_count=$((edge_count + 1))
        done <<< "$funcs"

    done <<< "$changed_files"

    # ─── Pass 3: Find cross-file dependencies ───────────────────────────
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "${project_dir}/${file}" ]] && continue

        # Find imports/requires/sources from this file
        local imports
        imports=$(grep -oE "(import|require|source|from)\s+['\"]([^'\"]+)['\"]" "${project_dir}/${file}" 2>/dev/null | \
            sed "s/.*['\"]//;s/['\"].*//" | head -20 || true)

        while IFS= read -r imp; do
            [[ -z "$imp" ]] && continue

            # Check if imported file is in our changed set
            local match
            match=$(echo "$changed_files" | grep -F "$imp" | head -1 || true)

            if [[ -n "$match" ]]; then
                local edge
                edge=$(printf '{"from":"file:%s","to":"file:%s","type":"imports"}' "$file" "$match")
                if [[ -n "$edges" ]]; then
                    edges="${edges},${edge}"
                else
                    edges="${edge}"
                fi
                edge_count=$((edge_count + 1))
            fi
        done <<< "$imports"

    done <<< "$changed_files"

    # ─── Pass 4: Find test → source relationships ───────────────────────
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if ! echo "$file" | grep >/dev/null -iE '(test|spec)'; then
            continue
        fi
        [[ ! -f "${project_dir}/${file}" ]] && continue

        # Test files typically import/source the file they test
        local tested_files
        tested_files=$(grep -oE "(import|require|source)\s+['\"]([^'\"]+)['\"]" "${project_dir}/${file}" 2>/dev/null | \
            sed "s/.*['\"]//;s/['\"].*//" | head -10 || true)

        while IFS= read -r tf; do
            [[ -z "$tf" ]] && continue
            local match
            match=$(echo "$changed_files" | grep -F "$tf" | head -1 || true)
            if [[ -n "$match" ]]; then
                local edge
                edge=$(printf '{"from":"file:%s","to":"file:%s","type":"tests"}' "$file" "$match")
                if [[ -n "$edges" ]]; then
                    edges="${edges},${edge}"
                else
                    edges="${edge}"
                fi
                edge_count=$((edge_count + 1))
            fi
        done <<< "$tested_files"
    done <<< "$changed_files"

    # ─── Write Graph ─────────────────────────────────────────────────────
    mkdir -p "$(dirname "$CAUSAL_GRAPH_FILE")"

    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "${CAUSAL_GRAPH_FILE}.raw")
    cat > "$tmp_file" <<EOF
{
  "built_at": "$(now_iso)",
  "base_ref": "${base_ref}",
  "node_count": ${node_count},
  "edge_count": ${edge_count},
  "nodes": [${nodes}],
  "edges": [${edges}]
}
EOF

    # Pretty-print if jq available, then atomic move
    if command -v jq >/dev/null 2>&1; then
        if jq '.' "$tmp_file" > "${CAUSAL_GRAPH_FILE}.pp" 2>/dev/null; then
            mv "${CAUSAL_GRAPH_FILE}.pp" "$CAUSAL_GRAPH_FILE"
        else
            mv "$tmp_file" "$CAUSAL_GRAPH_FILE"
        fi
    else
        mv "$tmp_file" "$CAUSAL_GRAPH_FILE"
    fi
    rm -f "$tmp_file" "${CAUSAL_GRAPH_FILE}.pp" "${CAUSAL_GRAPH_FILE}.raw" 2>/dev/null || true

    success "Causal graph: ${node_count} nodes, ${edge_count} edges"

    if type emit_event >/dev/null 2>&1; then
        emit_event "causal_graph_built" \
            "nodes=${node_count}" \
            "edges=${edge_count}" \
            "base_ref=${base_ref}"
    fi

    return 0
}

# ─── Trace Failure ───────────────────────────────────────────────────────────
# Given a failing test file, trace the causal chain to identify root cause.
# Returns JSON with the causal chain and suggested root cause.

causal_trace_failure() {
    local failing_test="${1:-}"
    local project_dir="${2:-.}"

    if [[ -z "$failing_test" ]]; then
        error "causal_trace_failure requires a failing test file path"
        return 1
    fi

    if [[ ! -f "$CAUSAL_GRAPH_FILE" ]]; then
        warn "No causal graph — building now..."
        causal_build_graph "$project_dir"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq required for causal tracing"
        return 1
    fi

    info "Tracing causal chain for: ${failing_test}"

    local chain=""
    local current="file:${failing_test}"
    local visited=""
    local depth=0

    # BFS through graph following edges from test → source → dependencies
    while [[ "$depth" -lt "$CAUSAL_MAX_DEPTH" ]]; do
        # Find all edges FROM current node
        local targets
        targets=$(jq -r --arg from "$current" \
            '.edges[] | select(.from == $from) | "\(.to)|\(.type)"' \
            "$CAUSAL_GRAPH_FILE" 2>/dev/null || true)

        if [[ -z "$targets" ]]; then
            break
        fi

        while IFS='|' read -r target edge_type; do
            [[ -z "$target" ]] && continue

            # Skip already visited
            if echo "$visited" | grep >/dev/null -F "$target" 2>/dev/null; then
                continue
            fi
            visited="${visited} ${target}"

            local node_info
            node_info=$(jq -c --arg id "$target" '.nodes[] | select(.id == $id)' \
                "$CAUSAL_GRAPH_FILE" 2>/dev/null || echo "{}")

            local entry
            entry=$(printf '{"node":"%s","edge_type":"%s","depth":%d,"info":%s}' \
                "$target" "$edge_type" "$depth" "${node_info:-\"{}\"}")

            if [[ -n "$chain" ]]; then
                chain="${chain},${entry}"
            else
                chain="${entry}"
            fi

            # Follow the chain deeper for source files
            if echo "$target" | grep >/dev/null "^file:"; then
                current="$target"
            fi
        done <<< "$targets"

        depth=$((depth + 1))
    done

    # Identify likely root cause (deepest source file in chain)
    local root_cause=""
    if [[ -n "$chain" ]]; then
        root_cause=$(echo "[${chain}]" | jq -r \
            '[.[] | select(.edge_type != "tests")] | last | .node // "unknown"' 2>/dev/null || echo "unknown")
    fi

    # Build trace result
    local trace_file="${CAUSAL_GRAPH_FILE%.json}-trace.json"
    cat > "$trace_file" <<EOF
{
  "traced_at": "$(now_iso)",
  "failing_test": "${failing_test}",
  "root_cause": "${root_cause}",
  "chain_depth": ${depth},
  "chain": [${chain}]
}
EOF

    if [[ "$root_cause" != "unknown" && -n "$root_cause" ]]; then
        success "Root cause identified: ${root_cause}"
    else
        warn "Could not determine root cause from graph (may need deeper analysis)"
    fi

    if type emit_event >/dev/null 2>&1; then
        emit_event "causal_trace_completed" \
            "test=${failing_test}" \
            "root_cause=${root_cause}" \
            "depth=${depth}"
    fi

    echo "$trace_file"
    return 0
}

# ─── Find Dependencies ──────────────────────────────────────────────────────
# Find all entities affected by a change to a given file/function.

causal_find_dependencies() {
    local node_id="${1:-}"

    if [[ -z "$node_id" ]]; then
        error "causal_find_dependencies requires a node ID (e.g., file:src/foo.ts)"
        return 1
    fi

    if [[ ! -f "$CAUSAL_GRAPH_FILE" ]]; then
        warn "No causal graph available"
        return 1
    fi

    # Find all nodes that depend on this one (reverse edge traversal)
    local dependents
    dependents=$(jq -r --arg to "$node_id" \
        '.edges[] | select(.to == $to) | .from' \
        "$CAUSAL_GRAPH_FILE" 2>/dev/null || true)

    if [[ -z "$dependents" ]]; then
        info "No dependents found for ${node_id}"
        return 0
    fi

    echo "Dependents of ${node_id}:"
    echo "$dependents" | while IFS= read -r dep; do
        local dep_info
        dep_info=$(jq -r --arg id "$dep" '.nodes[] | select(.id == $id) | "\(.type): \(.name)"' \
            "$CAUSAL_GRAPH_FILE" 2>/dev/null || echo "$dep")
        echo "  - ${dep_info}"
    done

    return 0
}

# ─── Suggest Fix ─────────────────────────────────────────────────────────────
# Given a causal trace, suggest what to fix based on the root cause type.

causal_suggest_fix() {
    local trace_file="${1:-}"

    if [[ ! -f "$trace_file" ]]; then
        error "Trace file not found: ${trace_file}"
        return 1
    fi

    local root_cause
    root_cause=$(jq -r '.root_cause // "unknown"' "$trace_file" 2>/dev/null)

    if [[ "$root_cause" == "unknown" ]]; then
        echo "Unable to suggest fix — root cause not identified"
        return 1
    fi

    # Extract file type from root cause
    local cause_file
    cause_file=$(echo "$root_cause" | sed 's/^file://')

    echo "Suggested fix approach:"
    echo "  Root cause: ${cause_file}"

    if echo "$cause_file" | grep >/dev/null -iE '(config|\.json$|\.ya?ml$|\.env)'; then
        echo "  Type: Configuration issue"
        echo "  Action: Check config values, defaults, and schema validation"
    elif echo "$cause_file" | grep >/dev/null -iE '(test|spec)'; then
        echo "  Type: Test issue (test itself may be wrong)"
        echo "  Action: Review test assertions and expected values"
    else
        echo "  Type: Source code issue"
        echo "  Action: Review recent changes to ${cause_file}"
        echo "  Hint: Check git diff for this file and verify logic correctness"
    fi

    # Show the causal chain for context
    echo ""
    echo "Causal chain:"
    jq -r '.chain[] | "  \(.edge_type): \(.node)"' "$trace_file" 2>/dev/null

    return 0
}

# ─── Graph Status ────────────────────────────────────────────────────────────

