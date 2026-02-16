#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright deps — Automated Dependency Update Management               ║
# ║  Scan · Classify · Test · Merge Dependabot/Renovate PRs                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Defaults ───────────────────────────────────────────────────────────────
DEPS_DIR="${HOME}/.shipwright/deps"
TEST_CMD=""
AUTO_MERGE=false
DRY_RUN=false

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright deps${RESET} — Dependency update automation"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright deps${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}scan${RESET}          List all open Dependabot/Renovate PRs"
    echo -e "  ${CYAN}classify${RESET}      Risk-score a PR (default: highest priority first)"
    echo -e "  ${CYAN}test${RESET}          Run tests against a PR branch"
    echo -e "  ${CYAN}merge${RESET}         Auto-merge low-risk PRs (with testing)"
    echo -e "  ${CYAN}batch${RESET}         Process all open dependency PRs (classify, test, merge)"
    echo -e "  ${CYAN}report${RESET}        Dependency health dashboard"
    echo -e "  ${CYAN}help${RESET}          Show this message"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${DIM}--test-cmd \"cmd\"${RESET}      Test command to run (e.g., 'npm test')"
    echo -e "  ${DIM}--auto-merge${RESET}          Auto-merge patches without prompt"
    echo -e "  ${DIM}--dry-run${RESET}             Show what would happen"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright deps scan${RESET}                           # List all dependency PRs"
    echo -e "  ${DIM}shipwright deps classify 123${RESET}                    # Score PR #123"
    echo -e "  ${DIM}shipwright deps test 123 --test-cmd \"npm test\"${RESET}"
    echo -e "  ${DIM}shipwright deps batch --auto-merge${RESET}              # Process all PRs"
    echo -e "  ${DIM}shipwright deps report${RESET}                         # Health dashboard"
    echo ""
}

# ─── Parse Version Strings ──────────────────────────────────────────────────

parse_version_bump() {
    local from="$1" to="$2"
    local from_major from_minor from_patch
    local to_major to_minor to_patch

    # Extract major.minor.patch (handle v prefix and pre-release)
    from="${from#v}"
    from="${from%%-*}"
    to="${to#v}"
    to="${to%%-*}"

    # Split on dots
    IFS='.' read -r from_major from_minor from_patch <<< "$from" || true
    IFS='.' read -r to_major to_minor to_patch <<< "$to" || true

    from_major="${from_major:-0}"
    from_minor="${from_minor:-0}"
    from_patch="${from_patch:-0}"
    to_major="${to_major:-0}"
    to_minor="${to_minor:-0}"
    to_patch="${to_patch:-0}"

    if [[ "$to_major" != "$from_major" ]]; then
        echo "major"
    elif [[ "$to_minor" != "$from_minor" ]]; then
        echo "minor"
    else
        echo "patch"
    fi
}

# ─── Scan for Dependency PRs ────────────────────────────────────────────────

cmd_scan() {
    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "GitHub API disabled (NO_GITHUB set)"
        return
    fi

    info "Scanning for dependency PRs..."
    echo ""

    local prs
    prs=$(gh pr list --author "dependabot[bot]" --author "renovate[bot]" --state open --json number,title,author,createdAt --template '{{json .}}' 2>/dev/null || echo '[]')

    if [[ -z "$prs" || "$prs" == "[]" ]]; then
        info "No open dependency PRs found."
        return
    fi

    local patch_count=0 minor_count=0 major_count=0

    echo "$prs" | jq -r '.[] | "\(.number)|\(.title)|\(.author.login)"' | while IFS='|' read -r pr_num title author; do
        # Extract version info from title (e.g., "Bump lodash from 4.17.20 to 4.17.21")
        if [[ "$title" =~ from\ ([^ ]+)\ to\ ([^ ]+) ]]; then
            local from_ver="${BASH_REMATCH[1]}"
            local to_ver="${BASH_REMATCH[2]}"
            local bump_type
            bump_type=$(parse_version_bump "$from_ver" "$to_ver")

            local color="$GREEN"
            [[ "$bump_type" == "minor" ]] && color="$YELLOW"
            [[ "$bump_type" == "major" ]] && color="$RED"

            printf "  ${color}%-8s${RESET} #%-5d  %s (${DIM}%s → %s${RESET})\n" \
                "$bump_type" "$pr_num" "$title" "$from_ver" "$to_ver"
        else
            printf "  ${YELLOW}%-8s${RESET} #%-5d  %s\n" "unknown" "$pr_num" "$title"
        fi
    done

    echo ""
    emit_event "deps.scan.completed" "timestamp=$(now_iso)"
}

# ─── Classify a PR by Risk ──────────────────────────────────────────────────

cmd_classify() {
    local pr_num="${1:-}"
    if [[ -z "$pr_num" ]]; then
        error "Usage: shipwright deps classify <pr-number>"
        exit 1
    fi

    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "GitHub API disabled (NO_GITHUB set)"
        return
    fi

    info "Classifying PR #${pr_num}..."

    local pr_data
    pr_data=$(gh pr view "$pr_num" --json number,title,author,changedFiles,isDraft --template '{{json .}}' 2>/dev/null)

    if [[ -z "$pr_data" ]]; then
        error "PR #${pr_num} not found"
        exit 1
    fi

    local title changed_files author
    title=$(echo "$pr_data" | jq -r '.title')
    changed_files=$(echo "$pr_data" | jq -r '.changedFiles')
    author=$(echo "$pr_data" | jq -r '.author.login')

    # Extract version bump type
    local from_ver to_ver bump_type
    if [[ "$title" =~ from\ ([^ ]+)\ to\ ([^ ]+) ]]; then
        from_ver="${BASH_REMATCH[1]}"
        to_ver="${BASH_REMATCH[2]}"
        bump_type=$(parse_version_bump "$from_ver" "$to_ver")
    else
        bump_type="unknown"
        from_ver="?"
        to_ver="?"
    fi

    # Score risk
    local risk_level risk_score recommendation
    case "$bump_type" in
        patch)
            risk_level="low"
            risk_score=15
            recommendation="auto-merge"
            ;;
        minor)
            risk_level="medium"
            risk_score=50
            recommendation="review"
            ;;
        major)
            risk_level="high"
            risk_score=85
            recommendation="full-pipeline"
            ;;
        *)
            risk_level="unknown"
            risk_score=60
            recommendation="manual-review"
            ;;
    esac

    # Adjust for file count
    if [[ "$changed_files" -gt 10 ]]; then
        risk_score=$((risk_score + 20))
    fi

    # Build JSON output
    local output
    output=$(jq -n \
        --argjson pr_number "$pr_num" \
        --arg title "$title" \
        --arg author "$author" \
        --arg bump_type "$bump_type" \
        --arg from_version "$from_ver" \
        --arg to_version "$to_ver" \
        --argjson changed_files "$changed_files" \
        --arg risk_level "$risk_level" \
        --argjson risk_score "$risk_score" \
        --arg recommendation "$recommendation" \
        '{
            pr_number: $pr_number,
            title: $title,
            author: $author,
            bump_type: $bump_type,
            from_version: $from_version,
            to_version: $to_version,
            changed_files: $changed_files,
            risk_level: $risk_level,
            risk_score: $risk_score,
            recommendation: $recommendation
        }')

    echo "$output" | jq .

    emit_event "deps.classify.completed" "pr=$pr_num" "risk=$risk_level" "score=$risk_score"
}

# ─── Test PR ────────────────────────────────────────────────────────────────

cmd_test() {
    local pr_num="${1:-}"
    if [[ -z "$pr_num" ]]; then
        error "Usage: shipwright deps test <pr-number> [--test-cmd \"cmd\"]"
        exit 1
    fi
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --test-cmd) TEST_CMD="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "GitHub API disabled (NO_GITHUB set)"
        return
    fi

    if [[ -z "$TEST_CMD" ]]; then
        # Auto-detect test command
        if [[ -f "package.json" ]]; then
            TEST_CMD="npm test"
        elif [[ -f "Gemfile" ]]; then
            TEST_CMD="bundle exec rspec"
        elif [[ -f "pytest.ini" || -f "setup.py" ]]; then
            TEST_CMD="pytest"
        else
            warn "Could not auto-detect test command. Specify with --test-cmd"
            return
        fi
    fi

    info "Testing PR #${pr_num}..."
    info "Test command: ${DIM}${TEST_CMD}${RESET}"

    # Save current branch
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    # Checkout PR branch
    if ! gh pr checkout "$pr_num" 2>/dev/null; then
        error "Failed to checkout PR #${pr_num}"
        return 1
    fi

    local test_passed=false
    local test_output=""

    # Run tests
    if test_output=$($TEST_CMD 2>&1); then
        test_passed=true
        success "Tests passed"
    else
        error "Tests failed"
    fi

    # Save results to JSON
    local results
    results=$(jq -n \
        --argjson pr_number "$pr_num" \
        --argjson passed "$test_passed" \
        --arg output "$test_output" \
        '{pr_number: $pr_number, passed: $passed, output: $output}')

    echo "$results" | jq .

    # Restore original branch
    git checkout "$current_branch" 2>/dev/null || true

    emit_event "deps.test.completed" "pr=$pr_num" "passed=$test_passed"

    if [[ "$test_passed" == "false" ]]; then
        return 1
    fi
}

# ─── Merge PR ───────────────────────────────────────────────────────────────

cmd_merge() {
    local pr_num="${1:-}"
    if [[ -z "$pr_num" ]]; then
        error "Usage: shipwright deps merge <pr-number>"
        exit 1
    fi

    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "GitHub API disabled (NO_GITHUB set)"
        return
    fi

    info "Evaluating PR #${pr_num} for merge..."

    # Classify first
    local classify_output
    classify_output=$(cmd_classify "$pr_num" 2>&1 | tail -20)

    local risk_level
    risk_level=$(echo "$classify_output" | jq -r '.risk_level' 2>/dev/null || echo "unknown")

    case "$risk_level" in
        low)
            success "Risk level: LOW — Auto-merging"
            if [[ "$DRY_RUN" == "true" ]]; then
                info "Dry run: would merge with --squash"
            else
                gh pr merge "$pr_num" --squash --auto 2>/dev/null || \
                    gh pr merge "$pr_num" --squash 2>/dev/null || true
                success "Merged PR #${pr_num}"
                emit_event "deps.merge.completed" "pr=$pr_num" "result=auto-merged"
            fi
            ;;
        medium)
            warn "Risk level: MEDIUM — Approval needed"
            gh pr approve "$pr_num" 2>/dev/null || true
            info "Approved PR #${pr_num} (awaiting manual merge)"
            emit_event "deps.merge.completed" "pr=$pr_num" "result=approved-pending"
            ;;
        high)
            warn "Risk level: HIGH — Manual review required"
            info "Added comment with analysis"
            emit_event "deps.merge.completed" "pr=$pr_num" "result=flagged-high-risk"
            ;;
        *)
            warn "Unknown risk level: $risk_level"
            ;;
    esac
}

# ─── Batch Process ──────────────────────────────────────────────────────────

cmd_batch() {
    info "Processing all open dependency PRs..."
    echo ""

    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "GitHub API disabled (NO_GITHUB set)"
        return
    fi

    local prs
    prs=$(gh pr list --author "dependabot[bot]" --author "renovate[bot]" --state open --json number --template '{{json .}}' 2>/dev/null || echo '[]')

    if [[ -z "$prs" || "$prs" == "[]" ]]; then
        info "No open dependency PRs to process."
        return
    fi

    local processed=0
    local merged=0
    local approved=0
    local flagged=0

    echo "$prs" | jq -r '.[] | .number' | while read -r pr_num; do
        info "Processing PR #${pr_num}..."

        local classify_json
        classify_json=$(cmd_classify "$pr_num" 2>&1 | grep -A100 '{' | head -20)

        local risk_level
        risk_level=$(echo "$classify_json" | jq -r '.risk_level' 2>/dev/null || echo "unknown")

        case "$risk_level" in
            low)
                cmd_merge "$pr_num"
                merged=$((merged + 1))
                ;;
            medium)
                gh pr approve "$pr_num" 2>/dev/null || true
                approved=$((approved + 1))
                ;;
            high)
                flagged=$((flagged + 1))
                ;;
        esac
        processed=$((processed + 1))
    done

    echo ""
    echo -e "${CYAN}${BOLD}═══ Batch Summary ═══${RESET}"
    echo -e "  Processed: ${processed}  |  Merged: ${merged}  |  Approved: ${approved}  |  Flagged: ${flagged}"
    echo ""

    emit_event "deps.batch.completed" "processed=$processed" "merged=$merged" "approved=$approved" "flagged=$flagged"
}

# ─── Health Report ──────────────────────────────────────────────────────────

cmd_report() {
    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "GitHub API disabled (NO_GITHUB set)"
        return
    fi

    info "Generating dependency health report..."
    echo ""

    local prs
    prs=$(gh pr list --author "dependabot[bot]" --author "renovate[bot]" --state open --json number,title,createdAt --template '{{json .}}' 2>/dev/null || echo '[]')

    local total=0
    local patch_count=0
    local minor_count=0
    local major_count=0

    if [[ -n "$prs" && "$prs" != "[]" ]]; then
        total=$(echo "$prs" | jq 'length')

        echo "$prs" | jq -r '.[] | .title' | while read -r title; do
            if [[ "$title" =~ from\ ([^ ]+)\ to\ ([^ ]+) ]]; then
                local from_ver="${BASH_REMATCH[1]}"
                local to_ver="${BASH_REMATCH[2]}"
                local bump_type
                bump_type=$(parse_version_bump "$from_ver" "$to_ver")
                case "$bump_type" in
                    patch) patch_count=$((patch_count + 1)) ;;
                    minor) minor_count=$((minor_count + 1)) ;;
                    major) major_count=$((major_count + 1)) ;;
                esac
            fi
        done
    fi

    # Find oldest PR
    local oldest_age="—"
    if [[ -n "$prs" && "$prs" != "[]" ]]; then
        local oldest_date
        oldest_date=$(echo "$prs" | jq -r '.[0].createdAt')
        if [[ -n "$oldest_date" && "$oldest_date" != "null" ]]; then
            oldest_age="$(date -d "$oldest_date" '+%s' 2>/dev/null || echo '?') seconds ago"
        fi
    fi

    echo -e "${CYAN}${BOLD}╔═════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Dependency Health Report                             ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Open PRs:${RESET}        ${total}"
    echo -e "    ├─ ${GREEN}Patches:${RESET}   ${patch_count}"
    echo -e "    ├─ ${YELLOW}Minor:${RESET}     ${minor_count}"
    echo -e "    └─ ${RED}Major:${RESET}     ${major_count}"
    echo ""
    echo -e "  ${BOLD}Oldest PR:${RESET}       ${oldest_age}"
    echo ""

    emit_event "deps.report.generated" "total=$total" "patches=$patch_count" "minors=$minor_count" "majors=$major_count"
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        scan)       cmd_scan "$@" ;;
        classify)   cmd_classify "$@" ;;
        test)       cmd_test "$@" ;;
        merge)      cmd_merge "$@" ;;
        batch)      cmd_batch "$@" ;;
        report)     cmd_report "$@" ;;
        help|-h|--help)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
