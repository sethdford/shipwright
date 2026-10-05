# pipeline-github.sh — GitHub API helpers for pipeline (for sw-pipeline.sh)
# Source from sw-pipeline.sh. Requires get_stage_status, get_stage_timing, get_stage_description, format_duration, now_iso from state/helpers.
[[ -n "${_PIPELINE_GITHUB_LOADED:-}" ]] && return 0
_PIPELINE_GITHUB_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
NO_GITHUB="${NO_GITHUB:-false}"
GOAL="${GOAL:-}"
PIPELINE_NAME="${PIPELINE_NAME:-pipeline}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
GIT_BRANCH="${GIT_BRANCH:-}"
PIPELINE_START_EPOCH="${PIPELINE_START_EPOCH:-}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
GH_AVAILABLE="${GH_AVAILABLE:-false}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"
PROGRESS_COMMENT_ID="${PROGRESS_COMMENT_ID:-}"

# ─── Markdown Escaping ───────────────────────────────────────────────
# Escape markdown special characters to prevent injection
escape_markdown() {
    local text="$1"
    # Escape ], [, (, ), *, _, \, `, #, -, +, .
    # This prevents markdown syntax injection in GitHub comments
    echo "$text" | sed 's/\([\\`*_\[\]()#+\-\.!]\)/\\\1/g'
}

gh_init() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        GH_AVAILABLE=false
        return
    fi

    if ! command -v gh >/dev/null 2>&1; then
        GH_AVAILABLE=false
        warn "gh CLI not found — GitHub integration disabled"
        return
    fi

    # Check if authenticated
    if ! gh auth status >/dev/null 2>&1; then
        GH_AVAILABLE=false
        warn "gh not authenticated — GitHub integration disabled"
        return
    fi

    # Detect repo owner/name from git remote
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || true)
    if [[ -n "$remote_url" ]]; then
        # Handle SSH: git@github.com:owner/repo.git
        # Handle HTTPS: https://github.com/owner/repo.git
        REPO_OWNER=$(echo "$remote_url" | sed -E 's#(.*github\.com[:/])([^/]+)/.*#\2#')
        REPO_NAME=$(echo "$remote_url" | sed -E 's#.*/([^/]+)(\.git)?$#\1#' | sed 's/\.git$//')
    fi

    if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
        GH_AVAILABLE=true
        info "GitHub: ${DIM}${REPO_OWNER}/${REPO_NAME}${RESET}"
    else
        GH_AVAILABLE=false
        warn "Could not detect GitHub repo — GitHub integration disabled"
    fi
}

# Post or update a comment on a GitHub issue
# Usage: gh_comment_issue <issue_number> <body>
gh_comment_issue() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" body="$2"
    _timeout 30 gh issue comment "$issue_num" --body "$body" 2>/dev/null || true
}

# Post a progress-tracking comment and save its ID for later updates
# Usage: gh_post_progress <issue_number> <body>
gh_post_progress() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" body="$2"
    local result
    result=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${issue_num}/comments" \
        -f body="$body" --jq '.id' --timeout 30 2>/dev/null) || true
    if [[ -n "$result" && "$result" != "null" ]]; then
        PROGRESS_COMMENT_ID="$result"
    fi
}

# Update an existing progress comment by ID
# Usage: gh_update_progress <body>
gh_update_progress() {
    [[ "$GH_AVAILABLE" != "true" || -z "$PROGRESS_COMMENT_ID" ]] && return 0
    local body="$1"
    gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${PROGRESS_COMMENT_ID}" \
        -X PATCH -f body="$body" --timeout 30 2>/dev/null || true
}

# Add labels to an issue or PR
# Usage: gh_add_labels <issue_number> <label1,label2,...>
gh_add_labels() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" labels="$2"
    [[ -z "$labels" ]] && return 0
    _timeout 30 gh issue edit "$issue_num" --add-label "$labels" 2>/dev/null || true
}

# Remove a label from an issue
# Usage: gh_remove_label <issue_number> <label>
gh_remove_label() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" label="$2"
    _timeout 30 gh issue edit "$issue_num" --remove-label "$label" 2>/dev/null || true
}

# Self-assign an issue
# Usage: gh_assign_self <issue_number>
gh_assign_self() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1"
    _timeout 30 gh issue edit "$issue_num" --add-assignee "@me" 2>/dev/null || true
}

# Get full issue metadata as JSON
# Usage: gh_get_issue_meta <issue_number>
gh_get_issue_meta() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1"
    _timeout 30 gh issue view "$issue_num" --json title,body,labels,milestone,assignees,comments,number,state 2>/dev/null || true
}

# _gh_prebuild_line — one markdown line summarizing non-passing prebuild findings (empty otherwise)
_gh_prebuild_line() {
    local f="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}/prebuild-check.json"
    [[ -f "$f" ]] || return 0
    jq -r 'select(.status != "pass") |
        "\n**Environment:** \(if .status == "fail" then "❌" else "⚠️" end) prebuild \(.status) — " +
        ([.findings[] | select(.severity != "info") | "`\(.id)`"] | join(", "))' \
        "$f" 2>/dev/null || true
}

# Build a progress table for GitHub comment
# Usage: gh_build_progress_body
gh_build_progress_body() {
    local escaped_goal
    escaped_goal=$(escape_markdown "${GOAL}")

    local body="## 🤖 Pipeline Progress — \`${PIPELINE_NAME}\`

**Delivering:** ${escaped_goal}
$(_gh_prebuild_line)

| Stage | Status | Duration | |
|-------|--------|----------|-|"

    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG" 2>/dev/null)
    while IFS= read -r -u 3 stage; do
        local id enabled
        id=$(echo "$stage" | jq -r '.id' 2>/dev/null) || id=""
        enabled=$(echo "$stage" | jq -r '.enabled' 2>/dev/null) || enabled=""

        if [[ "$enabled" != "true" ]]; then
            body="${body}
| ${id} | ⏭️ skipped | — | |"
            continue
        fi

        local sstatus
        sstatus=$(get_stage_status "$id")
        local duration
        duration=$(get_stage_timing "$id")

        local icon detail_col
        case "$sstatus" in
            complete)  icon="✅"; detail_col="" ;;
            running)   icon="🔄"; detail_col=$(get_stage_description "$id") ;;
            failed)    icon="❌"; detail_col="" ;;
            *)         icon="⬜"; detail_col=$(get_stage_description "$id") ;;
        esac

        body="${body}
| ${id} | ${icon} ${sstatus:-pending} | ${duration:-—} | ${detail_col} |"
    done 3<<< "$stages"

    body="${body}

**Branch:** \`${GIT_BRANCH}\`"

    [[ -n "${GITHUB_ISSUE:-}" ]] && body="${body}
**Issue:** ${GITHUB_ISSUE}"

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
        body="${body}
**Elapsed:** ${total_dur}"
    fi

    # Artifacts section
    local artifacts=""
    [[ -f "$ARTIFACTS_DIR/plan.md" ]] && artifacts="${artifacts}[Plan](.claude/pipeline-artifacts/plan.md)"
    [[ -f "$ARTIFACTS_DIR/design.md" ]] && { [[ -n "$artifacts" ]] && artifacts="${artifacts} · "; artifacts="${artifacts}[Design](.claude/pipeline-artifacts/design.md)"; }
    [[ -n "${PR_NUMBER:-}" ]] && { [[ -n "$artifacts" ]] && artifacts="${artifacts} · "; artifacts="${artifacts}PR #${PR_NUMBER}"; }
    [[ -n "$artifacts" ]] && body="${body}

📎 **Artifacts:** ${artifacts}"

    body="${body}

---
_Updated: $(now_iso) · shipwright pipeline_"
    echo "$body"
}

# Push a page to the GitHub wiki
# Usage: gh_wiki_page <title> <content>
gh_wiki_page() {
    local title="$1" content="$2"
    $GH_AVAILABLE || return 0
    $NO_GITHUB && return 0
    local wiki_dir="$ARTIFACTS_DIR/wiki"
    if [[ ! -d "$wiki_dir" ]]; then
        git clone "https://github.com/${REPO_OWNER}/${REPO_NAME}.wiki.git" "$wiki_dir" 2>/dev/null || {
            info "Wiki not initialized — skipping wiki update"
            return 0
        }
    fi
    echo "$content" > "$wiki_dir/${title}.md"
    ( cd "$wiki_dir" && git add -A && git commit -m "Pipeline: update $title" && git push ) 2>/dev/null || true
}

# ─── Auto-Detection ─────────────────────────────────────────────────────────

# Detect the test command from project files
