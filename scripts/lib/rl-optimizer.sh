#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_RL_OPTIMIZER_LOADED:-}" ]] && return 0
_RL_OPTIMIZER_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright rl-optimizer — Cross-Session Reinforcement Learning (Phase 7)║
# ║  Record (context, actions, outcome) episodes, weight by success,        ║
# ║  and suggest best approaches for new issues based on past experience.   ║
# ║  Decay: halve weight every 30 days. Min weight: 0.1.                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="4.0.0"

# ─── Output Helpers ──────────────────────────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ─── Configuration ───────────────────────────────────────────────────────────

RL_EPISODES_FILE="${RL_EPISODES_FILE:-${HOME}/.shipwright/rl-episodes.jsonl}"
RL_DECAY_HALF_LIFE_DAYS="${RL_DECAY_HALF_LIFE_DAYS:-30}"
RL_MIN_WEIGHT="${RL_MIN_WEIGHT:-0.1}"
RL_SUCCESS_REWARD="${RL_SUCCESS_REWARD:-1.0}"
RL_FAILURE_PENALTY="${RL_FAILURE_PENALTY:-0.5}"
RL_MAX_SUGGESTIONS="${RL_MAX_SUGGESTIONS:-3}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

_rl_ensure_dir() {
    local dir
    dir="$(dirname "$RL_EPISODES_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# Compute decay factor for an episode based on age in days.
# Output: float between RL_MIN_WEIGHT and 1.0
_rl_decay_factor() {
    local episode_epoch="${1:-0}"
    local now
    now="$(date +%s)"
    local age_days
    age_days=$(( (now - episode_epoch) / 86400 ))
    if [[ "$age_days" -le 0 ]]; then
        echo "1.0"
        return
    fi
    # Halve weight every RL_DECAY_HALF_LIFE_DAYS days
    # factor = max(0.5^(age/half_life), min_weight)
    local factor
    factor=$(awk -v age="$age_days" -v half="$RL_DECAY_HALF_LIFE_DAYS" -v min="$RL_MIN_WEIGHT" \
        'BEGIN { f = 2^(-age/half); if (f < min) f = min; printf "%.4f", f }')
    echo "$factor"
}

# Convert ISO timestamp to epoch seconds (portable)
# ─── Core Functions ──────────────────────────────────────────────────────────

# Record a completed pipeline episode.
# Args: $1=context_json, $2=actions_json, $3=outcome_json, $4=rewards_json (optional)
# context_json: {"language":"ts","complexity":"medium","issue_type":"bug"}
# actions_json: ["read_code","add_tests","refactor"]
# outcome_json: {"success":true,"iterations":5,"cost_usd":2.50}
# rewards_json: [45,55,70,85,95]  (process reward trajectory, optional)
rl_record_episode() {
    local context_json="${1:-"{}"}"
    local actions_json="${2:-"[]"}"
    local outcome_json="${3:-"{}"}"
    local rewards_json="${4:-"[]"}"

    _rl_ensure_dir

    local timestamp
    timestamp="$(now_iso)"
    local epoch
    epoch="$(date +%s)"

    # Build episode JSON with jq (compact for JSONL)
    local episode
    episode=$(jq -c -n \
        --arg ts "$timestamp" \
        --argjson epoch "$epoch" \
        --argjson ctx "$context_json" \
        --argjson acts "$actions_json" \
        --argjson out "$outcome_json" \
        --argjson rw "$rewards_json" \
        --argjson w 1.0 \
        '{timestamp: $ts, epoch: $epoch, context: $ctx, actions: $acts, outcome: $out, process_rewards: $rw, weight: $w}')

    # Atomic append via temp file
    local tmp
    tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/rl-ep-$$.tmp")"
    echo "$episode" > "$tmp"
    cat "$tmp" >> "$RL_EPISODES_FILE"
    rm -f "$tmp"

    local success_str
    success_str=$(echo "$outcome_json" | jq -r '.success // false')
    local iter_str
    iter_str=$(echo "$outcome_json" | jq -r '.iterations // 0')

    emit_event "rl.episode_recorded" \
        "success=$success_str" \
        "iterations=$iter_str" \
        "actions_count=$(echo "$actions_json" | jq 'length')"

    info "RL episode recorded (success=$success_str, iterations=$iter_str)"
}

# Suggest best approach for a new issue based on past episodes.
# Args: $1=language, $2=issue_type, $3=complexity
# Output: markdown-formatted suggestions
rl_suggest_approach() {
    local language="${1:-}"
    local issue_type="${2:-}"
    local complexity="${3:-}"

    if [[ ! -f "$RL_EPISODES_FILE" ]]; then
        echo ""
        return 0
    fi

    local episode_count
    episode_count=$(wc -l < "$RL_EPISODES_FILE" | tr -d ' ')
    if [[ "$episode_count" -eq 0 ]]; then
        echo ""
        return 0
    fi

    local now_epoch
    now_epoch="$(date +%s)"

    # Use jq to filter matching episodes, compute decay, rank by weighted success
    # Match: at least one of language/issue_type/complexity must match
    local suggestions
    suggestions=$(jq -r -s --arg lang "$language" --arg itype "$issue_type" \
        --arg cplx "$complexity" --argjson now "$now_epoch" \
        --argjson half "$RL_DECAY_HALF_LIFE_DAYS" --argjson min "$RL_MIN_WEIGHT" '
        # Compute similarity score (0-3)
        def sim:
            (if .context.language == $lang and $lang != "" then 1 else 0 end) +
            (if .context.issue_type == $itype and $itype != "" then 1 else 0 end) +
            (if .context.complexity == $cplx and $cplx != "" then 1 else 0 end);

        # Compute decay factor
        def decay:
            (($now - (.epoch // 0)) / 86400) as $age |
            if $age <= 0 then 1
            else (pow(0.5; ($age / $half))) | if . < $min then $min else . end
            end;

        # Filter episodes with at least 1 matching dimension
        [.[] | select(sim >= 1)] |

        # Group by action sequence (joined as key)
        group_by(.actions | sort | join(",")) |

        # For each action group, compute weighted stats
        [.[] | {
            actions: (.[0].actions | sort),
            action_key: (.[0].actions | sort | join(", ")),
            total_episodes: length,
            weighted_successes: ([.[] | select(.outcome.success == true) | decay * (.weight // 1)] | add // 0),
            weighted_total: ([.[] | decay * (.weight // 1)] | add // 0),
            avg_iterations: ([.[] | .outcome.iterations // 0] | add / length),
            avg_cost: ([.[] | .outcome.cost_usd // 0] | add / length),
            similarity: (.[0] | sim)
        }] |

        # Compute success rate and sort
        [.[] | .success_rate = (if .weighted_total > 0 then (.weighted_successes / .weighted_total * 100) else 0 end)] |
        sort_by(-.success_rate, -.similarity, .avg_iterations) |

        # Take top 3
        .[:3] |

        # Format as output lines
        .[] | "- **\(.action_key)**: \(.success_rate | floor)% success rate (\(.total_episodes) episodes, avg \(.avg_iterations | floor) iterations, ~$\(.avg_cost | . * 100 | floor / 100))"
    ' "$RL_EPISODES_FILE" 2>/dev/null || echo "")

    if [[ -z "$suggestions" ]]; then
        echo ""
        return 0
    fi

    local context_desc=""
    [[ -n "$language" ]] && context_desc="${language}"
    [[ -n "$issue_type" ]] && context_desc="${context_desc:+$context_desc }${issue_type}"
    [[ -n "$complexity" ]] && context_desc="${context_desc:+$context_desc }(${complexity})"

    echo "Based on ${episode_count} past episodes${context_desc:+ for $context_desc}:
${suggestions}"
}

# Compute effectiveness scores per action type.
# Output: one line per action with stats
rl_effectiveness_score() {
    if [[ ! -f "$RL_EPISODES_FILE" ]]; then
        echo "No episodes recorded yet."
        return 0
    fi

    local now_epoch
    now_epoch="$(date +%s)"

    jq -r -s --argjson now "$now_epoch" \
        --argjson half "$RL_DECAY_HALF_LIFE_DAYS" --argjson min "$RL_MIN_WEIGHT" '
        # Decay factor
        def decay:
            (($now - (.epoch // 0)) / 86400) as $age |
            if $age <= 0 then 1
            else (pow(0.5; ($age / $half))) | if . < $min then $min else . end
            end;

        # Flatten: one entry per action per episode
        [.[] | . as $ep | .actions[]? | {action: ., ep: $ep}] |

        # Group by action
        group_by(.action) |

        # Stats per action
        [.[] | {
            action: .[0].action,
            total: length,
            success_rate: (([.[] | select(.ep.outcome.success == true) | .ep | decay * (.weight // 1)] | add // 0) /
                          ([.[] | .ep | decay * (.weight // 1)] | add // 1) * 100),
            avg_iterations: ([.[] | .ep.outcome.iterations // 0] | add / length),
            avg_cost: ([.[] | .ep.outcome.cost_usd // 0] | add / length),
            recent_success: ([.[] | select(($now - (.ep.epoch // 0)) < 604800) | select(.ep.outcome.success == true)] | length),
            recent_total: ([.[] | select(($now - (.ep.epoch // 0)) < 604800)] | length)
        }] |

        sort_by(-.success_rate) |

        .[] |
        "\(.action): \(.success_rate | floor)% success (\(.total) episodes, avg \(.avg_iterations | floor) iters, ~$\(.avg_cost | . * 100 | floor / 100))" +
        (if .recent_total > 2 then
            (if (.recent_success / .recent_total) > (.success_rate / 100 + 0.1) then " (trending up)"
             elif (.recent_success / .recent_total) < (.success_rate / 100 - 0.1) then " (declining)"
             else " (stable)" end)
         else "" end)
    ' "$RL_EPISODES_FILE" 2>/dev/null || echo "No actionable data yet."
}

# Inject RL suggestions into pipeline prompt as markdown.
# Args: $1=language, $2=issue_type, $3=complexity
# Output: markdown section for prompt injection (empty if no data)
rl_inject_context() {
    local language="${1:-}"
    local issue_type="${2:-}"
    local complexity="${3:-}"

    local suggestions
    suggestions="$(rl_suggest_approach "$language" "$issue_type" "$complexity")"

    if [[ -z "$suggestions" ]]; then
        return 0
    fi

    cat <<EOF
## RL-Suggested Approaches (from past pipelines)
${suggestions}

Use these insights to guide your strategy. Approaches with higher success rates should be preferred.
EOF
}

# Update weights for actions after pipeline completion.
# Args: $1=actions_json (array), $2=success (true/false)
# Modifies the most recent episode matching these actions.
rl_update_weights() {
    local actions_json="${1:-"[]"}"
    local success="${2:-false}"

    if [[ ! -f "$RL_EPISODES_FILE" ]]; then
        return 0
    fi

    local delta
    if [[ "$success" == "true" ]]; then
        delta="$RL_SUCCESS_REWARD"
    else
        delta="-${RL_FAILURE_PENALTY}"
    fi

    # Update the weight of the last episode in the file
    local tmp
    tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/rl-uw-$$.tmp")"

    # Read all episodes, update the last one's weight, output compact JSONL
    jq -c -s --argjson delta "$delta" --argjson min "$RL_MIN_WEIGHT" '
        if length == 0 then []
        else
            .[-1].weight = ((.[-1].weight // 1) + $delta | if . < $min then $min else . end) |
            .
        end | .[]
    ' "$RL_EPISODES_FILE" > "$tmp" 2>/dev/null

    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$RL_EPISODES_FILE"
        emit_event "rl.weights_updated" "success=$success" "delta=$delta"
    else
        rm -f "$tmp"
    fi
}

# ─── Pipeline Integration Helpers ────────────────────────────────────────────

# Record episode from pipeline globals (convenience wrapper).
# Called at pipeline completion with globals: GOAL, TASK_TYPE, TEST_CMD, etc.
rl_record_from_pipeline() {
    local success="${1:-false}"
    local iterations="${2:-0}"
    local cost_usd="${3:-0}"
    local language="${4:-}"
    local complexity="${5:-}"
    local issue_type="${6:-}"
    local actions_json="${7:-"[]"}"
    local rewards_json="${8:-"[]"}"

    local context_json
    context_json=$(jq -c -n \
        --arg lang "$language" \
        --arg cplx "$complexity" \
        --arg itype "$issue_type" \
        '{language: $lang, complexity: $cplx, issue_type: $itype}')

    local outcome_json
    outcome_json=$(jq -c -n \
        --argjson success "$success" \
        --argjson iters "$iterations" \
        --argjson cost "$cost_usd" \
        '{success: $success, iterations: $iters, cost_usd: $cost}')

    rl_record_episode "$context_json" "$actions_json" "$outcome_json" "$rewards_json"
    rl_update_weights "$actions_json" "$success"
}

# Extract RL context for compose_prompt injection.
# Uses pipeline globals to determine context dimensions.
rl_compose_prompt_section() {
    local language="${INTELLIGENCE_LANGUAGE:-}"
    local issue_type="${INTELLIGENCE_ISSUE_TYPE:-}"
    local complexity="${INTELLIGENCE_COMPLEXITY:-}"

    rl_inject_context "$language" "$issue_type" "$complexity"
}
