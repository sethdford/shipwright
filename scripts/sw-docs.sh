#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright docs — Documentation Keeper                                 ║
# ║  Auto-sync documentation from source, detect staleness, generate wiki   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.1"
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

# ─── AUTO Section Processing ────────────────────────────────────────────────

# Find all files with AUTO markers
docs_find_auto_files() {
    grep -rl '<!-- AUTO:' "$REPO_DIR" --include='*.md' 2>/dev/null || true
}

# Extract section IDs from a file
docs_get_sections() {
    local file="$1"
    grep -oE '<!-- AUTO:[a-z0-9_-]+ -->' "$file" 2>/dev/null | sed 's/<!-- AUTO://;s/ -->//' || true
}

# Replace content between AUTO markers (using temp file for multi-line content)
docs_replace_section() {
    local file="$1" section_id="$2" new_content="$3"
    local tmp_file content_file
    tmp_file=$(mktemp)
    content_file=$(mktemp)

    printf '%s\n' "$new_content" > "$content_file"

    awk -v section="$section_id" -v cfile="$content_file" '
        $0 ~ "<!-- AUTO:" section " -->" {
            print
            while ((getline line < cfile) > 0) print line
            close(cfile)
            skip=1
            next
        }
        $0 ~ "<!-- /AUTO:" section " -->" { skip=0 }
        !skip { print }
    ' "$file" > "$tmp_file"

    mv "$tmp_file" "$file"
    rm -f "$content_file"
}

# Check if a section is stale (content differs from generated)
docs_check_section() {
    local file="$1" section_id="$2" expected="$3"
    local current
    current=$(awk -v section="$section_id" '
        $0 ~ "<!-- AUTO:" section " -->" { capture=1; next }
        $0 ~ "<!-- /AUTO:" section " -->" { capture=0 }
        capture { print }
    ' "$file" 2>/dev/null || true)

    if [[ "$current" != "$expected" ]]; then
        return 1  # stale
    fi
    return 0  # fresh
}

# ─── Section Generators ─────────────────────────────────────────────────────

# Generate architecture table for a given section
docs_gen_architecture_table() {
    local section="$1"

    case "$section" in
        core-scripts)
            echo ""
            echo "| File | Lines | Purpose |"
            echo "| --- | ---: | --- |"
            for f in "$REPO_DIR"/scripts/sw-*.sh; do
                [[ -f "$f" ]] || continue
                local basename
                basename=$(basename "$f")
                # Skip test files, tracker providers, github modules
                [[ "$basename" == *-test.sh ]] && continue
                [[ "$basename" == sw-tracker-*.sh ]] && continue
                [[ "$basename" == sw-github-*.sh ]] && continue
                local lines purpose
                lines=$(wc -l < "$f" | xargs)
                # Extract purpose from header: "# ║  shipwright X — Description  ║"
                purpose=$(sed -n '3p' "$f" 2>/dev/null | sed 's/^# *║ *//;s/ *║ *$//;s/.*— *//' || echo "")
                if [[ -z "$purpose" || "$purpose" == "#"* ]]; then
                    purpose=$(head -5 "$f" | grep -m1 '# .*—' | sed 's/.*— *//' | sed 's/ *║.*//' || echo "")
                fi
                echo "| \`scripts/${basename}\` | ${lines} | ${purpose} |"
            done
            # Also include the CLI router
            if [[ -f "$REPO_DIR/scripts/sw" ]]; then
                local sw_lines
                sw_lines=$(wc -l < "$REPO_DIR/scripts/sw" | xargs)
                echo "| \`scripts/sw\` | ${sw_lines} | CLI router — dispatches subcommands via exec |"
            fi
            ;;
        github-modules)
            echo ""
            echo "| File | Lines | Purpose |"
            echo "| --- | ---: | --- |"
            for f in "$REPO_DIR"/scripts/sw-github-*.sh; do
                [[ -f "$f" ]] || continue
                [[ "$f" == *-test.sh ]] && continue
                local basename lines purpose
                basename=$(basename "$f")
                lines=$(wc -l < "$f" | xargs)
                purpose=$(head -5 "$f" | grep -m1 '# .*—' | sed 's/.*— *//;s/ *║.*//' || echo "")
                echo "| \`scripts/${basename}\` | ${lines} | ${purpose} |"
            done
            ;;
        tracker-adapters)
            echo ""
            echo "| File | Lines | Purpose |"
            echo "| --- | ---: | --- |"
            for f in "$REPO_DIR"/scripts/sw-linear.sh "$REPO_DIR"/scripts/sw-jira.sh "$REPO_DIR"/scripts/sw-tracker-linear.sh "$REPO_DIR"/scripts/sw-tracker-jira.sh; do
                [[ -f "$f" ]] || continue
                local basename lines purpose
                basename=$(basename "$f")
                lines=$(wc -l < "$f" | xargs)
                purpose=$(head -5 "$f" | grep -m1 '# .*—' | sed 's/.*— *//;s/ *║.*//' || echo "")
                echo "| \`scripts/${basename}\` | ${lines} | ${purpose} |"
            done
            ;;
        test-suites)
            echo ""
            echo "| File | Lines | Purpose |"
            echo "| --- | ---: | --- |"
            for f in "$REPO_DIR"/scripts/sw-*-test.sh; do
                [[ -f "$f" ]] || continue
                local basename lines purpose
                basename=$(basename "$f")
                lines=$(wc -l < "$f" | xargs)
                purpose=$(head -5 "$f" | grep -m1 '# .*—' | sed 's/.*— *//;s/ *║.*//' || echo "")
                echo "| \`scripts/${basename}\` | ${lines} | ${purpose} |"
            done
            ;;
    esac
}

# Generate command table from CLI router
docs_gen_command_table() {
    local sw_file="$REPO_DIR/scripts/sw"
    [[ -f "$sw_file" ]] || return 0
    echo ""
    echo "| Command | Purpose |"
    echo "| --- | --- |"
    # Parse the show_help() output lines that match the command pattern
    awk '
        /^show_help\(\)/ { in_help=1 }
        in_help && /^}/ { in_help=0 }
        in_help && /echo.*CYAN.*RESET/ {
            line = $0
            # Extract command name between CYAN} and RESET}
            gsub(/.*CYAN\}/, "", line)
            gsub(/\$\{RESET\}.*/, "", line)
            gsub(/^[[:space:]]*/, "", line)
            cmd = line
            # Extract description — everything after the last RESET}
            line = $0
            n = split(line, parts, "\\$\\{RESET\\}")
            desc = parts[n]
            gsub(/^[[:space:]]*/, "", desc)
            gsub(/"[[:space:]]*$/, "", desc)
            if (cmd != "" && desc != "" && cmd !~ /shipwright/) {
                printf "| `shipwright %s` | %s |\n", cmd, desc
            }
        }
    ' "$sw_file" 2>/dev/null || true
}

# Generate test table from package.json
docs_gen_test_table() {
    local pkg="$REPO_DIR/package.json"
    [[ -f "$pkg" ]] || return 0
    echo ""
    local idx=1
    local test_files
    test_files=$(jq -r '.scripts | to_entries[] | select(.key | startswith("test:")) | .value' "$pkg" 2>/dev/null || true)
    if [[ -z "$test_files" ]]; then
        return 0
    fi
    while IFS= read -r cmd; do
        local test_file
        test_file=$(echo "$cmd" | grep -oE 'sw-[a-z-]+-test\.sh' || true)
        if [[ -n "$test_file" ]] && [[ -f "$REPO_DIR/scripts/$test_file" ]]; then
            local purpose
            purpose=$(head -5 "$REPO_DIR/scripts/$test_file" 2>/dev/null | grep -m1 '# .*—' | sed 's/.*— *//' || echo "")
            echo "${idx}. \`${test_file}\` — ${purpose}"
            idx=$((idx + 1))
        fi
    done <<< "$test_files"
}

# Generate feature flags table from daemon config defaults
docs_gen_feature_flags() {
    local daemon="$REPO_DIR/scripts/sw-daemon.sh"
    [[ -f "$daemon" ]] || return 0
    echo ""
    echo "| Flag | Default | Purpose |"
    echo "| --- | --- | --- |"
    # Extract intelligence config from the heredoc in sw-daemon.sh
    # Lines look like:    "enabled": true,
    local in_intel=false
    while IFS= read -r line; do
        if echo "$line" | grep -q '"intelligence"' 2>/dev/null; then
            in_intel=true
            continue
        fi
        if [[ "$in_intel" == "true" ]] && echo "$line" | grep -q '^\s*}' 2>/dev/null; then
            in_intel=false
            continue
        fi
        if [[ "$in_intel" == "true" ]]; then
            local key val
            key=$(echo "$line" | sed -n 's/.*"\([a-z_]*\)".*/\1/p' 2>/dev/null || true)
            val=$(echo "$line" | sed -n 's/.*: *\([a-z0-9.]*\).*/\1/p' 2>/dev/null || true)
            if [[ -n "$key" && -n "$val" ]]; then
                echo "| \`intelligence.${key}\` | \`${val}\` | |"
            fi
        fi
    done < "$daemon"
}

# Generate runtime state file locations
docs_gen_file_locations() {
    echo ""
    local locations
    locations="Pipeline state:.claude/pipeline-state.md
Pipeline artifacts:.claude/pipeline-artifacts/
Composed pipeline:.claude/pipeline-artifacts/composed-pipeline.json
Events log:~/.shipwright/events.jsonl
Daemon config:.claude/daemon-config.json
Fleet config:.claude/fleet-config.json
Heartbeats:~/.shipwright/heartbeats/<job-id>.json
Checkpoints:.claude/pipeline-artifacts/checkpoints/
Machine registry:~/.shipwright/machines.json
Cost data:~/.shipwright/costs.json, ~/.shipwright/budget.json
Intelligence cache:.claude/intelligence-cache.json
Optimization data:~/.shipwright/optimization/
Baselines:~/.shipwright/baselines/
Architecture models:~/.shipwright/memory/<repo-hash>/architecture.json
Team config:~/.shipwright/team-config.json
Developer registry:~/.shipwright/developer-registry.json
Team events:~/.shipwright/team-events.jsonl
Invite tokens:~/.shipwright/invite-tokens.json
Connect PID:~/.shipwright/connect.pid
Connect log:~/.shipwright/connect.log
GitHub cache:~/.shipwright/github-cache/
Check run IDs:.claude/pipeline-artifacts/check-run-ids.json
Deployment tracking:.claude/pipeline-artifacts/deployment.json
Error log:.claude/pipeline-artifacts/error-log.jsonl"

    while IFS= read -r loc; do
        [[ -z "$loc" ]] && continue
        local label="${loc%%:*}"
        local path="${loc#*:}"
        echo "- ${label}: \`${path}\`"
    done <<< "$locations"
}

# Generate codebase stats
docs_gen_stats() {
    local script_count=0 test_count=0 total_lines=0

    for f in "$REPO_DIR"/scripts/sw-*.sh "$REPO_DIR"/scripts/sw; do
        [[ -f "$f" ]] || continue
        if [[ "$f" == *-test.sh ]]; then
            test_count=$((test_count + 1))
        else
            script_count=$((script_count + 1))
        fi
        local lines
        lines=$(wc -l < "$f" | xargs)
        total_lines=$((total_lines + lines))
    done

    local template_count=0 team_template_count=0
    if [[ -d "$REPO_DIR/templates/pipelines" ]]; then
        template_count=$(find "$REPO_DIR/templates/pipelines" -name '*.json' 2>/dev/null | wc -l | xargs)
    fi
    if [[ -d "$REPO_DIR/tmux/templates" ]]; then
        team_template_count=$(find "$REPO_DIR/tmux/templates" -name '*.json' 2>/dev/null | wc -l | xargs)
    fi

    echo "- **${script_count}** core scripts + CLI router"
    echo "- **${test_count}** test suites"
    echo "- **${total_lines}** total lines of shell"
    echo "- **${template_count}** pipeline templates"
    echo "- **${team_template_count}** team composition templates"
}

# ─── Section Router ──────────────────────────────────────────────────────────

docs_generate_section() {
    local section_id="$1"
    case "$section_id" in
        core-scripts)      docs_gen_architecture_table "core-scripts" ;;
        github-modules)    docs_gen_architecture_table "github-modules" ;;
        tracker-adapters)  docs_gen_architecture_table "tracker-adapters" ;;
        test-suites)       docs_gen_architecture_table "test-suites" ;;
        commands-table)    docs_gen_command_table ;;
        test-list)         docs_gen_test_table ;;
        feature-flags)     docs_gen_feature_flags ;;
        runtime-state)     docs_gen_file_locations ;;
        stats)             docs_gen_stats ;;
        *)                 warn "Unknown AUTO section: $section_id"; return 1 ;;
    esac
}

# ─── Subcommands ─────────────────────────────────────────────────────────────

# Check which AUTO sections are stale
docs_check() {
    info "Checking documentation freshness..."
    local stale=0 fresh=0 total=0

    local files
    files=$(docs_find_auto_files)
    if [[ -z "$files" ]]; then
        warn "No files with AUTO markers found"
        return 0
    fi

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local sections
        sections=$(docs_get_sections "$file")
        while IFS= read -r section; do
            [[ -z "$section" ]] && continue
            total=$((total + 1))
            local expected
            expected=$(docs_generate_section "$section")
            if ! docs_check_section "$file" "$section" "$expected"; then
                stale=$((stale + 1))
                local rel_file="${file#$REPO_DIR/}"
                warn "Stale: ${rel_file}#${section}"
            else
                fresh=$((fresh + 1))
            fi
        done <<< "$sections"
    done <<< "$files"

    echo ""
    echo -e "${BOLD}Documentation Status:${RESET} ${fresh} fresh, ${stale} stale, ${total} total"

    if [[ "$stale" -gt 0 ]]; then
        warn "Run ${CYAN}shipwright docs sync${RESET} to update stale sections"
        return 1
    fi
    success "All documentation sections are fresh"
    return 0
}

# Regenerate all stale AUTO sections
docs_sync() {
    info "Syncing documentation..."
    local updated=0 total=0

    local files
    files=$(docs_find_auto_files)

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local sections
        sections=$(docs_get_sections "$file")
        while IFS= read -r section; do
            [[ -z "$section" ]] && continue
            total=$((total + 1))
            local expected
            expected=$(docs_generate_section "$section")
            if ! docs_check_section "$file" "$section" "$expected"; then
                docs_replace_section "$file" "$section" "$expected"
                updated=$((updated + 1))
                local rel_file="${file#$REPO_DIR/}"
                info "Updated: ${rel_file}#${section}"
            fi
        done <<< "$sections"
    done <<< "$files"

    if [[ "$updated" -gt 0 ]]; then
        success "Updated ${updated}/${total} sections"
        emit_event "docs.sync" "updated=$updated" "total=$total"
    else
        success "All ${total} sections already fresh"
    fi
}

# Generate GitHub wiki pages
docs_wiki() {
    local dry_run="${1:-false}"
    local wiki_dir
    wiki_dir=$(mktemp -d)

    info "Generating wiki pages..."

    # Home.md — from README intro
    if [[ -f "$REPO_DIR/README.md" ]]; then
        head -50 "$REPO_DIR/README.md" > "$wiki_dir/Home.md"
        echo "" >> "$wiki_dir/Home.md"
        echo "---" >> "$wiki_dir/Home.md"
        echo "*Auto-generated by \`shipwright docs wiki\` on $(date -u +%Y-%m-%d)*" >> "$wiki_dir/Home.md"
    fi

    # Architecture.md
    {
        echo "# Architecture"
        echo ""
        echo "## Core Scripts"
        docs_gen_architecture_table "core-scripts"
        echo ""
        echo "## GitHub API Modules"
        docs_gen_architecture_table "github-modules"
        echo ""
        echo "## Issue Tracker Adapters"
        docs_gen_architecture_table "tracker-adapters"
        echo ""
        echo "## Test Suites"
        docs_gen_architecture_table "test-suites"
        echo ""
        echo "## Stats"
        docs_gen_stats
        echo ""
        echo "---"
        echo "*Auto-generated by \`shipwright docs wiki\` on $(date -u +%Y-%m-%d)*"
    } > "$wiki_dir/Architecture.md"

    # Commands.md
    {
        echo "# Commands"
        docs_gen_command_table
        echo ""
        echo "---"
        echo "*Auto-generated by \`shipwright docs wiki\` on $(date -u +%Y-%m-%d)*"
    } > "$wiki_dir/Commands.md"

    # Intelligence.md
    {
        echo "# Intelligence Layer"
        echo ""
        echo "## Feature Flags"
        docs_gen_feature_flags
        echo ""
        echo "---"
        echo "*Auto-generated by \`shipwright docs wiki\` on $(date -u +%Y-%m-%d)*"
    } > "$wiki_dir/Intelligence.md"

    # Configuration.md
    {
        echo "# Configuration"
        echo ""
        echo "## Runtime State & Artifacts"
        docs_gen_file_locations
        echo ""
        echo "---"
        echo "*Auto-generated by \`shipwright docs wiki\` on $(date -u +%Y-%m-%d)*"
    } > "$wiki_dir/Configuration.md"

    if [[ "$dry_run" == "true" ]] || [[ "$dry_run" == "--dry-run" ]]; then
        info "Dry run — wiki pages generated in: $wiki_dir"
        ls -la "$wiki_dir"
        return 0
    fi

    # Push to GitHub wiki
    if [[ "${NO_GITHUB:-}" == "true" ]] || ! command -v gh &>/dev/null; then
        warn "GitHub not available — wiki pages saved to: $wiki_dir"
        return 0
    fi

    local repo_url
    repo_url=$(gh repo view --json url -q '.url' 2>/dev/null || true)
    if [[ -z "$repo_url" ]]; then
        warn "Could not determine repo URL — wiki pages saved to: $wiki_dir"
        return 0
    fi

    local wiki_repo="${repo_url}.wiki.git"
    local wiki_clone
    wiki_clone=$(mktemp -d)

    if git clone "$wiki_repo" "$wiki_clone" 2>/dev/null; then
        cp "$wiki_dir"/*.md "$wiki_clone/"
        ( cd "$wiki_clone" && git add -A && git commit -m "docs: auto-update wiki via shipwright docs wiki" && git push ) 2>/dev/null || true
        success "Wiki updated"
    else
        warn "Could not clone wiki repo — wiki pages saved to: $wiki_dir"
    fi

    rm -rf "$wiki_clone"
}

# Documentation freshness report
docs_report() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Documentation Report${RESET}"
    echo -e "${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""

    # Stats
    echo -e "${BOLD}Codebase Stats:${RESET}"
    docs_gen_stats
    echo ""

    # AUTO section status
    echo -e "${BOLD}AUTO Section Status:${RESET}"
    local files
    files=$(docs_find_auto_files)
    if [[ -z "$files" ]]; then
        echo "  No AUTO sections found"
    else
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local rel_file="${file#$REPO_DIR/}"
            local sections
            sections=$(docs_get_sections "$file")
            while IFS= read -r section; do
                [[ -z "$section" ]] && continue
                local expected
                expected=$(docs_generate_section "$section")
                if docs_check_section "$file" "$section" "$expected"; then
                    echo -e "  ${GREEN}✓${RESET} ${rel_file}#${section}"
                else
                    echo -e "  ${YELLOW}⚠${RESET} ${rel_file}#${section} ${DIM}(stale)${RESET}"
                fi
            done <<< "$sections"
        done <<< "$files"
    fi

    echo ""

    # File freshness
    echo -e "${BOLD}Document Freshness:${RESET}"
    for doc in README.md .claude/CLAUDE.md CHANGELOG.md; do
        local full_path="$REPO_DIR/$doc"
        [[ -f "$full_path" ]] || continue
        local last_modified
        last_modified=$(git -C "$REPO_DIR" log -1 --format='%cr' -- "$doc" 2>/dev/null || echo "unknown")
        echo "  ${doc}: last modified ${last_modified}"
    done
    echo ""
}

# ─── Help & Main ─────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright docs${RESET} — Documentation Keeper"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright docs${RESET} <command>"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}sync${RESET}         Regenerate all AUTO sections in markdown files"
    echo -e "  ${CYAN}check${RESET}        Check which sections are stale (exit 1 if any)"
    echo -e "  ${CYAN}wiki${RESET}         Generate/update GitHub wiki pages"
    echo -e "  ${CYAN}report${RESET}       Show documentation freshness report"
    echo -e "  ${CYAN}help${RESET}         Show this help"
    echo ""
    echo -e "${BOLD}AUTO MARKERS${RESET}"
    echo -e "  Place markers in any .md file to auto-generate content:"
    echo -e "  ${DIM}<!-- AUTO:core-scripts -->${RESET}"
    echo -e "  ${DIM}(auto-generated table)${RESET}"
    echo -e "  ${DIM}<!-- /AUTO:core-scripts -->${RESET}"
    echo ""
    echo -e "${BOLD}SECTIONS${RESET}"
    echo -e "  ${CYAN}core-scripts${RESET}      Architecture table of core scripts"
    echo -e "  ${CYAN}github-modules${RESET}    Architecture table of GitHub API modules"
    echo -e "  ${CYAN}tracker-adapters${RESET}  Architecture table of tracker adapters"
    echo -e "  ${CYAN}test-suites${RESET}       Architecture table of test suites"
    echo -e "  ${CYAN}commands-table${RESET}    Command reference from CLI router"
    echo -e "  ${CYAN}test-list${RESET}         Numbered test suite list from package.json"
    echo -e "  ${CYAN}feature-flags${RESET}     Intelligence feature flags"
    echo -e "  ${CYAN}runtime-state${RESET}     Runtime state file locations"
    echo -e "  ${CYAN}stats${RESET}             Codebase statistics"
}

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        sync)    docs_sync "$@" ;;
        check)   docs_check "$@" ;;
        wiki)    docs_wiki "$@" ;;
        report)  docs_report "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
