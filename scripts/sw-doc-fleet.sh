#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright doc-fleet — Documentation Fleet Orchestrator                 ║
# ║  5 specialized agents: Architect · Claude MD · Strategy · Patterns · README ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded
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
# ─── Constants ──────────────────────────────────────────────────────────────
FLEET_HOME="${HOME}/.shipwright/doc-fleet"
FLEET_STATE="${FLEET_HOME}/state.json"
FLEET_LOG="${FLEET_HOME}/runs.jsonl"
FLEET_REPORT_DIR="${FLEET_HOME}/reports"
MANIFEST_FILE="${REPO_DIR}/.claude/pipeline-artifacts/docs-manifest.json"

# Fleet agent definitions (role → focus areas → description)
FLEET_ROLES="doc-architect claude-md strategy-curator pattern-writer readme-optimizer"

# ─── Ensure directories exist ──────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "$FLEET_HOME" "$FLEET_REPORT_DIR"
    mkdir -p "${REPO_DIR}/.claude/pipeline-artifacts"
}

# ─── Initialize fleet state ────────────────────────────────────────────────
init_state() {
    if [[ ! -f "$FLEET_STATE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        cat > "$tmp_file" << 'JSON'
{
  "last_run": null,
  "run_count": 0,
  "agents": {},
  "last_audit": null,
  "docs_health_score": 0
}
JSON
        mv "$tmp_file" "$FLEET_STATE"
    fi
}

# ─── Audit: Scan documentation health ──────────────────────────────────────
cmd_audit() {
    ensure_dirs
    init_state

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║          Documentation Fleet — Health Audit                  ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    local total_score=0
    local total_checks=0
    local issues_found=0

    # --- Check 1: Documentation files exist
    info "Checking documentation inventory..."
    local expected_docs="README.md STRATEGY.md CHANGELOG.md docs/TIPS.md docs/KNOWN-ISSUES.md"
    local missing_docs=""
    for doc in $expected_docs; do
        total_checks=$((total_checks + 1))
        if [[ -f "${REPO_DIR}/${doc}" ]]; then
            total_score=$((total_score + 1))
        else
            missing_docs="${missing_docs} ${doc}"
            issues_found=$((issues_found + 1))
        fi
    done
    if [[ -n "$missing_docs" ]]; then
        warn "Missing docs:${missing_docs}"
    else
        success "All expected documentation files present"
    fi

    # --- Check 2: CLAUDE.md freshness
    info "Checking CLAUDE.md freshness..."
    total_checks=$((total_checks + 1))
    if [[ -f "${REPO_DIR}/.claude/CLAUDE.md" ]]; then
        local claude_age_days=0
        if command -v stat >/dev/null 2>&1; then
            local claude_mtime
            claude_mtime=$(file_mtime "${REPO_DIR}/.claude/CLAUDE.md")
            local now_epoch_val
            now_epoch_val=$(date +%s)
            claude_age_days=$(( (now_epoch_val - claude_mtime) / 86400 ))
        fi
        if [[ $claude_age_days -gt 14 ]]; then
            warn "CLAUDE.md last modified ${claude_age_days} days ago"
            issues_found=$((issues_found + 1))
        else
            total_score=$((total_score + 1))
            success "CLAUDE.md is fresh (${claude_age_days} days old)"
        fi
    else
        warn "No .claude/CLAUDE.md found"
        issues_found=$((issues_found + 1))
    fi

    # --- Check 3: Agent role definitions
    info "Checking agent role definitions..."
    total_checks=$((total_checks + 1))
    local agent_count=0
    if [[ -d "${REPO_DIR}/.claude/agents" ]]; then
        agent_count=$(ls -1 "${REPO_DIR}/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [[ $agent_count -ge 5 ]]; then
        total_score=$((total_score + 1))
        success "${agent_count} agent role definitions found"
    else
        warn "Only ${agent_count} agent role definitions (expected 5+)"
        issues_found=$((issues_found + 1))
    fi

    # --- Check 4: AUTO section staleness
    info "Checking AUTO section sync status..."
    total_checks=$((total_checks + 1))
    local docs_script="${SCRIPT_DIR}/sw-docs.sh"
    if [[ -x "$docs_script" ]]; then
        # Run with a 15-second timeout (macOS-compatible)
        local docs_check_ok=false
        bash "$docs_script" check >/dev/null 2>&1 &
        local docs_pid=$!
        local wait_count=0
        while kill -0 "$docs_pid" 2>/dev/null && [[ $wait_count -lt 15 ]]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        if kill -0 "$docs_pid" 2>/dev/null; then
            kill "$docs_pid" 2>/dev/null || true
            wait "$docs_pid" 2>/dev/null || true
            warn "AUTO section check timed out (skipped)"
            total_score=$((total_score + 1))
        elif wait "$docs_pid" 2>/dev/null; then
            docs_check_ok=true
        fi
        if [[ "$docs_check_ok" == "true" ]]; then
            total_score=$((total_score + 1))
            success "All AUTO sections are in sync"
        elif [[ $wait_count -lt 15 ]]; then
            warn "Stale AUTO sections detected"
            issues_found=$((issues_found + 1))
        fi
    else
        warn "sw-docs.sh not found — skipping AUTO section check"
    fi

    # --- Check 5: Docs directory structure
    info "Checking docs directory structure..."
    total_checks=$((total_checks + 1))
    local expected_dirs="docs docs/strategy docs/patterns docs/tmux-research"
    local missing_dirs=""
    for dir in $expected_dirs; do
        if [[ ! -d "${REPO_DIR}/${dir}" ]]; then
            missing_dirs="${missing_dirs} ${dir}"
        fi
    done
    if [[ -n "$missing_dirs" ]]; then
        warn "Missing directories:${missing_dirs}"
        issues_found=$((issues_found + 1))
    else
        total_score=$((total_score + 1))
        success "Documentation directory structure intact"
    fi

    # --- Check 6: Orphan detection (md files not linked from any index)
    info "Checking for orphan documentation..."
    total_checks=$((total_checks + 1))
    local orphan_count=0
    while IFS= read -r md_file; do
        local basename_file
        basename_file=$(basename "$md_file")
        # Skip index files, changelogs, and license
        case "$basename_file" in
            README.md|CHANGELOG*|LICENSE*|index.md) continue ;;
        esac
        # Check if referenced from any other md file
        local ref_count
        ref_count=$(grep -rl "$basename_file" "${REPO_DIR}"/*.md "${REPO_DIR}"/docs/*.md 2>/dev/null | wc -l | tr -d ' ') || ref_count=0
        if [[ $ref_count -eq 0 ]]; then
            orphan_count=$((orphan_count + 1))
        fi
    done < <(find "${REPO_DIR}/docs" -name "*.md" -maxdepth 1 2>/dev/null || true)
    if [[ $orphan_count -gt 3 ]]; then
        warn "${orphan_count} potentially orphan docs in docs/ (not linked from index)"
        issues_found=$((issues_found + 1))
    else
        total_score=$((total_score + 1))
        success "Orphan check passed (${orphan_count} unlinked docs)"
    fi

    # --- Check 7: Strategy alignment
    info "Checking strategy document freshness..."
    total_checks=$((total_checks + 1))
    if [[ -f "${REPO_DIR}/STRATEGY.md" ]]; then
        local strategy_lines
        strategy_lines=$(wc -l < "${REPO_DIR}/STRATEGY.md" | tr -d ' ')
        if [[ $strategy_lines -gt 50 ]]; then
            total_score=$((total_score + 1))
            success "STRATEGY.md has substance (${strategy_lines} lines)"
        else
            warn "STRATEGY.md seems thin (${strategy_lines} lines)"
            issues_found=$((issues_found + 1))
        fi
    else
        warn "No STRATEGY.md found"
        issues_found=$((issues_found + 1))
    fi

    # --- Check 8: Docs-to-code ratio
    info "Checking documentation coverage..."
    total_checks=$((total_checks + 1))
    local doc_files
    doc_files=$(find "${REPO_DIR}" -name "*.md" -not -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' ')
    local script_files
    script_files=$(find "${REPO_DIR}/scripts" -name "*.sh" -not -name "*-test.sh" 2>/dev/null | wc -l | tr -d ' ')
    if [[ $script_files -gt 0 ]]; then
        local ratio=$((doc_files * 100 / script_files))
        if [[ $ratio -ge 30 ]]; then
            total_score=$((total_score + 1))
            success "Docs-to-scripts ratio: ${doc_files}/${script_files} (${ratio}%)"
        else
            warn "Low docs-to-scripts ratio: ${doc_files}/${script_files} (${ratio}%)"
            issues_found=$((issues_found + 1))
        fi
    else
        total_score=$((total_score + 1))
    fi

    # --- Summary
    echo ""
    local health_pct=0
    if [[ $total_checks -gt 0 ]]; then
        health_pct=$((total_score * 100 / total_checks))
    fi

    local color="$RED"
    if [[ $health_pct -ge 90 ]]; then
        color="$GREEN"
    elif [[ $health_pct -ge 70 ]]; then
        color="$YELLOW"
    fi

    echo -e "${BOLD}Documentation Health Score: ${color}${health_pct}%${RESET} (${total_score}/${total_checks} checks passed)"
    echo -e "${DIM}Issues found: ${issues_found}${RESET}"
    echo ""

    # Update state
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg ts "$(now_iso)" \
       --argjson score "$health_pct" \
       --argjson issues "$issues_found" \
       '.last_audit = $ts | .docs_health_score = $score | .last_issues_found = $issues' \
        "$FLEET_STATE" > "$tmp_file" 2>/dev/null || echo '{}' > "$tmp_file"
    mv "$tmp_file" "$FLEET_STATE"

    emit_event "doc_fleet.audit" "health_score=${health_pct}" "issues=${issues_found}" "checks=${total_checks}"
    return 0
}

# ─── Launch: Spawn the documentation fleet ──────────────────────────────────
cmd_launch() {
    local mode="${1:-}"
    shift 2>/dev/null || true
    local specific_role="${1:-}"
    shift 2>/dev/null || true

    ensure_dirs
    init_state

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║          Documentation Fleet — Launch                        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    local roles_to_launch="$FLEET_ROLES"
    if [[ -n "$specific_role" ]]; then
        # Validate role
        local valid=false
        for r in $FLEET_ROLES; do
            if [[ "$r" == "$specific_role" ]]; then
                valid=true
                break
            fi
        done
        if [[ "$valid" != "true" ]]; then
            error "Unknown role: $specific_role"
            echo -e "  Valid roles: ${CYAN}${FLEET_ROLES}${RESET}"
            return 1
        fi
        roles_to_launch="$specific_role"
    fi

    local run_id
    run_id="docfleet-$(date +%s)-$((RANDOM % 10000))"
    local spawned=0

    info "Run ID: ${CYAN}${run_id}${RESET}"
    info "Mode: ${CYAN}${mode:-full}${RESET}"
    echo ""

    for role in $roles_to_launch; do
        local agent_goal=""
        local agent_focus=""

        case "$role" in
            doc-architect)
                agent_goal="Audit the full documentation tree structure. Find duplicates, orphans, missing cross-links. Create/update index files. Produce a docs manifest. Focus: docs/, .claude/, README.md, STRATEGY.md"
                agent_focus="docs/ .claude/ README.md STRATEGY.md"
                ;;
            claude-md)
                agent_goal="Audit all CLAUDE.md files and agent role definitions. Ensure AUTO sections are current, command tables accurate, development guidelines match reality. Remove stale content. Focus: .claude/CLAUDE.md, .claude/agents/, claude-code/"
                agent_focus=".claude/CLAUDE.md .claude/agents/ claude-code/"
                ;;
            strategy-curator)
                agent_goal="Audit strategic docs — STRATEGY.md, AGI-PLATFORM-PLAN.md, AGI-WHATS-NEXT.md, PLATFORM-TODO-BACKLOG.md, docs/strategy/. Mark completed items done, update metrics, remove aspirational content that is now reality. Focus: STRATEGY.md, docs/AGI-*, docs/PLATFORM-*, docs/strategy/"
                agent_focus="STRATEGY.md docs/AGI-PLATFORM-PLAN.md docs/AGI-WHATS-NEXT.md docs/PLATFORM-TODO-BACKLOG.md docs/strategy/"
                ;;
            pattern-writer)
                agent_goal="Audit developer guides and patterns. Update docs/patterns/ for accuracy, refresh TIPS.md with recent learnings, remove resolved items from KNOWN-ISSUES.md, verify config-policy.md matches actual schema. Focus: docs/patterns/, docs/TIPS.md, docs/KNOWN-ISSUES.md, docs/config-policy.md, docs/tmux-research/"
                agent_focus="docs/patterns/ docs/TIPS.md docs/KNOWN-ISSUES.md docs/config-policy.md docs/tmux-research/"
                ;;
            readme-optimizer)
                agent_goal="Audit the README.md and public-facing documentation. Verify command tables match actual CLI, install instructions work, badges and links are valid. Optimize for scannability. Focus: README.md, install.sh, .github/pull_request_template.md"
                agent_focus="README.md install.sh .github/pull_request_template.md"
                ;;
        esac

        info "Spawning ${CYAN}${role}${RESET}..."

        if [[ "$mode" == "--dry-run" ]]; then
            echo -e "  ${DIM}[dry-run] Would spawn ${role}${RESET}"
            echo -e "  ${DIM}Goal: ${agent_goal}${RESET}"
            echo ""
            spawned=$((spawned + 1))
            continue
        fi

        # Spawn via tmux if available
        if command -v tmux >/dev/null 2>&1; then
            local session_name="docfleet-${role}"

            # Kill existing session for this role if present
            tmux kill-session -t "$session_name" 2>/dev/null || true

            # Write agent brief to a file so tmux doesn't mangle the goal text
            local brief_file="${FLEET_HOME}/${role}-brief.md"
            local brief_tmp
            brief_tmp=$(mktemp)
            cat > "$brief_tmp" << BRIEF
# Doc Fleet Agent: ${role}

## Goal

${agent_goal}

## Focus Files

${agent_focus}

## Instructions

Read .claude/agents/doc-fleet-agent.md for your full role definition.
Run: claude --print .claude/agents/doc-fleet-agent.md to review before starting.
BRIEF
            mv "$brief_tmp" "$brief_file"

            if [[ "$mode" == "--autonomous" ]] && [[ -x "${SCRIPT_DIR}/sw-loop.sh" ]]; then
                # Launch via loop harness for autonomous mode
                tmux new-session -d -s "$session_name" -c "$REPO_DIR" \
                    "bash \"${SCRIPT_DIR}/sw-loop.sh\" \"${agent_goal}\" --max-iterations 10 --roles docs" 2>/dev/null || true
                success "Autonomous agent: ${CYAN}${session_name}${RESET} (loop mode)"
            else
                # Interactive mode: show the brief and wait for user to attach
                tmux new-session -d -s "$session_name" -c "$REPO_DIR" 2>/dev/null || true
                # Send the brief display commands
                tmux send-keys -t "$session_name" "cat \"${brief_file}\" && echo '' && echo 'Ready — start Claude Code in this session to begin work.'" Enter 2>/dev/null || true
                success "Tmux session: ${CYAN}${session_name}${RESET}"
            fi
        fi

        spawned=$((spawned + 1))
        echo ""
    done

    # Record run
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg ts "$(now_iso)" \
       --arg run_id "$run_id" \
       --argjson count "$spawned" \
       --arg mode "${mode:-full}" \
       '.last_run = $ts | .run_count += 1' \
        "$FLEET_STATE" > "$tmp_file" 2>/dev/null || echo '{}' > "$tmp_file"
    mv "$tmp_file" "$FLEET_STATE"

    local log_entry
    log_entry=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --arg run_id "$run_id" \
        --argjson agents_spawned "$spawned" \
        --arg mode "${mode:-full}" \
        '{ts: $ts, run_id: $run_id, agents_spawned: $agents_spawned, mode: $mode}')
    echo "$log_entry" >> "$FLEET_LOG"

    emit_event "doc_fleet.launch" "run_id=${run_id}" "agents=${spawned}" "mode=${mode:-full}"

    echo -e "${GREEN}${BOLD}Fleet launched: ${spawned} agents${RESET}"
    echo ""
    echo -e "  ${DIM}Monitor: ${CYAN}shipwright doc-fleet status${RESET}"
    echo -e "  ${DIM}Retire:  ${CYAN}shipwright doc-fleet retire${RESET}"
    echo ""
}

# ─── Status: Show fleet agent status ────────────────────────────────────────
cmd_status() {
    ensure_dirs
    init_state

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║          Documentation Fleet — Status                        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Show state
    local last_run last_audit health_score run_count
    last_run=$(jq -r '.last_run // "never"' "$FLEET_STATE" 2>/dev/null) || last_run="never"
    last_audit=$(jq -r '.last_audit // "never"' "$FLEET_STATE" 2>/dev/null) || last_audit="never"
    health_score=$(jq -r '.docs_health_score // 0' "$FLEET_STATE" 2>/dev/null) || health_score=0
    run_count=$(jq -r '.run_count // 0' "$FLEET_STATE" 2>/dev/null) || run_count=0

    echo -e "  Last run:         ${CYAN}${last_run}${RESET}"
    echo -e "  Last audit:       ${CYAN}${last_audit}${RESET}"
    echo -e "  Health score:     ${CYAN}${health_score}%${RESET}"
    echo -e "  Total runs:       ${CYAN}${run_count}${RESET}"
    echo ""

    # Show tmux sessions
    info "Active Doc Fleet Sessions:"
    echo ""

    local active=0
    for role in $FLEET_ROLES; do
        local session_name="docfleet-${role}"
        if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$session_name" 2>/dev/null; then
            echo -e "  ${GREEN}●${RESET} ${CYAN}${role}${RESET}  →  tmux session: ${DIM}${session_name}${RESET}"
            active=$((active + 1))
        else
            echo -e "  ${DIM}○${RESET} ${DIM}${role}${RESET}  →  ${DIM}not running${RESET}"
        fi
    done

    echo ""
    echo -e "  Active agents: ${CYAN}${active}${RESET} / ${#FLEET_ROLES}"
    echo ""

    # Show recent runs
    if [[ -f "$FLEET_LOG" ]] && [[ -s "$FLEET_LOG" ]]; then
        info "Recent Runs:"
        echo ""
        tail -5 "$FLEET_LOG" | while IFS= read -r line; do
            local ts run_id agents_spawned mode
            ts=$(echo "$line" | jq -r '.ts // "?"' 2>/dev/null) || ts="?"
            run_id=$(echo "$line" | jq -r '.run_id // "?"' 2>/dev/null) || run_id="?"
            agents_spawned=$(echo "$line" | jq -r '.agents_spawned // 0' 2>/dev/null) || agents_spawned=0
            mode=$(echo "$line" | jq -r '.mode // "?"' 2>/dev/null) || mode="?"
            echo -e "  ${DIM}${ts}${RESET}  ${CYAN}${run_id}${RESET}  agents=${agents_spawned}  mode=${mode}"
        done
        echo ""
    fi
}

# ─── Retire: Tear down fleet sessions ──────────────────────────────────────
cmd_retire() {
    local specific_role="${1:-}"
    shift 2>/dev/null || true

    ensure_dirs

    echo ""
    info "Retiring doc fleet agents..."
    echo ""

    local roles_to_retire="$FLEET_ROLES"
    if [[ -n "$specific_role" ]]; then
        roles_to_retire="$specific_role"
    fi

    local retired=0
    for role in $roles_to_retire; do
        local session_name="docfleet-${role}"
        if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$session_name" 2>/dev/null; then
            tmux kill-session -t "$session_name" 2>/dev/null && \
                success "Retired: ${CYAN}${role}${RESET}" || \
                warn "Failed to retire: ${role}"
            retired=$((retired + 1))
        else
            echo -e "  ${DIM}${role} — not running${RESET}"
        fi
    done

    echo ""
    success "Retired ${retired} agents"
    emit_event "doc_fleet.retire" "agents_retired=${retired}"
    echo ""
}

# ─── Manifest: Generate documentation manifest ─────────────────────────────
cmd_manifest() {
    ensure_dirs

    echo ""
    info "Generating documentation manifest..."
    echo ""

    local tmp_file
    tmp_file=$(mktemp)

    # Build manifest JSON
    local docs_json="[]"
    while IFS= read -r md_file; do
        local rel_path="${md_file#${REPO_DIR}/}"
        local line_count
        line_count=$(wc -l < "$md_file" | tr -d ' ')
        local title=""
        # Extract first heading
        title=$(grep -m1 '^#' "$md_file" 2>/dev/null | sed 's/^#* //' || echo "$rel_path")
        local mtime
        mtime=$(file_mtime "$md_file")

        # Determine audience
        local audience="contributor"
        case "$rel_path" in
            README.md|install.sh) audience="user" ;;
            .claude/*) audience="agent" ;;
            docs/strategy/*) audience="stakeholder" ;;
            docs/patterns/*) audience="contributor" ;;
            STRATEGY.md) audience="stakeholder" ;;
        esac

        docs_json=$(echo "$docs_json" | jq \
            --arg path "$rel_path" \
            --arg title "$title" \
            --argjson lines "$line_count" \
            --arg mtime "$mtime" \
            --arg audience "$audience" \
            '. += [{"path": $path, "title": $title, "lines": $lines, "last_modified": $mtime, "audience": $audience}]')
    done < <(find "${REPO_DIR}" -name "*.md" \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" \
        2>/dev/null | sort)

    local doc_count
    doc_count=$(echo "$docs_json" | jq 'length')

    jq -n \
        --arg ts "$(now_iso)" \
        --argjson docs "$docs_json" \
        --argjson count "$doc_count" \
        '{
            generated_at: $ts,
            total_documents: $count,
            documents: $docs,
            audiences: ["user", "contributor", "agent", "stakeholder", "operator"],
            structure: {
                root: ["README.md", "STRATEGY.md", "CHANGELOG.md"],
                claude: [".claude/CLAUDE.md", ".claude/agents/"],
                docs: ["docs/strategy/", "docs/patterns/", "docs/tmux-research/"],
                config: ["docs/config-policy.md", "config/policy.json"]
            }
        }' > "$tmp_file"

    mv "$tmp_file" "$MANIFEST_FILE"
    success "Manifest written to ${CYAN}.claude/pipeline-artifacts/docs-manifest.json${RESET}"
    echo -e "  ${DIM}Total documents: ${doc_count}${RESET}"
    echo ""

    emit_event "doc_fleet.manifest" "doc_count=${doc_count}"
}

# ─── Report: Generate comprehensive documentation report ────────────────────
cmd_report() {
    local format="${1:-text}"
    shift 2>/dev/null || true

    ensure_dirs
    init_state

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║          Documentation Fleet — Report                        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Count files by category
    local root_docs=0 claude_docs=0 docs_dir=0 agent_defs=0 pattern_docs=0 strategy_docs=0 tmux_docs=0

    root_docs=$(find "${REPO_DIR}" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    claude_docs=$(find "${REPO_DIR}/.claude" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    agent_defs=$(find "${REPO_DIR}/.claude/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    docs_dir=$(find "${REPO_DIR}/docs" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    pattern_docs=$(find "${REPO_DIR}/docs/patterns" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    strategy_docs=$(find "${REPO_DIR}/docs/strategy" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    tmux_docs=$(find "${REPO_DIR}/docs/tmux-research" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

    info "Documentation Inventory"
    echo ""
    echo -e "  Root documents:        ${CYAN}${root_docs}${RESET}"
    echo -e "  .claude/ documents:    ${CYAN}${claude_docs}${RESET}"
    echo -e "  Agent definitions:     ${CYAN}${agent_defs}${RESET}"
    echo -e "  docs/ documents:       ${CYAN}${docs_dir}${RESET}"
    echo -e "  Pattern guides:        ${CYAN}${pattern_docs}${RESET}"
    echo -e "  Strategy documents:    ${CYAN}${strategy_docs}${RESET}"
    echo -e "  tmux documentation:    ${CYAN}${tmux_docs}${RESET}"
    echo ""

    local total=$((root_docs + claude_docs + agent_defs + docs_dir + pattern_docs + strategy_docs + tmux_docs))
    echo -e "  ${BOLD}Total documentation files: ${CYAN}${total}${RESET}"
    echo ""

    # Line count totals
    info "Documentation Volume"
    echo ""
    local total_lines=0
    while IFS= read -r md_file; do
        local lines
        lines=$(wc -l < "$md_file" | tr -d ' ')
        total_lines=$((total_lines + lines))
    done < <(find "${REPO_DIR}" -name "*.md" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)
    echo -e "  Total documentation lines: ${CYAN}${total_lines}${RESET}"
    echo ""

    # Fleet state
    info "Fleet State"
    echo ""
    local health_score
    health_score=$(jq -r '.docs_health_score // 0' "$FLEET_STATE" 2>/dev/null) || health_score=0
    local last_audit
    last_audit=$(jq -r '.last_audit // "never"' "$FLEET_STATE" 2>/dev/null) || last_audit="never"
    echo -e "  Health score:   ${CYAN}${health_score}%${RESET}"
    echo -e "  Last audit:     ${CYAN}${last_audit}${RESET}"
    echo ""

    # JSON output if requested
    if [[ "$format" == "--json" || "$format" == "json" ]]; then
        local report_file="${FLEET_REPORT_DIR}/report-$(date +%Y%m%d-%H%M%S).json"
        jq -n \
            --arg ts "$(now_iso)" \
            --argjson root "$root_docs" \
            --argjson claude "$claude_docs" \
            --argjson agents "$agent_defs" \
            --argjson docs "$docs_dir" \
            --argjson patterns "$pattern_docs" \
            --argjson strategy "$strategy_docs" \
            --argjson tmux "$tmux_docs" \
            --argjson total "$total" \
            --argjson total_lines "$total_lines" \
            --argjson health "$health_score" \
            '{
                generated_at: $ts,
                inventory: {
                    root: $root, claude: $claude, agent_defs: $agents,
                    docs: $docs, patterns: $patterns, strategy: $strategy, tmux: $tmux,
                    total: $total
                },
                volume: { total_lines: $total_lines },
                health: { score: $health }
            }' > "$report_file"
        success "JSON report: ${CYAN}${report_file}${RESET}"
    fi

    emit_event "doc_fleet.report" "total_docs=${total}" "total_lines=${total_lines}" "health=${health_score}"
}

# ─── Roles: List available fleet roles ──────────────────────────────────────
cmd_roles() {
    echo ""
    info "Documentation Fleet Roles"
    echo ""
    echo -e "  ${CYAN}doc-architect${RESET}      Documentation structure, information architecture, cross-linking"
    echo -e "  ${CYAN}claude-md${RESET}          CLAUDE.md files, agent role definitions, AUTO sections"
    echo -e "  ${CYAN}strategy-curator${RESET}   Strategic docs, plans, AGI roadmap, backlog triage"
    echo -e "  ${CYAN}pattern-writer${RESET}     Developer guides, patterns, tips, known issues"
    echo -e "  ${CYAN}readme-optimizer${RESET}   README, onboarding, install flow, command tables"
    echo ""
    echo -e "  ${DIM}Launch specific: ${CYAN}shipwright doc-fleet launch --role <name>${RESET}"
    echo -e "  ${DIM}Launch all:      ${CYAN}shipwright doc-fleet launch${RESET}"
    echo ""
}

# ─── Help ───────────────────────────────────────────────────────────────────
cmd_help() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright doc-fleet — Documentation Fleet Orchestrator     ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  5 specialized agents for documentation refactoring, cleanup, and enhancement."
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo ""
    echo -e "    ${CYAN}audit${RESET}              Run documentation health audit (no agents needed)"
    echo -e "    ${CYAN}launch${RESET}             Spawn all 5 doc fleet agents in tmux"
    echo -e "    ${CYAN}launch --autonomous${RESET} Launch agents in autonomous loop mode"
    echo -e "    ${CYAN}launch --dry-run${RESET}    Preview what would launch without spawning"
    echo -e "    ${CYAN}launch --role <r>${RESET}   Launch a specific role only"
    echo -e "    ${CYAN}status${RESET}             Show fleet agent status and recent runs"
    echo -e "    ${CYAN}retire${RESET}             Tear down all fleet sessions"
    echo -e "    ${CYAN}retire <role>${RESET}       Retire a specific agent"
    echo -e "    ${CYAN}manifest${RESET}           Generate docs-manifest.json"
    echo -e "    ${CYAN}report${RESET}             Comprehensive documentation report"
    echo -e "    ${CYAN}report --json${RESET}       Report with JSON output"
    echo -e "    ${CYAN}roles${RESET}              List available fleet roles"
    echo -e "    ${CYAN}help${RESET}               Show this help"
    echo ""
    echo -e "  ${BOLD}FLEET ROLES${RESET}"
    echo ""
    echo -e "    ${CYAN}doc-architect${RESET}      Docs structure, info architecture, cross-linking, manifest"
    echo -e "    ${CYAN}claude-md${RESET}          CLAUDE.md, agent roles, AUTO sections, dev guidelines"
    echo -e "    ${CYAN}strategy-curator${RESET}   Strategy, AGI plan, backlog, metrics, roadmap"
    echo -e "    ${CYAN}pattern-writer${RESET}     Patterns, tips, known issues, policy docs, tmux docs"
    echo -e "    ${CYAN}readme-optimizer${RESET}   README, onboarding, install, commands, public docs"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo ""
    echo -e "    ${DIM}# Quick health check${RESET}"
    echo -e "    shipwright doc-fleet audit"
    echo ""
    echo -e "    ${DIM}# Launch full fleet for comprehensive docs overhaul${RESET}"
    echo -e "    shipwright doc-fleet launch"
    echo ""
    echo -e "    ${DIM}# Launch just the README optimizer${RESET}"
    echo -e "    shipwright doc-fleet launch --role readme-optimizer"
    echo ""
    echo -e "    ${DIM}# Autonomous mode — agents run via loop harness${RESET}"
    echo -e "    shipwright doc-fleet launch --autonomous"
    echo ""
    echo -e "    ${DIM}# Check agent status and monitor${RESET}"
    echo -e "    shipwright doc-fleet status"
    echo ""
    echo -e "    ${DIM}# Generate documentation inventory manifest${RESET}"
    echo -e "    shipwright doc-fleet manifest"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        audit)       cmd_audit "$@" ;;
        launch|start|spawn)
            # Handle --role flag
            local mode="" specific_role=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dry-run)     mode="--dry-run"; shift ;;
                    --autonomous)  mode="--autonomous"; shift ;;
                    --role)        shift; specific_role="${1:-}"; shift 2>/dev/null || true ;;
                    *)             shift ;;
                esac
            done
            cmd_launch "$mode" "$specific_role"
            ;;
        status)      cmd_status "$@" ;;
        retire|stop)  cmd_retire "$@" ;;
        manifest)    cmd_manifest "$@" ;;
        report)      cmd_report "$@" ;;
        roles)       cmd_roles "$@" ;;
        help|--help|-h)  cmd_help ;;
        *)
            error "Unknown command: $cmd"
            cmd_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
