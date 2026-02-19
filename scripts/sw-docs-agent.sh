#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright Autonomous Docs Agent — Auto-sync README, wiki, API docs     ║
# ║  Change detection · Freshness scoring · Auto-fix stale sections          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
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
# ─── Documentation Agent State ────────────────────────────────────────────
AGENT_HOME="${HOME}/.shipwright/docs-agent"
FRESHNESS_DB="${AGENT_HOME}/freshness.json"

ensure_agent_dir() {
    mkdir -p "$AGENT_HOME"
    [[ -f "$FRESHNESS_DB" ]] || echo '{}' > "$FRESHNESS_DB"
}

# ─── Change Detection ──────────────────────────────────────────────────────

# Detect code changes that affect documentation
scan_code_changes() {
    local last_commit="${1:-HEAD~1}"
    local current_commit="${2:-HEAD}"

    if ! git rev-parse "$last_commit" >/dev/null 2>&1; then
        # First run or initial commit
        git diff --name-only HEAD 2>/dev/null | sort || true
        return
    fi

    git diff --name-only "$last_commit..$current_commit" 2>/dev/null | sort || true
}

# Extract script names, functions, CLI args from code
extract_script_info() {
    local script="$1"

    if [[ ! -f "$script" ]]; then
        return 1
    fi

    local name basename
    basename="$(basename "$script")"

    # Extract VERSION
    local version
    version=$(grep "^VERSION=" "$script" | head -1 | cut -d'"' -f2)
    [[ -n "$version" ]] || version="unknown"

    # Extract main functions (function name or case handlers)
    local functions
    functions=$(grep -E "^[a-z_]+\(\)|^\s+[a-z_-]+\)" "$script" | sed 's/().*//' | sort | uniq | tr '\n' ',' | sed 's/,$//')

    # Line count
    local lines
    lines=$(wc -l < "$script")

    echo "{\"script\":\"$basename\",\"version\":\"$version\",\"functions\":\"$functions\",\"lines\":$lines}"
}

# ─── Freshness Scoring ────────────────────────────────────────────────────

# Score freshness: compare doc update time vs code change time
score_freshness() {
    local doc_file="$1"
    local code_pattern="$2"  # pattern to match related code files

    if [[ ! -f "$doc_file" ]]; then
        echo "0"
        return
    fi

    # Find most recent code change matching pattern
    local code_mtime
    code_mtime=$(find "$REPO_DIR" -name "$code_pattern" -type f -exec stat -c %Y {} \; 2>/dev/null | sort -rn | head -1 || echo "0")

    # Get doc file modification time
    local doc_mtime
    doc_mtime=$(stat -c %Y "$doc_file" 2>/dev/null || echo "0")

    if [[ "$code_mtime" -eq 0 ]]; then
        echo "100"
        return
    fi

    if [[ "$doc_mtime" -ge "$code_mtime" ]]; then
        echo "100"
    else
        local diff=$((code_mtime - doc_mtime))
        local days=$((diff / 86400))

        if [[ $days -eq 0 ]]; then
            echo "95"
        elif [[ $days -le 3 ]]; then
            echo "80"
        elif [[ $days -le 7 ]]; then
            echo "60"
        else
            echo $((100 - (days * 5)))
        fi
    fi
}

# ─── API Reference Generation ─────────────────────────────────────────────

# Generate API reference from script help text and argument parsing
generate_api_reference() {
    local output_file="${1:-${AGENT_HOME}/api-reference.md}"

    info "Generating API reference from scripts..."

    local temp_file
    temp_file=$(mktemp)

    {
        echo "# Shipwright API Reference"
        echo ""
        echo "Generated: $(date -u +%Y-%m-%d\ %H:%M:%SZ)"
        echo ""

        for script in "$REPO_DIR/scripts"/sw-*.sh; do
            [[ ! -f "$script" ]] && continue

            local script_name
            script_name=$(basename "$script" .sh)

            local cmd_name
            cmd_name="${script_name#sw-}"

            # Extract description (look for comment or first echo)
            local desc
            desc=$(head -5 "$script" | grep -E "^# " | head -1 | sed 's/^# //' || echo "Command: $cmd_name")

            echo "## \`$cmd_name\`"
            echo ""
            echo "$desc"
            echo ""

            # Extract usage patterns
            if grep -q "show_help\|usage" "$script"; then
                echo "### Usage"
                echo '```bash'
                grep -A 10 "show_help\|USAGE" "$script" | grep -E "echo|printf" | head -5 | sed 's/.*echo -e *//' | sed "s/'//g" | tr -d '\\' || true
                echo '```'
                echo ""
            fi
        done
    } > "$temp_file"

    mv "$temp_file" "$output_file"
    success "API reference generated: $output_file"
    emit_event "docs_api_generated" "file=$output_file"
}

# ─── Wiki Generation ──────────────────────────────────────────────────────

# Generate/update GitHub wiki pages per module
generate_wiki_pages() {
    local wiki_dir="${1:-${AGENT_HOME}/wiki}"

    mkdir -p "$wiki_dir"
    info "Generating wiki pages..."

    # Create module overview
    local modules_file="${wiki_dir}/Modules.md"
    local temp_file
    temp_file=$(mktemp)

    {
        echo "# Shipwright Modules"
        echo ""
        echo "## Core Scripts"
        echo ""

        for script in "$REPO_DIR/scripts"/sw-*.sh; do
            [[ ! -f "$script" ]] && continue

            local name
            name=$(basename "$script" .sh | sed 's/^sw-//')
            local lines
            lines=$(wc -l < "$script")

            local desc
            desc=$(sed -n '3p' "$script" | sed 's/^# //' | sed 's/ *$//')

            echo "### \`$name\`"
            echo ""
            echo "$desc"
            echo ""
            echo "* **File**: \`scripts/$(basename "$script")\`"
            echo "* **Lines**: $lines"
            echo ""
        done
    } > "$temp_file"

    mv "$temp_file" "$modules_file"
    success "Wiki generated: $wiki_dir"
    emit_event "docs_wiki_generated" "dir=$wiki_dir"
}

# ─── Documentation Impact Analysis ─────────────────────────────────────────

# Show documentation impact of recent changes
analyze_impact() {
    local commit_range="${1:-HEAD~10..HEAD}"

    info "Analyzing documentation impact for: $commit_range"
    echo ""

    local changed_scripts
    changed_scripts=$(git diff --name-only "$commit_range" 2>/dev/null | grep "scripts/sw-.*\.sh$" | sort -u)

    if [[ -z "$changed_scripts" ]]; then
        info "No script changes in range"
        return
    fi

    {
        echo "## Documentation Impact Summary"
        echo ""
        echo "**Commit Range**: \`$commit_range\`"
        echo "**Analysis Time**: $(now_iso)"
        echo ""
        echo "### Modified Scripts"
        echo ""

        while IFS= read -r script; do
            [[ -z "$script" ]] && continue
            local basename
            basename="$(basename "$script")"
            echo "* \`$basename\`"
        done <<< "$changed_scripts"

        echo ""
        echo "### Changes Requiring Documentation Updates"
        echo ""

        # Check for VERSION changes
        local version_changes
        version_changes=$(git diff "$commit_range" -- "$REPO_DIR/scripts/sw-*.sh" 2>/dev/null | grep "^+VERSION=" | wc -l)

        if [[ "$version_changes" -gt 0 ]]; then
            echo "* **Version bumps**: $version_changes scripts"
        fi

        # Check for new functions
        local new_functions
        new_functions=$(git diff "$commit_range" -- "$REPO_DIR/scripts/sw-*.sh" 2>/dev/null | grep "^+[a-z_]*() {" | wc -l)

        if [[ "$new_functions" -gt 0 ]]; then
            echo "* **New functions**: $new_functions"
        fi

        # Check for CLI changes
        local cli_changes
        cli_changes=$(git diff "$commit_range" -- "$REPO_DIR/scripts/sw" 2>/dev/null | grep "^[+-].*exec" | wc -l)

        if [[ "$cli_changes" -gt 0 ]]; then
            echo "* **CLI changes**: $cli_changes routes updated"
        fi

        echo ""
    }
}

# ─── Coverage Tracking ────────────────────────────────────────────────────

# Show documentation coverage metrics
show_coverage() {
    info "Analyzing documentation coverage..."
    echo ""

    local total_scripts
    total_scripts=$(find "$REPO_DIR/scripts" -name "sw-*.sh" -type f | wc -l)

    # Count documented scripts (have AUTO sections or README entries)
    local documented_count=0
    local undocumented_scripts=""

    for script in "$REPO_DIR/scripts"/sw-*.sh; do
        [[ ! -f "$script" ]] && continue
        local script_name
        script_name=$(basename "$script" .sh | sed 's/^sw-//')

        if grep -q "$script_name" "$REPO_DIR/.claude/CLAUDE.md" 2>/dev/null; then
            documented_count=$((documented_count + 1))
        else
            undocumented_scripts="${undocumented_scripts}${script_name}\\n"
        fi
    done

    local coverage_pct
    coverage_pct=$((documented_count * 100 / total_scripts))

    {
        echo "## Documentation Coverage"
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Total Scripts | $total_scripts |"
        echo "| Documented | $documented_count |"
        echo "| **Coverage** | **${coverage_pct}%** |"
        echo ""

        if [[ "$undocumented_scripts" != "" ]]; then
            echo "### Undocumented Scripts"
            echo ""
            echo -e "$undocumented_scripts" | while read -r script; do
                [[ -n "$script" ]] && echo "* \`$script\`"
            done
        fi
    }
}

# ─── Scan for Gaps ────────────────────────────────────────────────────────

# Scan for documentation gaps and stale sections
scan_gaps() {
    info "Scanning for documentation gaps..."
    echo ""
    ensure_agent_dir

    local gaps_found=0

    # Check README sections
    if [[ -f "$REPO_DIR/README.md" ]]; then
        local readme_sections
        readme_sections=$(grep -o "<!-- AUTO:[a-z0-9_-]* -->" "$REPO_DIR/README.md" | sed 's/<!-- AUTO://;s/ -->//' | sort -u)

        for section in $readme_sections; do
            local freshness
            freshness=$(score_freshness "$REPO_DIR/README.md" "scripts/sw-*.sh")

            if [[ "$freshness" -lt 70 ]]; then
                warn "Stale section in README: $section (freshness: ${freshness}%)"
                gaps_found=$((gaps_found + 1))
            fi
        done
    fi

    # Check CLAUDE.md
    if [[ -f "$REPO_DIR/.claude/CLAUDE.md" ]]; then
        local claude_sections
        claude_sections=$(grep -o "<!-- AUTO:[a-z0-9_-]* -->" "$REPO_DIR/.claude/CLAUDE.md" 2>/dev/null | sed 's/<!-- AUTO://;s/ -->//' | sort -u)

        for section in $claude_sections; do
            local freshness
            freshness=$(score_freshness "$REPO_DIR/.claude/CLAUDE.md" "scripts/sw-*.sh")

            if [[ "$freshness" -lt 70 ]]; then
                warn "Stale section in CLAUDE.md: $section (freshness: ${freshness}%)"
                gaps_found=$((gaps_found + 1))
            fi
        done
    fi

    if [[ $gaps_found -eq 0 ]]; then
        success "No stale sections found"
    else
        warn "Found $gaps_found stale sections"
    fi

    return $((gaps_found > 0 ? 1 : 0))
}

# ─── Auto-Sync ────────────────────────────────────────────────────────────

# Auto-update stale documentation sections
sync_docs() {
    info "Starting documentation sync..."
    ensure_agent_dir

    local synced_count=0

    # Regenerate API reference
    generate_api_reference
    synced_count=$((synced_count + 1))

    # Regenerate wiki
    generate_wiki_pages
    synced_count=$((synced_count + 1))

    success "Documentation sync complete ($synced_count updates)"
    emit_event "docs_sync_complete" "updates=$synced_count"
}

# ─── Continuous Watch Mode ────────────────────────────────────────────────

# Watch mode: re-scan on file changes
watch_mode() {
    info "Starting documentation watch mode (Ctrl+C to stop)..."

    local watch_paths=(
        "$REPO_DIR/scripts/sw-*.sh"
        "$REPO_DIR/README.md"
        "$REPO_DIR/.claude/CLAUDE.md"
    )

    # Simple polling implementation
    local last_state=""
    local check_interval="${1:-5}"  # seconds

    while true; do
        # Create state string from file modification times
        local current_state=""
        for pattern in "${watch_paths[@]}"; do
            current_state="${current_state}$(find "$REPO_DIR" -path "$pattern" -type f -exec stat -c %Y {} \; 2>/dev/null | sort -n | tail -1 || echo 0),"
        done

        if [[ "$current_state" != "$last_state" ]]; then
            echo ""
            info "Changes detected, scanning..."
            scan_gaps || true
            last_state="$current_state"
        fi

        sleep "$check_interval"
    done
}

# ─── Help Text ────────────────────────────────────────────────────────────

show_help() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║  Autonomous Documentation Agent                                          ║
║  Auto-sync README, wiki, API docs, CLAUDE.md — track freshness           ║
╚═══════════════════════════════════════════════════════════════════════════╝

USAGE
  shipwright docs-agent <command> [options]

COMMANDS
  scan           Scan for documentation gaps and stale sections
  sync           Auto-update all stale documentation
  coverage       Show documentation coverage metrics
  api            Generate API reference from script help text
  wiki           Generate/update GitHub wiki pages
  impact         Show documentation impact of recent changes
  watch [secs]   Continuous mode — re-scan on file changes (default: 5s)
  help           Show this help message

EXAMPLES
  shipwright docs-agent scan               # Check for stale sections
  shipwright docs-agent sync               # Auto-update documentation
  shipwright docs-agent coverage           # Show coverage metrics
  shipwright docs-agent impact HEAD~5      # Analyze last 5 commits
  shipwright docs-agent watch              # Continuous mode (5s polling)

EOF
}

# ─── Main Router ──────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        scan)
            scan_gaps
            ;;
        sync)
            sync_docs
            ;;
        coverage)
            show_coverage
            ;;
        api)
            generate_api_reference "${1:-.}"
            ;;
        wiki)
            generate_wiki_pages "${1:-.}"
            ;;
        impact)
            analyze_impact "${1:-HEAD~10..HEAD}"
            ;;
        watch)
            watch_mode "${1:-5}"
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
