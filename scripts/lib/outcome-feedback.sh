#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/outcome-feedback — PR review capture & quality scoring   ║
# ║  Review comments → memory · Merge quality tracking · Rule auto-generation║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Double-source guard
[[ -n "${_SW_OUTCOME_FEEDBACK_LOADED:-}" ]] && return 0
_SW_OUTCOME_FEEDBACK_LOADED=1

# ─── Helpers (already loaded by caller, but provide fallbacks) ───────────────
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi
if [[ "$(type -t info 2>/dev/null)" != "function" ]]; then
  info()    { echo "▸ $*"; }
  success() { echo "✓ $*"; }
  warn()    { echo "⚠ $*" >&2; }
  error()   { echo "✗ $*" >&2; }
fi

# ─── Storage Paths ──────────────────────────────────────────────────────────

# Allow override of memory root for testing
OUTCOME_FEEDBACK_MEMORY_ROOT="${OUTCOME_FEEDBACK_MEMORY_ROOT:-${HOME}/.shipwright/memory}"

# Repo hash: echo -n "$repo_path" | shasum -a 256 | cut -c1-12
_outcome_feedback_repo_hash() {
    local repo_path="${1:-.}"
    echo -n "$repo_path" | shasum -a 256 | cut -c1-12
}

_outcome_feedback_memory_dir() {
    local repo_hash="$1"
    echo "${OUTCOME_FEEDBACK_MEMORY_ROOT}/${repo_hash}"
}

# ─── Category Extraction from Review Comments ────────────────────────────────

# Extract review comment categories using keyword matching
# Returns space-separated list of categories (error_handling, validation, naming, etc.)
_extract_comment_categories() {
    local comment="$1"
    local categories=""

    # Normalize to lowercase for matching
    local lower_comment
    lower_comment=$(echo "$comment" | tr '[:upper:]' '[:lower:]')

    # Check for each category using substring matching
    echo "$lower_comment" | grep >/dev/null -iE "(error|exception|crash|fail|panic)" && categories="$categories error_handling"
    echo "$lower_comment" | grep >/dev/null -iE "(validat|check|assert|guard|verify)" && categories="$categories validation"
    echo "$lower_comment" | grep >/dev/null -iE "(nam|identifier|variable|function|class)" && categories="$categories naming"
    echo "$lower_comment" | grep >/dev/null -iE "(test|spec|coverage|mock|fixture)" && categories="$categories testing"
    echo "$lower_comment" | grep >/dev/null -iE "(secur|auth|encript|credential|token|xss|sql)" && categories="$categories security"
    echo "$lower_comment" | grep >/dev/null -iE "(perform|optim|speed|latency|cache|memory)" && categories="$categories performance"
    echo "$lower_comment" | grep >/dev/null -iE "(type|interface|contract|signature)" && categories="$categories typing"
    echo "$lower_comment" | grep >/dev/null -iE "(doc|comment|readme|example)" && categories="$categories documentation"

    # If no categories detected, use generic "other"
    if [[ -z "$categories" ]]; then
        categories="other"
    fi

    echo "$categories" | xargs  # Trim and normalize whitespace
}

# ─── Capture PR Review Comments ──────────────────────────────────────────────

# capture_review_feedback <pr_number> <repo_path>
# Fetches PR reviews and comments from GitHub, stores as JSON entries in memory
# Uses gh API if available (guarded by NO_GITHUB check)
capture_review_feedback() {
    local pr_number="$1"
    local repo_path="${2:-.}"

    [[ -z "$pr_number" ]] && { error "Usage: capture_review_feedback <pr_number> [repo_path]"; return 1; }

    # Ensure memory dir exists (always, even if NO_GITHUB)
    local repo_hash
    repo_hash=$(_outcome_feedback_repo_hash "$repo_path")
    local mem_dir
    mem_dir=$(_outcome_feedback_memory_dir "$repo_hash")
    mkdir -p "$mem_dir"

    local feedback_file="${mem_dir}/review-feedback.jsonl"

    # Skip if NO_GITHUB is set
    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        info "Skipping review capture (NO_GITHUB set)"
        return 0
    fi

    info "Capturing review feedback for PR #${pr_number}..."

    # Try to get owner/repo from git remote
    local owner_repo
    owner_repo=$(git -C "$repo_path" remote get-url origin 2>/dev/null | \
        sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##' || true)

    if [[ -z "$owner_repo" ]]; then
        warn "Cannot determine owner/repo — skipping review capture"
        return 0
    fi

    # Fetch reviews
    local reviews_json
    if reviews_json=$(gh api "repos/${owner_repo}/pulls/${pr_number}/reviews" 2>/dev/null); then
        echo "$reviews_json" | jq -c '.[]? |
            select(.body != null and .body != "") |
            {
                body: .body,
                state: .state,
                author: .user.login,
                timestamp: .submitted_at
            }' | while read -r review; do
            [[ -z "$review" ]] && continue

            local comment
            comment=$(echo "$review" | jq -r '.body')
            local categories
            categories=$(_extract_comment_categories "$comment")

            # Create JSONL entry
            echo "$review" | jq \
                --arg pr "$pr_number" \
                --arg cats "$categories" \
                --arg ts "$(now_iso)" \
                '. += {
                    pr: ($pr | tonumber),
                    categories: $cats,
                    captured_at: $ts
                }' >> "$feedback_file"
        done
    fi

    # Fetch review comments (inline code comments)
    local comments_json
    if comments_json=$(gh api "repos/${owner_repo}/pulls/${pr_number}/comments" 2>/dev/null); then
        echo "$comments_json" | jq -c '.[]? |
            select(.body != null and .body != "") |
            {
                body: .body,
                path: .path,
                commit_id: .commit_id,
                author: .user.login,
                timestamp: .created_at
            }' | while read -r comment_obj; do
            [[ -z "$comment_obj" ]] && continue

            local comment
            comment=$(echo "$comment_obj" | jq -r '.body')
            local categories
            categories=$(_extract_comment_categories "$comment")

            # Create JSONL entry
            echo "$comment_obj" | jq \
                --arg pr "$pr_number" \
                --arg cats "$categories" \
                --arg ts "$(now_iso)" \
                '. += {
                    pr: ($pr | tonumber),
                    categories: $cats,
                    captured_at: $ts
                }' >> "$feedback_file"
        done
    fi

    success "Captured review feedback for PR #${pr_number}"
    return 0
}

# ─── Compute Merge Quality Score ────────────────────────────────────────────

# compute_merge_quality <pr_number> <repo_path> [merge_status]
# Scores PR based on merge outcome: clean_merge=+1, changes_requested=-1, reverted=-3, regression=-2
# Stores as JSON in merge-quality.jsonl
compute_merge_quality() {
    local pr_number="$1"
    local repo_path="${2:-.}"
    local merge_status="${3:-clean_merge}"  # Default to clean_merge

    [[ -z "$pr_number" ]] && { error "Usage: compute_merge_quality <pr_number> [repo_path] [merge_status]"; return 1; }

    local repo_hash
    repo_hash=$(_outcome_feedback_repo_hash "$repo_path")
    local mem_dir
    mem_dir=$(_outcome_feedback_memory_dir "$repo_hash")
    mkdir -p "$mem_dir"

    local quality_file="${mem_dir}/merge-quality.jsonl"

    # Compute score based on merge status
    local score=0
    case "$merge_status" in
        clean_merge)   score=1 ;;
        changes_requested) score=-1 ;;
        reverted)      score=-3 ;;
        regression)    score=-2 ;;
        *)             score=0 ;;
    esac

    # Get PR title (if available from GitHub)
    local pr_title=""
    if [[ "${NO_GITHUB:-}" != "true" && "${NO_GITHUB:-}" != "1" ]]; then
        local owner_repo
        owner_repo=$(git -C "$repo_path" remote get-url origin 2>/dev/null | \
            sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##' || true)

        if [[ -n "$owner_repo" ]]; then
            pr_title=$(gh api "repos/${owner_repo}/pulls/${pr_number}" \
                --jq '.title' 2>/dev/null || echo "")
        fi
    fi

    # Append JSONL entry (compact, one per line)
    local entry
    entry=$(jq -cn \
        --argjson pr "$pr_number" \
        --argjson score "$score" \
        --arg status "$merge_status" \
        --arg title "$pr_title" \
        --arg ts "$(now_iso)" \
        '{
            pr: $pr,
            score: $score,
            type: $status,
            title: $title,
            timestamp: $ts
        }')

    echo "$entry" >> "$quality_file"

    success "Computed merge quality: PR #${pr_number} score=${score} (${merge_status})"
    return 0
}

# ─── Rolling Quality Score Calculation ───────────────────────────────────────

# get_rolling_quality_score <repo_path> [window_size]
# Computes average quality score over last N PRs
# Returns JSON with score, pr_count, details
get_rolling_quality_score() {
    local repo_path="${1:-.}"
    local window_size="${2:-20}"

    local repo_hash
    repo_hash=$(_outcome_feedback_repo_hash "$repo_path")
    local mem_dir
    mem_dir=$(_outcome_feedback_memory_dir "$repo_hash")
    local quality_file="${mem_dir}/merge-quality.jsonl"

    # If file doesn't exist, return zero score
    if [[ ! -f "$quality_file" ]]; then
        echo '{"rolling_score": 0, "pr_count": 0, "details": []}'
        return 0
    fi

    # Tail last N entries and compute rolling average
    local result
    result=$(tail -n "$window_size" "$quality_file" | jq -s \
        '{
            rolling_score: (if length > 0 then ([.[].score] | add / length) else 0 end),
            pr_count: length,
            by_type: (group_by(.type) | map({type: .[0].type, count: length, avg_score: (([.[].score] | add / length) | . * 100 | round / 100)}))
        }' 2>/dev/null || echo '{"rolling_score": 0, "pr_count": 0}')

    echo "$result"
    return 0
}

# ─── Detect Recurring Review Patterns ────────────────────────────────────────

# detect_review_patterns <repo_path> [min_count]
# Groups review comments by category
# Detects patterns appearing in min_count (default 3) or more PRs
# Returns JSON with pattern_name, count, prs
detect_review_patterns() {
    local repo_path="${1:-.}"
    local min_count="${2:-3}"

    local repo_hash
    repo_hash=$(_outcome_feedback_repo_hash "$repo_path")
    local mem_dir
    mem_dir=$(_outcome_feedback_memory_dir "$repo_hash")
    local feedback_file="${mem_dir}/review-feedback.jsonl"

    # If no feedback file, return empty patterns
    if [[ ! -f "$feedback_file" ]]; then
        echo '{"patterns": []}'
        return 0
    fi

    # Group by category, count PRs per category, filter by min_count
    local patterns
    patterns=$(jq -s '
        [.[] |
            select(.categories != null) |
            .categories |
            split(" ") |
            .[] |
            select(. != "")] |
        group_by(.) |
        map({
            category: .[0],
            count: length,
            prs: map(input_line_number) | unique
        }) |
        map(select(.count >= '$min_count')) |
        sort_by(-.count)
    ' "$feedback_file" 2>/dev/null || echo "[]")

    # Output as JSON
    echo "{\"patterns\": $patterns}"
    return 0
}

# ─── Generate Learned Quality Rules ────────────────────────────────────────────

# generate_learned_rules <repo_path> <quality_profile_path>
# Detects recurring review patterns (3+ occurrences)
# Generates quality rules and adds to quality-profile.json's learned_rules array
# Idempotent: doesn't duplicate existing rules
generate_learned_rules() {
    local repo_path="${1:-.}"
    local quality_profile="${2:-./  .claude/quality-profile.json}"

    [[ -z "$quality_profile" || ! -f "$quality_profile" ]] && {
        warn "Quality profile not found: $quality_profile"
        return 1
    }

    info "Generating learned rules from review patterns..."

    # Detect patterns
    local patterns_json
    patterns_json=$(detect_review_patterns "$repo_path" 3 || echo '{"patterns": []}')

    local pattern_count
    pattern_count=$(echo "$patterns_json" | jq '.patterns | length' 2>/dev/null || echo 0)

    if [[ "$pattern_count" -eq 0 ]]; then
        info "No recurring patterns detected (threshold: 3+ PRs)"
        return 0
    fi

    # For each pattern, generate a rule and add to quality profile
    echo "$patterns_json" | jq -c '.patterns[]?' | while read -r pattern; do
        [[ -z "$pattern" ]] && continue

        local category
        category=$(echo "$pattern" | jq -r '.category')
        local count
        count=$(echo "$pattern" | jq -r '.count')

        # Compute confidence: count/20, capped at 0.95 from 10 occurrences up.
        #
        # This used `bc` with `if (...) then ... else ... end`, which is not bc
        # syntax — bc has no `then`/`end` keywords. bc reported a parse error
        # and, critically, still exited 0, so the `|| echo "0.6"` fallback never
        # fired and $confidence came back EMPTY on both platforms. jq then hit
        # `"" | tonumber`, no rule was written, and the profile was left
        # unparseable ("Expected JSON value while parsing ''").
        #
        # awk does the arithmetic in-process: no bc dependency, no reliance on
        # an exit code, and a guaranteed numeric result.
        local confidence
        confidence=$(awk -v c="$count" 'BEGIN { printf "%.2f", (c >= 10 ? 0.95 : c / 20) }' 2>/dev/null)
        [[ "$confidence" =~ ^[0-9]+\.[0-9]+$ ]] || confidence="0.60"

        # Generate rule text based on category
        local rule_text
        case "$category" in
            error_handling)
                rule_text="Always add error handling for external API calls and edge cases — try/catch, timeout guards, validation"
                ;;
            validation)
                rule_text="Validate input parameters and contract assumptions before processing — guard clauses, type checks"
                ;;
            naming)
                rule_text="Use clear, descriptive names for functions, variables, and classes — avoid abbreviations, be explicit"
                ;;
            testing)
                rule_text="Write tests for happy path, edge cases, and error conditions — aim for >80% coverage on modified code"
                ;;
            security)
                rule_text="Review all authentication, authorization, and data handling code — no hardcoded secrets, use secure methods"
                ;;
            performance)
                rule_text="Profile for hot paths — avoid N+1 queries, unnecessary allocations, and blocking I/O in loops"
                ;;
            typing)
                rule_text="Use strong types and explicit interfaces — avoid 'any', verify type safety at boundaries"
                ;;
            documentation)
                rule_text="Document public APIs and non-obvious code — include examples, parameter descriptions, return types"
                ;;
            *)
                rule_text="Address recurring review feedback: ${category}"
                ;;
        esac

        # Check if rule already exists in learned_rules (avoid duplicates)
        local rule_exists
        rule_exists=$(jq --arg cat "$category" \
            '.quality.learned_rules[]? | select(.source == "review_pattern_" + $cat) | .rule' \
            "$quality_profile" 2>/dev/null || echo "")

        if [[ -n "$rule_exists" ]]; then
            info "Rule already exists for category: $category"
            continue
        fi

        # Add rule to quality profile
        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'" RETURN

        jq \
            --arg rule "$rule_text" \
            --arg source "review_pattern_${category}" \
            --arg confidence "$confidence" \
            --arg ts "$(now_iso)" \
            '.quality.learned_rules += [{
                rule: $rule,
                source: $source,
                confidence: ($confidence | tonumber),
                created_at: $ts,
                inject_at: ["plan", "build", "review"]
            }]' \
            "$quality_profile" > "$tmp_file" && \
            mv "$tmp_file" "$quality_profile"

        success "Added learned rule: ${category} (confidence: ${confidence})"
    done

    return 0
}

# ─── Format Outcome Summary for DORA Dashboard ───────────────────────────────

# format_outcome_summary <repo_path>
# Produces summary JSON with rolling quality score, pattern analysis, recent PRs
format_outcome_summary() {
    local repo_path="${1:-.}"

    # Get rolling quality score
    local rolling_json
    rolling_json=$(get_rolling_quality_score "$repo_path" 20 2>/dev/null || echo '{}')

    # Get patterns
    local patterns_json
    patterns_json=$(detect_review_patterns "$repo_path" 3 2>/dev/null || echo '{"patterns": []}')

    # Get repo hash and memory dir info
    local repo_hash
    repo_hash=$(_outcome_feedback_repo_hash "$repo_path")
    local mem_dir
    mem_dir=$(_outcome_feedback_memory_dir "$repo_hash")

    # Count total feedback entries
    local feedback_count=0
    [[ -f "${mem_dir}/review-feedback.jsonl" ]] && \
        feedback_count=$(wc -l < "${mem_dir}/review-feedback.jsonl" 2>/dev/null || echo 0)

    # Assemble summary
    local summary
    summary=$(jq -n \
        --argjson rolling "$rolling_json" \
        --argjson patterns "$patterns_json" \
        --argjson feedback_count "$feedback_count" \
        --arg ts "$(now_iso)" \
        '{
            timestamp: $ts,
            rolling_quality: $rolling,
            review_patterns: $patterns,
            feedback_entries: $feedback_count
        }')

    echo "$summary"
    return 0
}

# ─── Post-Merge Feedback Hook ───────────────────────────────────────────────

# post_merge_feedback <pr_number> <repo_path> <quality_profile_path>
# Full post-merge workflow: capture reviews, compute score, detect patterns, generate rules
post_merge_feedback() {
    local pr_number="$1"
    local repo_path="${2:-.}"
    local quality_profile="${3:-./.claude/quality-profile.json}"

    [[ -z "$pr_number" ]] && { error "Usage: post_merge_feedback <pr_number> [repo_path] [quality_profile]"; return 1; }

    info "Running post-merge feedback collection for PR #${pr_number}..."

    # Step 1: Capture review comments
    capture_review_feedback "$pr_number" "$repo_path" || true

    # Step 2: Compute merge quality score
    compute_merge_quality "$pr_number" "$repo_path" "clean_merge" || true

    # Step 3: Detect patterns
    local patterns
    patterns=$(detect_review_patterns "$repo_path" 3 2>/dev/null || echo '{"patterns": []}')
    local pattern_count
    pattern_count=$(echo "$patterns" | jq '.patterns | length')

    if [[ "$pattern_count" -gt 0 ]]; then
        info "Detected $pattern_count recurring patterns"

        # Step 4: Generate learned rules (if quality profile exists)
        if [[ -f "$quality_profile" ]]; then
            generate_learned_rules "$repo_path" "$quality_profile" || true
        fi
    fi

    success "Post-merge feedback collection complete"
    return 0
}

# Export functions for sourcing
export -f capture_review_feedback
export -f compute_merge_quality
export -f get_rolling_quality_score
export -f detect_review_patterns
export -f generate_learned_rules
export -f format_outcome_summary
export -f post_merge_feedback
