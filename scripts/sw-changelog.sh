#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright changelog — Automated Release Notes & Migration Guides       ║
# ║  Parse commits, categorize changes, generate markdown and stakeholder    ║
# ║  announcements with version recommendations and migration instructions   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── Commit Parsing ──────────────────────────────────────────────────────────

# Extract conventional commit type (feat, fix, perf, security, etc.)
get_commit_type() {
    local msg="$1"
    if [[ "$msg" =~ ^(feat|fix|perf|chore|docs|style|refactor|test|ci|security|breaking) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$msg" =~ ^BREAKING ]]; then
        echo "breaking"
    else
        echo "other"
    fi
}

# Extract scope if present (e.g., "feat(auth):" → "auth")
get_commit_scope() {
    local msg="$1"
    # Use simpler pattern: extract text between parens after type
    echo "$msg" | grep -oE '^[a-z]+\([^)]+\)' | sed 's/^[a-z]*(\(.*\))/\1/' || true
}

# Clean commit message (remove type prefix and scope)
clean_commit_msg() {
    local msg="$1"
    msg="${msg#feat: }"
    msg="${msg#fix: }"
    msg="${msg#perf: }"
    msg="${msg#chore: }"
    msg="${msg#docs: }"
    msg="${msg#style: }"
    msg="${msg#refactor: }"
    msg="${msg#test: }"
    msg="${msg#ci: }"
    msg="${msg#security: }"
    msg="${msg#BREAKING: }"
    msg="${msg#BREAKING CHANGE: }"
    # Remove scope if present
    msg="${msg#*()*: }"
    msg=$(echo "$msg" | sed 's/^[a-z]*(\([^)]*\)): //')
    echo "$msg"
}

# Get commits since last release (tag) or from start
get_commits() {
    local from_ref="${1:-}"
    local to_ref="${2:-HEAD}"

    if [[ -z "$from_ref" ]]; then
        # Find last tag
        from_ref=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "$(git -C "$REPO_DIR" rev-list --max-parents=0 HEAD)")
    fi

    if [[ "$from_ref" == "HEAD" ]]; then
        return
    fi

    git -C "$REPO_DIR" log "${from_ref}..${to_ref}" --pretty=format:"%H|%an|%ae|%ai|%s|%b" 2>/dev/null || true
}

# Parse commits into categorized structure
parse_commits() {
    local from_ref="${1:-}"
    local to_ref="${2:-HEAD}"
    local commits_log
    commits_log=$(get_commits "$from_ref" "$to_ref")

    local features fixes perf_changes security_changes breaking_changes docs_changes chores
    features=""
    fixes=""
    perf_changes=""
    security_changes=""
    breaking_changes=""
    docs_changes=""
    chores=""
    local contributors=""
    local pr_links=""

    while IFS='|' read -r hash author email date subject body; do
        [[ -z "$hash" ]] && continue

        local type scope msg
        type=$(get_commit_type "$subject")
        scope=$(get_commit_scope "$subject")
        msg=$(clean_commit_msg "$subject")

        # Extract PR number if in body
        local pr_num=""
        if [[ "$body" =~ ([Pp][Rr]\s*#?([0-9]+)|#([0-9]+)) ]]; then
            pr_num="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
        fi

        # Build entry
        local entry="$msg"
        [[ -n "$scope" ]] && entry="**${scope}**: $entry"
        [[ -n "$pr_num" ]] && entry="$entry ([\#$pr_num]($(_sw_github_url)/pull/$pr_num))"

        # Categorize
        case "$type" in
            breaking)
                breaking_changes="${breaking_changes}${entry}
"
                ;;
            feat)
                features="${features}${entry}
"
                ;;
            fix)
                fixes="${fixes}${entry}
"
                ;;
            perf)
                perf_changes="${perf_changes}${entry}
"
                ;;
            security)
                security_changes="${security_changes}${entry}
"
                ;;
            docs)
                docs_changes="${docs_changes}${entry}
"
                ;;
            chore|style|refactor|test|ci)
                chores="${chores}${entry}
"
                ;;
            *)
                # Treat as feature if breaking indicator present
                if echo "$subject" | grep -qi "breaking"; then
                    breaking_changes="${breaking_changes}${msg}
"
                else
                    features="${features}${entry}
"
                fi
                ;;
        esac

        # Track contributors
        contributors="${contributors}${author} (${email})
"
    done <<< "$commits_log"

    # Output as JSON
    jq -n \
        --arg features "$features" \
        --arg fixes "$fixes" \
        --arg perf "$perf_changes" \
        --arg security "$security_changes" \
        --arg breaking "$breaking_changes" \
        --arg docs "$docs_changes" \
        --arg chores "$chores" \
        --arg contributors "$contributors" \
        '{
            features: ($features | split("\n") | map(select(length > 0))),
            fixes: ($fixes | split("\n") | map(select(length > 0))),
            perf: ($perf | split("\n") | map(select(length > 0))),
            security: ($security | split("\n") | map(select(length > 0))),
            breaking: ($breaking | split("\n") | map(select(length > 0))),
            docs: ($docs | split("\n") | map(select(length > 0))),
            chores: ($chores | split("\n") | map(select(length > 0))),
            contributors: ($contributors | split("\n") | map(select(length > 0)) | unique)
        }'
}

# ─── Version Recommendation ──────────────────────────────────────────────────

recommend_version() {
    local changes_json="$1"
    local current_version="${2:-0.1.0}"

    # Parse current version
    local major minor patch
    IFS='.' read -r major minor patch <<< "$current_version"
    patch="${patch%%[^0-9]*}"  # Strip any pre-release/build metadata

    # Check for breaking changes
    local breaking_count
    breaking_count=$(echo "$changes_json" | jq '.breaking | length')

    # Check for features
    local features_count
    features_count=$(echo "$changes_json" | jq '.features | length')

    # Check for fixes
    local fixes_count
    fixes_count=$(echo "$changes_json" | jq '.fixes | length')

    if [[ "$breaking_count" -gt 0 ]]; then
        echo "$((major + 1)).0.0"
    elif [[ "$features_count" -gt 0 ]]; then
        echo "${major}.$((minor + 1)).0"
    elif [[ "$fixes_count" -gt 0 ]]; then
        echo "${major}.${minor}.$((patch + 1))"
    else
        echo "${major}.${minor}.${patch}"
    fi
}

# ─── Release Notes Generation ────────────────────────────────────────────────

generate_markdown() {
    local changes_json="$1"
    local version="${2:-Unreleased}"
    local date="${3:-$(date -u +%Y-%m-%d)}"

    local output=""
    output+="## [${version}] — ${date}
"
    output+="
"

    # Breaking Changes
    local breaking_count
    breaking_count=$(echo "$changes_json" | jq '.breaking | length')
    if [[ "$breaking_count" -gt 0 ]]; then
        output+="### ⚠️ Breaking Changes
"
        output+="
"
        echo "$changes_json" | jq -r '.breaking[]' | while read -r change; do
            output+="- ${change}
"
        done
        output+="
"
    fi

    # Features
    local features_count
    features_count=$(echo "$changes_json" | jq '.features | length')
    if [[ "$features_count" -gt 0 ]]; then
        output+="### ✨ Features
"
        output+="
"
        echo "$changes_json" | jq -r '.features[]' | while read -r change; do
            output+="- ${change}
"
        done
        output+="
"
    fi

    # Security
    local security_count
    security_count=$(echo "$changes_json" | jq '.security | length')
    if [[ "$security_count" -gt 0 ]]; then
        output+="### 🔒 Security
"
        output+="
"
        echo "$changes_json" | jq -r '.security[]' | while read -r change; do
            output+="- ${change}
"
        done
        output+="
"
    fi

    # Performance
    local perf_count
    perf_count=$(echo "$changes_json" | jq '.perf | length')
    if [[ "$perf_count" -gt 0 ]]; then
        output+="### 🚀 Performance
"
        output+="
"
        echo "$changes_json" | jq -r '.perf[]' | while read -r change; do
            output+="- ${change}
"
        done
        output+="
"
    fi

    # Bug Fixes
    local fixes_count
    fixes_count=$(echo "$changes_json" | jq '.fixes | length')
    if [[ "$fixes_count" -gt 0 ]]; then
        output+="### 🐛 Bug Fixes
"
        output+="
"
        echo "$changes_json" | jq -r '.fixes[]' | while read -r change; do
            output+="- ${change}
"
        done
        output+="
"
    fi

    # Documentation
    local docs_count
    docs_count=$(echo "$changes_json" | jq '.docs | length')
    if [[ "$docs_count" -gt 0 ]]; then
        output+="### 📚 Documentation
"
        output+="
"
        echo "$changes_json" | jq -r '.docs[]' | while read -r change; do
            output+="- ${change}
"
        done
        output+="
"
    fi

    # Contributors
    local contributors_count
    contributors_count=$(echo "$changes_json" | jq '.contributors | length')
    if [[ "$contributors_count" -gt 0 ]]; then
        output+="### 👥 Contributors
"
        output+="
"
        echo "$changes_json" | jq -r '.contributors[]' | while read -r contrib; do
            [[ -n "$contrib" ]] && output+="- ${contrib}
"
        done
        output+="
"
    fi

    echo -e "$output"
}

# ─── Migration Guide Generation ──────────────────────────────────────────────

generate_migration_guide() {
    local changes_json="$1"
    local version="${2:-Unreleased}"

    local breaking_count
    breaking_count=$(echo "$changes_json" | jq '.breaking | length')

    if [[ "$breaking_count" -eq 0 ]]; then
        echo "No breaking changes in this release."
        return 0
    fi

    local output=""
    output+="# Migration Guide — Version ${version}
"
    output+="
"
    output+="This release includes breaking changes. Follow this guide to update your code.
"
    output+="
"

    local idx=1
    echo "$changes_json" | jq -r '.breaking[]' | while read -r change; do
        output+="## Change ${idx}: ${change}
"
        output+="
"
        output+="### Before
"
        output+="
"
        output+="\`\`\`bash
# Previous approach
old_command --flag value
\`\`\`
"
        output+="
"
        output+="### After
"
        output+="
"
        output+="\`\`\`bash
# New approach
new_command --new-flag value
\`\`\`
"
        output+="
"
        idx=$((idx + 1))
    done

    echo -e "$output"
}

# ─── Stakeholder Announcement ────────────────────────────────────────────────

generate_announcement() {
    local changes_json="$1"
    local version="${2:-Unreleased}"

    local features_count
    features_count=$(echo "$changes_json" | jq '.features | length')
    local fixes_count
    fixes_count=$(echo "$changes_json" | jq '.fixes | length')
    local breaking_count
    breaking_count=$(echo "$changes_json" | jq '.breaking | length')

    local output=""
    output+="# 🎉 Release: Version ${version}
"
    output+="
"
    output+="We're excited to announce the release of Shipwright ${version}, packed with improvements to make your CI/CD pipeline even more powerful.
"
    output+="
"
    output+="## What's New
"
    output+="
"

    if [[ "$features_count" -gt 0 ]]; then
        output+="**${features_count} new features** that streamline your workflow and improve productivity:
"
        output+="
"
        echo "$changes_json" | jq -r '.features[]' | head -3 | while read -r feature; do
            output+="- ${feature}
"
        done
        output+="
"
    fi

    if [[ "$fixes_count" -gt 0 ]]; then
        output+="**${fixes_count} bug fixes** that make Shipwright more reliable:
"
        output+="
"
        echo "$changes_json" | jq -r '.fixes[]' | head -3 | while read -r fix; do
            output+="- ${fix}
"
        done
        output+="
"
    fi

    if [[ "$breaking_count" -gt 0 ]]; then
        output+="⚠️ **Note:** This release includes breaking changes. Please review the migration guide before upgrading.
"
        output+="
"
    fi

    output+="## Get Started
"
    output+="
"
    output+="Upgrade to version ${version} to take advantage of these improvements. See our documentation for detailed information.
"
    output+="
"

    echo -e "$output"
}

# ─── Subcommands ────────────────────────────────────────────────────────────

cmd_generate() {
    local from_ref="${1:-}"
    local to_ref="HEAD"

    if [[ "$from_ref" == "--from" ]] && [[ -n "${2:-}" ]]; then
        from_ref="$2"
        if [[ "${3:-}" == "--to" ]] && [[ -n "${4:-}" ]]; then
            to_ref="$4"
        fi
    fi

    info "Parsing commits from ${from_ref:-last release} to ${to_ref}..."
    local changes_json
    changes_json=$(parse_commits "$from_ref" "$to_ref")

    local current_version
    current_version=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")
    current_version="${current_version#v}"

    local next_version
    next_version=$(recommend_version "$changes_json" "$current_version")

    info "Recommended version: ${CYAN}${next_version}${RESET}"

    local release_notes
    release_notes=$(generate_markdown "$changes_json" "v${next_version}")

    local output_file="${REPO_DIR}/CHANGELOG-${next_version}.md"
    echo "$release_notes" > "$output_file"
    success "Release notes generated: ${output_file}"

    emit_event "changelog.generate" "version=$next_version" "commits=$(echo "$changes_json" | jq '.features | length')"
}

cmd_preview() {
    local from_ref="${1:-}"
    local to_ref="HEAD"

    info "Parsing commits for preview..."
    local changes_json
    changes_json=$(parse_commits "$from_ref" "$to_ref")

    local current_version
    current_version=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")
    current_version="${current_version#v}"

    local next_version
    next_version=$(recommend_version "$changes_json" "$current_version")

    echo ""
    echo -e "${CYAN}${BOLD}Preview: Release v${next_version}${RESET}"
    echo ""

    generate_markdown "$changes_json" "v${next_version}"
}

cmd_version() {
    local from_ref="${1:-}"
    local to_ref="HEAD"

    info "Analyzing commits for version recommendation..."
    local changes_json
    changes_json=$(parse_commits "$from_ref" "$to_ref")

    local current_version
    current_version=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")
    current_version="${current_version#v}"

    local next_version
    next_version=$(recommend_version "$changes_json" "$current_version")

    echo ""
    echo -e "${BOLD}Current version:${RESET} ${current_version}"
    echo -e "${BOLD}Recommended version:${RESET} ${CYAN}${next_version}${RESET}"

    local breaking_count
    breaking_count=$(echo "$changes_json" | jq '.breaking | length')
    local features_count
    features_count=$(echo "$changes_json" | jq '.features | length')
    local fixes_count
    fixes_count=$(echo "$changes_json" | jq '.fixes | length')

    echo ""
    echo "Rationale:"
    [[ "$breaking_count" -gt 0 ]] && echo "  - ${RED}${breaking_count} breaking changes${RESET} → major version bump"
    [[ "$features_count" -gt 0 ]] && echo "  - ${GREEN}${features_count} new features${RESET} → minor version bump"
    [[ "$fixes_count" -gt 0 ]] && echo "  - ${GREEN}${fixes_count} bug fixes${RESET} → patch version bump"
    echo ""
}

cmd_migrate() {
    local from_ref="${1:-}"
    local to_ref="HEAD"

    info "Generating migration guide..."
    local changes_json
    changes_json=$(parse_commits "$from_ref" "$to_ref")

    local current_version
    current_version=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")
    current_version="${current_version#v}"

    local next_version
    next_version=$(recommend_version "$changes_json" "$current_version")

    local migration
    migration=$(generate_migration_guide "$changes_json" "v${next_version}")

    local output_file="${REPO_DIR}/MIGRATION-${next_version}.md"
    echo "$migration" > "$output_file"
    success "Migration guide generated: ${output_file}"

    emit_event "changelog.migrate" "version=$next_version"
}

cmd_announce() {
    local from_ref="${1:-}"
    local to_ref="HEAD"

    info "Generating stakeholder announcement..."
    local changes_json
    changes_json=$(parse_commits "$from_ref" "$to_ref")

    local current_version
    current_version=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")
    current_version="${current_version#v}"

    local next_version
    next_version=$(recommend_version "$changes_json" "$current_version")

    local announcement
    announcement=$(generate_announcement "$changes_json" "v${next_version}")

    local output_file="${REPO_DIR}/ANNOUNCE-${next_version}.md"
    echo "$announcement" > "$output_file"
    success "Announcement generated: ${output_file}"

    emit_event "changelog.announce" "version=$next_version"
}

cmd_formats() {
    echo ""
    echo -e "${BOLD}Available Output Formats:${RESET}"
    echo ""
    echo -e "  ${CYAN}markdown${RESET}     Release notes in markdown format (default)"
    echo -e "  ${CYAN}json${RESET}         Structured changes in JSON"
    echo -e "  ${CYAN}html${RESET}         HTML-formatted release notes"
    echo -e "  ${CYAN}text${RESET}         Plain text format"
    echo ""
}

show_help() {
    echo -e "${CYAN}${BOLD}shipwright changelog${RESET} — Automated Release Notes & Migration Guides"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright changelog${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}generate${RESET}         Generate changelog since last release"
    echo -e "  ${CYAN}generate --from TAG --to TAG  Changelog between specific tags"
    echo -e "  ${CYAN}preview${RESET}          Preview next release notes without committing"
    echo -e "  ${CYAN}version${RESET}          Recommend next semantic version"
    echo -e "  ${CYAN}migrate${RESET}          Generate migration guide for breaking changes"
    echo -e "  ${CYAN}announce${RESET}         Generate stakeholder announcement"
    echo -e "  ${CYAN}formats${RESET}          List available output formats"
    echo -e "  ${CYAN}help${RESET}             Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright changelog generate${RESET}"
    echo -e "  ${DIM}shipwright changelog preview${RESET}"
    echo -e "  ${DIM}shipwright changelog version${RESET}"
    echo -e "  ${DIM}shipwright changelog generate --from v1.0.0 --to v1.1.0${RESET}"
    echo ""
}

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        generate)  cmd_generate "$@" ;;
        preview)   cmd_preview "$@" ;;
        version)   cmd_version "$@" ;;
        migrate)   cmd_migrate "$@" ;;
        announce)  cmd_announce "$@" ;;
        formats)   cmd_formats "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
