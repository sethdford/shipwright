#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright architecture — Living Architecture Model & Enforcer         ║
# ║  Build models · Validate changes · Evolve patterns                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

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

# ─── Structured Event Log ────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Source Intelligence Core ─────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
fi

# ─── Configuration ───────────────────────────────────────────────────────
MEMORY_DIR="${HOME}/.shipwright/memory"

_architecture_enabled() {
    local config="${REPO_DIR}/.claude/daemon-config.json"
    if [[ -f "$config" ]]; then
        local enabled
        enabled=$(jq -r '.intelligence.architecture_enabled // false' "$config" 2>/dev/null || echo "false")
        [[ "$enabled" == "true" ]]
    else
        return 1
    fi
}

repo_hash() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    echo -n "$origin" | shasum -a 256 | cut -c1-12
}

_model_path() {
    local hash
    hash=$(repo_hash)
    echo "${MEMORY_DIR}/${hash}/architecture.json"
}

# ─── Build Architecture Model ────────────────────────────────────────────

architecture_build_model() {
    local repo_root="${1:-$REPO_DIR}"

    if ! _architecture_enabled; then
        warn "Architecture enforcer disabled — enable intelligence.architecture_enabled" >&2
        echo "{}"
        return 0
    fi

    info "Building architecture model for: $repo_root" >&2

    # Sample key files for context
    local context=""
    local readme=""
    if [[ -f "$repo_root/README.md" ]]; then
        readme=$(head -100 "$repo_root/README.md" 2>/dev/null || true)
        context="${context}README.md:\n${readme}\n\n"
    fi

    # Detect project type and read manifest
    local manifest=""
    for mf in package.json Cargo.toml go.mod pyproject.toml; do
        if [[ -f "$repo_root/$mf" ]]; then
            manifest=$(head -50 "$repo_root/$mf" 2>/dev/null || true)
            context="${context}${mf}:\n${manifest}\n\n"
            break
        fi
    done

    # Sample directory structure
    local tree=""
    if command -v find >/dev/null 2>&1; then
        tree=$(find "$repo_root" -maxdepth 3 -type f -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.sh" 2>/dev/null | head -50 || true)
        context="${context}File structure:\n${tree}\n"
    fi

    local prompt
    prompt=$(jq -n --arg ctx "$context" '{
        instruction: "Analyze this codebase and extract its architectural model. Return a JSON object with: layers (array of layer names like presentation/business/data), patterns (array of design patterns used like MVC/provider/pipeline), conventions (array of coding conventions), and dependencies (array of key external dependencies).",
        codebase_context: $ctx
    }' | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n\n")')

    local result
    if ! result=$(_intelligence_call_claude "$prompt" "architecture_model_$(repo_hash)" 7200); then
        warn "Claude call failed — returning empty model" >&2
        echo "{}"
        return 0
    fi

    # Ensure valid model structure
    result=$(echo "$result" | jq '{
        layers: (.layers // []),
        patterns: (.patterns // []),
        conventions: (.conventions // []),
        dependencies: (.dependencies // []),
        built_at: (now | todate),
        repo_hash: "'"$(repo_hash)"'"
    }' 2>/dev/null || echo '{"layers":[],"patterns":[],"conventions":[],"dependencies":[]}')

    # Store model atomically
    local model_file
    model_file=$(_model_path)
    local model_dir
    model_dir=$(dirname "$model_file")
    mkdir -p "$model_dir"

    local tmp_file="${model_file}.tmp"
    echo "$result" > "$tmp_file"
    mv "$tmp_file" "$model_file"

    local layer_count pattern_count
    layer_count=$(echo "$result" | jq '.layers | length' 2>/dev/null || echo "0")
    pattern_count=$(echo "$result" | jq '.patterns | length' 2>/dev/null || echo "0")

    emit_event "architecture.model_built" "layers=$layer_count" "patterns=$pattern_count" "repo_hash=$(repo_hash)"
    success "Architecture model built: $layer_count layers, $pattern_count patterns" >&2

    echo "$result"
}

# ─── Validate Changes ────────────────────────────────────────────────────

architecture_validate_changes() {
    local diff="${1:-}"
    local model_file="${2:-$(_model_path)}"

    if ! _architecture_enabled; then
        warn "Architecture enforcer disabled" >&2
        echo "[]"
        return 0
    fi

    if [[ -z "$diff" ]]; then
        error "Usage: architecture validate <diff> [model_file]"
        return 1
    fi

    if [[ ! -f "$model_file" ]]; then
        warn "No architecture model found — run 'architecture build' first" >&2
        echo "[]"
        return 0
    fi

    info "Validating changes against architecture model..." >&2

    local model
    model=$(jq -c '.' "$model_file" 2>/dev/null || echo '{}')

    local prompt
    prompt=$(jq -n --arg model "$model" --arg diff "$diff" '{
        instruction: "Given this architectural model, does this code change follow the established patterns and conventions? Report any violations. Return a JSON array of violations, each with: violation (description), severity (critical|high|medium|low), pattern_broken (which pattern/convention was violated), and suggestion (how to fix it). Return an empty array [] if no violations found.",
        architecture_model: $model,
        code_diff: $diff
    }' | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n\n")')

    local result
    if ! result=$(_intelligence_call_claude "$prompt" "architecture_validate_$(echo -n "$diff" | head -c 200 | _intelligence_md5)" 300); then
        warn "Claude call failed — returning empty violations" >&2
        echo "[]"
        return 0
    fi

    # Ensure result is a JSON array
    if ! echo "$result" | jq 'if type == "array" then . else empty end' >/dev/null 2>&1; then
        result=$(echo "$result" | jq '.violations // []' 2>/dev/null || echo "[]")
    fi

    # Emit events for violations
    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
    local i=0
    while [[ $i -lt $count ]]; do
        local severity pattern
        severity=$(echo "$result" | jq -r ".[$i].severity // \"medium\"" 2>/dev/null || echo "medium")
        pattern=$(echo "$result" | jq -r ".[$i].pattern_broken // \"unknown\"" 2>/dev/null | head -c 50)
        emit_event "architecture.violation" "severity=$severity" "pattern=$pattern"
        i=$((i + 1))
    done

    if [[ "$count" -eq 0 ]]; then
        success "No architecture violations found" >&2
    else
        warn "$count architecture violation(s) found" >&2
    fi

    echo "$result"
}

# ─── Evolve Model ────────────────────────────────────────────────────────

architecture_evolve_model() {
    local model_file="${1:-$(_model_path)}"
    local changes_summary="${2:-}"

    if ! _architecture_enabled; then
        warn "Architecture enforcer disabled" >&2
        return 0
    fi

    if [[ ! -f "$model_file" ]]; then
        warn "No architecture model to evolve" >&2
        return 0
    fi

    if [[ -z "$changes_summary" ]]; then
        error "Usage: architecture evolve [model_file] <changes_summary>"
        return 1
    fi

    info "Checking for architectural evolution..." >&2

    local model
    model=$(jq -c '.' "$model_file" 2>/dev/null || echo '{}')

    local prompt
    prompt=$(jq -n --arg model "$model" --arg changes "$changes_summary" '{
        instruction: "This code change was validated against the architecture model. Does it represent an intentional architectural evolution? If so, return a JSON object with evolved: true and updated_model containing the full updated model (layers, patterns, conventions, dependencies arrays). If no evolution, return {evolved: false}.",
        current_model: $model,
        validated_changes: $changes
    }' | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n\n")')

    local result
    if ! result=$(_intelligence_call_claude "$prompt" "architecture_evolve_$(echo -n "$changes_summary" | head -c 200 | _intelligence_md5)" 300); then
        warn "Claude call failed during evolution check" >&2
        return 0
    fi

    local evolved
    evolved=$(echo "$result" | jq -r '.evolved // false' 2>/dev/null || echo "false")

    if [[ "$evolved" == "true" ]]; then
        local updated_model
        updated_model=$(echo "$result" | jq '.updated_model // empty' 2>/dev/null || true)

        if [[ -n "$updated_model" ]] && echo "$updated_model" | jq '.layers' >/dev/null 2>&1; then
            local tmp_file="${model_file}.tmp"
            echo "$updated_model" > "$tmp_file"
            mv "$tmp_file" "$model_file"
            emit_event "architecture.evolved" "repo_hash=$(repo_hash)"
            success "Architecture model evolved" >&2
        else
            warn "Evolution detected but updated model invalid — keeping current model" >&2
        fi
    else
        info "No architectural evolution detected" >&2
    fi
}

# ─── Help ─────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Architecture${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright architecture <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}build${RESET}     [repo_root]                   Build architecture model"
    echo -e "    ${CYAN}validate${RESET}  <diff> [model_file]           Validate changes against model"
    echo -e "    ${CYAN}evolve${RESET}   [model_file] <changes_summary> Evolve model with new patterns"
    echo -e "    ${CYAN}help${RESET}                                    Show this help"
    echo ""
    echo -e "  ${BOLD}CONFIGURATION${RESET}"
    echo -e "    Feature flag:  ${DIM}intelligence.architecture_enabled${RESET} in daemon-config.json"
    echo -e "    Model stored:  ${DIM}~/.shipwright/memory/<repo-hash>/architecture.json${RESET}"
    echo ""
}

# ─── Command Router ──────────────────────────────────────────────────────

main() {
    case "${1:-help}" in
        build)     shift; architecture_build_model "$@" ;;
        validate)  shift; architecture_validate_changes "$@" ;;
        evolve)    shift; architecture_evolve_model "$@" ;;
        help|--help|-h) show_help ;;
        *)         error "Unknown: $1"; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
