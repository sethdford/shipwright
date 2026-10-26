#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_POLICY_LEARNER_LOADED:-}" ]] && return 0
_POLICY_LEARNER_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright policy-learner — Strategy Selection & Prompt Optimization   ║
# ║  Learn optimal strategies from historical RL episodes and rewards.      ║
# ║  Bucket by (language, issue_type, complexity), find best strategy per   ║
# ║  bucket, optimize prompt section weights, inject into agent prompts.    ║
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

POLICY_EPISODES_FILE="${POLICY_EPISODES_FILE:-${HOME}/.shipwright/rl-episodes.jsonl}"
POLICY_REWARDS_FILE="${POLICY_REWARDS_FILE:-${HOME}/.shipwright/rewards.jsonl}"
POLICY_LEARNED_FILE="${POLICY_LEARNED_FILE:-${HOME}/.shipwright/learned-policy.json}"
POLICY_MIN_EPISODES="${POLICY_MIN_EPISODES:-3}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

_policy_ensure_dir() {
    local dir
    dir="$(dirname "$POLICY_LEARNED_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# Build context key from language, issue_type, complexity
# Output: "ts:bug:medium" or partial like "*:bug:*"
_policy_context_key() {
    local lang="${1:-*}"
    local itype="${2:-*}"
    local cplx="${3:-*}"
    [[ -z "$lang" ]] && lang="*"
    [[ -z "$itype" ]] && itype="*"
    [[ -z "$cplx" ]] && cplx="*"
    echo "${lang}:${itype}:${cplx}"
}

# ─── Core Functions ──────────────────────────────────────────────────────────

# Learn from all historical episodes. Analyze by context bucket, find best
# strategy per bucket, compute averages, and store in learned-policy.json.
policy_learn_from_history() {
    _policy_ensure_dir

    if [[ ! -f "$POLICY_EPISODES_FILE" ]]; then
        warn "No episodes file found at $POLICY_EPISODES_FILE"
        return 0
    fi

    local episode_count
    episode_count=$(wc -l < "$POLICY_EPISODES_FILE" | tr -d ' ')
    if [[ "$episode_count" -eq 0 ]]; then
        warn "No episodes recorded yet"
        return 0
    fi

    local now_ts
    now_ts="$(now_iso)"

    # Use jq to process all episodes: bucket by context key, find best strategy
    # per bucket, compute avg reward/iterations/cost
    local policy_json
    policy_json=$(jq -c -s --arg now "$now_ts" --argjson min_ep "$POLICY_MIN_EPISODES" '
        def ctx_key:
            ((.context.language // "*") + ":" +
             (.context.issue_type // "*") + ":" +
             (.context.complexity // "*"));
        def strategy_key:
            (.actions // [] | [.[] | if type == "object" then (.strategy // tostring) else tostring end] | sort | join(","));
        group_by(ctx_key) |
        [.[] | . as $bucket |
            ($bucket[0] | ctx_key) as $key |
            ($bucket | group_by(strategy_key)) |
            [.[] |
                {
                    strategy: (.[0] | strategy_key),
                    episodes: length,
                    successes: ([.[] | select(.outcome.success == true)] | length),
                    avg_reward: (
                        [.[] | if .outcome.success == true then 1.0 else 0.0 end] |
                        if length > 0 then (add / length)
                        else 0 end
                    ),
                    avg_iterations: ([.[] | .outcome.iterations // 0] | add / length),
                    avg_cost: ([.[] | .outcome.cost_usd // 0] | add / length)
                } |
                .success_rate = (if .episodes > 0 then (.successes / .episodes) else 0 end)
            ] |
            sort_by(-.success_rate, .avg_iterations) |
            {
                key: $key,
                best: (if length > 0 then .[0].strategy else "default" end),
                reward: (if length > 0 then .[0].success_rate else 0 end),
                episodes: ([.[] | .episodes] | add // 0),
                avg_iterations: (if length > 0 then .[0].avg_iterations else 0 end),
                avg_cost: (if length > 0 then .[0].avg_cost else 0 end),
                all_strategies: .
            }
        ] |
        {
            updated_at: $now,
            total_episodes: ([.[].episodes] | add // 0),
            min_episodes: $min_ep,
            strategies: (
                [.[] | {(.key): {
                    best: .best,
                    reward: (.reward * 100 | floor / 100),
                    episodes: .episodes,
                    avg_iterations: (.avg_iterations * 10 | floor / 10),
                    avg_cost: (.avg_cost * 100 | floor / 100),
                    confident: (.episodes >= $min_ep)
                }}] | add // {}
            ),
            model_preferences: {},
            prompt_weights: {}
        }
    ' "$POLICY_EPISODES_FILE" 2>/dev/null)

    if [[ -z "$policy_json" ]] || [[ "$policy_json" == "null" ]]; then
        warn "Failed to analyze episodes"
        return 1
    fi

    # Note: partial matching handled at query time in policy_suggest_strategy


    # Merge model preferences from episodes (which models correlate with success)
    local model_prefs
    model_prefs=$(jq -c -s '
        [.[] | select(.context.model != null)] |
        if length == 0 then {}
        else
            group_by(.context.complexity // "medium") |
            [.[] |
                (.[0].context.complexity // "medium") as $cplx |
                group_by(.context.model) |
                [.[] | {
                    model: .[0].context.model,
                    success_rate: (([.[] | select(.outcome.success == true)] | length) / length)
                }] |
                sort_by(-.success_rate) |
                if length > 0 then {("build:" + $cplx): .[0].model} else {} end
            ] | add // {}
        end
    ' "$POLICY_EPISODES_FILE" 2>/dev/null || echo "{}")

    # Merge model preferences into policy
    if [[ -n "$model_prefs" ]] && [[ "$model_prefs" != "{}" ]]; then
        policy_json=$(echo "$policy_json" | jq -c --argjson mp "$model_prefs" '.model_preferences = $mp')
    fi

    # Compute prompt weights via policy_optimize_prompt_weights (inline)
    local prompt_weights
    prompt_weights=$(_policy_compute_prompt_weights)
    if [[ -n "$prompt_weights" ]] && [[ "$prompt_weights" != "{}" ]]; then
        policy_json=$(echo "$policy_json" | jq -c --argjson pw "$prompt_weights" '.prompt_weights = $pw')
    fi

    # Atomic write
    local tmp
    tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/policy-learn-$$.tmp")"
    echo "$policy_json" | jq '.' > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$POLICY_LEARNED_FILE"
        local total
        total=$(echo "$policy_json" | jq '.total_episodes // 0')
        local strat_count
        strat_count=$(echo "$policy_json" | jq '.strategies | keys | length')
        success "Learned policy from $total episodes across $strat_count context buckets"
        emit_event "policy.learned" "episodes=$total" "buckets=$strat_count"
    else
        rm -f "$tmp"
        error "Failed to write learned policy"
        return 1
    fi
}

# Suggest best strategy for a given context.
# Args: $1=language, $2=issue_type, $3=complexity
# Output: JSON with strategy, expected_reward, confidence, evidence_count
policy_suggest_strategy() {
    local language="${1:-}"
    local issue_type="${2:-}"
    local complexity="${3:-}"

    if [[ ! -f "$POLICY_LEARNED_FILE" ]]; then
        echo '{"strategy":"default","expected_reward":0,"confidence":"none","evidence_count":0}'
        return 0
    fi

    local exact_key partial1 partial2 partial3
    exact_key="$(_policy_context_key "$language" "$issue_type" "$complexity")"

    # Partial match keys for fallback
    # ts:bug:medium → ts:bug:* → *:bug:medium → *:*:medium → default
    partial1="$(_policy_context_key "$language" "$issue_type" "*")"
    partial2="$(_policy_context_key "*" "$issue_type" "$complexity")"
    partial3="$(_policy_context_key "*" "*" "$complexity")"

    # Partial matching: try exact, then scan keys for partial matches
    # ts:bug:medium → any key matching ts:bug:* → any matching *:bug:medium → *:*:medium
    local result
    result=$(jq -c \
        --arg exact "$exact_key" \
        --arg lang "$language" \
        --arg itype "$issue_type" \
        --arg cplx "$complexity" \
        --argjson min_ep "$POLICY_MIN_EPISODES" '
        .strategies as $s |

        # Try exact match first
        (if $s[$exact] then {match: $s[$exact], tier: "exact"}
        else
            # Scan all keys for partial matches
            ($s | to_entries | [
                # Match lang:type:*
                (.[] | select((.key | split(":")[0]) == $lang and (.key | split(":")[1]) == $itype) | {match: .value, tier: "partial_type"}),
                # Match *:type:complexity
                (.[] | select((.key | split(":")[1]) == $itype and (.key | split(":")[2]) == $cplx) | {match: .value, tier: "partial_lang"}),
                # Match *:*:complexity
                (.[] | select((.key | split(":")[2]) == $cplx) | {match: .value, tier: "partial_cplx"})
            ] | first // null)
        end) |

        if . == null then
            {strategy: "default", expected_reward: 0, confidence: "none", evidence_count: 0}
        else
            {
                strategy: .match.best,
                expected_reward: .match.reward,
                confidence: (
                    if .match.episodes >= ($min_ep * 3) then "high"
                    elif .match.episodes >= $min_ep then "medium"
                    else "low" end
                ),
                evidence_count: .match.episodes,
                match_tier: .tier,
                avg_iterations: .match.avg_iterations
            }
        end
    ' "$POLICY_LEARNED_FILE" 2>/dev/null)

    if [[ -z "$result" ]] || [[ "$result" == "null" ]]; then
        echo '{"strategy":"default","expected_reward":0,"confidence":"none","evidence_count":0}'
    else
        echo "$result"
    fi
}

# Compute which prompt sections correlate with better outcomes.
# Internal helper — called by policy_learn_from_history.
# Output: JSON object with section weights (0.0–1.0)
_policy_compute_prompt_weights() {
    if [[ ! -f "$POLICY_EPISODES_FILE" ]]; then
        echo "{}"
        return 0
    fi

    # Analyze episodes for prompt section correlation
    # Look for context fields that indicate which sections were active
    jq -c -s '
        def section_weight(field):
            [.[] | select(.context[field] == true)] as $with |
            [.[] | select(.context[field] != true)] as $without |
            if ($with | length) < 2 then 0.5
            elif ($without | length) < 2 then 0.5
            else
                (([($with[] | select(.outcome.success == true)] | length) / ([$with[] | .] | length)) -
                 ([($without[] | select(.outcome.success == true)] | length) / ([$without[] | .] | length))) |
                (0.5 + . / 2) |
                if . < 0 then 0 elif . > 1 then 1 else (. * 100 | floor / 100) end
            end;
        {
            inject_memory: section_weight("has_memory"),
            inject_architecture: section_weight("has_architecture"),
            inject_coverage_baseline: section_weight("has_coverage"),
            inject_rl_context: section_weight("has_rl_context"),
            inject_error_history: section_weight("has_error_history")
        }
    ' "$POLICY_EPISODES_FILE" 2>/dev/null || echo "{}"
}

# Public wrapper — learn and return prompt weights.
policy_optimize_prompt_weights() {
    if [[ ! -f "$POLICY_LEARNED_FILE" ]]; then
        policy_learn_from_history
    fi

    if [[ -f "$POLICY_LEARNED_FILE" ]]; then
        jq -c '.prompt_weights // {}' "$POLICY_LEARNED_FILE" 2>/dev/null || echo "{}"
    else
        echo "{}"
    fi
}

# Format learned policy suggestions for agent prompt injection.
# Args: $1=language, $2=issue_type, $3=complexity
# Output: markdown section for prompt (empty if no useful data)
policy_inject_into_prompt() {
    local language="${1:-}"
    local issue_type="${2:-}"
    local complexity="${3:-}"

    local suggestion
    suggestion="$(policy_suggest_strategy "$language" "$issue_type" "$complexity")"

    local confidence
    confidence=$(echo "$suggestion" | jq -r '.confidence // "none"')

    if [[ "$confidence" == "none" ]]; then
        return 0
    fi

    local strategy evidence reward avg_iters
    strategy=$(echo "$suggestion" | jq -r '.strategy // "default"')
    evidence=$(echo "$suggestion" | jq -r '.evidence_count // 0')
    reward=$(echo "$suggestion" | jq -r '.expected_reward // 0')
    avg_iters=$(echo "$suggestion" | jq -r '.avg_iterations // 0')

    # Format strategy name for display
    local display_strategy
    display_strategy=$(echo "$strategy" | tr ',' ' → ')

    local pct
    pct=$(awk -v r="$reward" 'BEGIN { printf "%d", r * 100 }')

    cat <<EOF
## Policy-Learned Strategy
Based on ${evidence} similar issues: **${display_strategy}** (${pct}% success rate, avg ${avg_iters} iterations)
Confidence: ${confidence}
EOF

    # Add prompt weight guidance if available
    if [[ -f "$POLICY_LEARNED_FILE" ]]; then
        local weights
        weights=$(jq -r '
            .prompt_weights // {} |
            to_entries |
            [.[] | select(.value >= 0.7)] |
            if length > 0 then
                "Include: " + ([.[].key | gsub("inject_"; "")] | join(", "))
            else empty end
        ' "$POLICY_LEARNED_FILE" 2>/dev/null || true)

        local exclude
        exclude=$(jq -r '
            .prompt_weights // {} |
            to_entries |
            [.[] | select(.value < 0.3)] |
            if length > 0 then
                "Exclude (low impact): " + ([.[].key | gsub("inject_"; "")] | join(", "))
            else empty end
        ' "$POLICY_LEARNED_FILE" 2>/dev/null || true)

        if [[ -n "$weights" ]]; then
            echo "$weights"
        fi
        if [[ -n "$exclude" ]]; then
            echo "$exclude"
        fi
    fi
}

# Display a human-readable report of what the policy has learned.
policy_report() {
    if [[ ! -f "$POLICY_LEARNED_FILE" ]]; then
        echo "No learned policy found. Run policy_learn_from_history first."
        return 0
    fi

    local updated total
    updated=$(jq -r '.updated_at // "unknown"' "$POLICY_LEARNED_FILE")
    total=$(jq -r '.total_episodes // 0' "$POLICY_LEARNED_FILE")

    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  Learned Policy Report                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Updated: ${updated}"
    echo "Total episodes: ${total}"
    echo ""

    # Strategy buckets
    echo "── Strategy Recommendations ──────────────────────────────────"
    jq -r '
        .strategies // {} | to_entries[] |
        "  \(.key): \(.value.best) " +
        "(\(.value.reward * 100 | floor)% success, " +
        "\(.value.avg_iterations) avg iters, " +
        "~$\(.value.avg_cost), " +
        "\(.value.episodes) episodes" +
        (if .value.confident then ", confident" else ", low data" end) +
        ")"
    ' "$POLICY_LEARNED_FILE" 2>/dev/null || echo "  (none)"
    echo ""

    # Model preferences
    echo "── Model Preferences ─────────────────────────────────────────"
    local mp_count
    mp_count=$(jq '.model_preferences // {} | keys | length' "$POLICY_LEARNED_FILE" 2>/dev/null || echo "0")
    if [[ "$mp_count" -gt 0 ]]; then
        jq -r '.model_preferences // {} | to_entries[] | "  \(.key): \(.value)"' "$POLICY_LEARNED_FILE" 2>/dev/null
    else
        echo "  (no model preference data yet)"
    fi
    echo ""

    # Prompt weights
    echo "── Prompt Section Weights ────────────────────────────────────"
    local pw_count
    pw_count=$(jq '.prompt_weights // {} | keys | length' "$POLICY_LEARNED_FILE" 2>/dev/null || echo "0")
    if [[ "$pw_count" -gt 0 ]]; then
        jq -r '
            .prompt_weights // {} | to_entries |
            sort_by(-.value)[] |
            "  \(.key): \(.value)" +
            (if .value >= 0.7 then " (include)" elif .value < 0.3 then " (exclude)" else " (neutral)" end)
        ' "$POLICY_LEARNED_FILE" 2>/dev/null
    else
        echo "  (no prompt weight data yet)"
    fi
}
