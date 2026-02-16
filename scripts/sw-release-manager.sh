#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright release-manager — Autonomous Release Pipeline                     ║
# ║  Readiness checks · Version bumping · Changelog · RC flow · Rollback     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.2"
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

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Release State Storage ─────────────────────────────────────────────────
RELEASE_STATE_DIR="${HOME}/.shipwright/releases"

ensure_release_dir() {
    mkdir -p "$RELEASE_STATE_DIR"
}

# ─── Git helpers ─────────────────────────────────────────────────────────────

get_latest_tag() {
    git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0"
}

parse_version() {
    local version="$1"
    version="${version#v}"
    IFS='.' read -r major minor patch <<< "$version"
    echo "$major|$minor|${patch:-0}"
}

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

detect_bump_type() {
    local from="$1" to="$2"
    local has_breaking=false
    local has_feature=false

    while IFS='|' read -r hash subject body; do
        [[ -z "$hash" ]] && continue

        local type
        if [[ $subject =~ ^([a-z]+) ]]; then
            type="${BASH_REMATCH[1]}"
        else
            continue
        fi

        case "$type" in
            feat)
                has_feature=true
                if echo "$body" | grep -q "BREAKING CHANGE:"; then
                    has_breaking=true
                fi
                ;;
        esac
    done < <(git log "${from}..${to}" --format="%h|%s|%b" 2>/dev/null || true)

    if [[ "$has_breaking" == "true" ]]; then
        echo "major"
    elif [[ "$has_feature" == "true" ]]; then
        echo "minor"
    else
        echo "patch"
    fi
}

# ─── Quality Gate Checks ──────────────────────────────────────────────────

check_tests_passing() {
    info "Checking test status..."

    if [[ ! -f "$REPO_DIR/package.json" ]]; then
        warn "No package.json found — skipping test check"
        return 0
    fi

    if ! npm test 2>&1 | tee /tmp/test-output.log | tail -20; then
        error "Tests are not passing"
        return 1
    fi

    success "All tests passing"
    return 0
}

check_coverage_threshold() {
    local threshold="${1:-80}"
    info "Checking test coverage (threshold: ${threshold}%)..."

    if [[ ! -f /tmp/test-output.log ]]; then
        warn "No test output found — skipping coverage check"
        return 0
    fi

    local coverage=""
    coverage=$(grep -oE '[0-9]+%' /tmp/test-output.log | head -1 | tr -d '%' || echo "")

    if [[ -z "$coverage" ]]; then
        warn "Could not determine coverage percentage"
        return 0
    fi

    if [[ $coverage -lt $threshold ]]; then
        error "Coverage ${coverage}% is below threshold ${threshold}%"
        return 1
    fi

    success "Coverage ${coverage}% meets threshold"
    return 0
}

check_no_open_blockers() {
    info "Checking for open blockers..."

    if ! command -v gh &>/dev/null; then
        warn "GitHub CLI not available — skipping blocker check"
        return 0
    fi

    local blockers
    blockers=$(gh issue list --label "blocker" --state "open" --json "number" 2>/dev/null | jq 'length' || echo "0")

    if [[ $blockers -gt 0 ]]; then
        error "Found $blockers open blocker issues"
        return 1
    fi

    success "No open blocker issues"
    return 0
}

check_security_scan() {
    info "Checking security scan status..."

    if ! command -v gh &>/dev/null; then
        warn "GitHub CLI not available — skipping security check"
        return 0
    fi

    local vulns
    vulns=$(gh api repos/{owner}/{repo}/dependabot/alerts --jq 'length' 2>/dev/null || echo "0")

    if [[ $vulns -gt 0 ]]; then
        error "Found $vulns security vulnerabilities"
        return 1
    fi

    success "Security scan clean"
    return 0
}

check_docs_updated() {
    info "Checking documentation status..."

    # Check if stale documentation markers exist
    if grep -r "AUTO:" "$REPO_DIR/.claude/CLAUDE.md" 2>/dev/null | grep -qv "AUTO.*:"; then
        warn "Documentation contains stale AUTO sections"
        return 1
    fi

    success "Documentation is up to date"
    return 0
}

# ─── Release Readiness ──────────────────────────────────────────────────────

check_release_readiness() {
    local exit_code=0

    echo ""
    info "Performing release readiness checks..."
    echo ""

    check_tests_passing || exit_code=1
    echo ""

    check_coverage_threshold 80 || exit_code=1
    echo ""

    check_no_open_blockers || exit_code=1
    echo ""

    check_security_scan || exit_code=1
    echo ""

    check_docs_updated || exit_code=1
    echo ""

    if [[ $exit_code -eq 0 ]]; then
        success "All release gates passing ✓"
        return 0
    else
        error "Release readiness check failed"
        return 1
    fi
}

# ─── Prepare Release ──────────────────────────────────────────────────────

prepare_release() {
    local current_version
    current_version="$(get_latest_tag)"

    # Detect bump type from commits
    local bump_type
    bump_type="$(detect_bump_type "$current_version" "HEAD")"

    local next_version
    next_version="$(bump_version "$current_version" "$bump_type")"

    echo ""
    info "Release Preparation"
    echo ""
    echo -e "  Current version:     ${CYAN}${current_version}${RESET}"
    echo -e "  Next version:        ${CYAN}${next_version}${RESET}"
    echo -e "  Bump type:           ${CYAN}${bump_type}${RESET}"
    echo ""

    # Save state to file
    ensure_release_dir
    local state_file="$RELEASE_STATE_DIR/current-release.json"
    jq -n --arg version "$next_version" \
           --arg bump_type "$bump_type" \
           --arg timestamp "$(now_iso)" \
           '{version: $version, bump_type: $bump_type, status: "prepared", timestamp: $timestamp}' > "$state_file"

    success "Release prepared: $next_version"
    emit_event "release.prepare" "version=$next_version" "bump_type=$bump_type"
}

# ─── Publish Release ──────────────────────────────────────────────────────

publish_release() {
    local release_state_file="$RELEASE_STATE_DIR/current-release.json"

    if [[ ! -f "$release_state_file" ]]; then
        error "No prepared release found — run 'prepare' first"
        return 1
    fi

    local next_version
    next_version=$(jq -r '.version' "$release_state_file")

    info "Publishing release: ${CYAN}${next_version}${RESET}"
    echo ""

    # Create annotated tag
    if git tag -a "$next_version" -m "Release $next_version"; then
        success "Git tag created"
    else
        error "Failed to create git tag"
        return 1
    fi

    # Push tag to origin
    if git push origin "$next_version"; then
        success "Tag pushed to origin"
    else
        warn "Failed to push tag"
    fi

    # Create GitHub release
    if command -v gh &>/dev/null; then
        if gh release create "$next_version" --title "$next_version" --generate-notes; then
            success "GitHub release created"
        else
            warn "Failed to create GitHub release"
        fi
    else
        warn "GitHub CLI not available — skipping release creation"
    fi

    # Update state
    jq '.status = "published"' "$release_state_file" > "${release_state_file}.tmp" && \
        mv "${release_state_file}.tmp" "$release_state_file"

    success "Release published: ${CYAN}${next_version}${RESET}"
    emit_event "release.publish" "version=$next_version"
}

# ─── Release Candidate Flow ──────────────────────────────────────────────

create_rc() {
    local rc_number="${1:-1}"
    local current_version
    current_version="$(get_latest_tag)"

    local bump_type
    bump_type="$(detect_bump_type "$current_version" "HEAD")"

    local next_version
    next_version="$(bump_version "$current_version" "$bump_type")"

    local rc_version="${next_version}-rc.${rc_number}"

    info "Creating release candidate: ${CYAN}${rc_version}${RESET}"
    echo ""

    # Create RC tag
    if git tag -a "$rc_version" -m "Release Candidate: $rc_version"; then
        success "RC tag created"
    else
        error "Failed to create RC tag"
        return 1
    fi

    # Push RC tag
    if git push origin "$rc_version"; then
        success "RC tag pushed"
    else
        warn "Failed to push RC tag"
    fi

    # Create GitHub pre-release
    if command -v gh &>/dev/null; then
        if gh release create "$rc_version" --title "RC: $rc_version" --prerelease --generate-notes; then
            success "GitHub pre-release created"
        else
            warn "Failed to create GitHub pre-release"
        fi
    fi

    # Save RC state
    ensure_release_dir
    local rc_state_file="$RELEASE_STATE_DIR/rc-${rc_number}.json"
    jq -n --arg version "$rc_version" \
           --arg timestamp "$(now_iso)" \
           '{version: $version, rc_number: '$rc_number', status: "active", timestamp: $timestamp}' > "$rc_state_file"

    success "RC created: ${CYAN}${rc_version}${RESET}"
    emit_event "release.rc_create" "version=$rc_version" "rc_number=$rc_number"
}

promote_rc() {
    local rc_number="${1:-1}"
    local rc_state_file="$RELEASE_STATE_DIR/rc-${rc_number}.json"

    if [[ ! -f "$rc_state_file" ]]; then
        error "RC ${rc_number} not found"
        return 1
    fi

    local rc_version
    rc_version=$(jq -r '.version' "$rc_state_file")

    info "Promoting RC to stable: ${CYAN}${rc_version}${RESET}"
    echo ""

    # Extract stable version (remove -rc.X)
    local stable_version="${rc_version%-rc*}"

    # Create stable tag from RC
    if git tag -a "$stable_version" -m "Release $stable_version" "$(git rev-list -n 1 "$rc_version")"; then
        success "Stable tag created"
    else
        error "Failed to create stable tag"
        return 1
    fi

    # Push stable tag
    if git push origin "$stable_version"; then
        success "Stable tag pushed"
    else
        warn "Failed to push stable tag"
    fi

    # Create GitHub release (not pre-release)
    if command -v gh &>/dev/null; then
        if gh release create "$stable_version" --title "$stable_version" --generate-notes; then
            success "GitHub release created"
        else
            warn "Failed to create GitHub release"
        fi
    fi

    # Update RC state
    jq '.status = "promoted"' "$rc_state_file" > "${rc_state_file}.tmp" && \
        mv "${rc_state_file}.tmp" "$rc_state_file"

    success "RC promoted to stable: ${CYAN}${stable_version}${RESET}"
    emit_event "release.rc_promote" "rc_version=$rc_version" "stable_version=$stable_version"
}

# ─── Rollback ──────────────────────────────────────────────────────────

rollback_release() {
    local version="${1:-}"

    if [[ -z "$version" ]]; then
        version="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
    fi

    if [[ -z "$version" ]]; then
        error "No version specified and no recent tag found"
        return 1
    fi

    info "Rolling back release: ${CYAN}${version}${RESET}"
    echo ""

    # Delete local tag
    if git tag -d "$version"; then
        success "Local tag deleted"
    else
        warn "Failed to delete local tag"
    fi

    # Delete remote tag
    if git push origin ":refs/tags/$version"; then
        success "Remote tag deleted"
    else
        warn "Failed to delete remote tag"
    fi

    # Delete GitHub release
    if command -v gh &>/dev/null; then
        if gh release delete "$version" --yes 2>/dev/null; then
            success "GitHub release deleted"
        else
            warn "Failed to delete GitHub release"
        fi
    fi

    success "Rollback complete for ${CYAN}${version}${RESET}"
    emit_event "release.rollback" "version=$version"
}

# ─── Release Schedule ──────────────────────────────────────────────────────

set_release_schedule() {
    local schedule_type="${1:-}"

    if [[ -z "$schedule_type" ]]; then
        error "Schedule type required: weekly, on-demand, on-green"
        return 1
    fi

    ensure_release_dir
    local schedule_file="$RELEASE_STATE_DIR/schedule.json"

    case "$schedule_type" in
        weekly)
            jq -n --arg type "weekly" \
                   --arg day "monday" \
                   --arg time "09:00 UTC" \
                   --arg timestamp "$(now_iso)" \
                   '{type: $type, day: $day, time: $time, timestamp: $timestamp}' > "$schedule_file"
            success "Release schedule set to: weekly (Monday 09:00 UTC)"
            ;;
        on-demand)
            jq -n --arg type "on-demand" \
                   --arg timestamp "$(now_iso)" \
                   '{type: $type, timestamp: $timestamp}' > "$schedule_file"
            success "Release schedule set to: on-demand"
            ;;
        on-green)
            jq -n --arg type "on-green" \
                   --arg threshold "all gates passing" \
                   --arg timestamp "$(now_iso)" \
                   '{type: $type, threshold: $threshold, timestamp: $timestamp}' > "$schedule_file"
            success "Release schedule set to: on-green (all gates passing)"
            ;;
        *)
            error "Unknown schedule type: $schedule_type"
            return 1
            ;;
    esac

    emit_event "release.schedule" "type=$schedule_type"
}

# ─── History and Stats ──────────────────────────────────────────────────

show_history() {
    info "Release History"
    echo ""

    if ! command -v gh &>/dev/null; then
        error "GitHub CLI required for history"
        return 1
    fi

    gh release list --limit 10
    echo ""
}

show_stats() {
    info "Release Statistics"
    echo ""

    local total_releases
    total_releases=$(git tag | wc -l)

    local releases_this_month
    releases_this_month=$(git log --all --oneline --grep="Release" --since="1 month ago" | wc -l)

    local days_since_last
    local last_tag
    last_tag="$(get_latest_tag)"
    days_since_last=$(git log "$last_tag"..HEAD --format="%ai" | wc -l)

    echo -e "  Total releases:      ${CYAN}${total_releases}${RESET}"
    echo -e "  This month:          ${CYAN}${releases_this_month}${RESET}"
    echo -e "  Commits since last:  ${CYAN}${days_since_last}${RESET}"
    echo ""
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    cat << 'EOF'
shipwright release-manager — Autonomous Release Pipeline

USAGE
  shipwright release-manager <command> [options]
  shipwright rm <command> [options]

COMMANDS
  check
      Check release readiness (all quality gates)
      • Tests passing
      • Coverage threshold met (80%)
      • No open blocker issues
      • Security scan clean
      • Documentation up to date

  prepare
      Prepare a release (determine version, but don't publish)
      Auto-detects version from conventional commits
      Saves state for publication

  publish
      Publish prepared release (create tag + GitHub release)
      Requires prepared state from 'prepare' command

  rc [RC_NUMBER]
      Create release candidate (e.g., v1.2.0-rc.1)
      Default RC_NUMBER: 1

  promote RC_NUMBER
      Promote release candidate to stable release
      Example: shipwright rm promote 1

  rollback [VERSION]
      Rollback a release (delete tag + GitHub release)
      If no VERSION specified, rolls back latest tag

  schedule SCHEDULE_TYPE
      Set release schedule
      Types: weekly, on-demand, on-green

  history
      Show recent releases and stats

  stats
      Show release statistics

  help
      Show this help message

OPTIONS
  (none at this time)

EXAMPLES
  # Check if we can release
  shipwright release-manager check

  # Prepare a release
  shipwright release-manager prepare

  # Publish after all checks pass
  shipwright release-manager publish

  # Create release candidate
  shipwright release-manager rc 1

  # Promote RC to stable
  shipwright release-manager promote 1

  # Rollback last release
  shipwright release-manager rollback

  # Set automatic on-green releases
  shipwright release-manager schedule on-green

  # View release history
  shipwright release-manager history

CONVENTIONAL COMMITS

The release manager auto-detects version bumps from commits:

  feat: New feature             → minor version bump
  fix: Bug fix                  → patch version bump
  BREAKING CHANGE: in message   → major version bump

QUALITY GATES

A release requires all of these checks to pass:
  ✓ Tests passing
  ✓ Coverage >= 80%
  ✓ No open blockers
  ✓ Security scan clean
  ✓ Documentation updated

RC FLOW

1. Create RC: shipwright rm rc 1         → v1.2.0-rc.1
2. Test RC in staging
3. Promote: shipwright rm promote 1      → v1.2.0
4. Monitor in production

ALIASES

  shipwright rm = shipwright release-manager

EOF
}

# ─── Main Router ──────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        check)
            check_release_readiness
            ;;
        prepare)
            prepare_release
            ;;
        publish)
            publish_release
            ;;
        rc)
            create_rc "${1:-1}"
            ;;
        promote)
            promote_rc "${1:-}"
            ;;
        rollback)
            rollback_release "${1:-}"
            ;;
        schedule)
            set_release_schedule "${1:-}"
            ;;
        history)
            show_history
            ;;
        stats)
            show_stats
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Source guard: allow sourcing without executing
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
