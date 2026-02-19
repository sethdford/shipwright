#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright oversight — Quality Oversight Board                          ║
# ║  Multi-agent review council · Voting system · Architecture governance    ║
# ║  Security review · Performance review · Verdict aggregation              ║
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
# ─── Structured Event Log ────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── State & Configuration ────────────────────────────────────────────────
OVERSIGHT_ROOT="${HOME}/.shipwright/oversight"
BOARD_CONFIG="${OVERSIGHT_ROOT}/config.json"
REVIEW_LOG="${OVERSIGHT_ROOT}/reviews.jsonl"
HISTORY_DIR="${OVERSIGHT_ROOT}/history"
MEMBERS_FILE="${OVERSIGHT_ROOT}/members.json"

# ─── Initialization ─────────────────────────────────────────────────────────

_ensure_oversight_dirs() {
    mkdir -p "$OVERSIGHT_ROOT" "$HISTORY_DIR"
}

_init_board_config() {
    _ensure_oversight_dirs
    if [[ ! -f "$BOARD_CONFIG" ]]; then
        cat > "$BOARD_CONFIG" <<'EOF'
{
  "quorum": 0.5,
  "reviewers": ["code_quality", "security", "performance", "architecture"],
  "strictness": "normal",
  "enabled": true,
  "appeal_max_attempts": 3
}
EOF
        success "Initialized oversight board config"
    fi
}

_init_members() {
    _ensure_oversight_dirs
    if [[ ! -f "$MEMBERS_FILE" ]]; then
        cat > "$MEMBERS_FILE" <<'EOF'
{
  "code_quality": {
    "role": "Code Quality Reviewer",
    "expertise": ["readability", "maintainability", "style", "structure"],
    "reviews": 0,
    "avg_confidence": 0.0
  },
  "security": {
    "role": "Security Specialist",
    "expertise": ["owasp", "credentials", "injection", "defaults", "cwe"],
    "reviews": 0,
    "avg_confidence": 0.0
  },
  "performance": {
    "role": "Performance Engineer",
    "expertise": ["n+1_queries", "memory_leaks", "caching", "algorithms"],
    "reviews": 0,
    "avg_confidence": 0.0
  },
  "architecture": {
    "role": "Architecture Enforcer",
    "expertise": ["layer_boundaries", "dependency_direction", "naming", "modules"],
    "reviews": 0,
    "avg_confidence": 0.0
  }
}
EOF
        success "Initialized oversight board members"
    fi
}

# ─── Review Submission ───────────────────────────────────────────────────

cmd_review() {
    local pr_number=""
    local commit=""
    local diff_file=""
    local description=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr)           pr_number="$2"; shift 2 ;;
            --commit)       commit="$2"; shift 2 ;;
            --diff)         diff_file="$2"; shift 2 ;;
            --description)  description="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: oversight review [--pr <N>|--commit <ref>|--diff <file>] [--description <text>]"
                exit 0
                ;;
            *)  error "Unknown option: $1"; exit 1 ;;
        esac
    done

    _init_board_config
    _init_members

    if [[ -z "$pr_number" && -z "$commit" && -z "$diff_file" ]]; then
        error "Provide --pr, --commit, or --diff"
        exit 1
    fi

    local review_id
    review_id=$(date +%s)_$(head -c8 /dev/urandom | od -A n -t x1 | tr -d ' ')

    local review_file="${OVERSIGHT_ROOT}/${review_id}.json"

    # Build review record
    cat > "$review_file" <<EOF
{
  "id": "$review_id",
  "submitted_at": "$(now_iso)",
  "pr_number": ${pr_number:-null},
  "commit": ${commit:-null},
  "diff_file": ${diff_file:-null},
  "description": "${description//\"/\\\"}",
  "votes": {},
  "verdict": null,
  "confidence_score": 0.0,
  "appeals": []
}
EOF

    emit_event "oversight_review_submitted" "review_id=$review_id" "pr=$pr_number" "commit=$commit"

    info "Review submitted: $review_id"
    echo "  PR: ${pr_number:-—}"
    echo "  Commit: ${commit:-—}"
    echo "  Diff: ${diff_file:-—}"
    echo ""
    echo "Board members will review and vote:"
    jq -r '.[] | "  • \(.role)"' "$MEMBERS_FILE"
}

# ─── Vote Recording ────────────────────────────────────────────────────

cmd_vote() {
    local review_id=""
    local reviewer=""
    local decision=""  # approve, reject, abstain
    local reasoning=""
    local confidence=0.0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --review)       review_id="$2"; shift 2 ;;
            --reviewer)     reviewer="$2"; shift 2 ;;
            --decision)     decision="$2"; shift 2 ;;
            --reasoning)    reasoning="$2"; shift 2 ;;
            --confidence)   confidence="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: oversight vote --review <id> --reviewer <name> --decision [approve|reject|abstain] --reasoning <text> [--confidence <0.0-1.0>]"
                exit 0
                ;;
            *)  error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$review_id" || -z "$reviewer" || -z "$decision" ]]; then
        error "Require --review, --reviewer, --decision"
        exit 1
    fi

    local review_file="${OVERSIGHT_ROOT}/${review_id}.json"
    if [[ ! -f "$review_file" ]]; then
        error "Review not found: $review_id"
        exit 1
    fi

    # Validate decision
    case "$decision" in
        approve|reject|abstain) ;;
        *)  error "Invalid decision: $decision (must be approve, reject, or abstain)"; exit 1 ;;
    esac

    # Update review with vote
    local tmp_file="${review_file}.tmp"
    jq --arg reviewer "$reviewer" \
       --arg decision "$decision" \
       --arg reasoning "${reasoning//\"/\\\"}" \
       --arg confidence "$confidence" \
       '.votes[$reviewer] = {
           "decision": $decision,
           "reasoning": $reasoning,
           "confidence": ($confidence | tonumber),
           "voted_at": "'$(now_iso)'"
       }' "$review_file" > "$tmp_file"
    mv "$tmp_file" "$review_file"

    success "Vote recorded: $reviewer → $decision"
    emit_event "oversight_vote_recorded" "review_id=$review_id" "reviewer=$reviewer" "decision=$decision" "confidence=$confidence"

    _update_verdict "$review_id"
}

# ─── Verdict Calculation ─────────────────────────────────────────────────

_update_verdict() {
    local review_id="$1"
    local review_file="${OVERSIGHT_ROOT}/${review_id}.json"

    if [[ ! -f "$review_file" ]]; then
        return 1
    fi

    local votes
    votes=$(jq '.votes' "$review_file")

    local approve_count=0
    local reject_count=0
    local abstain_count=0
    local total_confidence=0.0
    local reviewer_count=0

    while IFS= read -r reviewer_data; do
        local decision
        decision=$(echo "$reviewer_data" | jq -r '.decision')
        local confidence
        confidence=$(echo "$reviewer_data" | jq -r '.confidence')

        case "$decision" in
            approve)   approve_count=$((approve_count + 1)) ;;
            reject)    reject_count=$((reject_count + 1)) ;;
            abstain)   abstain_count=$((abstain_count + 1)) ;;
        esac

        total_confidence=$(echo "$total_confidence + $confidence" | bc 2>/dev/null || echo "0")
        reviewer_count=$((reviewer_count + 1))
    done < <(echo "$votes" | jq -c '.[]')

    local quorum
    quorum=$(jq -r '.quorum // 0.5' "$BOARD_CONFIG")

    local active_votes=$((approve_count + reject_count))
    local total_votes=$((approve_count + reject_count + abstain_count))

    local verdict="pending"
    local confidence_score=0.0

    if [[ $total_votes -gt 0 ]]; then
        if [[ $reviewer_count -gt 0 ]]; then
            confidence_score=$(echo "$total_confidence / $reviewer_count" | bc -l 2>/dev/null | cut -c1-5 || echo "0.5")
        fi

        if [[ $active_votes -gt 0 ]]; then
            local approve_ratio
            approve_ratio=$(echo "$approve_count / $active_votes" | bc -l 2>/dev/null || echo "0")

            local quorum_num
            quorum_num=$(echo "$quorum * 100" | bc 2>/dev/null || echo "50")

            local approve_pct
            approve_pct=$(echo "$approve_ratio * 100" | bc 2>/dev/null || echo "0")

            # Check if quorum met and decision reached
            local quorum_met=0
            if (( $(echo "$active_votes >= $total_votes * $quorum" | bc -l) )); then
                quorum_met=1
            fi

            if [[ $quorum_met -eq 1 ]]; then
                # Simple majority among active votes
                if [[ $approve_count -gt $reject_count ]]; then
                    verdict="approved"
                elif [[ $reject_count -gt $approve_count ]]; then
                    verdict="rejected"
                else
                    verdict="deadlock"
                fi
            fi
        fi
    fi

    # Update verdict in review file
    local tmp_file="${review_file}.tmp"
    jq --arg verdict "$verdict" \
       --arg confidence "$confidence_score" \
       '.verdict = $verdict | .confidence_score = ($confidence | tonumber)' \
       "$review_file" > "$tmp_file"
    mv "$tmp_file" "$review_file"

    if [[ "$verdict" != "pending" ]]; then
        emit_event "oversight_verdict_rendered" "review_id=$review_id" "verdict=$verdict" "confidence=$confidence_score"
    fi
}

# ─── Pipeline gate: submit review, record vote(s), output verdict ───────────
# Usage: oversight gate --diff <file> [--description <text>] [--reject-if <reason>]
# Outputs: approved | rejected | deadlock | pending (for pipeline to block on non-approved)
cmd_gate() {
    local diff_file=""
    local description=""
    local reject_if=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --diff)         diff_file="$2"; shift 2 ;;
            --description)  description="$2"; shift 2 ;;
            --reject-if)    reject_if="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: oversight gate --diff <file> [--description <text>] [--reject-if <reason>]"
                echo "Outputs verdict: approved | rejected | deadlock | pending"
                exit 0
                ;;
            *)  error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$diff_file" || ! -f "$diff_file" ]]; then
        error "Provide --diff <file> (must exist)"
        exit 1
    fi

    _init_board_config
    _init_members

    local review_id
    review_id=$(date +%s)_$(head -c8 /dev/urandom 2>/dev/null | od -A n -t x1 | tr -d ' ' || echo "$$")
    local review_file="${OVERSIGHT_ROOT}/${review_id}.json"

    # Build review record safely via jq (no JSON injection from description/diff_file)
    jq -n \
        --arg id "$review_id" \
        --arg submitted "$(now_iso)" \
        --arg diff "$diff_file" \
        --arg desc "$description" \
        '{id: $id, submitted_at: $submitted, pr_number: null, commit: null, diff_file: $diff, description: $desc, votes: {}, verdict: null, confidence_score: 0.0, appeals: []}' \
        > "$review_file"

    # Single pipeline voter: reject if --reject-if given, else approve
    local decision="approve"
    local reasoning="Pipeline review passed"
    if [[ -n "$reject_if" ]]; then
        decision="reject"
        reasoning="$reject_if"
    fi

    local tmp_file="${review_file}.tmp"
    jq --arg reviewer "pipeline" \
       --arg decision "$decision" \
       --arg reasoning "${reasoning//\"/\\\"}" \
       --arg confidence "0.9" \
       '.votes[$reviewer] = {
           "decision": $decision,
           "reasoning": $reasoning,
           "confidence": ($confidence | tonumber),
           "voted_at": "'$(now_iso)'"
       }' "$review_file" > "$tmp_file"
    mv "$tmp_file" "$review_file"

    _update_verdict "$review_id"

    local verdict
    verdict=$(jq -r '.verdict // "pending"' "$review_file")
    echo "$verdict"
    if [[ "$verdict" == "rejected" || "$verdict" == "deadlock" ]]; then
        exit 1
    fi
}

# ─── Verdict Display ──────────────────────────────────────────────────────

cmd_verdict() {
    local review_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --review)  review_id="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: oversight verdict --review <id>"
                exit 0
                ;;
            *)  error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$review_id" ]]; then
        error "Require --review <id>"
        exit 1
    fi

    local review_file="${OVERSIGHT_ROOT}/${review_id}.json"
    if [[ ! -f "$review_file" ]]; then
        error "Review not found: $review_id"
        exit 1
    fi

    local verdict
    verdict=$(jq -r '.verdict' "$review_file")
    local confidence
    confidence=$(jq -r '.confidence_score' "$review_file")

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Review: $review_id"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local votes
    votes=$(jq '.votes' "$review_file")
    echo "Board Votes:"
    echo "$votes" | jq -r 'to_entries | .[] | "  \(.key): \(.value.decision) (confidence: \(.value.confidence))\n    Reasoning: \(.value.reasoning)"'
    echo ""

    case "$verdict" in
        approved)
            echo -e "${GREEN}${BOLD}✓ APPROVED${RESET}"
            ;;
        rejected)
            echo -e "${RED}${BOLD}✗ REJECTED${RESET}"
            ;;
        pending)
            echo -e "${YELLOW}${BOLD}⊙ PENDING${RESET}"
            ;;
        deadlock)
            echo -e "${YELLOW}${BOLD}↔ DEADLOCK${RESET}"
            ;;
    esac

    echo "  Confidence: ${confidence}"
    echo ""
}

# ─── History ─────────────────────────────────────────────────────────────

cmd_history() {
    local limit=20
    local filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)   limit="$2"; shift 2 ;;
            --filter)  filter="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: oversight history [--limit <N>] [--filter <verdict>]"
                exit 0
                ;;
            *)  error "Unknown option: $1"; exit 1 ;;
        esac
    done

    _ensure_oversight_dirs

    local count=0
    for file in $(find "$OVERSIGHT_ROOT" -maxdepth 1 -name '*.json' -type f | sort -r); do
        [[ ! -f "$file" ]] && continue

        # Skip config and members files
        local basename
        basename=$(basename "$file")
        if [[ "$basename" == "config.json" || "$basename" == "members.json" ]]; then
            continue
        fi

        # Stop after limit
        [[ $count -ge "$limit" ]] && break

        local verdict
        verdict=$(jq -r '.verdict' "$file" 2>/dev/null || echo "unknown")

        if [[ -n "$filter" && "$verdict" != "$filter" ]]; then
            continue
        fi

        local id
        id="${basename%.json}"
        local submitted
        submitted=$(jq -r '.submitted_at' "$file" 2>/dev/null || echo "—")
        local pr
        pr=$(jq -r '.pr_number // "—"' "$file" 2>/dev/null)

        echo "$id | $submitted | PR: $pr | Verdict: $verdict"
        count=$((count + 1))
    done

    [[ $count -eq 0 ]] && echo "No reviews found"
}

# ─── Members List ────────────────────────────────────────────────────────

cmd_members() {
    _init_members

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Oversight Board Members"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    jq -r 'to_entries | .[] | "\(.value.role) (\(.key))\n  Expertise: \(.value.expertise | join(", "))\n  Reviews: \(.value.reviews) | Avg Confidence: \(.value.avg_confidence | tostring)\n"' "$MEMBERS_FILE"
}

# ─── Configuration ──────────────────────────────────────────────────────

cmd_config() {
    local action="show"
    local key=""
    local value=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            get)        action="get"; shift ;;
            set)        action="set"; shift ;;
            show)       action="show"; shift ;;
            -h|--help)
                echo "Usage: oversight config [get|set|show] [key] [value]"
                exit 0
                ;;
            *)
                if [[ "$action" == "get" && -z "$key" ]]; then
                    key="$1"; shift
                elif [[ "$action" == "set" && -z "$key" ]]; then
                    key="$1"; shift
                elif [[ "$action" == "set" && -z "$value" ]]; then
                    value="$1"; shift
                else
                    error "Unknown option: $1"
                    exit 1
                fi
                ;;
        esac
    done

    _init_board_config

    case "$action" in
        get)
            if [[ -z "$key" ]]; then
                error "Provide key for get"
                exit 1
            fi
            jq -r ".$key // \"not found\"" "$BOARD_CONFIG"
            ;;
        set)
            if [[ -z "$key" || -z "$value" ]]; then
                error "Provide key and value for set"
                exit 1
            fi
            local tmp_file="${BOARD_CONFIG}.tmp"
            jq ".$key = \"$value\"" "$BOARD_CONFIG" > "$tmp_file"
            mv "$tmp_file" "$BOARD_CONFIG"
            success "Config updated: $key = $value"
            ;;
        show)
            jq '.' "$BOARD_CONFIG"
            ;;
    esac
}

# ─── Appeal Process ─────────────────────────────────────────────────────

cmd_appeal() {
    local review_id=""
    local message=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --review)    review_id="$2"; shift 2 ;;
            --message)   message="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: oversight appeal --review <id> --message <text>"
                exit 0
                ;;
            *)  error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$review_id" || -z "$message" ]]; then
        error "Require --review and --message"
        exit 1
    fi

    local review_file="${OVERSIGHT_ROOT}/${review_id}.json"
    if [[ ! -f "$review_file" ]]; then
        error "Review not found: $review_id"
        exit 1
    fi

    local verdict
    verdict=$(jq -r '.verdict' "$review_file")
    if [[ "$verdict" != "rejected" ]]; then
        error "Can only appeal rejected reviews"
        exit 1
    fi

    local appeal_count
    appeal_count=$(jq '.appeals | length' "$review_file" 2>/dev/null || echo 0)

    local max_appeals
    max_appeals=$(jq -r '.appeal_max_attempts // 3' "$BOARD_CONFIG")

    if [[ $appeal_count -ge $max_appeals ]]; then
        error "Maximum appeal attempts reached ($max_appeals)"
        exit 1
    fi

    local tmp_file="${review_file}.tmp"
    jq --arg message "$message" '.appeals += [{"message": $message, "appealed_at": "'$(now_iso)'"}]' "$review_file" > "$tmp_file"
    mv "$tmp_file" "$review_file"

    success "Appeal submitted ($((appeal_count + 1))/$max_appeals)"
    emit_event "oversight_appeal_submitted" "review_id=$review_id" "appeal_number=$((appeal_count + 1))"
}

# ─── Statistics ──────────────────────────────────────────────────────────

cmd_stats() {
    _ensure_oversight_dirs

    local total_reviews=0
    local approved=0
    local rejected=0
    local pending=0

    for file in "$OVERSIGHT_ROOT"/*.json; do
        [[ -f "$file" ]] || continue

        # Skip config and members files
        local basename
        basename=$(basename "$file")
        if [[ "$basename" == "config.json" || "$basename" == "members.json" ]]; then
            continue
        fi

        total_reviews=$((total_reviews + 1))

        local verdict
        verdict=$(jq -r '.verdict' "$file" 2>/dev/null || echo "unknown")
        case "$verdict" in
            approved)  approved=$((approved + 1)) ;;
            rejected)  rejected=$((rejected + 1)) ;;
            pending)   pending=$((pending + 1)) ;;
        esac
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Oversight Board Statistics"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Total Reviews: $total_reviews"
    echo "  Approved:  $approved"
    echo "  Rejected:  $rejected"
    echo "  Pending:   $pending"
    echo ""

    if [[ $total_reviews -gt 0 ]]; then
        local approval_rate
        local total_decided=$((approved + rejected))
        if [[ $total_decided -gt 0 ]]; then
            approval_rate=$(echo "scale=1; $approved * 100 / $total_decided" | bc 2>/dev/null || echo "N/A")
            echo "Approval Rate: ${approval_rate}%"
        fi
    fi
    echo ""
}

# ─── Help ────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright oversight${RESET} — Quality Oversight Board"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}oversight${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}review${RESET}        Submit changes for board review (--pr, --commit, or --diff)"
    echo -e "  ${CYAN}vote${RESET}          Record a vote (--review, --reviewer, --decision)"
    echo -e "  ${CYAN}verdict${RESET}       Show review status and votes"
    echo -e "  ${CYAN}history${RESET}       List past reviews and outcomes"
    echo -e "  ${CYAN}members${RESET}       Show board members and specialties"
    echo -e "  ${CYAN}config${RESET}        Get/set board configuration"
    echo -e "  ${CYAN}appeal${RESET}        Appeal a rejected review"
    echo -e "  ${CYAN}stats${RESET}         Review board statistics"
    echo -e "  ${CYAN}help${RESET}          Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright oversight review --pr 42 --description \"Feature: Auth\"${RESET}"
    echo -e "  ${DIM}shipwright oversight vote --review <id> --reviewer security --decision approve${RESET}"
    echo -e "  ${DIM}shipwright oversight verdict --review <id>${RESET}"
    echo -e "  ${DIM}shipwright oversight stats${RESET}"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    _ensure_oversight_dirs

    case "$cmd" in
        review)   cmd_review "$@" ;;
        vote)     cmd_vote "$@" ;;
        gate)     cmd_gate "$@" ;;
        verdict)  cmd_verdict "$@" ;;
        history)  cmd_history "$@" ;;
        members)  cmd_members "$@" ;;
        config)   cmd_config "$@" ;;
        appeal)   cmd_appeal "$@" ;;
        stats)    cmd_stats "$@" ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
