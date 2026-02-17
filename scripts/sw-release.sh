#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright release — Release train automation                          ║
# ║  Bump versions, generate changelog, create tags and GitHub releases      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR
trap 'rm -f "${tmp_file:-}"' EXIT

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
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

# ─── Parse flags ───────────────────────────────────────────────────────────
DRY_RUN=false
VERSION_TYPE=""
FROM_TAG=""
TO_TAG="HEAD"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --major) VERSION_TYPE="major" ;;
        --minor) VERSION_TYPE="minor" ;;
        --patch) VERSION_TYPE="patch" ;;
        --from) shift_next=true ;;
        --from=*) FROM_TAG="${arg#--from=}" ;;
        --to) shift_next=true ;;
        --to=*) TO_TAG="${arg#--to=}" ;;
        *)
            if [[ "${shift_next:-false}" == "true" ]]; then
                case "${prev_arg:-}" in
                    --from) FROM_TAG="$arg" ;;
                    --to) TO_TAG="$arg" ;;
                esac
                shift_next=false
            fi
            prev_arg="$arg"
            ;;
    esac
done

# ─── Git helpers ───────────────────────────────────────────────────────────

# Get latest tag
get_latest_tag() {
    git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0"
}

# Parse semantic version (e.g., "v1.2.3" -> major=1, minor=2, patch=3)
parse_version() {
    local version="$1"
    # Strip leading 'v' if present
    version="${version#v}"

    IFS='.' read -r major minor patch <<< "$version"

    echo "$major|$minor|${patch:-0}"
}

# Compare semantic versions
# Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
compare_versions() {
    local v1="$1" v2="$2"

    IFS='|' read -r m1 mi1 p1 <<< "$(parse_version "$v1")"
    IFS='|' read -r m2 mi2 p2 <<< "$(parse_version "$v2")"

    if [[ $m1 -lt $m2 ]]; then echo -1; return; fi
    if [[ $m1 -gt $m2 ]]; then echo 1; return; fi
    if [[ $mi1 -lt $mi2 ]]; then echo -1; return; fi
    if [[ $mi1 -gt $mi2 ]]; then echo 1; return; fi
    if [[ $p1 -lt $p2 ]]; then echo -1; return; fi
    if [[ $p1 -gt $p2 ]]; then echo 1; return; fi
    echo 0
}

# Bump version
bump_version() {
    local current="$1" bump_type="$2"

    IFS='|' read -r major minor patch <<< "$(parse_version "$current")"

    case "$bump_type" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
    esac

    echo "v${major}.${minor}.${patch}"
}

# Get conventional commit type from message
get_commit_type() {
    local msg="$1"
    # Extract type from "type: description" or "type(scope): description"
    if [[ $msg =~ ^([a-z]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Check if commit contains BREAKING CHANGE
has_breaking_change() {
    local commit_hash="$1"
    git show "$commit_hash" | grep -q "BREAKING CHANGE:" && echo "yes" || echo ""
}

# ─── Changelog generation ─────────────────────────────────────────────────

# Get commits between two revisions
get_commits() {
    local from="$1" to="$2"

    if [[ "$from" == "v0.0.0" ]]; then
        git log "$to" --oneline --format="%h|%s|%b" 2>/dev/null || true
    else
        git log "${from}..${to}" --oneline --format="%h|%s|%b" 2>/dev/null || true
    fi
}

# Parse commits and categorize them (using parallel arrays for bash 3.2 compatibility)
categorize_commits() {
    local from="$1" to="$2"

    # Use parallel arrays instead of associative arrays
    local breaking_hashes=() breaking_subjects=()
    local features_hashes=() features_subjects=()
    local fixes_hashes=() fixes_subjects=()
    local chores_hashes=() chores_subjects=()
    local docs_hashes=() docs_subjects=()

    # Read commits from git log
    while IFS='|' read -r hash subject body; do
        [[ -z "$hash" ]] && continue

        local type
        type="$(get_commit_type "$subject")"

        # Check for breaking change
        local breaking_flag=""
        if echo "$body" | grep -q "BREAKING CHANGE:"; then
            breaking_flag="yes"
        fi

        # Categorize using parallel arrays
        case "$type" in
            feat)
                if [[ "$breaking_flag" == "yes" ]]; then
                    breaking_hashes+=("$hash")
                    breaking_subjects+=("$subject")
                else
                    features_hashes+=("$hash")
                    features_subjects+=("$subject")
                fi
                ;;
            fix)
                fixes_hashes+=("$hash")
                fixes_subjects+=("$subject")
                ;;
            chore|ci|test)
                chores_hashes+=("$hash")
                chores_subjects+=("$subject")
                ;;
            docs)
                docs_hashes+=("$hash")
                docs_subjects+=("$subject")
                ;;
        esac
    done < <(get_commits "$from" "$to")

    # Output data (not used by default, kept for future use)
    true
}

# Generate markdown changelog (bash 3.2 compatible - no associative arrays)
generate_changelog_md() {
    local version="$1" from="$2" to="$3"

    echo "## [$version] — $(date +%Y-%m-%d)"
    echo ""

    # Use grep filtering to categorize commits
    local breaking_commits docs_commits features_commits fixes_commits

    breaking_commits="$(get_commits "$from" "$to" | while IFS='|' read -r hash subject body; do
        [[ -z "$hash" ]] && continue
        type="$(get_commit_type "$subject")"
        if [[ "$type" == "feat" ]] && echo "$body" | grep -q "BREAKING CHANGE:"; then
            echo "$hash|$subject"
        fi
    done)"

    features_commits="$(get_commits "$from" "$to" | while IFS='|' read -r hash subject body; do
        [[ -z "$hash" ]] && continue
        type="$(get_commit_type "$subject")"
        if [[ "$type" == "feat" ]] && ! echo "$body" | grep -q "BREAKING CHANGE:"; then
            echo "$hash|$subject"
        fi
    done)"

    fixes_commits="$(get_commits "$from" "$to" | while IFS='|' read -r hash subject body; do
        [[ -z "$hash" ]] && continue
        type="$(get_commit_type "$subject")"
        [[ "$type" == "fix" ]] && echo "$hash|$subject"
    done)"

    docs_commits="$(get_commits "$from" "$to" | while IFS='|' read -r hash subject body; do
        [[ -z "$hash" ]] && continue
        type="$(get_commit_type "$subject")"
        [[ "$type" == "docs" ]] && echo "$hash|$subject"
    done)"

    # Breaking changes section
    if [[ -n "$breaking_commits" ]]; then
        echo "### Breaking Changes"
        echo ""
        echo "$breaking_commits" | while IFS='|' read -r hash subject; do
            [[ -z "$hash" ]] && continue
            echo "- $subject ([\`$hash\`]($(_sw_github_url)/commit/$hash))"
        done
        echo ""
    fi

    # Features section
    if [[ -n "$features_commits" ]]; then
        echo "### Features"
        echo ""
        echo "$features_commits" | while IFS='|' read -r hash subject; do
            [[ -z "$hash" ]] && continue
            echo "- $subject ([\`$hash\`]($(_sw_github_url)/commit/$hash))"
        done
        echo ""
    fi

    # Fixes section
    if [[ -n "$fixes_commits" ]]; then
        echo "### Bug Fixes"
        echo ""
        echo "$fixes_commits" | while IFS='|' read -r hash subject; do
            [[ -z "$hash" ]] && continue
            echo "- $subject ([\`$hash\`]($(_sw_github_url)/commit/$hash))"
        done
        echo ""
    fi

    # Docs section
    if [[ -n "$docs_commits" ]]; then
        echo "### Documentation"
        echo ""
        echo "$docs_commits" | while IFS='|' read -r hash subject; do
            [[ -z "$hash" ]] && continue
            echo "- $subject ([\`$hash\`]($(_sw_github_url)/commit/$hash))"
        done
        echo ""
    fi
}

# ─── Version detection ─────────────────────────────────────────────────────

# Detect next version based on commit types
detect_next_version() {
    local current="$1" from="$2" to="$3"

    local has_breaking=false
    local has_feature=false

    while IFS='|' read -r hash subject body; do
        [[ -z "$hash" ]] && continue

        local type
        type="$(get_commit_type "$subject")"

        case "$type" in
            feat)
                has_feature=true
                if echo "$body" | grep -q "BREAKING CHANGE:"; then
                    has_breaking=true
                fi
                ;;
        esac
    done < <(get_commits "$from" "$to")

    if $has_breaking; then
        bump_version "$current" "major"
    elif $has_feature; then
        bump_version "$current" "minor"
    else
        bump_version "$current" "patch"
    fi
}

# ─── Update VERSION in scripts ─────────────────────────────────────────────

update_version_in_files() {
    local new_version="$1"
    local version_num="${new_version#v}"  # Strip 'v' prefix

    info "Updating VERSION variable in scripts..."

    # Find all shell scripts with VERSION variable
    while IFS= read -r file; do
        if grep -q '^VERSION=' "$file"; then
            # Use sed to update VERSION="x.y.z" pattern
            # This is shell-safe: VERSION="1.11.0" → VERSION="1.12.0"
            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" RETURN
            sed 's/^VERSION="[^"]*"$/VERSION="'"$version_num"'"/' "$file" > "$tmp_file"
            mv "$tmp_file" "$file"
            success "Updated VERSION in $(basename "$file")"
        fi
    done < <(find "$REPO_DIR/scripts" -name "sw*.sh" -o -name "lib/*.sh" 2>/dev/null)
}

# ─── Command implementations ──────────────────────────────────────────────

cmd_prepare() {
    local current_version
    current_version="$(get_latest_tag)"

    if [[ -z "$VERSION_TYPE" ]]; then
        # Auto-detect from commits
        info "Auto-detecting version bump from commits..."
        local next_version
        next_version="$(detect_next_version "$current_version" "$current_version" "HEAD")"
        VERSION_TYPE="detected"
    else
        local next_version
        next_version="$(bump_version "$current_version" "$VERSION_TYPE")"
    fi

    echo ""
    info "Release Preparation"
    echo ""
    echo -e "  Current version:     ${CYAN}${current_version}${RESET}"
    echo -e "  Next version:        ${CYAN}${next_version}${RESET}"
    echo -e "  Bump type:           ${CYAN}${VERSION_TYPE}${RESET}"

    if $DRY_RUN; then
        echo -e "  Mode:                ${YELLOW}DRY RUN${RESET}"
    fi

    echo ""

    if ! $DRY_RUN; then
        echo -e "This will:"
        echo -e "  1. Update VERSION variable in all scripts"
        echo -e "  2. Generate changelog"
        echo -e "  3. Create git tag: ${CYAN}${next_version}${RESET}"
        echo ""

        read -p "Continue? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            warn "Aborted"
            return 1
        fi

        update_version_in_files "$next_version"
    fi

    success "Preparation complete"
}

cmd_changelog() {
    local from_tag="$FROM_TAG"
    local to_tag="$TO_TAG"

    if [[ -z "$from_tag" ]]; then
        from_tag="$(get_latest_tag)"
    fi

    info "Generating changelog"
    echo ""

    echo -e "From:   ${CYAN}${from_tag}${RESET}"
    echo -e "To:     ${CYAN}${to_tag}${RESET}"
    echo ""

    if $DRY_RUN; then
        echo -e "${YELLOW}DRY RUN${RESET} — showing preview only"
        echo ""
    fi

    local changelog
    changelog="$(generate_changelog_md "$to_tag" "$from_tag" "$to_tag")"

    echo "$changelog"

    echo ""
    success "Changelog generated"
}

cmd_tag() {
    local tag_version="$1"

    if [[ -z "$tag_version" ]]; then
        error "Version required: shipwright release tag v1.2.3"
        return 1
    fi

    info "Creating git tag: ${CYAN}${tag_version}${RESET}"
    echo ""

    # Validate format
    if ! [[ $tag_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Invalid version format. Expected: v1.2.3"
        return 1
    fi

    if $DRY_RUN; then
        echo -e "${YELLOW}DRY RUN${RESET} — tag would be created"
        echo ""
        success "Tag validation passed"
        return
    fi

    # Create annotated tag with message
    local tag_msg="Release $tag_version"
    git tag -a "$tag_version" -m "$tag_msg"

    success "Tag created: ${CYAN}${tag_version}${RESET}"

    # Show next steps
    echo ""
    info "Push tag with: ${DIM}git push origin $tag_version${RESET}"
}

cmd_publish() {
    local current_version
    current_version="$(get_latest_tag)"

    local next_version
    next_version="$(detect_next_version "$current_version" "$current_version" "HEAD")"

    info "Full Release: ${CYAN}${next_version}${RESET}"
    echo ""

    if $DRY_RUN; then
        echo -e "${YELLOW}DRY RUN${RESET} — showing what would happen:"
        echo ""
        echo "  1. Update all VERSION variables to ${CYAN}${next_version#v}${RESET}"
        echo "  2. Generate changelog"
        echo "  3. Create git tag: ${CYAN}${next_version}${RESET}"
        echo "  4. Push tag to origin"
        echo "  5. Create GitHub release"
        echo ""
        success "Dry run complete — no changes made"
        return
    fi

    read -p "Release ${next_version}? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Aborted"
        return 1
    fi

    echo ""

    # Step 1: Update versions
    info "Step 1/5: Updating VERSION variables..."
    update_version_in_files "$next_version"
    echo ""

    # Step 2: Generate changelog
    info "Step 2/5: Generating changelog..."
    local changelog
    changelog="$(generate_changelog_md "$next_version" "$current_version" "HEAD")"
    echo "$changelog" > /tmp/release-changelog.md
    success "Changelog generated"
    echo ""

    # Step 3: Create git tag
    info "Step 3/5: Creating git tag..."
    git tag -a "$next_version" -m "Release $next_version"
    success "Tag created"
    echo ""

    # Step 4: Push tag
    info "Step 4/5: Pushing tag to origin..."
    if git push origin "$next_version"; then
        success "Tag pushed"
    else
        warn "Failed to push tag (may already exist)"
    fi
    echo ""

    # Step 5: Create GitHub release
    info "Step 5/5: Creating GitHub release..."
    if command -v gh &>/dev/null; then
        if gh release create "$next_version" --title "$next_version" --notes-file /tmp/release-changelog.md; then
            success "GitHub release created"
        else
            warn "Failed to create GitHub release (may already exist)"
        fi
    else
        warn "gh CLI not installed — skipping GitHub release creation"
        echo -e "  Manual create: ${DIM}gh release create $next_version --title '$next_version' --notes-file /tmp/release-changelog.md${RESET}"
    fi
    echo ""

    success "Release ${next_version} complete!"

    emit_event "release" "version=$next_version" "type=publish"
}

cmd_status() {
    local current_version
    current_version="$(get_latest_tag)"

    info "Release Status"
    echo ""
    echo -e "  Current version:     ${CYAN}${current_version}${RESET}"

    # Check for unreleased commits
    local unreleased_count
    unreleased_count="$(git rev-list "${current_version}..HEAD" --count 2>/dev/null || echo 0)"

    if [[ $unreleased_count -gt 0 ]]; then
        echo -e "  Unreleased commits:  ${YELLOW}${unreleased_count}${RESET}"

        # Predict next version
        local next_version
        next_version="$(detect_next_version "$current_version" "$current_version" "HEAD")"

        echo -e "  Predicted next:      ${CYAN}${next_version}${RESET}"

        echo ""
        info "Recent commits:"
        git log "${current_version}..HEAD" --oneline | head -5
    else
        echo -e "  Unreleased commits:  ${GREEN}0${RESET}"
        echo ""
        success "All commits have been released"
    fi

    echo ""
}

cmd_help() {
    cat << 'EOF'
shipwright release — Release train automation

USAGE
  shipwright release <command> [options]

COMMANDS
  prepare [--major|--minor|--patch]
      Prepare a release: bump version, generate changelog
      Auto-detects version type from conventional commits if not specified

  changelog [--from TAG --to HEAD]
      Generate markdown changelog from conventional commits
      Default: from last tag to HEAD

  tag [version]
      Create and push a git tag (e.g., v1.2.3)
      Validates semantic version format

  publish
      Full automated release: prepare + changelog + tag + GitHub release
      Updates all VERSION variables, commits, tags, and creates release

  status
      Show current version, unreleased commits, and predicted next version

  help
      Show this help message

OPTIONS
  --dry-run
      Show what would happen without making changes

  --major
      Release with major version bump (for breaking changes)

  --minor
      Release with minor version bump (for new features)

  --patch
      Release with patch version bump (for bug fixes)

  --from TAG
      Start changelog from specific tag (changelog only)

  --to REV
      End changelog at specific revision (default: HEAD)

EXAMPLES
  # Check current release status
  shipwright release status

  # Auto-detect and prepare next release
  shipwright release prepare

  # Force a minor version bump
  shipwright release prepare --minor

  # Generate changelog from v1.0.0 to HEAD
  shipwright release changelog --from v1.0.0

  # Dry run of full release
  shipwright release publish --dry-run

  # Publish full release
  shipwright release publish

CONVENTIONAL COMMITS

The release tool parses commits to auto-detect version bumps:

  feat: New feature             → minor version bump
  fix: Bug fix                  → patch version bump
  BREAKING CHANGE: in message   → major version bump
  chore, docs, ci: Other        → no bump (patch only)

Example commit messages:
  - "feat: add authentication system"
  - "fix: prevent data loss in sync"
  - "feat: new API endpoint\n\nBREAKING CHANGE: old endpoint removed"

EOF
}

# ─── Main router ──────────────────────────────────────────────────────────

main() {
    local cmd="${1:-status}"
    shift 2>/dev/null || true

    case "$cmd" in
        prepare)
            cmd_prepare "$@"
            ;;
        changelog)
            cmd_changelog "$@"
            ;;
        tag)
            cmd_tag "$@"
            ;;
        publish)
            cmd_publish "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# Only run main if this script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
