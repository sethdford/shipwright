#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright Autonomous Decision Engine                                   ║
# ║  Collects signals, scores value, enforces tiered autonomy, learns       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# shellcheck disable=SC2034
VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Dependencies ─────────────────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/policy.sh"
source "$SCRIPT_DIR/lib/decide-signals.sh"
source "$SCRIPT_DIR/lib/decide-scoring.sh"
source "$SCRIPT_DIR/lib/decide-autonomy.sh"
# Issue intake caps for auto-filed issues (ADR-0007)
source "$SCRIPT_DIR/lib/safety-gates.sh"

# ─── Config ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2034
DECISION_ENABLED=$(policy_get ".decision.enabled" "false")
DEDUP_WINDOW_DAYS=$(policy_get ".decision.dedup_window_days" "7")
# shellcheck disable=SC2034
OUTCOME_LEARNING=$(policy_get ".decision.outcome_learning_enabled" "true")
OUTCOME_MIN_SAMPLES=$(policy_get ".decision.outcome_min_samples" "10")

REPO_DIR="${_REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo '.')}"
DRAFTS_DIR="${REPO_DIR}/.claude/decision-drafts"

# ─── Help ─────────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright decide${RESET} — Autonomous Decision Engine"
    echo ""
    echo -e "${BOLD}Usage:${RESET}  shipwright decide <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${RESET}"
    echo -e "  ${CYAN}run${RESET} [--dry-run] [--once]   Run a decision cycle"
    echo -e "  ${CYAN}status${RESET}                     Show today's decisions and limits"
    echo -e "  ${CYAN}log${RESET} [--days N]             Decision history with outcomes"
    echo -e "  ${CYAN}tiers${RESET}                      Show configured autonomy tiers"
    echo -e "  ${CYAN}candidates${RESET} [--signal X]    Show current candidates without acting"
    echo -e "  ${CYAN}approve${RESET} <id>               Approve a proposed candidate"
    echo -e "  ${CYAN}reject${RESET} <id> [--reason ..]  Reject with feedback"
    echo -e "  ${CYAN}tune${RESET}                       Run outcome-based weight adjustment"
    echo -e "  ${CYAN}halt${RESET}                       Emergency halt all decisions"
    echo -e "  ${CYAN}resume${RESET}                     Resume after halt"
    echo -e "  ${CYAN}help${RESET}                       Show this help"
    echo ""
    echo -e "${BOLD}Examples:${RESET}"
    echo -e "  ${DIM}shipwright decide run --dry-run${RESET}     Preview decisions without creating issues"
    echo -e "  ${DIM}shipwright decide candidates${RESET}        See what the engine would propose"
    echo -e "  ${DIM}shipwright decide status${RESET}            Check daily limits and recent decisions"
    echo ""
}

# ─── Deduplication ────────────────────────────────────────────────────────────

_dedup_against_issues() {
    local candidates="$1"

    # Deduplicate against open GitHub issues
    local open_titles=""
    if [[ "${NO_GITHUB:-false}" != "true" ]]; then
        open_titles=$(gh issue list --label "shipwright" --state open --json title -q '.[].title' 2>/dev/null || echo "")
    fi

    # Deduplicate against recent decisions (DEDUP_WINDOW_DAYS)
    local recent_dedup_keys=""
    local window_seconds=$((DEDUP_WINDOW_DAYS * 86400))
    local cutoff=$(($(now_epoch) - window_seconds))
    for log_file in "${DECISIONS_DIR}"/daily-log-*.jsonl; do
        [[ -f "$log_file" ]] || continue
        local file_keys
        file_keys=$(jq -r 'select(.epoch // 0 >= '"$cutoff"') | .dedup_key // empty' "$log_file" 2>/dev/null || true)
        recent_dedup_keys="${recent_dedup_keys}${file_keys}"$'\n'
    done

    # Filter candidates
    echo "$candidates" | jq -c '.[]' 2>/dev/null | while IFS= read -r candidate; do
        local dedup_key title
        dedup_key=$(echo "$candidate" | jq -r '.dedup_key // ""')
        title=$(echo "$candidate" | jq -r '.title // ""')

        # Check against recent decision dedup keys
        if [[ -n "$dedup_key" ]] && echo "$recent_dedup_keys" | grep -qF "$dedup_key" 2>/dev/null; then
            continue
        fi

        # Check against open issue titles (substring match)
        local is_dup=false
        if [[ -n "$open_titles" && -n "$title" ]]; then
            while IFS= read -r existing_title; do
                [[ -z "$existing_title" ]] && continue
                if [[ "$existing_title" == *"$title"* ]] || [[ "$title" == *"$existing_title"* ]]; then
                    is_dup=true
                    break
                fi
            done <<< "$open_titles"
        fi

        [[ "$is_dup" == "true" ]] && continue
        echo "$candidate"
    done | jq -s '.'
}

# ─── Execute Decision ────────────────────────────────────────────────────────

_execute_decision() {
    local candidate="$1"
    local tier="$2"
    local dry_run="${3:-false}"

    local id title category labels
    id=$(echo "$candidate" | jq -r '.id')
    title=$(echo "$candidate" | jq -r '.title')
    category=$(echo "$candidate" | jq -r '.category')
    labels=$(autonomy_get_labels "$tier")

    local description
    description=$(echo "$candidate" | jq -r '.description // ""')
    local value_score
    value_score=$(echo "$candidate" | jq -r '.value_score // 0')
    local dedup_key
    dedup_key=$(echo "$candidate" | jq -r '.dedup_key // ""')

    local action=""
    local issue_number=""
    # Intake cap label: the tier's shipwright:* label (shipwright:auto, shipwright:proposed)
    local intake_label
    intake_label=$(printf '%s' "$labels" | tr ',' '\n' | grep -m1 '^shipwright:' || true)
    [[ -z "$intake_label" ]] && intake_label="${PATROL_LABEL:-auto-patrol}"
    local create_out="" create_rc=0

    if [[ "$dry_run" == "true" ]]; then
        case "$tier" in
            auto)    echo -e "  ${GREEN}AUTO${RESET}    [${value_score}] ${title}" ;;
            propose) echo -e "  ${YELLOW}PROPOSE${RESET} [${value_score}] ${title}" ;;
            draft)   echo -e "  ${DIM}DRAFT${RESET}   [${value_score}] ${title}" ;;
        esac
        return 0
    fi

    case "$tier" in
        auto)
            if [[ "${NO_GITHUB:-false}" != "true" ]]; then
                local body
                body="## ${title}

${description}

| Field | Value |
|-------|-------|
| Category | \`${category}\` |
| Value Score | **${value_score}** |
| Decision ID | \`${id}\` |

Auto-created by \`shipwright decide\` at $(now_iso)."

                create_out=$(patrol_issue_create --intake-label "$intake_label" \
                    --title "$title" \
                    --body "$body" \
                    --label "$labels") || create_rc=$?
                issue_number=$(printf '%s' "$create_out" | grep -oE '[0-9]+$' || true)
                if [[ "$create_rc" -eq 0 ]]; then
                    action="issue_created"
                    success "AUTO: Created issue #${issue_number} — ${title}"
                else
                    action="issue_refused"
                    warn "AUTO: not filed (intake gate refused or gh failed, rc=${create_rc}) — ${title}"
                fi
            else
                info "AUTO (local): ${title}"
                action="issue_created_local"
            fi
            ;;
        propose)
            if [[ "${NO_GITHUB:-false}" != "true" ]]; then
                local body
                body="## ${title}

${description}

| Field | Value |
|-------|-------|
| Category | \`${category}\` |
| Value Score | **${value_score}** |
| Decision ID | \`${id}\` |

> This issue was proposed by the decision engine. Add the \`ready-to-build\` label to approve.

Proposed by \`shipwright decide\` at $(now_iso)."

                create_out=$(patrol_issue_create --intake-label "$intake_label" \
                    --title "$title" \
                    --body "$body" \
                    --label "$labels") || create_rc=$?
                issue_number=$(printf '%s' "$create_out" | grep -oE '[0-9]+$' || true)
                if [[ "$create_rc" -eq 0 ]]; then
                    action="issue_proposed"
                    info "PROPOSE: Created issue #${issue_number} — ${title}"
                else
                    action="proposal_refused"
                    warn "PROPOSE: not filed (intake gate refused or gh failed, rc=${create_rc}) — ${title}"
                fi
            else
                info "PROPOSE (local): ${title}"
                action="issue_proposed_local"
            fi
            ;;
        draft)
            mkdir -p "$DRAFTS_DIR"
            local draft_file="${DRAFTS_DIR}/${id}.json"
            local tmp
            tmp=$(mktemp)
            echo "$candidate" | jq '. + {tier: "draft", drafted_at: "'"$(now_iso)"'"}' > "$tmp" && mv "$tmp" "$draft_file"
            action="draft_written"
            echo -e "  ${DIM}DRAFT: ${title} -> ${draft_file}${RESET}"
            ;;
    esac

    # Record decision
    local decision_record
    decision_record=$(jq -n \
        --arg id "$id" \
        --arg title "$title" \
        --arg category "$category" \
        --arg tier "$tier" \
        --arg action "$action" \
        --arg issue "${issue_number:-}" \
        --argjson score "$value_score" \
        --arg dedup "$dedup_key" \
        --arg ts "$(now_iso)" \
        --argjson epoch "$(now_epoch)" \
        '($action | endswith("_refused")) as $refused
         | {id:$id, title:$title, category:$category, tier:$tier, action:$action, issue_number:$issue, value_score:$score,
            dedup_key: (if $refused then "" else $dedup end), decided_at:$ts, epoch:$epoch,
            estimated_cost_usd: (if $refused then 0 elif $tier == "auto" then 5.0 elif $tier == "propose" then 0.01 else 0 end)}')

    autonomy_record_decision "$decision_record"
    emit_event "decision.executed" "id=$id" "tier=$tier" "action=$action" "score=$value_score"
}

# ─── Run Decision Cycle ──────────────────────────────────────────────────────

decide_run() {
    local dry_run=false
    local once=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --once)
                # shellcheck disable=SC2034
                once=true; shift ;;
            *)         shift ;;
        esac
    done

    echo -e "${PURPLE}${BOLD}━━━ Decision Engine ━━━${RESET}"
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo -e "  ${YELLOW}DRY RUN${RESET} — no issues will be created"
        echo ""
    fi

    # Step 1: Check halt
    if ! autonomy_check_halt; then
        local halt_reason
        halt_reason=$(jq -r '.reason // "unknown"' "$HALT_FILE" 2>/dev/null || echo "unknown")
        error "Decision engine halted: ${halt_reason}"
        echo -e "  ${DIM}Run 'shipwright decide resume' to resume${RESET}"
        return 1
    fi

    # Step 2: Rate limit
    if [[ "$dry_run" != "true" ]] && ! autonomy_check_rate_limit; then
        local last_ts
        last_ts=$(jq -r '.decided_at // "unknown"' "$LAST_DECISION_FILE" 2>/dev/null || echo "unknown")
        warn "Rate limited — last decision at ${last_ts}"
        local cooldown
        cooldown=$(echo "${TIER_LIMITS:-{}}" | jq -r '.cooldown_seconds // 300')
        echo -e "  ${DIM}Cooldown: ${cooldown}s between cycles${RESET}"
        return 0
    fi

    # Step 3: Load tiers
    if ! autonomy_load_tiers; then
        error "Cannot load tier config — run 'shipwright decide tiers' to debug"
        return 1
    fi
    scoring_load_weights

    # Step 4: Collect signals
    info "Collecting signals..."
    local candidates
    candidates=$(signals_collect_all)
    local raw_count
    raw_count=$(echo "$candidates" | jq 'length' 2>/dev/null || echo "0")
    info "Found ${raw_count} raw candidate(s)"

    if [[ "${raw_count:-0}" -eq 0 ]]; then
        success "No candidates — nothing to decide"
        emit_event "decision.cycle_complete" "candidates=0" "decisions=0"
        return 0
    fi

    # Step 5: Deduplicate
    info "Deduplicating..."
    local unique_candidates
    unique_candidates=$(_dedup_against_issues "$candidates")
    local unique_count
    unique_count=$(echo "$unique_candidates" | jq 'length' 2>/dev/null || echo "0")
    info "${unique_count} candidate(s) after dedup"

    if [[ "${unique_count:-0}" -eq 0 ]]; then
        success "All candidates already tracked — nothing new"
        emit_event "decision.cycle_complete" "candidates=0" "decisions=0"
        return 0
    fi

    # Step 6: Score and sort
    info "Scoring candidates..."
    local scored_candidates="[]"
    while IFS= read -r candidate; do
        local scored
        scored=$(score_candidate "$candidate")
        scored_candidates=$(echo "$scored_candidates" | jq --argjson c "$scored" '. + [$c]')
    done < <(echo "$unique_candidates" | jq -c '.[]' 2>/dev/null)

    # Sort by value_score descending
    scored_candidates=$(echo "$scored_candidates" | jq 'sort_by(-.value_score)')

    # Step 7: Execute decisions
    local decisions_made=0
    echo ""
    echo -e "${BOLD}Decisions:${RESET}"

    while IFS= read -r candidate; do
        local category risk_score
        category=$(echo "$candidate" | jq -r '.category // "unknown"')
        risk_score=$(echo "$candidate" | jq -r '.risk_score // 50')

        # Resolve tier
        local tier
        tier=$(autonomy_resolve_tier "$category")

        # Check risk ceiling
        if ! autonomy_check_risk_ceiling "$category" "$risk_score"; then
            local ceiling
            ceiling=$(echo "$CATEGORY_RULES" | jq -r --arg cat "$category" '.[$cat].risk_ceiling // 100')
            echo -e "  ${DIM}SKIP (risk ${risk_score} > ceiling ${ceiling}): $(echo "$candidate" | jq -r '.title')${RESET}"
            continue
        fi

        # Check budget
        if [[ "$dry_run" != "true" ]] && ! autonomy_check_budget "$tier"; then
            warn "Budget exhausted — stopping"
            break
        fi

        # Execute
        _execute_decision "$candidate" "$tier" "$dry_run"
        decisions_made=$((decisions_made + 1))

    done < <(echo "$scored_candidates" | jq -c '.[]' 2>/dev/null)

    # Step 8: Check consecutive failures
    if [[ "$dry_run" != "true" ]]; then
        autonomy_check_consecutive_failures || true
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Cycle Complete ━━━${RESET}"
    echo -e "  Candidates: ${raw_count} raw, ${unique_count} unique"
    echo -e "  Decisions:  ${decisions_made}"
    if [[ "$dry_run" == "true" ]]; then
        echo -e "  ${DIM}(dry run — no changes made)${RESET}"
    fi
    echo ""

    emit_event "decision.cycle_complete" "candidates=${unique_count}" "decisions=${decisions_made}" "dry_run=$dry_run"

    # Clear pending signals after successful cycle
    if [[ "$dry_run" != "true" ]]; then
        signals_clear_pending
    fi
}

# ─── Status ───────────────────────────────────────────────────────────────────

decide_status() {
    echo -e "${CYAN}${BOLD}Decision Engine Status${RESET}"
    echo ""

    # Halt state
    if [[ -f "$HALT_FILE" ]]; then
        local reason
        reason=$(jq -r '.reason // "unknown"' "$HALT_FILE" 2>/dev/null || echo "unknown")
        local halted_at
        halted_at=$(jq -r '.halted_at // "unknown"' "$HALT_FILE" 2>/dev/null || echo "unknown")
        echo -e "  ${RED}${BOLD}HALTED${RESET}: ${reason}"
        echo -e "  ${DIM}Since: ${halted_at}${RESET}"
    else
        echo -e "  Status: ${GREEN}active${RESET}"
    fi

    # Load tiers for limits
    autonomy_load_tiers 2>/dev/null || true

    echo ""
    local summary
    summary=$(autonomy_daily_summary)
    local total auto propose draft remaining_issues
    total=$(echo "$summary" | jq '.total // 0')
    auto=$(echo "$summary" | jq '.auto // 0')
    propose=$(echo "$summary" | jq '.propose // 0')
    draft=$(echo "$summary" | jq '.draft // 0')
    remaining_issues=$(echo "$summary" | jq '.budget_remaining.issues // 15')

    echo -e "  ${BOLD}Today's Decisions:${RESET}"
    echo -e "    Total:    ${total}"
    echo -e "    Auto:     ${auto}"
    echo -e "    Proposed: ${propose}"
    echo -e "    Drafted:  ${draft}"
    echo ""
    echo -e "  ${BOLD}Budget Remaining:${RESET}"
    echo -e "    Issues: ${remaining_issues}"
    echo ""

    # Weights
    scoring_load_weights
    echo -e "  ${BOLD}Scoring Weights:${RESET}"
    echo -e "    Impact:     ${_W_IMPACT}"
    echo -e "    Urgency:    ${_W_URGENCY}"
    echo -e "    Effort:     ${_W_EFFORT}"
    echo -e "    Confidence: ${_W_CONFIDENCE}"
    echo -e "    Risk:       ${_W_RISK}"
    echo ""
}

# ─── Log ──────────────────────────────────────────────────────────────────────

decide_log() {
    local days=7
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            *)      shift ;;
        esac
    done

    echo -e "${CYAN}${BOLD}Decision Log (last ${days} days)${RESET}"
    echo ""

    local found=false
    for i in $(seq 0 $((days - 1))); do
        local date_str
        # shellcheck disable=SC2106
        date_str=$(date -u -v-${i}d +%Y-%m-%d 2>/dev/null || date -u -d "${i} days ago" +%Y-%m-%d 2>/dev/null || continue)
        local log_file="${DECISIONS_DIR}/daily-log-${date_str}.jsonl"
        [[ ! -f "$log_file" ]] && continue

        found=true
        echo -e "  ${BOLD}${date_str}${RESET}"
        while IFS= read -r entry; do
            local tier action title score outcome
            tier=$(echo "$entry" | jq -r '.tier // "?"')
            action=$(echo "$entry" | jq -r '.action // "?"')
            title=$(echo "$entry" | jq -r '.title // "?"')
            score=$(echo "$entry" | jq -r '.value_score // "?"')
            outcome=$(echo "$entry" | jq -r '.outcome // "-"')

            local tier_color="${DIM}"
            case "$tier" in
                auto) tier_color="${GREEN}" ;;
                propose) tier_color="${YELLOW}" ;;
            esac

            echo -e "    ${tier_color}${tier}${RESET} [${score}] ${title} ${DIM}(${outcome})${RESET}"
        done < "$log_file"
        echo ""
    done

    if [[ "$found" == "false" ]]; then
        echo -e "  ${DIM}No decisions in the last ${days} days${RESET}"
    fi
}

# ─── Tiers ────────────────────────────────────────────────────────────────────

decide_tiers() {
    echo -e "${CYAN}${BOLD}Autonomy Tiers${RESET}"
    echo ""

    if ! autonomy_load_tiers; then
        error "Cannot load tiers config"
        echo -e "  ${DIM}Expected at: config/decision-tiers.json${RESET}"
        return 1
    fi

    # Display tier definitions
    for tier in auto propose draft; do
        local desc labels
        desc=$(echo "$TIERS_DATA" | jq -r --arg t "$tier" '.tiers[$t].description // "N/A"')
        labels=$(echo "$TIERS_DATA" | jq -r --arg t "$tier" '.tiers[$t].labels // [] | join(", ")')
        local color="${DIM}"
        case "$tier" in
            auto) color="${GREEN}" ;;
            propose) color="${YELLOW}" ;;
            draft) color="${DIM}" ;;
        esac
        echo -e "  ${color}${BOLD}${tier}${RESET}: ${desc}"
        [[ -n "$labels" ]] && echo -e "    ${DIM}Labels: ${labels}${RESET}"
    done
    echo ""

    # Display category rules
    echo -e "  ${BOLD}Category Rules:${RESET}"
    echo "$CATEGORY_RULES" | jq -r 'to_entries[] | "    \(.key): tier=\(.value.tier), ceiling=\(.value.risk_ceiling)"' 2>/dev/null
    echo ""

    # Display limits
    echo -e "  ${BOLD}Limits:${RESET}"
    echo "$TIER_LIMITS" | jq -r 'to_entries[] | "    \(.key): \(.value)"' 2>/dev/null
    echo ""
}

# ─── Candidates ───────────────────────────────────────────────────────────────

decide_candidates() {
    local signal_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --signal) signal_filter="$2"; shift 2 ;;
            *)        shift ;;
        esac
    done

    echo -e "${CYAN}${BOLD}Current Candidates${RESET}"
    echo ""

    if ! autonomy_load_tiers; then
        error "Cannot load tiers config"
        return 1
    fi
    scoring_load_weights

    info "Collecting signals..."
    local candidates
    candidates=$(signals_collect_all)

    if [[ -n "$signal_filter" ]]; then
        candidates=$(echo "$candidates" | jq --arg s "$signal_filter" '[.[] | select(.signal == $s)]')
    fi

    local count
    count=$(echo "$candidates" | jq 'length' 2>/dev/null || echo "0")
    info "Found ${count} candidate(s)"

    if [[ "${count:-0}" -eq 0 ]]; then
        echo -e "  ${DIM}No candidates found${RESET}"
        return 0
    fi

    echo ""
    while IFS= read -r candidate; do
        local scored
        scored=$(score_candidate "$candidate")
        local title signal category score tier
        title=$(echo "$scored" | jq -r '.title')
        signal=$(echo "$scored" | jq -r '.signal')
        category=$(echo "$scored" | jq -r '.category')
        score=$(echo "$scored" | jq -r '.value_score')
        tier=$(autonomy_resolve_tier "$category")

        local color="${DIM}"
        case "$tier" in
            auto) color="${GREEN}" ;;
            propose) color="${YELLOW}" ;;
        esac

        echo -e "  ${color}${tier}${RESET} [${score}] ${title} ${DIM}(${signal}/${category})${RESET}"
    done < <(echo "$candidates" | jq -c '.[]' 2>/dev/null)
    echo ""
}

# ─── Approve / Reject ────────────────────────────────────────────────────────

decide_approve() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        error "Usage: shipwright decide approve <decision-id>"
        return 1
    fi

    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        error "Cannot approve in local mode (NO_GITHUB=true)"
        return 1
    fi

    # Find the issue number for this decision
    local daily_log
    daily_log=$(_daily_log_file)
    if [[ ! -f "$daily_log" ]]; then
        error "No decisions today — check 'shipwright decide log'"
        return 1
    fi

    local issue_number
    issue_number=$(jq -r --arg id "$id" 'select(.id == $id) | .issue_number // empty' "$daily_log" 2>/dev/null | head -1)
    if [[ -z "$issue_number" ]]; then
        error "Decision '${id}' not found in today's log"
        return 1
    fi

    gh issue edit "$issue_number" --add-label "ready-to-build" 2>/dev/null || {
        error "Failed to add ready-to-build label to issue #${issue_number}"
        return 1
    }
    success "Approved: issue #${issue_number} now has ready-to-build label"
    autonomy_record_outcome "$id" "approved"
    emit_event "decision.approved" "id=$id" "issue=$issue_number"
}

decide_reject() {
    local id="${1:-}"
    local reason=""
    shift 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason) reason="$2"; shift 2 ;;
            *)        shift ;;
        esac
    done

    if [[ -z "$id" ]]; then
        error "Usage: shipwright decide reject <decision-id> [--reason \"...\"]"
        return 1
    fi

    autonomy_record_outcome "$id" "rejected" "$reason"
    success "Rejected: ${id}${reason:+ — $reason}"
    emit_event "decision.rejected" "id=$id" "reason=$reason"
}

# ─── Tune ─────────────────────────────────────────────────────────────────────

decide_tune() {
    echo -e "${CYAN}${BOLD}Outcome-Based Weight Tuning${RESET}"
    echo ""

    if [[ ! -f "${OUTCOMES_FILE}" ]]; then
        warn "No outcomes recorded yet — need at least ${OUTCOME_MIN_SAMPLES} samples"
        return 0
    fi

    local sample_count
    sample_count=$(wc -l < "$OUTCOMES_FILE" 2>/dev/null | tr -d ' ')
    info "Outcomes: ${sample_count}"

    if [[ "$sample_count" -lt "$OUTCOME_MIN_SAMPLES" ]]; then
        warn "Need ${OUTCOME_MIN_SAMPLES} samples, have ${sample_count} — skipping"
        return 0
    fi

    scoring_load_weights
    echo -e "  ${BOLD}Before:${RESET} impact=${_W_IMPACT} urgency=${_W_URGENCY} effort=${_W_EFFORT} conf=${_W_CONFIDENCE} risk=${_W_RISK}"

    # Process recent outcomes
    local processed=0
    while IFS= read -r outcome; do
        scoring_update_weights "$outcome"
        processed=$((processed + 1))
    done < <(tail -20 "$OUTCOMES_FILE")

    echo -e "  ${BOLD}After:${RESET}  impact=${_W_IMPACT} urgency=${_W_URGENCY} effort=${_W_EFFORT} conf=${_W_CONFIDENCE} risk=${_W_RISK}"
    echo -e "  ${DIM}Processed ${processed} outcome(s)${RESET}"

    emit_event "decision.tuned" "samples=$processed"
    success "Weights updated"
}

# ─── Command Router ──────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        run)        decide_run "$@" ;;
        status)     decide_status ;;
        log)        decide_log "$@" ;;
        tiers)      decide_tiers ;;
        candidates) decide_candidates "$@" ;;
        approve)    decide_approve "$@" ;;
        reject)     decide_reject "$@" ;;
        tune)       decide_tune ;;
        halt)       autonomy_halt "${1:-manual halt}"; success "Decision engine halted" ;;
        resume)     autonomy_resume; success "Decision engine resumed" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: ${cmd}"
            show_help
            exit 1
            ;;
    esac
}

# Run only when executed, so tests can source the functions
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
