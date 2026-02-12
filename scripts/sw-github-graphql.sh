#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-graphql — GitHub GraphQL API Client                  ║
# ║  Code history · Blame data · Contributors · Security alerts            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.9.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Cache Configuration ───────────────────────────────────────────────────
GH_CACHE_DIR="${HOME}/.shipwright/github-cache"

# ═══════════════════════════════════════════════════════════════════════════════
# AVAILABILITY CHECK
# ═══════════════════════════════════════════════════════════════════════════════

_gh_graphql_available() {
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        return 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        return 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CACHE LAYER
# ═══════════════════════════════════════════════════════════════════════════════

_gh_cache_init() {
    mkdir -p "$GH_CACHE_DIR"
}

_gh_cache_get() {
    local cache_key="$1"
    local ttl_seconds="${2:-3600}"
    local cache_file="${GH_CACHE_DIR}/${cache_key}.json"

    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    # Check file age
    local file_epoch now
    if [[ "$(uname)" == "Darwin" ]]; then
        file_epoch=$(stat -f '%m' "$cache_file" 2>/dev/null || echo "0")
    else
        file_epoch=$(stat -c '%Y' "$cache_file" 2>/dev/null || echo "0")
    fi
    now=$(now_epoch)
    local age=$(( now - file_epoch ))

    if [[ "$age" -gt "$ttl_seconds" ]]; then
        return 1
    fi

    cat "$cache_file"
    return 0
}

_gh_cache_set() {
    local cache_key="$1"
    local content="$2"
    _gh_cache_init
    local cache_file="${GH_CACHE_DIR}/${cache_key}.json"
    local tmp_file="${cache_file}.tmp.$$"
    printf '%s\n' "$content" > "$tmp_file"
    mv "$tmp_file" "$cache_file"
}

_gh_cache_clear() {
    if [[ -d "$GH_CACHE_DIR" ]]; then
        rm -rf "$GH_CACHE_DIR"
        _gh_cache_init
        success "GitHub cache cleared"
    else
        info "No cache to clear"
    fi
}

_gh_cache_stats() {
    _gh_cache_init
    local count=0
    local total_size=0
    local oldest=""
    local newest=""

    for f in "$GH_CACHE_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        count=$((count + 1))
        local size
        if [[ "$(uname)" == "Darwin" ]]; then
            size=$(stat -f '%z' "$f" 2>/dev/null || echo "0")
        else
            size=$(stat -c '%s' "$f" 2>/dev/null || echo "0")
        fi
        total_size=$((total_size + size))
    done

    echo -e "${CYAN}${BOLD}GitHub API Cache${RESET}"
    echo -e "  ${DIM}Directory:${RESET}  $GH_CACHE_DIR"
    echo -e "  ${DIM}Entries:${RESET}    $count"
    echo -e "  ${DIM}Total size:${RESET} $((total_size / 1024))KB"
}

# ═══════════════════════════════════════════════════════════════════════════════
# REPO DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

GH_OWNER=""
GH_REPO=""

_gh_detect_repo() {
    if [[ -n "$GH_OWNER" && -n "$GH_REPO" ]]; then
        return 0
    fi

    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || true)

    if [[ -z "$remote_url" ]]; then
        error "No git remote 'origin' found"
        return 1
    fi

    # Handle SSH: git@github.com:owner/repo.git
    if [[ "$remote_url" =~ git@github\.com:([^/]+)/([^/.]+)(\.git)?$ ]]; then
        GH_OWNER="${BASH_REMATCH[1]}"
        GH_REPO="${BASH_REMATCH[2]}"
        return 0
    fi

    # Handle HTTPS: https://github.com/owner/repo.git
    if [[ "$remote_url" =~ github\.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
        GH_OWNER="${BASH_REMATCH[1]}"
        GH_REPO="${BASH_REMATCH[2]}"
        return 0
    fi

    error "Could not parse owner/repo from remote: $remote_url"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# CORE GRAPHQL EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

gh_graphql() {
    local query="$1"
    local variables="${2:-{\}}"

    if ! _gh_graphql_available; then
        echo '{"error": "GitHub API not available"}'
        return 1
    fi

    local result
    result=$(gh api graphql -f query="$query" --input - <<< "$variables" 2>/dev/null) || {
        error "GraphQL query failed"
        echo '{"error": "query failed"}'
        return 1
    }

    # Check for GraphQL errors
    local has_errors
    has_errors=$(echo "$result" | jq 'has("errors")' 2>/dev/null || echo "false")
    if [[ "$has_errors" == "true" ]]; then
        local err_msg
        err_msg=$(echo "$result" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null)
        warn "GraphQL error: $err_msg"
    fi

    echo "$result"
}

gh_graphql_cached() {
    local cache_key="$1"
    local ttl_seconds="$2"
    local query="$3"
    local variables="${4:-{\}}"

    # Try cache first
    local cached
    cached=$(_gh_cache_get "$cache_key" "$ttl_seconds" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    # Cache miss — execute query
    local result
    result=$(gh_graphql "$query" "$variables") || return $?

    # Cache the result
    _gh_cache_set "$cache_key" "$result"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$result"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DATA QUERIES
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# File change frequency — commit count for a path in last N days
# ──────────────────────────────────────────────────────────────────────────────
gh_file_change_frequency() {
    local owner="$1"
    local repo="$2"
    local path="$3"
    local days="${4:-30}"

    if ! _gh_graphql_available; then
        echo "0"
        return 0
    fi

    local since
    if [[ "$(uname)" == "Darwin" ]]; then
        since=$(date -u -v-"${days}d" +"%Y-%m-%dT%H:%M:%SZ")
    else
        since=$(date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ")
    fi

    local cache_key="freq_${owner}_${repo}_$(echo "$path" | tr '/' '_')_${days}d"

    local query='query($owner: String!, $repo: String!, $since: GitTimestamp!) {
  repository(owner: $owner, name: $repo) {
    defaultBranchRef {
      target {
        ... on Commit {
          history(since: $since) {
            totalCount
          }
        }
      }
    }
  }
}'

    local variables
    variables=$(jq -n --arg owner "$owner" --arg repo "$repo" --arg since "$since" \
        '{owner: $owner, repo: $repo, since: $since}')

    local result
    result=$(gh_graphql_cached "$cache_key" "3600" "$query" "$variables") || {
        echo "0"
        return 0
    }

    local count
    count=$(echo "$result" | jq -r '.data.repository.defaultBranchRef.target.history.totalCount // 0' 2>/dev/null || echo "0")
    echo "$count"
}

# ──────────────────────────────────────────────────────────────────────────────
# Blame data — commit authors and counts for a file
# ──────────────────────────────────────────────────────────────────────────────
gh_blame_data() {
    local owner="$1"
    local repo="$2"
    local path="$3"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    local cache_key="blame_${owner}_${repo}_$(echo "$path" | tr '/' '_')"
    local cached
    cached=$(_gh_cache_get "$cache_key" "14400" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    # Use REST API for commit history on path
    local result
    result=$(gh api "repos/${owner}/${repo}/commits?path=${path}&per_page=100" 2>/dev/null) || {
        echo "[]"
        return 0
    }

    # Parse commit authors and aggregate
    local parsed
    parsed=$(echo "$result" | jq '[group_by(.commit.author.name) | .[] |
        {
            author: .[0].commit.author.name,
            commits: length,
            last_commit: (sort_by(.commit.author.date) | last | .commit.author.date)
        }] | sort_by(-.commits)' 2>/dev/null || echo "[]")

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Contributors — repo contributor list with commit counts
# ──────────────────────────────────────────────────────────────────────────────
gh_contributors() {
    local owner="$1"
    local repo="$2"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    local cache_key="contrib_${owner}_${repo}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "86400" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    local result
    result=$(gh api "repos/${owner}/${repo}/contributors?per_page=100" 2>/dev/null) || {
        echo "[]"
        return 0
    }

    local parsed
    parsed=$(echo "$result" | jq '[.[] | {login: .login, contributions: .contributions}]' 2>/dev/null || echo "[]")

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Similar issues — closed issues matching search text
# ──────────────────────────────────────────────────────────────────────────────
gh_similar_issues() {
    local owner="$1"
    local repo="$2"
    local search_text="$3"
    local limit="${4:-5}"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    # Truncate search text to 100 chars (API limit)
    if [[ ${#search_text} -gt 100 ]]; then
        search_text="${search_text:0:100}"
    fi

    local search_query="repo:${owner}/${repo} is:issue is:closed ${search_text}"
    local cache_key="similar_${owner}_${repo}_$(echo "$search_text" | tr ' /' '__' | head -c 50)"

    local query='query($q: String!, $limit: Int!) {
  search(query: $q, type: ISSUE, first: $limit) {
    nodes {
      ... on Issue {
        number
        title
        closedAt
        labels(first: 10) {
          nodes { name }
        }
      }
    }
  }
}'

    local variables
    variables=$(jq -n --arg q "$search_query" --argjson limit "$limit" \
        '{q: $q, limit: $limit}')

    local result
    result=$(gh_graphql_cached "$cache_key" "3600" "$query" "$variables") || {
        echo "[]"
        return 0
    }

    echo "$result" | jq '[.data.search.nodes[] |
        {
            number: .number,
            title: .title,
            labels: [.labels.nodes[].name],
            closedAt: .closedAt
        }]' 2>/dev/null || echo "[]"
}

# ──────────────────────────────────────────────────────────────────────────────
# Commit history — recent commits touching a path
# ──────────────────────────────────────────────────────────────────────────────
gh_commit_history() {
    local owner="$1"
    local repo="$2"
    local path="$3"
    local limit="${4:-10}"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    local cache_key="history_${owner}_${repo}_$(echo "$path" | tr '/' '_')_${limit}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "3600" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    local result
    result=$(gh api "repos/${owner}/${repo}/commits?path=${path}&per_page=${limit}" 2>/dev/null) || {
        echo "[]"
        return 0
    }

    local parsed
    parsed=$(echo "$result" | jq '[.[] | {
        sha: .sha[0:7],
        message: (.commit.message | split("\n")[0]),
        author: .commit.author.name,
        date: .commit.author.date
    }]' 2>/dev/null || echo "[]")

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Branch protection — protection rules for a branch
# ──────────────────────────────────────────────────────────────────────────────
gh_branch_protection() {
    local owner="$1"
    local repo="$2"
    local branch="${3:-main}"

    if ! _gh_graphql_available; then
        echo '{"protected": false}'
        return 0
    fi

    local cache_key="protection_${owner}_${repo}_${branch}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "3600" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    local result
    result=$(gh api "repos/${owner}/${repo}/branches/${branch}/protection" 2>/dev/null) || {
        # 404 = no protection rules
        local parsed='{"protected": false}'
        _gh_cache_set "$cache_key" "$parsed"
        echo "$parsed"
        return 0
    }

    local parsed
    parsed=$(echo "$result" | jq '{
        protected: true,
        required_reviewers: (.required_pull_request_reviews.required_approving_review_count // 0),
        dismiss_stale_reviews: (.required_pull_request_reviews.dismiss_stale_reviews // false),
        require_code_owner_reviews: (.required_pull_request_reviews.require_code_owner_reviews // false),
        required_checks: [(.required_status_checks.contexts // [])[]],
        enforce_admins: (.enforce_admins.enabled // false),
        linear_history: (.required_linear_history.enabled // false)
    }' 2>/dev/null || echo '{"protected": false}')

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ──────────────────────────────────────────────────────────────────────────────
# CODEOWNERS — parsed CODEOWNERS file
# ──────────────────────────────────────────────────────────────────────────────
gh_codeowners() {
    local owner="$1"
    local repo="$2"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    local cache_key="codeowners_${owner}_${repo}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "86400" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    # Try common CODEOWNERS locations
    local content=""
    local locations=("CODEOWNERS" ".github/CODEOWNERS" "docs/CODEOWNERS")
    for loc in "${locations[@]}"; do
        content=$(gh api "repos/${owner}/${repo}/contents/${loc}" --jq '.content' 2>/dev/null || true)
        if [[ -n "$content" ]]; then
            break
        fi
    done

    if [[ -z "$content" ]]; then
        _gh_cache_set "$cache_key" "[]"
        echo "[]"
        return 0
    fi

    # Decode base64 and parse
    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

    if [[ -z "$decoded" ]]; then
        _gh_cache_set "$cache_key" "[]"
        echo "[]"
        return 0
    fi

    # Parse CODEOWNERS format: pattern owners...
    local parsed="["
    local first=true
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        local pattern
        pattern=$(echo "$line" | awk '{print $1}')
        local owners_str
        owners_str=$(echo "$line" | awk '{$1=""; print $0}' | xargs)

        # Build JSON owners array
        local owners_json="["
        local ofirst=true
        for o in $owners_str; do
            if [[ "$ofirst" == "true" ]]; then
                ofirst=false
            else
                owners_json="${owners_json},"
            fi
            owners_json="${owners_json}$(jq -n --arg v "$o" '$v')"
        done
        owners_json="${owners_json}]"

        if [[ "$first" == "true" ]]; then
            first=false
        else
            parsed="${parsed},"
        fi
        parsed="${parsed}$(jq -n --arg p "$pattern" --argjson o "$owners_json" '{pattern: $p, owners: $o}')"
    done <<< "$decoded"
    parsed="${parsed}]"

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Security alerts — CodeQL code scanning alerts
# ──────────────────────────────────────────────────────────────────────────────
gh_security_alerts() {
    local owner="$1"
    local repo="$2"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    local cache_key="security_${owner}_${repo}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "1800" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    local result
    result=$(gh api "repos/${owner}/${repo}/code-scanning/alerts?state=open&per_page=50" 2>/dev/null) || {
        # 403 = feature not enabled, 404 = not found
        _gh_cache_set "$cache_key" "[]"
        echo "[]"
        return 0
    }

    local parsed
    parsed=$(echo "$result" | jq '[.[] | {
        number: .number,
        severity: .rule.severity,
        rule: .rule.id,
        description: .rule.description,
        path: .most_recent_instance.location.path,
        state: .state
    }]' 2>/dev/null || echo "[]")

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Dependabot alerts — vulnerability alerts
# ──────────────────────────────────────────────────────────────────────────────
gh_dependabot_alerts() {
    local owner="$1"
    local repo="$2"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    local cache_key="dependabot_${owner}_${repo}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "1800" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    local result
    result=$(gh api "repos/${owner}/${repo}/dependabot/alerts?state=open&per_page=50" 2>/dev/null) || {
        # 403 = feature not enabled
        _gh_cache_set "$cache_key" "[]"
        echo "[]"
        return 0
    }

    local parsed
    parsed=$(echo "$result" | jq '[.[] | {
        number: .number,
        severity: .security_advisory.severity,
        package: .dependency.package.name,
        ecosystem: .dependency.package.ecosystem,
        vulnerable_range: .security_vulnerability.vulnerable_version_range,
        summary: .security_advisory.summary,
        state: .state
    }]' 2>/dev/null || echo "[]")

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Actions runs — recent workflow run durations
# ──────────────────────────────────────────────────────────────────────────────
gh_actions_runs() {
    local owner="$1"
    local repo="$2"
    local workflow="$3"
    local limit="${4:-10}"

    if ! _gh_graphql_available; then
        echo "[]"
        return 0
    fi

    local cache_key="actions_${owner}_${repo}_$(echo "$workflow" | tr '/' '_')_${limit}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "900" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    local result
    result=$(gh api "repos/${owner}/${repo}/actions/workflows/${workflow}/runs?per_page=${limit}" 2>/dev/null) || {
        echo "[]"
        return 0
    }

    local parsed
    parsed=$(echo "$result" | jq '[.workflow_runs[] | {
        id: .id,
        conclusion: .conclusion,
        created_at: .created_at,
        updated_at: .updated_at,
        duration_seconds: (
            ((.updated_at | fromdateiso8601) - (.created_at | fromdateiso8601))
        )
    }]' 2>/dev/null || echo "[]")

    _gh_cache_set "$cache_key" "$parsed"
    emit_event "github.cache_miss" "key=$cache_key"

    echo "$parsed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# AGGREGATED REPO CONTEXT
# ═══════════════════════════════════════════════════════════════════════════════

gh_repo_context() {
    local owner="$1"
    local repo="$2"

    if ! _gh_graphql_available; then
        echo '{"error": "GitHub API not available", "contributors": [], "security_alerts": [], "dependabot_alerts": []}'
        return 0
    fi

    local cache_key="context_${owner}_${repo}"
    local cached
    cached=$(_gh_cache_get "$cache_key" "3600" 2>/dev/null) && {
        emit_event "github.cache_hit" "key=$cache_key"
        echo "$cached"
        return 0
    }

    info "Fetching repo context for ${owner}/${repo}..." >&2

    # Gather data (each function handles its own caching/errors)
    local contributors security dependabot protection

    contributors=$(gh_contributors "$owner" "$repo")
    security=$(gh_security_alerts "$owner" "$repo")
    dependabot=$(gh_dependabot_alerts "$owner" "$repo")
    protection=$(gh_branch_protection "$owner" "$repo" "main")

    # Get basic repo info
    local repo_info
    repo_info=$(gh api "repos/${owner}/${repo}" 2>/dev/null || echo '{}')

    local primary_language
    primary_language=$(echo "$repo_info" | jq -r '.language // "unknown"' 2>/dev/null || echo "unknown")

    local contributor_count
    contributor_count=$(echo "$contributors" | jq 'length' 2>/dev/null || echo "0")

    local top_contributors
    top_contributors=$(echo "$contributors" | jq '.[0:5]' 2>/dev/null || echo "[]")

    local security_count
    security_count=$(echo "$security" | jq 'length' 2>/dev/null || echo "0")

    local dependabot_count
    dependabot_count=$(echo "$dependabot" | jq 'length' 2>/dev/null || echo "0")

    local context
    context=$(jq -n \
        --arg owner "$owner" \
        --arg repo "$repo" \
        --arg language "$primary_language" \
        --argjson contributor_count "$contributor_count" \
        --argjson top_contributors "$top_contributors" \
        --argjson security_count "$security_count" \
        --argjson dependabot_count "$dependabot_count" \
        --argjson protection "$protection" \
        --argjson security_alerts "$security" \
        --argjson dependabot_alerts "$dependabot" \
        '{
            owner: $owner,
            repo: $repo,
            primary_language: $language,
            contributor_count: $contributor_count,
            top_contributors: $top_contributors,
            security_alert_count: $security_count,
            dependabot_alert_count: $dependabot_count,
            branch_protection: $protection,
            security_alerts: $security_alerts,
            dependabot_alerts: $dependabot_alerts,
            fetched_at: now | todate
        }')

    _gh_cache_set "$cache_key" "$context"
    emit_event "github.repo_context" "owner=$owner" "repo=$repo"

    echo "$context"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

gh_repo_context_cli() {
    local owner="${1:-}"
    local repo="${2:-}"

    if [[ -z "$owner" || -z "$repo" ]]; then
        _gh_detect_repo || { error "Usage: sw github-graphql context <owner> <repo>"; exit 1; }
        owner="$GH_OWNER"
        repo="$GH_REPO"
    fi

    local result
    result=$(gh_repo_context "$owner" "$repo")
    echo "$result" | jq .
}

gh_security_cli() {
    local owner="${1:-}"
    local repo="${2:-}"

    if [[ -z "$owner" || -z "$repo" ]]; then
        _gh_detect_repo || { error "Usage: sw github-graphql security <owner> <repo>"; exit 1; }
        owner="$GH_OWNER"
        repo="$GH_REPO"
    fi

    echo -e "${CYAN}${BOLD}Security Overview: ${owner}/${repo}${RESET}"
    echo ""

    echo -e "${BOLD}Code Scanning Alerts${RESET}"
    local security
    security=$(gh_security_alerts "$owner" "$repo")
    local sec_count
    sec_count=$(echo "$security" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$sec_count" -gt 0 ]]; then
        echo "$security" | jq -r '.[] | "  \(.severity)\t\(.rule)\t\(.path // "n/a")"'
    else
        echo -e "  ${GREEN}No open alerts${RESET}"
    fi
    echo ""

    echo -e "${BOLD}Dependabot Alerts${RESET}"
    local dependabot
    dependabot=$(gh_dependabot_alerts "$owner" "$repo")
    local dep_count
    dep_count=$(echo "$dependabot" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$dep_count" -gt 0 ]]; then
        echo "$dependabot" | jq -r '.[] | "  \(.severity)\t\(.package)\t\(.summary)"'
    else
        echo -e "  ${GREEN}No open alerts${RESET}"
    fi
}

gh_blame_data_cli() {
    local owner="${1:-}"
    local repo="${2:-}"
    local path="${3:-}"

    if [[ -z "$path" ]]; then
        error "Usage: sw github-graphql blame <owner> <repo> <path>"
        exit 1
    fi

    local result
    result=$(gh_blame_data "$owner" "$repo" "$path")
    echo "$result" | jq .
}

gh_commit_history_cli() {
    local owner="${1:-}"
    local repo="${2:-}"
    local path="${3:-}"
    local limit="${4:-10}"

    if [[ -z "$path" ]]; then
        error "Usage: sw github-graphql history <owner> <repo> <path> [limit]"
        exit 1
    fi

    local result
    result=$(gh_commit_history "$owner" "$repo" "$path" "$limit")
    echo "$result" | jq .
}

gh_cache_cli() {
    local subcmd="${1:-stats}"
    case "$subcmd" in
        stats)  _gh_cache_stats ;;
        clear)  _gh_cache_clear ;;
        *)      error "Usage: sw github-graphql cache [stats|clear]"; exit 1 ;;
    esac
}

show_help() {
    echo -e "${CYAN}${BOLD}shipwright github-graphql${RESET} — GitHub GraphQL API Client"
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo "  sw github-graphql <command> [args]"
    echo ""
    echo -e "${BOLD}Commands:${RESET}"
    echo "  context [owner] [repo]       Aggregated repo context for intelligence"
    echo "  security [owner] [repo]      Security alert overview"
    echo "  blame <owner> <repo> <path>  File blame/contributor data"
    echo "  history <owner> <repo> <path> [limit]  Commit history for file"
    echo "  cache [stats|clear]          Manage API cache"
    echo "  help                         Show this help"
    echo ""
    echo -e "${DIM}If owner/repo omitted, auto-detects from git remote.${RESET}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        context)   shift; gh_repo_context_cli "$@" ;;
        security)  shift; gh_security_cli "$@" ;;
        blame)     shift; gh_blame_data_cli "$@" ;;
        history)   shift; gh_commit_history_cli "$@" ;;
        cache)     shift; gh_cache_cli "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
