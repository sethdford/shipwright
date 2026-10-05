#!/usr/bin/env bash
# Memory common — storage paths, repo identity, embedding store helpers

[[ -n "${_MEMORY_COMMON_LOADED:-}" ]] && return 0
_MEMORY_COMMON_LOADED=1

# ─── Memory Storage Paths ──────────────────────────────────────────────
MEMORY_ROOT="${HOME}/.shipwright/memory"
GLOBAL_MEMORY="${MEMORY_ROOT}/global.json"

# ─── Domain keyword expansion (shared semantic concept) ──────────────────────

_expand_domain_keywords() {
    local text="$1"
    local expanded="$text"

    local dom
    for dom in auth api db ui test deploy error perf; do
        case "$dom" in
            auth)   [[ "$text" =~ [aA]uth ]] && expanded="$expanded authentication authorization login session token credential permission access" ;;
            api)    [[ "$text" =~ [aA]pi ]]  && expanded="$expanded endpoint route handler request response rest graphql" ;;
            db)     [[ "$text" =~ [dD]b ]]   && expanded="$expanded database query migration schema model table sql" ;;
            ui)     [[ "$text" =~ [uU]i ]]   && expanded="$expanded component view render template layout style css frontend" ;;
            test)   [[ "$text" =~ [tT]est ]] && expanded="$expanded testing assertion coverage mock stub fixture spec" ;;
            deploy) [[ "$text" =~ [dD]eploy ]] && expanded="$expanded deployment release publish ship ci cd pipeline" ;;
            error)  [[ "$text" =~ [eE]rror ]] && expanded="$expanded exception failure crash bug issue defect" ;;
            perf)   [[ "$text" =~ [pP]erf ]] && expanded="$expanded performance optimization speed latency throughput cache" ;;
        esac
    done

    echo "$expanded"
}

# ─── Embedding & Semantic Search ───────────────────────────────────────────

# Generate content hash for deduplication
_memory_content_hash() {
    echo -n "$1" | shasum -a 256 | cut -d' ' -f1
}

# Store a memory with its text content for future embedding
memory_store_for_embedding() {
    local source_type="$1" content_text="$2" repo_hash="${3:-}"
    local content_hash
    content_hash=$(_memory_content_hash "$content_text")

    if type db_save_embedding >/dev/null 2>&1; then
        db_save_embedding "$content_hash" "$source_type" "$content_text" "$repo_hash" 2>/dev/null || true
    fi
}

# Check if vector embeddings search is available (future: SQLite vec0, etc.)
_has_embeddings() {
    return 1  # No embedding-based search yet
}

# Get a deterministic hash for the current repo
repo_hash() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    echo -n "$origin" | shasum -a 256 | cut -c1-12
}

repo_name() {
    git config --get remote.origin.url 2>/dev/null \
        | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|' \
        | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|' \
        || echo "local"
}

repo_memory_dir() {
    echo "${MEMORY_ROOT}/$(repo_hash)"
}

ensure_memory_dir() {
    local dir
    dir="$(repo_memory_dir)"
    mkdir -p "$dir"

    # Initialize empty JSON files if they don't exist
    [[ -f "$dir/patterns.json" ]]  || echo '{}' > "$dir/patterns.json"
    [[ -f "$dir/failures.json" ]]  || echo '{"failures":[]}' > "$dir/failures.json"
    [[ -f "$dir/decisions.json" ]] || echo '{"decisions":[]}' > "$dir/decisions.json"
    [[ -f "$dir/metrics.json" ]]   || echo '{"baselines":{}}' > "$dir/metrics.json"

    # Initialize global memory if missing
    mkdir -p "$MEMORY_ROOT"
    [[ -f "$GLOBAL_MEMORY" ]] || echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$GLOBAL_MEMORY"
}
