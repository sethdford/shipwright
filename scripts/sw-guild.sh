#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright guild — Knowledge Guilds & Cross-Team Learning             ║
# ║  Patterns · Best Practices · Cross-Pollination · Guild Intelligence    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
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

# ─── Guild Storage Paths ───────────────────────────────────────────────────
GUILD_ROOT="${HOME}/.shipwright/guilds"
GUILD_CONFIG="${GUILD_ROOT}/config.json"
GUILD_DATA="${GUILD_ROOT}/guilds.json"

# ─── Event Logging ────────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Initialization ────────────────────────────────────────────────────────
ensure_guild_dir() {
    mkdir -p "$GUILD_ROOT"

    if [[ ! -f "$GUILD_CONFIG" ]]; then
        cat > "$GUILD_CONFIG" << 'EOF'
{
  "version": "1.0",
  "created_at": "NOW",
  "guild_definitions": {
    "security": {
      "description": "Security patterns, vulnerability fixes, threat modeling",
      "members": [],
      "pattern_count": 0,
      "practice_count": 0
    },
    "performance": {
      "description": "Optimization patterns, caching, bottleneck analysis",
      "members": [],
      "pattern_count": 0,
      "practice_count": 0
    },
    "testing": {
      "description": "Test strategies, coverage patterns, edge cases",
      "members": [],
      "pattern_count": 0,
      "practice_count": 0
    },
    "architecture": {
      "description": "Design patterns, layering, dependency management",
      "members": [],
      "pattern_count": 0,
      "practice_count": 0
    },
    "documentation": {
      "description": "Doc patterns, clarity, examples, API docs",
      "members": [],
      "pattern_count": 0,
      "practice_count": 0
    },
    "reliability": {
      "description": "Error handling, observability, resilience patterns",
      "members": [],
      "pattern_count": 0,
      "practice_count": 0
    },
    "cost-optimization": {
      "description": "Resource efficiency, token optimization, cost patterns",
      "members": [],
      "pattern_count": 0,
      "practice_count": 0
    }
  }
}
EOF
        sed -i "" "s/NOW/$(date -u +"%Y-%m-%dT%H:%M:%SZ")/g" "$GUILD_CONFIG" 2>/dev/null || true
    fi

    if [[ ! -f "$GUILD_DATA" ]]; then
        echo '{"patterns":{},"practices":{},"cross_pollination":[]}' > "$GUILD_DATA"
    fi
}

# ─── List Guilds ──────────────────────────────────────────────────────────
cmd_list() {
    ensure_guild_dir

    info "Available Guilds"
    echo ""

    jq -r '.guild_definitions | to_entries[] |
        "\(.key | ascii_upcase): \(.value.description)\n  Patterns: \(.value.pattern_count) | Practices: \(.value.practice_count)"' \
        "$GUILD_CONFIG" 2>/dev/null | while read -r line; do
        if [[ "$line" =~ ^[A-Z] ]]; then
            echo -e "${CYAN}${BOLD}${line}${RESET}"
        else
            echo -e "  ${DIM}${line}${RESET}"
        fi
    done
}

# ─── Show Guild Details ───────────────────────────────────────────────────
cmd_show() {
    local guild="${1:-}"

    if [[ -z "$guild" ]]; then
        error "Guild name required. Usage: shipwright guild show <guild>"
        return 1
    fi

    ensure_guild_dir

    # Validate guild exists
    if ! jq -e ".guild_definitions[\"$guild\"]" "$GUILD_CONFIG" >/dev/null 2>&1; then
        error "Guild not found: $guild"
        return 1
    fi

    info "Guild: ${CYAN}${BOLD}${guild}${RESET}"

    jq -r ".guild_definitions[\"$guild\"] |
        \"Description: \(.description)\n\" +
        \"Members: \(.members | length)\n\" +
        \"Patterns: \(.pattern_count)\n\" +
        \"Practices: \(.practice_count)\"" \
        "$GUILD_CONFIG"

    echo ""
    info "Patterns:"
    jq -r ".patterns[\"$guild\"] // [] | .[] |
        \"  • \(.title) (confidence: \(.confidence | tostring)%, used \(.usage_count) times)\"" \
        "$GUILD_DATA" | head -10 || echo "  ${DIM}(none)${RESET}"

    echo ""
    info "Best Practices:"
    jq -r ".practices[\"$guild\"] // [] | .[] |
        \"  • \(.title) (confidence: \(.confidence | tostring)%, adopted \(.adoption_count) times)\"" \
        "$GUILD_DATA" | head -10 || echo "  ${DIM}(none)${RESET}"
}

# ─── Search Knowledge Base ────────────────────────────────────────────────
cmd_search() {
    local query="${1:-}"
    local domain="${2:-}"

    if [[ -z "$query" ]]; then
        error "Search query required. Usage: shipwright guild search <query> [domain]"
        return 1
    fi

    ensure_guild_dir

    info "Searching knowledge base for: ${CYAN}${query}${RESET}"
    [[ -n "$domain" ]] && info "Domain filter: ${CYAN}${domain}${RESET}"

    echo ""

    # Search patterns
    local pattern_count=0
    jq -r ".patterns | to_entries[] |
        select(.value | length > 0) |
        select((.key | contains(\"$domain\")) or (\"$domain\" == \"\")) |
        .value[] |
        select((.title | test(\"$query\"; \"i\")) or (.description | test(\"$query\"; \"i\"))) |
        \"PATTERN: \(.title) [\(.source.pipeline // \"unknown\")]\\n  \(.description)\"" \
        "$GUILD_DATA" 2>/dev/null | while read -r line; do
        echo -e "${GREEN}${line}${RESET}"
    done
    pattern_count=$(jq -r ".patterns | to_entries[] |
        select(.value | length > 0) |
        select((.key | contains(\"$domain\")) or (\"$domain\" == \"\")) |
        .value[] |
        select((.title | test(\"$query\"; \"i\")) or (.description | test(\"$query\"; \"i\"))) | \"1\"" \
        "$GUILD_DATA" 2>/dev/null | wc -l)

    # Search practices
    jq -r ".practices | to_entries[] |
        select(.value | length > 0) |
        select((.key | contains(\"$domain\")) or (\"$domain\" == \"\")) |
        .value[] |
        select((.title | test(\"$query\"; \"i\")) or (.description | test(\"$query\"; \"i\"))) |
        \"PRACTICE: \(.title) [confidence: \(.confidence)%]\\n  \(.description)\"" \
        "$GUILD_DATA" 2>/dev/null | while read -r line; do
        echo -e "${BLUE}${line}${RESET}"
    done

    local practice_count=0
    practice_count=$(jq -r ".practices | to_entries[] |
        select(.value | length > 0) |
        select((.key | contains(\"$domain\")) or (\"$domain\" == \"\")) |
        .value[] |
        select((.title | test(\"$query\"; \"i\")) or (.description | test(\"$query\"; \"i\"))) | \"1\"" \
        "$GUILD_DATA" 2>/dev/null | wc -l)

    if [[ $pattern_count -eq 0 && $practice_count -eq 0 ]]; then
        warn "No matches found"
        return 1
    fi
}

# ─── Add Pattern or Practice ──────────────────────────────────────────────
cmd_add() {
    local type="${1:-}"
    local guild="${2:-}"
    local title="${3:-}"

    if [[ -z "$type" || -z "$guild" || -z "$title" ]]; then
        error "Usage: shipwright guild add <pattern|practice> <guild> <title>"
        return 1
    fi

    [[ "$type" != "pattern" && "$type" != "practice" ]] && { error "Type must be pattern or practice"; return 1; }

    ensure_guild_dir

    if ! jq -e ".guild_definitions[\"$guild\"]" "$GUILD_CONFIG" >/dev/null 2>&1; then
        error "Guild not found: $guild"
        return 1
    fi

    # Read description from stdin if piped
    local description="${4:-}"
    if [[ -z "$description" && -t 0 ]]; then
        echo -n "Description: "
        read -r description
    fi

    local tmp_file
    tmp_file=$(mktemp "$GUILD_DATA.tmp.XXXXXX")

    if [[ "$type" == "pattern" ]]; then
        jq --arg guild "$guild" \
           --arg title "$title" \
           --arg desc "$description" \
           --arg ts "$(now_iso)" \
           ".patterns[\$guild] //= [] |
            .patterns[\$guild] += [{
              title: \$title,
              description: \$desc,
              confidence: 75,
              usage_count: 1,
              source: {pipeline: \"manual\", created_at: \$ts},
              tags: []
            }]" \
           "$GUILD_DATA" > "$tmp_file" && mv "$tmp_file" "$GUILD_DATA"
        success "Pattern added to ${CYAN}${guild}${RESET}"
    else
        jq --arg guild "$guild" \
           --arg title "$title" \
           --arg desc "$description" \
           --arg ts "$(now_iso)" \
           ".practices[\$guild] //= [] |
            .practices[\$guild] += [{
              title: \$title,
              description: \$desc,
              confidence: 80,
              adoption_count: 0,
              source: {pipeline: \"manual\", created_at: \$ts},
              tags: []
            }]" \
           "$GUILD_DATA" > "$tmp_file" && mv "$tmp_file" "$GUILD_DATA"
        success "Practice added to ${CYAN}${guild}${RESET}"
    fi

    emit_event "guild.add" "type=${type}" "guild=${guild}" "title=${title}"
}

# ─── Learn from Pipeline ──────────────────────────────────────────────────
cmd_learn() {
    local pipeline_dir="${1:-}"

    if [[ -z "$pipeline_dir" || ! -d "$pipeline_dir" ]]; then
        error "Pipeline artifacts directory required. Usage: shipwright guild learn <artifacts_dir>"
        return 1
    fi

    ensure_guild_dir

    info "Extracting learnings from pipeline: ${CYAN}${pipeline_dir}${RESET}"

    # This would be called by the pipeline with artifacts directory
    # For now, emit a learning event that signals a Claude agent to analyze
    emit_event "guild.learn_requested" "pipeline_dir=${pipeline_dir}"

    success "Learning extraction queued (requires Claude analysis)"
}

# ─── Inject Knowledge into Prompt ────────────────────────────────────────
cmd_inject() {
    local task_type="${1:-}"
    local context="${2:-}"

    if [[ -z "$task_type" ]]; then
        error "Task type required. Usage: shipwright guild inject <task_type> [context]"
        return 1
    fi

    ensure_guild_dir

    info "Relevant guild knowledge for ${CYAN}${task_type}${RESET}:"
    echo ""

    # Map task types to relevant guilds
    case "$task_type" in
        security|auth|vulnerability)
            echo "# Security Guild Knowledge"
            jq -r ".practices.security // [] | .[0:3] | .[] |
                \"- \(.title): \(.description)\"" "$GUILD_DATA"
            ;;
        performance|optimization)
            echo "# Performance Guild Knowledge"
            jq -r ".practices.performance // [] | .[0:3] | .[] |
                \"- \(.title): \(.description)\"" "$GUILD_DATA"
            ;;
        testing|test|coverage)
            echo "# Testing Guild Knowledge"
            jq -r ".practices.testing // [] | .[0:3] | .[] |
                \"- \(.title): \(.description)\"" "$GUILD_DATA"
            ;;
        architecture|design|refactor)
            echo "# Architecture Guild Knowledge"
            jq -r ".practices.architecture // [] | .[0:3] | .[] |
                \"- \(.title): \(.description)\"" "$GUILD_DATA"
            ;;
        docs|documentation)
            echo "# Documentation Guild Knowledge"
            jq -r ".practices.documentation // [] | .[0:3] | .[] |
                \"- \(.title): \(.description)\"" "$GUILD_DATA"
            ;;
        reliability|error|observability)
            echo "# Reliability Guild Knowledge"
            jq -r ".practices.reliability // [] | .[0:3] | .[] |
                \"- \(.title): \(.description)\"" "$GUILD_DATA"
            ;;
        cost|budget|tokens)
            echo "# Cost Optimization Guild Knowledge"
            jq -r ".practices.cost-optimization // [] | .[0:3] | .[] |
                \"- \(.title): \(.description)\"" "$GUILD_DATA"
            ;;
        *)
            info "Top practices across all guilds:"
            jq -r ".practices | to_entries[] | .value[] |
                select(.confidence >= 80) |
                \"- \(.title) [\(.source.pipeline // \"unknown\")]\"" \
                "$GUILD_DATA" | head -5 || true
            ;;
    esac
}

# ─── Guild Reports ───────────────────────────────────────────────────────
cmd_report() {
    local guild="${1:-all}"

    ensure_guild_dir

    if [[ "$guild" == "all" ]]; then
        info "Guild Knowledge Growth Report"
        echo ""

        jq -r '.guild_definitions | to_entries[] |
            "\(.key | ascii_upcase):\n  Patterns: \(.value.pattern_count)\n  Practices: \(.value.practice_count)"' \
            "$GUILD_CONFIG" | while read -r line; do
            if [[ "$line" =~ ^[A-Z] ]]; then
                echo -e "${CYAN}${BOLD}${line}${RESET}"
            else
                echo -e "  ${DIM}${line}${RESET}"
            fi
        done
    else
        if ! jq -e ".guild_definitions[\"$guild\"]" "$GUILD_CONFIG" >/dev/null 2>&1; then
            error "Guild not found: $guild"
            return 1
        fi

        info "Guild Report: ${CYAN}${BOLD}${guild}${RESET}"
        echo ""

        local pattern_count
        pattern_count=$(jq -r ".patterns[\"$guild\"] // [] | length" "$GUILD_DATA")
        local practice_count
        practice_count=$(jq -r ".practices[\"$guild\"] // [] | length" "$GUILD_DATA")

        echo -e "  Patterns:       ${CYAN}${pattern_count}${RESET}"
        echo -e "  Practices:      ${CYAN}${practice_count}${RESET}"

        local avg_conf
        avg_conf=$(jq -r ".practices[\"$guild\"] // [] |
            if length > 0 then map(.confidence) | add / length | floor else 0 end" \
            "$GUILD_DATA")
        echo -e "  Avg Confidence: ${GREEN}${avg_conf}%${RESET}"
    fi
}

# ─── Export Knowledge ────────────────────────────────────────────────────
cmd_export() {
    local format="${1:-json}"
    local output_file="${2:-}"

    [[ "$format" != "json" && "$format" != "markdown" ]] && { error "Format must be json or markdown"; return 1; }

    ensure_guild_dir

    if [[ -z "$output_file" ]]; then
        output_file="${GUILD_ROOT}/export.${format}"
    fi

    if [[ "$format" == "json" ]]; then
        cp "$GUILD_DATA" "$output_file"
        success "Exported to ${CYAN}${output_file}${RESET}"
    else
        {
            echo "# Shipwright Guild Knowledge Base"
            echo ""
            echo "Generated: $(date)"
            echo ""

            jq -r '.guild_definitions | keys[]' "$GUILD_CONFIG" | while read -r guild; do
                local guild_title
                guild_title=$(echo "$guild" | sed 's/^./\U&/')
                echo "## $guild_title"
                jq -r ".guild_definitions[\"$guild\"].description" "$GUILD_CONFIG"
                echo ""

                echo "### Patterns"
                jq -r ".patterns[\"$guild\"] // [] | .[] |
                    \"- **\(.title)**: \(.description) (confidence: \(.confidence)%, used \(.usage_count) times)\"" \
                    "$GUILD_DATA" || echo "No patterns yet."
                echo ""

                echo "### Best Practices"
                jq -r ".practices[\"$guild\"] // [] | .[] |
                    \"- **\(.title)**: \(.description) (confidence: \(.confidence)%, adopted \(.adoption_count) times)\"" \
                    "$GUILD_DATA" || echo "No practices yet."
                echo ""
            done
        } > "$output_file"
        success "Exported to ${CYAN}${output_file}${RESET}"
    fi
}

# ─── Help ──────────────────────────────────────────────────────────────────
show_help() {
    cat << EOF
${CYAN}${BOLD}shipwright guild${RESET} — Knowledge Guilds & Cross-Team Learning

${BOLD}USAGE${RESET}
  ${CYAN}shipwright guild${RESET} <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}list${RESET}             List all guilds and their knowledge stats
  ${CYAN}show${RESET} <guild>     Show guild details, patterns, and practices
  ${CYAN}search${RESET} <query>   Search knowledge base by keyword
  ${CYAN}add${RESET} <type> <guild> <title>
                  Manually add a pattern or best practice
  ${CYAN}learn${RESET} <dir>      Extract patterns from pipeline artifacts
  ${CYAN}inject${RESET} <task>    Show knowledge to inject for a task type
  ${CYAN}report${RESET} [guild]   Guild knowledge growth report
  ${CYAN}export${RESET} [format]  Export knowledge as JSON or Markdown
  ${CYAN}help${RESET}             Show this help message

${BOLD}GUILDS${RESET}
  • ${CYAN}security${RESET}            Security patterns, vulnerability fixes
  • ${CYAN}performance${RESET}         Optimization patterns, caching strategies
  • ${CYAN}testing${RESET}             Test strategies, coverage patterns
  • ${CYAN}architecture${RESET}        Design patterns, layering rules
  • ${CYAN}documentation${RESET}       Doc patterns, clarity guidelines
  • ${CYAN}reliability${RESET}         Error handling, observability patterns
  • ${CYAN}cost-optimization${RESET}   Resource efficiency patterns

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright guild list${RESET}
  ${DIM}shipwright guild show security${RESET}
  ${DIM}shipwright guild search "error handling" reliability${RESET}
  ${DIM}shipwright guild add pattern testing "Unit test template" < description.txt${RESET}
  ${DIM}shipwright guild inject security${RESET}
  ${DIM}shipwright guild report performance${RESET}
  ${DIM}shipwright guild export markdown knowledge-base.md${RESET}

EOF
}

# ─── Main Router ───────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"

    case "$cmd" in
        list)
            cmd_list
            ;;
        show)
            cmd_show "${2:-}"
            ;;
        search)
            cmd_search "${2:-}" "${3:-}"
            ;;
        add)
            cmd_add "${2:-}" "${3:-}" "${4:-}" "${5:-}"
            ;;
        learn)
            cmd_learn "${2:-}"
            ;;
        inject)
            cmd_inject "${2:-}" "${3:-}"
            ;;
        report)
            cmd_report "${2:-all}"
            ;;
        export)
            cmd_export "${2:-json}" "${3:-}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            if [[ -z "$cmd" ]]; then
                show_help
            else
                error "Unknown command: ${cmd}"
                echo ""
                show_help
                exit 1
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
