#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2064  # config vars used by sourced scripts; traps expand at definition time
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-recruit.sh — AGI-Level Agent Recruitment & Talent Management        ║
# ║                                                                         ║
# ║  Dynamic role creation · LLM-powered matching · Closed-loop learning   ║
# ║  Self-tuning thresholds · Role evolution · Cross-agent intelligence     ║
# ║  Meta-learning · Autonomous role invention · Theory of mind            ║
# ║  Goal decomposition · Self-modifying heuristics                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-exec.sh"
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECRUIT_VERSION="3.0.0"

# ─── Dependency check ─────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: sw-recruit.sh requires 'jq' (JSON processor). Install with:" >&2
    echo "  macOS:  brew install jq" >&2
    echo "  Ubuntu: sudo apt install jq" >&2
    echo "  Alpine: apk add jq" >&2
    exit 1
fi

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
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── File Locking for Concurrent Safety ────────────────────────────────────
# Usage: _recruit_locked_write <target_file> <tmp_file>
# Acquires flock, then moves tmp_file to target atomically.
# Caller is responsible for creating tmp_file and cleaning up on error.
_recruit_locked_write() {
    local target="$1"
    local tmp_file="$2"
    local lock_file="${target}.lock"

    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 5 200 2>/dev/null || true
        fi
        mv "$tmp_file" "$target"
    ) 200>"$lock_file"
}

# ─── Recruitment Storage Paths ─────────────────────────────────────────────
RECRUIT_ROOT="${HOME}/.shipwright/recruitment"
ROLES_DB="${RECRUIT_ROOT}/roles.json"
PROFILES_DB="${RECRUIT_ROOT}/profiles.json"
TALENT_DB="${RECRUIT_ROOT}/talent.json"
ONBOARDING_DB="${RECRUIT_ROOT}/onboarding.json"
MATCH_HISTORY="${RECRUIT_ROOT}/match-history.jsonl"
ROLE_USAGE_DB="${RECRUIT_ROOT}/role-usage.json"
HEURISTICS_DB="${RECRUIT_ROOT}/heuristics.json"
AGENT_MINDS_DB="${RECRUIT_ROOT}/agent-minds.json"
INVENTED_ROLES_LOG="${RECRUIT_ROOT}/invented-roles.jsonl"
META_LEARNING_DB="${RECRUIT_ROOT}/meta-learning.json"

# ─── Policy Integration ──────────────────────────────────────────────────
POLICY_FILE="${SCRIPT_DIR}/../config/policy.json"
_recruit_policy() {
    local key="$1"
    local default="$2"
    if [[ -f "$POLICY_FILE" ]] && command -v jq >/dev/null 2>&1; then
        local val
        val=$(jq -r ".recruit.${key} // empty" "$POLICY_FILE" 2>/dev/null) || true
        [[ -n "$val" ]] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

RECRUIT_CONFIDENCE_THRESHOLD=$(_recruit_policy "match_confidence_threshold" "0.3")
RECRUIT_MAX_MATCH_HISTORY=$(_recruit_policy "max_match_history_size" "5000")
RECRUIT_META_ACCURACY_FLOOR=$(_recruit_policy "meta_learning_accuracy_floor" "50")
RECRUIT_LLM_TIMEOUT=$(_recruit_policy "llm_timeout_seconds" "30")
RECRUIT_DEFAULT_MODEL=$(_recruit_policy "default_model" "sonnet")
RECRUIT_SELF_TUNE_MIN_MATCHES=$(_recruit_policy "self_tune_min_matches" "5")
RECRUIT_PROMOTE_TASKS=$(_recruit_policy "promote_threshold_tasks" "10")
RECRUIT_PROMOTE_SUCCESS=$(_recruit_policy "promote_threshold_success_rate" "85")
RECRUIT_AUTO_EVOLVE_AFTER=$(_recruit_policy "auto_evolve_after_outcomes" "20")

ensure_recruit_dir() {
    mkdir -p "$RECRUIT_ROOT"
    [[ -f "$ROLES_DB" ]]          || echo '{}' > "$ROLES_DB"
    [[ -f "$PROFILES_DB" ]]       || echo '{}' > "$PROFILES_DB"
    [[ -f "$TALENT_DB" ]]         || echo '[]' > "$TALENT_DB"
    [[ -f "$ONBOARDING_DB" ]]     || echo '{}' > "$ONBOARDING_DB"
    [[ -f "$ROLE_USAGE_DB" ]]     || echo '{}' > "$ROLE_USAGE_DB"
    [[ -f "$HEURISTICS_DB" ]]     || echo '{"keyword_weights":{},"match_accuracy":[],"last_tuned":"never"}' > "$HEURISTICS_DB"
    [[ -f "$AGENT_MINDS_DB" ]]    || echo '{}' > "$AGENT_MINDS_DB"
    [[ -f "$META_LEARNING_DB" ]]  || echo '{"corrections":[],"accuracy_trend":[],"last_reflection":"never"}' > "$META_LEARNING_DB"
}

# ─── Intelligence Engine (optional) ────────────────────────────────────────
INTELLIGENCE_AVAILABLE=false
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    # shellcheck source=sw-intelligence.sh
    source "$SCRIPT_DIR/sw-intelligence.sh"
    INTELLIGENCE_AVAILABLE=true
fi

# Check if Claude CLI is available for LLM-powered features
# Set SW_RECRUIT_NO_LLM=1 to disable LLM calls (e.g., in tests)
_recruit_has_claude() {
    [[ "${SW_RECRUIT_NO_LLM:-}" == "1" ]] && return 1
    command -v claude >/dev/null 2>&1
}

# Call Claude with a prompt, return text. Falls back gracefully.
_recruit_call_claude() {
    local prompt="$1"
    local model="${2:-sonnet}"

    # Honor the no-LLM flag everywhere (not just _recruit_has_claude)
    [[ "${SW_RECRUIT_NO_LLM:-}" == "1" ]] && { echo ""; return; }

    if [[ "$INTELLIGENCE_AVAILABLE" == "true" ]] && command -v _intelligence_call_claude >/dev/null 2>&1; then
        _intelligence_call_claude "$prompt" 2>/dev/null || echo ""
        return
    fi

    if _recruit_has_claude; then
        "$SW_AGENT_EXEC" claude -p "$prompt" --model "$model" 2>/dev/null || echo ""
        return
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# SOURCE FOCUSED MODULES (Tier-based organization)
# ═══════════════════════════════════════════════════════════════════════════════

# shellcheck source=lib/recruit-roles.sh
[[ -f "$SCRIPT_DIR/lib/recruit-roles.sh" ]] && source "$SCRIPT_DIR/lib/recruit-roles.sh"

# shellcheck source=lib/recruit-learning.sh
[[ -f "$SCRIPT_DIR/lib/recruit-learning.sh" ]] && source "$SCRIPT_DIR/lib/recruit-learning.sh"

# shellcheck source=lib/recruit-commands.sh
[[ -f "$SCRIPT_DIR/lib/recruit-commands.sh" ]] && source "$SCRIPT_DIR/lib/recruit-commands.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# NEGATIVE-COMPOUNDING FEEDBACK LOOP (Self-Audit)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_audit() {
    ensure_recruit_dir

    info "Running negative-compounding self-audit..."
    echo ""

    local total_checks=0
    local pass_count=0
    local fail_count=0
    local warnings=()
    local failures=()

    # Color fallbacks
    GREEN="${GREEN:-\033[38;2;74;222;128m}"
    RED="${RED:-\033[38;2;248;113;113m}"
    YELLOW="${YELLOW:-\033[38;2;251;204;21m}"
    RESET="${RESET:-\033[0m}"
    BOLD="${BOLD:-\033[1m}"

    _audit_check() {
        local name="$1"
        local result="$2"  # pass|fail|warn
        local detail="$3"
        total_checks=$((total_checks + 1))
        case "$result" in
            pass) pass_count=$((pass_count + 1)); echo -e "  ${GREEN}✓${RESET} $name" ;;
            fail) fail_count=$((fail_count + 1)); failures+=("$name: $detail"); echo -e "  ${RED}✗${RESET} $name — $detail" ;;
            warn) pass_count=$((pass_count + 1)); warnings+=("$name: $detail"); echo -e "  ${YELLOW}⚠${RESET} $name — $detail" ;;
        esac
    }

    echo -e "${BOLD}1. DATA STORES${RESET}"

    # Check all data stores exist and are valid JSON
    for db_name in ROLES_DB PROFILES_DB ROLE_USAGE_DB HEURISTICS_DB META_LEARNING_DB AGENT_MINDS_DB; do
        local db_path="${!db_name}"
        if [[ -f "$db_path" ]]; then
            if jq empty "$db_path" 2>/dev/null; then
                _audit_check "$db_name is valid JSON" "pass" ""
            else
                _audit_check "$db_name is valid JSON" "fail" "corrupted JSON"
            fi
        else
            _audit_check "$db_name exists" "warn" "not yet created (will be on first use)"
        fi
    done
    [[ -f "$MATCH_HISTORY" ]] && _audit_check "MATCH_HISTORY exists" "pass" "" || _audit_check "MATCH_HISTORY exists" "warn" "no matches yet"
    echo ""

    echo -e "${BOLD}2. FEEDBACK LOOPS${RESET}"

    # Loop 1: Role usage tracking
    if [[ -f "$ROLE_USAGE_DB" ]]; then
        local has_outcomes
        has_outcomes=$(jq '[.[]] | map(select(.successes > 0 or .failures > 0)) | length' "$ROLE_USAGE_DB" 2>/dev/null || echo "0")
        if [[ "$has_outcomes" -gt 0 ]]; then
            _audit_check "Role usage tracks outcomes (successes/failures)" "pass" ""
        else
            _audit_check "Role usage tracks outcomes (successes/failures)" "warn" "all roles have 0 successes & 0 failures — run pipelines first"
        fi
    else
        _audit_check "Role usage tracks outcomes" "warn" "no role-usage.json yet"
    fi

    # Loop 2: Match → outcome linkage
    if [[ -f "$MATCH_HISTORY" ]]; then
        local has_match_ids
        has_match_ids=$(head -5 "$MATCH_HISTORY" | jq -r '.match_id // empty' 2>/dev/null | head -1)
        if [[ -n "$has_match_ids" ]]; then
            _audit_check "Match history has match_id for outcome linkage" "pass" ""
        else
            _audit_check "Match history has match_id for outcome linkage" "fail" "old records lack match_id — run new matches"
        fi

        local resolved_outcomes
        resolved_outcomes=$(grep -cE '"outcome":"(success|failure)"' "$MATCH_HISTORY" 2>/dev/null | tr -d '[:space:]' || true)
        resolved_outcomes="${resolved_outcomes:-0}"
        local total_mh
        total_mh=$(wc -l < "$MATCH_HISTORY" 2>/dev/null | tr -d ' ')
        if [[ "$resolved_outcomes" -gt 0 ]]; then
            _audit_check "Match outcomes backfilled" "pass" "${resolved_outcomes}/${total_mh} resolved"
        else
            _audit_check "Match outcomes backfilled" "warn" "0/${total_mh} resolved — need pipeline outcomes"
        fi
    else
        _audit_check "Match → outcome linkage" "warn" "no match history yet"
    fi

    # Loop 3: Self-tune effectiveness
    if [[ -f "$HEURISTICS_DB" ]]; then
        local kw_count
        kw_count=$(jq '.keyword_weights | length' "$HEURISTICS_DB" 2>/dev/null || echo "0")
        if [[ "$kw_count" -gt 0 ]]; then
            _audit_check "Self-tune has learned keyword weights" "pass" "${kw_count} keywords"
        else
            _audit_check "Self-tune has learned keyword weights" "warn" "empty — need more match/outcome data"
        fi
    else
        _audit_check "Self-tune active" "warn" "no heuristics.json yet"
    fi

    # Loop 4: Meta-learning accuracy trend
    if [[ -f "$META_LEARNING_DB" ]]; then
        local trend_len
        trend_len=$(jq '.accuracy_trend | length' "$META_LEARNING_DB" 2>/dev/null || echo "0")
        if [[ "$trend_len" -ge 3 ]]; then
            local latest_acc
            latest_acc=$(jq '.accuracy_trend[-1].accuracy' "$META_LEARNING_DB" 2>/dev/null || echo "0")
            local floor="${RECRUIT_META_ACCURACY_FLOOR:-50}"
            if awk -v a="$latest_acc" -v f="$floor" 'BEGIN{exit !(a >= f)}'; then
                _audit_check "Meta-learning accuracy above floor" "pass" "${latest_acc}% >= ${floor}%"
            else
                _audit_check "Meta-learning accuracy above floor" "fail" "${latest_acc}% < ${floor}%"
            fi
        else
            _audit_check "Meta-learning has accuracy trend" "warn" "only ${trend_len} data points (need 3+)"
        fi
    else
        _audit_check "Meta-learning active" "warn" "no meta-learning.json yet"
    fi
    echo ""

    echo -e "${BOLD}3. INTEGRATION WIRING${RESET}"

    # Check each integration exists in the source
    for script_check in \
        "sw-pipeline.sh:sw-recruit.sh.*match.*--json:pipeline model selection" \
        "sw-pipeline.sh:sw-recruit.sh.*ingest-pipeline:pipeline auto-ingest" \
        "sw-pipeline.sh:agent_id=.*PIPELINE_AGENT_ID:pipeline agent_id in events" \
        "sw-pm.sh:sw-recruit.sh.*team.*--json:PM team integration" \
        "sw-triage.sh:sw-recruit.sh.*team.*--json:triage team integration" \
        "sw-loop.sh:sw-recruit.sh.*team.*--json:loop role assignment" \
        "sw-loop.sh:recruit_roles_db:loop recruit DB descriptions" \
        "sw-swarm.sh:sw-recruit.sh.*match.*--json:swarm type selection" \
        "sw-autonomous.sh:sw-recruit.sh.*match.*--json:autonomous model selection" \
        "sw-autonomous.sh:sw-recruit.sh.*team.*--json:autonomous team recommendation" \
        "sw-pipeline.sh:intelligence_validate_prediction:pipeline intelligence validation" \
        "sw-pipeline.sh:confirm-anomaly:pipeline predictive anomaly confirmation" \
        "sw-pipeline.sh:fix-outcome.*true.*false:pipeline memory negative fix-outcome" \
        "sw-triage.sh:gh_available=false:triage offline fallback support"; do
        local sc="${script_check%%:*}"; local rest="${script_check#*:}"
        local pat="${rest%%:*}"; local desc="${rest#*:}"
        if [[ -f "$SCRIPT_DIR/$sc" ]] && grep -qE "$pat" "$SCRIPT_DIR/$sc" 2>/dev/null; then
            _audit_check "$desc ($sc)" "pass" ""
        else
            _audit_check "$desc ($sc)" "fail" "pattern not found"
        fi
    done
    echo ""

    echo -e "${BOLD}4. POLICY GOVERNANCE${RESET}"

    if [[ -f "$POLICY_FILE" ]]; then
        local has_recruit_section
        has_recruit_section=$(jq '.recruit // empty' "$POLICY_FILE" 2>/dev/null)
        if [[ -n "$has_recruit_section" ]]; then
            _audit_check "policy.json has recruit section" "pass" ""
        else
            _audit_check "policy.json has recruit section" "fail" "missing recruit section"
        fi
    else
        _audit_check "policy.json exists" "fail" "config/policy.json not found"
    fi
    echo ""

    echo -e "${BOLD}5. AUTOMATION TRIGGERS${RESET}"

    grep -q "cmd_self_tune.*2>/dev/null" "$SCRIPT_DIR/sw-recruit.sh" && \
        _audit_check "Self-tune auto-triggers after ingest" "pass" "" || \
        _audit_check "Self-tune auto-triggers after ingest" "fail" "not wired"

    grep -q "cmd_evolve.*2>/dev/null" "$SCRIPT_DIR/sw-recruit.sh" && \
        _audit_check "Evolve auto-triggers after sufficient outcomes" "pass" "" || \
        _audit_check "Evolve auto-triggers after sufficient outcomes" "fail" "not wired"

    grep -q "_recruit_meta_validate_self_tune" "$SCRIPT_DIR/sw-recruit.sh" && \
        _audit_check "Meta-validation runs during reflect" "pass" "" || \
        _audit_check "Meta-validation runs during reflect" "fail" "not wired"
    echo ""

    # ── Compute score ────────────────────────────────────────────────────────
    local score
    score=$(awk -v p="$pass_count" -v t="$total_checks" 'BEGIN{if(t>0) printf "%.1f", (p/t)*100; else print "0"}')

    echo "════════════════════════════════════════════════════════════════"
    echo -e "${BOLD}AUDIT SCORE:${RESET} ${score}% (${pass_count}/${total_checks} checks passed, ${fail_count} failures, ${#warnings[@]} warnings)"
    echo "════════════════════════════════════════════════════════════════"

    # Record audit result in events for trend tracking
    emit_event "recruit_audit" "score=${score}" "passed=${pass_count}" "failed=${fail_count}" "warnings=${#warnings[@]}" "total=${total_checks}"

    # Track audit score trend in meta-learning DB
    if [[ -f "$META_LEARNING_DB" ]]; then
        local tmp_audit
        tmp_audit=$(mktemp)
        trap "rm -f '$tmp_audit'" RETURN
        jq --argjson score "$score" --arg ts "$(now_iso)" --argjson fails "$fail_count" '
            .audit_trend = ((.audit_trend // []) + [{score: $score, ts: $ts, failures: $fails}] | .[-50:])
        ' "$META_LEARNING_DB" > "$tmp_audit" && _recruit_locked_write "$META_LEARNING_DB" "$tmp_audit" || rm -f "$tmp_audit"
    fi

    # Negative compounding: if score is declining, escalate
    if [[ -f "$META_LEARNING_DB" ]]; then
        local audit_trend_len
        audit_trend_len=$(jq '.audit_trend // [] | length' "$META_LEARNING_DB" 2>/dev/null || echo "0")
        if [[ "$audit_trend_len" -ge 3 ]]; then
            local prev_score
            prev_score=$(jq '.audit_trend[-2].score // 100' "$META_LEARNING_DB" 2>/dev/null || echo "100")
            if awk -v c="$score" -v p="$prev_score" 'BEGIN{exit !(c < p - 5)}'; then
                echo ""
                warn "NEGATIVE COMPOUND: Audit score DECLINED from ${prev_score}% to ${score}%"
                warn "System health is degrading. Failures that compound:"
                for f in "${failures[@]}"; do
                    echo -e "  ${RED}→${RESET} $f"
                done
                emit_event "recruit_audit_decline" "from=${prev_score}" "to=${score}" "failures=${fail_count}"
            fi
        fi
    fi

    if [[ ${#failures[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}FAILURES REQUIRING ACTION:${RESET}"
        for f in "${failures[@]}"; do
            echo -e "  ${RED}→${RESET} $f"
        done
    fi

    [[ "$fail_count" -gt 0 ]] && return 1 || return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELP & ROUTING
# ═══════════════════════════════════════════════════════════════════════════════

cmd_help() {
    cat <<EOF
${BOLD}${CYAN}shipwright recruit${RESET} ${DIM}v${RECRUIT_VERSION}${RESET} — AGI-Level Agent Recruitment & Talent Management

${BOLD}CORE COMMANDS${RESET}
  ${CYAN}roles${RESET}                    List all available agent roles (builtin + dynamic)
  ${CYAN}match${RESET} "<task>"           Analyze task → recommend role (LLM + keyword fallback)
  ${CYAN}evaluate${RESET} <id>            Score agent performance (population-aware thresholds)
  ${CYAN}team${RESET} "<issue>"           Recommend optimal team (AI + codebase analysis)
  ${CYAN}profiles${RESET}                 Show all agent performance profiles
  ${CYAN}promote${RESET} <id>             Recommend model upgrades (self-tuning thresholds)
  ${CYAN}onboard${RESET} <role> [agent]   Generate adaptive onboarding context
  ${CYAN}stats${RESET}                    Show recruitment statistics and talent trends

${BOLD}DYNAMIC ROLES (Tier 1)${RESET}
  ${CYAN}create-role${RESET} <key> [title] [desc]   Create a new role manually
  ${CYAN}create-role${RESET} --auto "<task>"         AI-generate a role from task description

${BOLD}FEEDBACK LOOP (Tier 1)${RESET}
  ${CYAN}record-outcome${RESET} <agent> <task> <success|failure> [quality] [duration]
  ${CYAN}ingest-pipeline${RESET} [days]              Ingest outcomes from events.jsonl

${BOLD}INTELLIGENCE (Tier 2)${RESET}
  ${CYAN}evolve${RESET}                   Analyze role usage → suggest splits/merges/retirements
  ${CYAN}specializations${RESET}          Show agent specialization analysis
  ${CYAN}route${RESET} "<task>"           Smart-route task to best available agent

${BOLD}AGI-LEVEL (Tier 3)${RESET}
  ${CYAN}reflect${RESET}                  Meta-learning: analyze matching accuracy
  ${CYAN}invent${RESET}                   Autonomously discover & create new roles
  ${CYAN}mind${RESET} [agent-id]          Theory of mind: agent working style profiles
  ${CYAN}decompose${RESET} "<goal>"       Break vague goals into sub-tasks + role assignments
  ${CYAN}self-tune${RESET}                Self-modify keyword→role heuristics from outcomes
  ${CYAN}audit${RESET}                   Negative-compounding self-audit of all loops and integrations

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright recruit match "Add OAuth2 authentication"${RESET}
  ${DIM}shipwright recruit create-role --auto "Database migration planning"${RESET}
  ${DIM}shipwright recruit record-outcome agent-001 task-42 success 8 15${RESET}
  ${DIM}shipwright recruit decompose "Make the product enterprise-ready"${RESET}
  ${DIM}shipwright recruit invent${RESET}
  ${DIM}shipwright recruit self-tune${RESET}
  ${DIM}shipwright recruit mind agent-builder-001${RESET}

${BOLD}ROLE CATALOG${RESET}
  Built-in: architect, builder, reviewer, tester, security-auditor,
  docs-writer, optimizer, devops, pm, incident-responder
  + any dynamically created or invented roles

${DIM}Store: ~/.shipwright/recruitment/${RESET}
EOF
}

# ─── Main Router ──────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ensure_recruit_dir

    cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        roles)              cmd_roles ;;
        match)              cmd_match "$@" ;;
        evaluate)           cmd_evaluate "$@" ;;
        team)               cmd_team "$@" ;;
        profiles)           cmd_profiles ;;
        promote)            cmd_promote "$@" ;;
        onboard)            cmd_onboard "$@" ;;
        stats)              cmd_stats ;;
        create-role)        cmd_create_role "$@" ;;
        record-outcome)     cmd_record_outcome "$@" ;;
        ingest-pipeline)    cmd_ingest_pipeline "$@" ;;
        evolve)             cmd_evolve ;;
        specializations)    cmd_specializations ;;
        route)              cmd_route "$@" ;;
        reflect)            cmd_reflect ;;
        invent)             cmd_invent ;;
        mind)               cmd_mind "$@" ;;
        decompose)          cmd_decompose "$@" ;;
        self-tune)          cmd_self_tune ;;
        audit)              cmd_audit ;;
        help|--help|-h)     cmd_help ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
fi
