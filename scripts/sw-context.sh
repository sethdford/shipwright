#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright context — Context Engine for Pipeline Stages                 ║
# ║  Gather architecture decisions · File hotspots · PR outcomes · Memory    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
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

# ─── Paths ────────────────────────────────────────────────────────────────
ARTIFACTS_DIR="${REPO_DIR}/.claude/pipeline-artifacts"
CONTEXT_BUNDLE="${ARTIFACTS_DIR}/context-bundle.md"
CLAUDE_CONFIG="${REPO_DIR}/.claude/CLAUDE.md"
INTELLIGENCE_CACHE="${REPO_DIR}/.claude/intelligence-cache.json"
MEMORY_ROOT="${HOME}/.shipwright/memory"

# ─── Get repo identifier for memory lookups ────────────────────────────────
repo_hash() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    echo -n "$origin" | shasum -a 256 | cut -c1-12
}

repo_memory_dir() {
    echo "${MEMORY_ROOT}/$(repo_hash)"
}

# ─── Extract codebase patterns from CLAUDE.md ──────────────────────────────
extract_codebase_patterns() {
    if [[ ! -f "$CLAUDE_CONFIG" ]]; then
        echo "# Codebase Patterns"
        echo "(No CLAUDE.md found)"
        return
    fi

    local patterns_section
    patterns_section=$(sed -n '/^## Shell Standards/,/^## [A-Z]/p' "$CLAUDE_CONFIG" 2>/dev/null || true)

    if [[ -n "$patterns_section" ]]; then
        echo "$patterns_section"
    fi

    echo ""
    echo "### Common Pitfalls"
    local pitfalls_section
    pitfalls_section=$(sed -n '/^### Common Pitfalls/,/^## [A-Z]/p' "$CLAUDE_CONFIG" 2>/dev/null || true)
    if [[ -n "$pitfalls_section" ]]; then
        echo "$pitfalls_section"
    fi
}

# ─── Extract file hotspots from intelligence cache ────────────────────────
extract_file_hotspots() {
    if [[ ! -f "$INTELLIGENCE_CACHE" ]]; then
        echo "# File Hotspots"
        echo "(Intelligence cache not available)"
        return
    fi

    echo "# File Hotspots"
    echo ""
    echo "From intelligence analysis:"
    echo ""

    # Try to extract relevance data from cache
    local hotspots
    hotspots=$(jq -r '.entries[].result.results[]? | "\(.file): \(.relevance)% — \(.summary)"' "$INTELLIGENCE_CACHE" 2>/dev/null || true)

    if [[ -n "$hotspots" ]]; then
        echo "$hotspots" | sort -rn | uniq
    else
        echo "(No file hotspot data in cache)"
    fi
}

# ─── Get recent merged PRs ───────────────────────────────────────────────
extract_recent_prs() {
    echo "# Recent PR Outcomes"
    echo ""

    if [[ "${NO_GITHUB:-}" == "true" ]]; then
        echo "(GitHub disabled, using git log)"
        echo ""
        local recent_commits
        recent_commits=$(git log --oneline --all --max-count=5 2>/dev/null || echo "(no git history)" | head -5)
        echo "$recent_commits"
        return
    fi

    if ! command -v gh &>/dev/null; then
        echo "(gh CLI not available, using git log)"
        echo ""
        local recent_commits
        recent_commits=$(git log --oneline --all --max-count=5 2>/dev/null | head -5 || echo "(no history)")
        echo "$recent_commits"
        return
    fi

    # Fetch last 5 merged PRs
    local prs_json
    prs_json=$(gh pr list --state merged --limit 5 --json title,mergedAt,additions,deletions,author 2>/dev/null || echo "[]")

    if [[ "$prs_json" != "[]" ]] && [[ -n "$prs_json" ]]; then
        echo "## Merged PRs (last 5)"
        echo ""
        echo "$prs_json" | jq -r '.[] | "\(.title) (author: \(.author.login), +\(.additions)−\(.deletions))"' 2>/dev/null || true
    else
        echo "(No merged PRs found or GitHub access limited)"
    fi
}

# ─── Extract relevant memory entries ───────────────────────────────────────
extract_memory_entries() {
    echo "# Relevant Memory"
    echo ""

    local mem_dir
    mem_dir="$(repo_memory_dir)"

    if [[ ! -d "$mem_dir" ]]; then
        echo "(No memory entries yet)"
        return
    fi

    # Check for failures
    if [[ -f "$mem_dir/failures.json" ]]; then
        local failure_count
        failure_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null || echo "0")
        if [[ "$failure_count" -gt 0 ]]; then
            echo "## Failure Patterns"
            echo ""
            jq -r '.failures[] | "- **\(.category)**: \(.summary)"' "$mem_dir/failures.json" 2>/dev/null | head -5 || true
            echo ""
        fi
    fi

    # Check for patterns
    if [[ -f "$mem_dir/patterns.json" ]]; then
        local pattern_count
        pattern_count=$(jq 'length' "$mem_dir/patterns.json" 2>/dev/null || echo "0")
        if [[ "$pattern_count" -gt 0 ]]; then
            echo "## Successful Patterns"
            echo ""
            jq -r 'to_entries[] | "- **\(.key)**: \(.value)"' "$mem_dir/patterns.json" 2>/dev/null | head -5 || true
            echo ""
        fi
    fi

    # Check for decisions
    if [[ -f "$mem_dir/decisions.json" ]]; then
        local decision_count
        decision_count=$(jq '.decisions | length' "$mem_dir/decisions.json" 2>/dev/null || echo "0")
        if [[ "$decision_count" -gt 0 ]]; then
            echo "## Architecture Decisions"
            echo ""
            jq -r '.decisions[] | "- \(.decision): \(.rationale)"' "$mem_dir/decisions.json" 2>/dev/null | head -5 || true
            echo ""
        fi
    fi
}

# ─── Extract relevant file previews based on goal ─────────────────────────
extract_file_previews() {
    local goal="$1"
    echo "# Relevant File Previews"
    echo ""

    # Try to identify relevant files from goal keywords
    local keywords
    keywords=$(echo "$goal" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z]+\b' | sort -u | head -10 || true)

    if [[ -z "$keywords" ]]; then
        echo "(Could not identify relevant files from goal)"
        return
    fi

    # Find files matching keywords in their name or content
    local relevant_files=""
    local count=0

    for kw in $keywords; do
        if [[ $count -ge 3 ]]; then break; fi

        # Search for files matching keyword
        local found
        found=$(find "$REPO_DIR" -type f \( -name "*.sh" -o -name "*.md" -o -name "*.ts" -o -name "*.json" \) \
            -not -path "*/.git/*" \
            -not -path "*/node_modules/*" \
            -not -path "*/.claude/*" \
            ! -size +100k \
            2>/dev/null | grep -i "$kw" | head -2 || true)

        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            echo "$relevant_files" | grep -q "$file" && continue
            relevant_files="${relevant_files}${file}"$'\n'
            ((count++)) || true
            if [[ $count -ge 3 ]]; then break 2; fi
        done <<< "$found"
    done

    if [[ -z "$relevant_files" ]]; then
        echo "(No matching files found)"
        return
    fi

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if [[ ! -f "$file" ]]; then continue; fi

        echo "## File: $(basename "$file")"
        echo ""
        echo '```'
        head -20 "$file" 2>/dev/null | sed 's/^/  /'
        echo '```'
        echo ""
    done <<< "$relevant_files"
}

# ─── Extract architecture decisions from docs ──────────────────────────────
extract_architecture_decisions() {
    echo "# Architecture Decision Records"
    echo ""

    local adr_file="${REPO_DIR}/.claude/ARCHITECTURE.md"
    if [[ -f "$adr_file" ]]; then
        head -40 "$adr_file" | sed 's/^//'
        echo ""
    else
        echo "(No ARCHITECTURE.md found)"
    fi
}

# ─── Stage-specific guidance ───────────────────────────────────────────────
stage_guidance() {
    local stage="$1"

    case "$stage" in
        plan)
            cat <<'EOF'
# Plan Stage Guidance

## Focus Areas
- Break down goal into measurable milestones
- Identify dependencies and blockers
- Estimate scope and complexity
- Consider edge cases and error paths

## Key Questions
- What are the success criteria?
- What are the known constraints?
- What existing patterns apply here?
- Are there similar completed features to reference?

## Anti-patterns to Avoid
- Over-scoping the initial plan
- Missing edge cases in requirement analysis
- Ignoring technical debt in design phase
EOF
            ;;
        design)
            cat <<'EOF'
# Design Stage Guidance

## Focus Areas
- Define interfaces and contracts
- Establish layer boundaries
- Document state management approach
- Plan error handling and recovery

## Architectural Constraints
- Follow established naming conventions from codebase
- Respect layer dependencies (check ARCHITECTURE.md)
- Use patterns validated in memory system
- Consider testability from the start

## Common Pitfalls
- Designing without understanding existing patterns
- Over-engineering for future extensibility
- Inconsistent error handling strategies
EOF
            ;;
        build)
            cat <<'EOF'
# Build Stage Guidance

## Standards to Follow
- Match existing code style (imports, naming, structure)
- Use patterns from hotspot files
- Implement with full error handling
- Write as you go, not after

## Testing Strategy
- Write tests alongside implementation
- Test error paths and edge cases
- Verify integration with existing code
- Use coverage targets from memory

## Quick Wins
- Look at similar recently-merged PRs for patterns
- Check failure patterns to avoid repeating mistakes
- Use mock patterns from test specialists
- Reference file previews for coding style
EOF
            ;;
        test)
            cat <<'EOF'
# Test Stage Guidance

## Testing Focus
- Cover both happy and error paths
- Test boundaries and edge cases
- Verify integration with existing code
- Achieve coverage targets from memory

## Mock Patterns
- Study existing test files for mock approach
- Use established test harness conventions
- Mock external dependencies consistently
- Validate error scenarios

## Coverage Requirements
- Unit tests for all public functions
- Integration tests for multi-component flows
- End-to-end tests for user-facing features
- Document coverage gaps
EOF
            ;;
        review)
            cat <<'EOF'
# Review Stage Guidance

## Review Checklist
- Code matches established patterns from hotspots
- No violations of architecture layer boundaries
- Error handling is complete and tested
- Breaking changes are documented
- Performance impact is acceptable

## Security Check
- No credential or secret exposure
- Input validation at boundaries
- Authorization checks where needed
- Dependencies are reviewed

## Common Issues
- Deviations from established patterns
- Incomplete error handling
- Test coverage gaps
- Missing documentation updates
EOF
            ;;
        *)
            echo "# Stage-Specific Guidance"
            echo "(No specific guidance for stage: $stage)"
            ;;
    esac
}

# ─── Main gather function ─────────────────────────────────────────────────
gather_context() {
    local goal="$1"
    local stage="${2:-build}"

    info "Building context bundle for ${CYAN}${stage}${RESET} stage..."

    mkdir -p "$ARTIFACTS_DIR"

    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-context-bundle.XXXXXX")

    # Write bundle header
    {
        echo "# Pipeline Context Bundle"
        echo ""
        echo "Generated: $(now_iso)"
        echo "Stage: ${stage}"
        echo "Goal: ${goal}"
        echo ""
        echo "---"
        echo ""
    } >> "$tmp_file"

    # Section: Codebase Patterns
    {
        echo ""
        extract_codebase_patterns
        echo ""
        echo "---"
        echo ""
    } >> "$tmp_file"

    # Section: File Hotspots
    {
        extract_file_hotspots
        echo ""
        echo "---"
        echo ""
    } >> "$tmp_file"

    # Section: Recent PR Outcomes
    {
        extract_recent_prs
        echo ""
        echo "---"
        echo ""
    } >> "$tmp_file"

    # Section: Memory Entries
    {
        extract_memory_entries
        echo ""
        echo "---"
        echo ""
    } >> "$tmp_file"

    # Section: File Previews
    {
        extract_file_previews "$goal"
        echo ""
        echo "---"
        echo ""
    } >> "$tmp_file"

    # Section: Architecture Decisions
    {
        extract_architecture_decisions
        echo ""
        echo "---"
        echo ""
    } >> "$tmp_file"

    # Section: Stage-Specific Guidance
    {
        echo ""
        stage_guidance "$stage"
        echo ""
    } >> "$tmp_file"

    # Atomically move to final location
    mv "$tmp_file" "$CONTEXT_BUNDLE"
    success "Context bundle written to ${CYAN}${CONTEXT_BUNDLE}${RESET}"

    return 0
}

# ─── Show current bundle ───────────────────────────────────────────────────
show_context() {
    if [[ ! -f "$CONTEXT_BUNDLE" ]]; then
        warn "No context bundle found at ${CONTEXT_BUNDLE}"
        echo "Run '${CYAN}shipwright context gather --goal \"...\" --stage plan${RESET}' first"
        return 1
    fi

    cat "$CONTEXT_BUNDLE"
}

# ─── Clear stale bundle ────────────────────────────────────────────────────
clear_context() {
    if [[ -f "$CONTEXT_BUNDLE" ]]; then
        rm -f "$CONTEXT_BUNDLE"
        success "Context bundle cleared"
    else
        warn "No context bundle to clear"
    fi
}

# ─── Help ──────────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
${CYAN}${BOLD}shipwright context${RESET} ${DIM}v${VERSION}${RESET} — Context gathering engine for pipeline stages

${BOLD}USAGE${RESET}
  ${CYAN}shipwright context${RESET} <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}gather${RESET} --goal "..." --stage plan     Generate context bundle
  ${CYAN}gather${RESET} --issue N --stage build        Generate from GitHub issue
  ${CYAN}show${RESET}                                   Display current bundle
  ${CYAN}clear${RESET}                                  Remove stale bundle
  ${CYAN}help${RESET}                                   Show this help

${BOLD}OPTIONS${RESET}
  ${CYAN}--goal${RESET} TEXT          Goal or description for context gathering
  ${CYAN}--issue${RESET} N             GitHub issue number
  ${CYAN}--stage${RESET} STAGE         Pipeline stage: plan, design, build, test, review

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright context gather --goal "Add OAuth" --stage design${RESET}
  ${DIM}shipwright context gather --issue 42 --stage build${RESET}
  ${DIM}shipwright context show${RESET}
  ${DIM}shipwright context clear${RESET}

${BOLD}BUNDLE INCLUDES${RESET}
  • Codebase patterns and standards
  • File hotspots from intelligence analysis
  • Recent merged PR outcomes
  • Failure patterns and learned patterns
  • Relevant file previews with code samples
  • Architecture decision records
  • Stage-specific guidance and checklists

${DIM}The context bundle is written to .claude/pipeline-artifacts/context-bundle.md${RESET}
${DIM}and automatically included in pipeline prompts.${RESET}

EOF
}

# ─── Main dispatcher ───────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        gather)
            local goal="" issue="" stage="build"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --goal)
                        goal="$2"
                        shift 2
                        ;;
                    --issue)
                        issue="$2"
                        shift 2
                        ;;
                    --stage)
                        stage="$2"
                        shift 2
                        ;;
                    *)
                        error "Unknown option: $1"
                        echo ""
                        show_help
                        exit 1
                        ;;
                esac
            done

            if [[ -z "$goal" && -z "$issue" ]]; then
                error "Must provide --goal or --issue"
                echo ""
                show_help
                exit 1
            fi

            # If issue provided, fetch from GitHub
            if [[ -n "$issue" ]]; then
                if [[ "${NO_GITHUB:-}" == "true" ]] || ! command -v gh &>/dev/null; then
                    goal="GitHub issue #$issue (fetch unavailable)"
                else
                    goal=$(gh issue view "$issue" --json title,body --template '{{.title}}: {{.body}}' 2>/dev/null || echo "GitHub issue #$issue")
                fi
            fi

            gather_context "$goal" "$stage"
            ;;
        show)
            show_context
            ;;
        clear)
            clear_context
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
