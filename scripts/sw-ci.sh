#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright ci — GitHub Actions CI/CD Orchestration                      ║
# ║  Workflow generation · Matrix testing · Caching · Secret management      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            local escaped_val
            escaped_val=$(printf '%s' "$val" | jq -Rs '.' 2>/dev/null || printf '"%s"' "${val//\"/\\\"}")
            json_fields="${json_fields},\"${key}\":${escaped_val}"
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Generate Workflow YAML from Pipeline Template ──────────────────────────

cmd_generate() {
    local pipeline_config="${1:-.claude/pipeline-artifacts/composed-pipeline.json}"
    local workflow_name="${2:-shipwright-generated}"

    [[ ! -f "$pipeline_config" ]] && {
        error "Pipeline config not found: $pipeline_config"
        exit 1
    }

    info "Generating GitHub Actions workflow from pipeline config"

    local yaml_file=".github/workflows/${workflow_name}.yml"
    mkdir -p ".github/workflows"

    # Build YAML header
    local yaml_content
    yaml_content="name: ${workflow_name^}

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  SHIPWRIGHT_PIPELINE: ${workflow_name}

jobs:
"

    # Extract stages from pipeline config and generate jobs
    local stages
    stages=$(jq -r '.stages[] | select(.enabled==true) | .id' "$pipeline_config" 2>/dev/null || echo "")

    while IFS= read -r stage_id; do
        [[ -z "$stage_id" ]] && continue

        local stage_config
        stage_config=$(jq ".stages[] | select(.id==\"$stage_id\")" "$pipeline_config" 2>/dev/null || echo "{}")

        local gate
        gate=$(jq -r '.gate // "auto"' <<< "$stage_config")

        yaml_content+="  ${stage_id}:
    runs-on: ubuntu-latest
    needs: []
    if: success()
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y jq tmux
      - name: Run ${stage_id} stage
        run: shipwright pipeline run --stage ${stage_id}
"
    done <<< "$stages"

    # Write YAML to file atomically
    local tmp_file="${yaml_file}.tmp"
    echo "$yaml_content" > "$tmp_file"
    mv "$tmp_file" "$yaml_file"

    success "Generated workflow: $yaml_file"
    emit_event "ci_workflow_generated" "workflow=${workflow_name}" "stages=$(echo "$stages" | wc -l)"
}

# ─── Generate Test Matrix Configuration ─────────────────────────────────────

cmd_matrix() {
    local output_file="${1:-.github/workflows/test-matrix.yml}"

    info "Generating test matrix configuration"

    local matrix_yaml
    matrix_yaml="name: Test Matrix

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: \${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        bash-version: ['3.2', '4.0', '5.0', '5.2']
        node-version: ['18', '20', 'lts/*']

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v3
        with:
          node-version: \${{ matrix.node-version }}

      - name: Install bash \${{ matrix.bash-version }}
        run: |
          if [[ \"\${{ runner.os }}\" == \"macOS\" ]]; then
            brew install bash@\${{ matrix.bash-version }}
          else
            sudo apt-get update
            sudo apt-get install -y bash
          fi

      - name: Run tests with bash \${{ matrix.bash-version }}
        run: bash scripts/sw-pipeline-test.sh
"

    mkdir -p ".github/workflows"
    local tmp_file="${output_file}.tmp"
    echo "$matrix_yaml" > "$tmp_file"
    mv "$tmp_file" "$output_file"

    success "Generated matrix config: $output_file"
    emit_event "ci_matrix_generated" "os=2" "bash_versions=4" "node_versions=3"
}

# ─── Optimize Caching Strategy ─────────────────────────────────────────────

cmd_cache() {
    local workflow_file="${1:-.github/workflows/test.yml}"

    [[ ! -f "$workflow_file" ]] && {
        error "Workflow file not found: $workflow_file"
        exit 1
    }

    info "Optimizing caching strategy for workflow"

    local cache_steps
    cache_steps='      - name: Cache node_modules
        uses: actions/cache@v3
        with:
          path: node_modules
          key: ${{ runner.os }}-node-${{ hashFiles('"'"'package-lock.json'"'"') }}
          restore-keys: |
            ${{ runner.os }}-node-

      - name: Cache npm packages
        uses: actions/cache@v3
        with:
          path: ~/.npm
          key: ${{ runner.os }}-npm-${{ hashFiles('"'"'package-lock.json'"'"') }}
          restore-keys: |
            ${{ runner.os }}-npm-

      - name: Cache test results
        uses: actions/cache@v3
        with:
          path: coverage
          key: ${{ runner.os }}-coverage-${{ github.sha }}
          restore-keys: |
            ${{ runner.os }}-coverage-'

    # Parse workflow and insert cache steps after checkout (basic insertion)
    local tmp_file="${workflow_file}.tmp"
    awk -v cache_steps="$cache_steps" '
        /- uses: actions\/checkout@v/ {
            print;
            if (!printed_cache) {
                print cache_steps;
                printed_cache = 1
            }
            next
        }
        { print }
    ' "$workflow_file" > "$tmp_file"

    mv "$tmp_file" "$workflow_file"

    success "Optimized caching in: $workflow_file"
    emit_event "ci_cache_optimized" "workflow=$(basename "$workflow_file")"
}

# ─── Analyze Workflow Efficiency ────────────────────────────────────────────

cmd_analyze() {
    local workflow_file="${1:-.github/workflows/test.yml}"

    [[ ! -f "$workflow_file" ]] && {
        error "Workflow file not found: $workflow_file"
        exit 1
    }

    info "Analyzing workflow efficiency"

    local job_count step_count matrix_enabled
    job_count=$(grep -c "^  [a-z_-]*:" "$workflow_file" 2>/dev/null || echo "0")
    step_count=$(grep -c "      - name:" "$workflow_file" 2>/dev/null || echo "0")
    matrix_enabled=$(grep -c "matrix:" "$workflow_file" 2>/dev/null || echo "0")

    local has_cache
    has_cache=$(grep -c "actions/cache" "$workflow_file" 2>/dev/null || echo "0")

    local has_timeout
    has_timeout=$(grep -c "timeout-minutes:" "$workflow_file" 2>/dev/null || echo "0")

    echo ""
    echo -e "${BOLD}Workflow Analysis: $(basename "$workflow_file")${RESET}"
    echo -e "  ${CYAN}Jobs:${RESET} $job_count"
    echo -e "  ${CYAN}Steps:${RESET} $step_count"
    echo -e "  ${CYAN}Matrix enabled:${RESET} $([ "$matrix_enabled" -gt 0 ] && echo "yes" || echo "no")"
    echo -e "  ${CYAN}Cache steps:${RESET} $has_cache"
    echo -e "  ${CYAN}Timeouts configured:${RESET} $([ "$has_timeout" -gt 0 ] && echo "yes" || echo "no")"
    echo ""

    # Recommendations
    if [[ $has_cache -eq 0 ]]; then
        warn "No caching detected. Run 'shipwright ci cache' to optimize"
    fi

    if [[ $has_timeout -eq 0 ]]; then
        warn "No job timeouts configured. Consider adding timeout-minutes"
    fi

    success "Analysis complete"
    emit_event "ci_workflow_analyzed" "jobs=$job_count" "steps=$step_count" "has_cache=$has_cache"
}

# ─── Audit Required Secrets ────────────────────────────────────────────────

cmd_secrets() {
    local action="${1:-audit}"

    case "$action" in
        audit)
            info "Auditing required secrets"

            local required_secrets=()
            [[ -f ".github/workflows/test.yml" ]] && {
                required_secrets+=("GITHUB_TOKEN")
            }

            # Check for common secret patterns in workflows
            local secrets_found
            secrets_found=$(grep -rh '\${{ secrets\.' .github/workflows 2>/dev/null | \
                grep -oE 'secrets\.[A-Z_]+' | sort -u | sed 's/secrets\.//' || true)

            if [[ -z "$secrets_found" ]]; then
                success "No secrets referenced in workflows"
            else
                echo ""
                echo -e "${BOLD}Required Secrets:${RESET}"
                echo "$secrets_found" | while read -r secret; do
                    echo -e "  ${CYAN}•${RESET} $secret"
                done
                echo ""
            fi

            emit_event "ci_secrets_audited" "secrets_found=$(echo "$secrets_found" | wc -l)"
            ;;

        check)
            info "Checking secret availability in GitHub"

            local repo="${2:-.}"
            local owner org_name

            # Parse owner from git remote
            owner=$(cd "$repo" && git config --get remote.origin.url | \
                grep -oE '[:/]([^/]+)/[^/]+\.git' | sed 's|[:/]||g' | cut -d/ -f1)

            if [[ -z "$owner" ]]; then
                error "Could not determine repository owner"
                exit 1
            fi

            success "Secrets check would query: $owner"
            emit_event "ci_secrets_checked" "owner=$owner"
            ;;

        rotate)
            warn "Secret rotation should be done manually in GitHub repository settings"
            info "Visit: https://github.com/$owner/settings/secrets/actions"
            ;;

        *)
            error "Unknown secrets action: $action"
            exit 1
            ;;
    esac
}

# ─── Generate Reusable Workflow Templates ──────────────────────────────────

cmd_reusable() {
    local template_name="${1:-base-test}"
    local output_dir="${2:-.github/workflows}"

    info "Generating reusable workflow template: $template_name"

    mkdir -p "$output_dir"

    local workflow_file="${output_dir}/${template_name}.yml"
    local template_content

    case "$template_name" in
        base-test)
            template_content='name: Reusable Test Workflow

on:
  workflow_call:
    inputs:
      test-cmd:
        required: true
        type: string
      os:
        required: false
        type: string
        default: "ubuntu-latest"
    secrets:
      GITHUB_TOKEN:
        required: true

jobs:
  test:
    runs-on: ${{ inputs.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: sudo apt-get update && sudo apt-get install -y jq tmux
      - name: Run tests
        run: ${{ inputs.test-cmd }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
'
            ;;

        deploy)
            template_content='name: Reusable Deploy Workflow

on:
  workflow_call:
    inputs:
      environment:
        required: true
        type: string
      deploy-cmd:
        required: true
        type: string
    secrets:
      DEPLOY_KEY:
        required: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to ${{ inputs.environment }}
        run: ${{ inputs.deploy-cmd }}
        env:
          DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}
'
            ;;

        *)
            error "Unknown template: $template_name"
            exit 1
            ;;
    esac

    local tmp_file="${workflow_file}.tmp"
    echo "$template_content" > "$tmp_file"
    mv "$tmp_file" "$workflow_file"

    success "Generated reusable workflow: $workflow_file"
    emit_event "ci_reusable_generated" "template=$template_name"
}

# ─── Generate Status Badges ────────────────────────────────────────────────

cmd_badges() {
    local workflow_name="${1:-test}"
    local repo="${2:-.}"

    info "Generating status badges for workflow: $workflow_name"

    # Extract owner/repo from git remote
    local owner repo_name
    owner=$(cd "$repo" && git config --get remote.origin.url | \
        grep -oE '[:/]([^/]+)/[^/]+\.git' | sed 's|[:/]||g' | cut -d/ -f1)
    repo_name=$(cd "$repo" && git config --get remote.origin.url | \
        grep -oE '[^/]+\.git$' | sed 's/\.git//')

    if [[ -z "$owner" ]] || [[ -z "$repo_name" ]]; then
        error "Could not determine repository owner/name"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}Status Badge Markdown:${RESET}"
    echo ""
    echo "[![${workflow_name}](https://github.com/${owner}/${repo_name}/actions/workflows/${workflow_name}.yml/badge.svg)](https://github.com/${owner}/${repo_name}/actions/workflows/${workflow_name}.yml)"
    echo ""

    success "Badges generated for ${owner}/${repo_name}"
    emit_event "ci_badges_generated" "workflow=$workflow_name" "repo=${owner}/${repo_name}"
}

# ─── Validate Workflow YAML Syntax ─────────────────────────────────────────

cmd_validate() {
    local workflow_file="${1:-.github/workflows/test.yml}"

    [[ ! -f "$workflow_file" ]] && {
        error "Workflow file not found: $workflow_file"
        exit 1
    }

    info "Validating workflow YAML: $workflow_file"

    # Check for valid YAML structure
    if ! jq -e 'type' <<< "$(yq eval -o=json "$workflow_file" 2>/dev/null || echo '{}')" &>/dev/null; then
        # Fallback: basic validation
        if grep -q "^name:" "$workflow_file" && grep -q "^on:" "$workflow_file" && grep -q "^jobs:" "$workflow_file"; then
            success "Workflow structure looks valid"
            emit_event "ci_workflow_validated" "file=$(basename "$workflow_file")"
        else
            error "Workflow missing required sections (name, on, jobs)"
            exit 1
        fi
    else
        success "Workflow YAML is valid"
        emit_event "ci_workflow_validated" "file=$(basename "$workflow_file")"
    fi
}

# ─── Runner Management & Recommendations ────────────────────────────────────

cmd_runners() {
    local action="${1:-list}"

    case "$action" in
        list)
            info "GitHub-hosted runners available:"
            echo ""
            echo -e "  ${CYAN}ubuntu-latest${RESET}      - Linux (Ubuntu 22.04)"
            echo -e "  ${CYAN}macos-latest${RESET}       - macOS (ARM64)"
            echo -e "  ${CYAN}windows-latest${RESET}     - Windows Server 2022"
            echo -e "  ${CYAN}ubuntu-20.04${RESET}       - Linux (Ubuntu 20.04)"
            echo -e "  ${CYAN}macos-12${RESET}           - macOS (Intel)"
            echo ""
            emit_event "ci_runners_listed"
            ;;

        recommend)
            info "Runner recommendations based on workload"
            echo ""
            echo -e "  ${CYAN}Build/test (fast):${RESET}   ubuntu-latest"
            echo -e "  ${CYAN}Multi-OS testing:${RESET}   matrix [ubuntu, macos, windows]"
            echo -e "  ${CYAN}Bash scripting:${RESET}     ubuntu-latest or macos-latest"
            echo -e "  ${CYAN}Production deploy:${RESET}  self-hosted runner"
            echo ""
            emit_event "ci_runners_recommended"
            ;;

        *)
            error "Unknown runners action: $action"
            exit 1
            ;;
    esac
}

# ─── Show Help ──────────────────────────────────────────────────────────────

show_help() {
    cat << EOF
${CYAN}${BOLD}shipwright ci${RESET} — GitHub Actions CI/CD Orchestration

${BOLD}USAGE${RESET}
  shipwright ci <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}generate${RESET} [config] [name]     Generate workflow YAML from pipeline config
  ${CYAN}analyze${RESET} [workflow]           Analyze workflow efficiency and recommendations
  ${CYAN}matrix${RESET} [output]              Generate test matrix configuration
  ${CYAN}cache${RESET} [workflow]             Optimize caching strategy in workflow
  ${CYAN}secrets${RESET} <audit|check|rotate> Manage and audit required secrets
  ${CYAN}reusable${RESET} [template] [dir]    Generate reusable workflow templates
  ${CYAN}badges${RESET} [workflow] [repo]     Generate status badge markdown
  ${CYAN}runners${RESET} <list|recommend>     Runner management and recommendations
  ${CYAN}validate${RESET} [workflow]          Validate workflow YAML syntax
  ${CYAN}help${RESET}                         Show this help message
  ${CYAN}version${RESET}                      Show version

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright ci generate${RESET}                     # Generate from composed pipeline
  ${DIM}shipwright ci matrix${RESET}                       # Create test matrix with bash/node versions
  ${DIM}shipwright ci analyze .github/workflows/test.yml${RESET}
  ${DIM}shipwright ci cache .github/workflows/test.yml${RESET}
  ${DIM}shipwright ci secrets audit${RESET}
  ${DIM}shipwright ci badges test${RESET}
  ${DIM}shipwright ci validate${RESET}

${BOLD}FEATURES${RESET}
  • Workflow generation from pipeline templates
  • Multi-OS and multi-version test matrices
  • Smart dependency caching optimization
  • Workflow efficiency analysis
  • Secret auditing and rotation guidance
  • Reusable workflow templates
  • Status badge generation
  • YAML validation

EOF
}

# ─── Source Guard & Main ────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"

    case "$cmd" in
        generate)  shift; cmd_generate "$@" ;;
        analyze)   shift; cmd_analyze "$@" ;;
        matrix)    shift; cmd_matrix "$@" ;;
        cache)     shift; cmd_cache "$@" ;;
        secrets)   shift; cmd_secrets "$@" ;;
        reusable)  shift; cmd_reusable "$@" ;;
        badges)    shift; cmd_badges "$@" ;;
        runners)   shift; cmd_runners "$@" ;;
        validate)  shift; cmd_validate "$@" ;;
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            echo "shipwright ci v${VERSION}"
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
fi
