#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-discover — Auto-Discovery from GitHub Orgs             ║
# ║  Scan GitHub org for eligible repos · Filter by language/activity/topic  ║
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

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet discover v${VERSION} ━━━${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright fleet discover${RESET} --org <name> [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--org${RESET} <name>              GitHub organization to scan (required)"
    echo -e "  ${CYAN}--config${RESET} <path>          Fleet config path ${DIM}(default: .claude/fleet-config.json)${RESET}"
    echo -e "  ${CYAN}--min-activity-days${RESET} <N>  Only repos pushed to within N days ${DIM}(default: 90)${RESET}"
    echo -e "  ${CYAN}--language${RESET} <lang>        Filter by primary language ${DIM}(e.g. Go, TypeScript, Python)${RESET}"
    echo -e "  ${CYAN}--topic${RESET} <tag>            Only repos with this topic"
    echo -e "  ${CYAN}--exclude-topic${RESET} <tag>    Skip repos with this topic ${DIM}(e.g. 'no-shipwright')${RESET}"
    echo -e "  ${CYAN}--dry-run${RESET}                Show repos that would be added without modifying config"
    echo -e "  ${CYAN}--json${RESET}                   Output results as JSON"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}# Discover all repos in org, active within 90 days${RESET}"
    echo -e "  ${DIM}shipwright fleet discover --org myorg${RESET}"
    echo ""
    echo -e "  ${DIM}# Filter by language and recent activity${RESET}"
    echo -e "  ${DIM}shipwright fleet discover --org myorg --language Go --min-activity-days 30${RESET}"
    echo ""
    echo -e "  ${DIM}# Dry-run: show what would be added${RESET}"
    echo -e "  ${DIM}shipwright fleet discover --org myorg --dry-run${RESET}"
    echo ""
    echo -e "  ${DIM}# Skip repos with 'no-shipwright' topic${RESET}"
    echo -e "  ${DIM}shipwright fleet discover --org myorg --exclude-topic no-shipwright${RESET}"
    echo ""
}

# ─── GitHub API Checks ───────────────────────────────────────────────────────

check_gh_auth() {
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        error "GitHub API disabled via NO_GITHUB"
        return 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        error "gh CLI not found"
        return 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        error "Not authenticated to GitHub"
        return 1
    fi
    return 0
}

# ─── Discover Repos from GitHub Org ─────────────────────────────────────────
# Queries /orgs/{org}/repos with pagination and applies filters

discover_repos() {
    local org="$1"
    local min_activity_days="$2"
    local language_filter="$3"
    local topic_filter="$4"
    local exclude_topic="$5"
    local dry_run="$6"
    local json_output="$7"

    info "Discovering repos in GitHub organization: ${CYAN}${org}${RESET}"

    # Check GitHub auth
    if ! check_gh_auth; then
        error "Cannot authenticate to GitHub API"
        return 1
    fi

    local discovered_repos=()
    local skipped_repos=()
    local opted_out_repos=()

    # Calculate cutoff date for activity filter
    local cutoff_epoch=0
    if [[ "$min_activity_days" -gt 0 ]]; then
        cutoff_epoch=$(($(now_epoch) - (min_activity_days * 86400)))
    fi

    # Paginate through org repos
    local page=1
    local per_page=100
    local total_found=0
    local has_more=true

    while [[ "$has_more" == "true" ]]; do
        info "Fetching page ${page}..."

        local repos_json
        repos_json=$(gh api "/orgs/${org}/repos" \
            --paginate \
            --jq '.[] | {name, full_name, url, archived, disabled, topics, language, pushed_at, has_issues}' \
            -q '.' 2>/dev/null) || {
            error "Failed to fetch repos from GitHub org: $org"
            return 1
        }

        # Check if we got results
        if [[ -z "$repos_json" ]]; then
            has_more=false
            break
        fi

        # Process each repo
        local repo_count=0
        while IFS= read -r repo_line; do
            [[ -z "$repo_line" ]] && continue

            local repo_data="$repo_line"
            local name full_name url archived disabled topics language pushed_at has_issues

            name=$(echo "$repo_data" | jq -r '.name // ""')
            full_name=$(echo "$repo_data" | jq -r '.full_name // ""')
            url=$(echo "$repo_data" | jq -r '.url // ""')
            archived=$(echo "$repo_data" | jq -r '.archived // false')
            disabled=$(echo "$repo_data" | jq -r '.disabled // false')
            topics=$(echo "$repo_data" | jq -r '.topics | join(",") // ""')
            language=$(echo "$repo_data" | jq -r '.language // ""')
            pushed_at=$(echo "$repo_data" | jq -r '.pushed_at // ""')
            has_issues=$(echo "$repo_data" | jq -r '.has_issues // false')

            total_found=$((total_found + 1))
            repo_count=$((repo_count + 1))

            # Skip archived/disabled repos
            if [[ "$archived" == "true" || "$disabled" == "true" ]]; then
                skipped_repos+=("$name:archived_or_disabled")
                continue
            fi

            # Skip repos without issues enabled
            if [[ "$has_issues" != "true" ]]; then
                skipped_repos+=("$name:no_issues")
                continue
            fi

            # Check language filter
            if [[ -n "$language_filter" && "$language" != "$language_filter" ]]; then
                skipped_repos+=("$name:language")
                continue
            fi

            # Check topic filter (if specified, repo must have it)
            if [[ -n "$topic_filter" ]]; then
                local has_topic=false
                if echo "$topics" | grep -q "$topic_filter"; then
                    has_topic=true
                fi
                if [[ "$has_topic" != "true" ]]; then
                    skipped_repos+=("$name:topic_filter")
                    continue
                fi
            fi

            # Check exclude topic filter
            if [[ -n "$exclude_topic" ]]; then
                local has_exclude_topic=false
                if echo "$topics" | grep -q "$exclude_topic"; then
                    has_exclude_topic=true
                fi
                if [[ "$has_exclude_topic" == "true" ]]; then
                    opted_out_repos+=("$name")
                    continue
                fi
            fi

            # Check activity filter
            if [[ "$min_activity_days" -gt 0 && -n "$pushed_at" ]]; then
                # Parse ISO timestamp to epoch
                local pushed_epoch
                pushed_epoch=$(date -d "$pushed_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed_at" +%s 2>/dev/null || echo 0)

                if [[ "$pushed_epoch" -lt "$cutoff_epoch" ]]; then
                    skipped_repos+=("$name:inactive")
                    continue
                fi
            fi

            # Check for .shipwright-ignore file in repo (opt-out)
            local has_ignore=false
            if gh api "/repos/${full_name}/contents/.shipwright-ignore" >/dev/null 2>&1; then
                has_ignore=true
            fi

            if [[ "$has_ignore" == "true" ]]; then
                opted_out_repos+=("$name")
                continue
            fi

            # Repo passed all filters
            discovered_repos+=("$full_name")

        done <<< "$repos_json"

        # GitHub API pagination — check if there are more pages
        # The --paginate flag automatically fetches all, so we only get one pass
        has_more=false
    done

    # Output results
    if [[ "$json_output" == "true" ]]; then
        # JSON output
        local discovered_json="[]"
        for repo in "${discovered_repos[@]}"; do
            discovered_json=$(echo "$discovered_json" | jq --arg r "$repo" '. += [$r]')
        done

        local skipped_json="{}"
        for skip in "${skipped_repos[@]}"; do
            local skip_repo="${skip%%:*}"
            local skip_reason="${skip#*:}"
            skipped_json=$(echo "$skipped_json" | jq --arg r "$skip_repo" --arg reason "$skip_reason" '.[$r] = $reason')
        done

        local opted_out_json="[]"
        for opted in "${opted_out_repos[@]}"; do
            opted_out_json=$(echo "$opted_out_json" | jq --arg r "$opted" '. += [$r]')
        done

        local result_json
        result_json=$(jq -n \
            --argjson discovered "$discovered_json" \
            --argjson skipped "$skipped_json" \
            --argjson opted_out "$opted_out_json" \
            --arg org "$org" \
            --argjson total_found "$total_found" \
            --argjson total_added "$((${#discovered_repos[@]:-0}))" \
            --argjson total_skipped "$((${#skipped_repos[@]:-0}))" \
            --argjson total_opted_out "$((${#opted_out_repos[@]:-0}))" \
            '{
                org: $org,
                discovered: $discovered,
                skipped: $skipped,
                opted_out: $opted_out,
                summary: {
                    total_found: $total_found,
                    total_eligible: $total_added,
                    total_skipped: $total_skipped,
                    total_opted_out: $total_opted_out
                }
            }')
        echo "$result_json"
        return 0
    fi

    # Human-readable output
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Discovery Results ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Organization: ${CYAN}${org}${RESET}"
    echo ""

    if [[ ${#discovered_repos[@]} -gt 0 ]]; then
        echo -e "${BOLD}Eligible Repos (${#discovered_repos[@]}):${RESET}"
        for repo in "${discovered_repos[@]}"; do
            echo -e "  ${GREEN}✓${RESET} ${repo}"
        done
        echo ""
    else
        echo -e "${YELLOW}No eligible repos found${RESET}"
        echo ""
    fi

    if [[ ${#skipped_repos[@]} -gt 0 ]]; then
        echo -e "${BOLD}Skipped Repos (${#skipped_repos[@]}):${RESET}"
        for skip in "${skipped_repos[@]}"; do
            local skip_repo="${skip%%:*}"
            local skip_reason="${skip#*:}"
            echo -e "  ${DIM}•${RESET} ${skip_repo}  ${DIM}(${skip_reason})${RESET}"
        done
        echo ""
    fi

    if [[ ${#opted_out_repos[@]} -gt 0 ]]; then
        echo -e "${BOLD}Opted Out Repos (${#opted_out_repos[@]}):${RESET}"
        for opted in "${opted_out_repos[@]}"; do
            echo -e "  ${YELLOW}⊘${RESET} ${opted}  ${DIM}(has .shipwright-ignore or no-shipwright topic)${RESET}"
        done
        echo ""
    fi

    echo -e "${BOLD}Summary:${RESET}"
    echo -e "  Total scanned: ${CYAN}${total_found}${RESET}"
    echo -e "  Eligible to add: ${GREEN}${#discovered_repos[@]}${RESET}"
    echo -e "  Skipped (filters): ${YELLOW}${#skipped_repos[@]}${RESET}"
    echo -e "  Opted out: ${RED}${#opted_out_repos[@]}${RESET}"
    echo ""

    # Return list of discovered repos (for integration with config update)
    if [[ ${#discovered_repos[@]} -gt 0 ]]; then
        printf '%s\n' "${discovered_repos[@]}"
    fi
}

# ─── Merge Discovered Repos into Fleet Config ────────────────────────────────
# Adds new repos without overwriting existing manual entries

merge_into_config() {
    local config_path="$1"
    shift
    local discovered_repos=("$@")

    if [[ ! -f "$config_path" ]]; then
        error "Config file not found: $config_path"
        return 1
    fi

    # Validate existing JSON
    if ! jq empty "$config_path" 2>/dev/null; then
        error "Invalid JSON in config: $config_path"
        return 1
    fi

    # Get current repo list
    local current_repos
    current_repos=$(jq -r '.repos[].path // empty' "$config_path")

    # Build list of new repos to add (those not already in config)
    local repos_to_add=()
    for new_repo in "${discovered_repos[@]}"; do
        local repo_exists=false
        while IFS= read -r existing_repo; do
            if [[ "$existing_repo" == "$new_repo" ]]; then
                repo_exists=true
                break
            fi
        done <<< "$current_repos"

        if [[ "$repo_exists" != "true" ]]; then
            repos_to_add+=("$new_repo")
        fi
    done

    if [[ ${#repos_to_add[@]} -eq 0 ]]; then
        success "No new repos to add to config"
        return 0
    fi

    # Merge into config
    local tmp_config="${config_path}.tmp.$$"
    local updated_config=$(cat "$config_path")

    for repo_path in "${repos_to_add[@]}"; do
        updated_config=$(echo "$updated_config" | jq \
            --arg path "$repo_path" \
            '.repos += [{"path": $path}]')
    done

    # Write atomically
    echo "$updated_config" > "$tmp_config"
    mv "$tmp_config" "$config_path"

    success "Added ${#repos_to_add[@]} new repo(s) to config"
    info "Config saved: ${DIM}${config_path}${RESET}"

    emit_event "fleet.discover.merged" \
        "org=$1" \
        "repos_added=${#repos_to_add[@]}" \
        "total_repos=$(echo "$updated_config" | jq '.repos | length')"

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local org=""
    local config_path=".claude/fleet-config.json"
    local min_activity_days=90
    local language_filter=""
    local topic_filter=""
    local exclude_topic=""
    local dry_run=false
    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --org)
                org="${2:-}"
                [[ -z "$org" ]] && { error "Missing value for --org"; return 1; }
                shift 2
                ;;
            --org=*)
                org="${1#--org=}"
                shift
                ;;
            --config)
                config_path="${2:-}"
                [[ -z "$config_path" ]] && { error "Missing value for --config"; return 1; }
                shift 2
                ;;
            --config=*)
                config_path="${1#--config=}"
                shift
                ;;
            --min-activity-days)
                min_activity_days="${2:-90}"
                shift 2
                ;;
            --min-activity-days=*)
                min_activity_days="${1#--min-activity-days=}"
                shift
                ;;
            --language)
                language_filter="${2:-}"
                [[ -z "$language_filter" ]] && { error "Missing value for --language"; return 1; }
                shift 2
                ;;
            --language=*)
                language_filter="${1#--language=}"
                shift
                ;;
            --topic)
                topic_filter="${2:-}"
                [[ -z "$topic_filter" ]] && { error "Missing value for --topic"; return 1; }
                shift 2
                ;;
            --topic=*)
                topic_filter="${1#--topic=}"
                shift
                ;;
            --exclude-topic)
                exclude_topic="${2:-}"
                [[ -z "$exclude_topic" ]] && { error "Missing value for --exclude-topic"; return 1; }
                shift 2
                ;;
            --exclude-topic=*)
                exclude_topic="${1#--exclude-topic=}"
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --json)
                json_output=true
                shift
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                return 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$org" ]]; then
        error "Missing required argument: --org"
        show_help
        return 1
    fi

    # Validate min_activity_days is numeric
    if ! [[ "$min_activity_days" =~ ^[0-9]+$ ]]; then
        error "Invalid value for --min-activity-days: must be a number"
        return 1
    fi

    # Run discovery
    local discovered_repos_output
    discovered_repos_output=$(discover_repos "$org" "$min_activity_days" \
        "$language_filter" "$topic_filter" "$exclude_topic" "$dry_run" "$json_output") || return 1

    if [[ "$json_output" == "true" ]]; then
        # Already formatted as JSON
        echo "$discovered_repos_output"
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        info "Dry-run mode — no changes made to config"
        return 0
    fi

    # Extract list of repos from output (last N lines before summary)
    # The discover_repos function outputs them one per line at the end
    local discovered_repos=()
    while IFS= read -r line; do
        if [[ -n "$line" && "$line" != " "* && "$line" != "Eligible"* && "$line" != "Skipped"* ]]; then
            # Only add if it looks like a repo path (contains /)
            if [[ "$line" == *"/"* ]]; then
                discovered_repos+=("$line")
            fi
        fi
    done <<< "$discovered_repos_output"

    # Merge into config if not in dry-run mode
    if [[ ${#discovered_repos[@]} -gt 0 ]]; then
        merge_into_config "$config_path" "${discovered_repos[@]}"
        emit_event "fleet.discover.completed" \
            "org=$org" \
            "repos_discovered=${#discovered_repos[@]}"
    fi
}

# ─── Source Guard ───────────────────────────────────────────────────────────
# Allow this script to be sourced by other scripts
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
