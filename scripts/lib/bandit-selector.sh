#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_BANDIT_SELECTOR_LOADED:-}" ]] && return 0
_BANDIT_SELECTOR_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright bandit-selector — Thompson Sampling for Model/Template      ║
# ║  Multi-armed bandit: Beta(α,β) priors, Thompson sampling selection      ║
# ║  Replaces static model routing with learned optimal selection           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="4.0.0"

# ─── Output Helpers ──────────────────────────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Configuration ───────────────────────────────────────────────────────────

BANDIT_STATE_FILE="${BANDIT_STATE_FILE:-$HOME/.shipwright/bandits.json}"

# Default models and stages for arm initialization
BANDIT_MODELS="${BANDIT_MODELS:-haiku,sonnet,opus}"
BANDIT_STAGES="${BANDIT_STAGES:-build,test,review,design,plan,intake,pr}"
BANDIT_TEMPLATES="${BANDIT_TEMPLATES:-fast,standard,full,hotfix,autonomous}"
BANDIT_ISSUE_TYPES="${BANDIT_ISSUE_TYPES:-bug,feature,refactor,docs}"

# ─── Beta Sampling ───────────────────────────────────────────────────────────
# Sample from Beta(alpha, beta) using Gamma decomposition.
# If X~Gamma(a,1) and Y~Gamma(b,1), then X/(X+Y)~Beta(a,b).
# Gamma(k,1) for integer k = sum of k Exponential(1) samples.

_beta_sample() {
    local alpha="$1" beta="$2"
    awk -v a="$alpha" -v b="$beta" -v seed="$RANDOM" 'BEGIN {
        srand(seed)
        x = 0; y = 0
        for (i = 0; i < a; i++) { r = rand(); if (r < 1e-10) r = 1e-10; x += -log(r) }
        for (i = 0; i < b; i++) { r = rand(); if (r < 1e-10) r = 1e-10; y += -log(r) }
        if (x + y > 0) printf "%.6f", x / (x + y)
        else printf "0.500000"
    }'
}

# ─── JSON Helpers ────────────────────────────────────────────────────────────

_bandit_ensure_dir() {
    local dir
    dir="$(dirname "$BANDIT_STATE_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

_bandit_read_state() {
    if [[ -f "$BANDIT_STATE_FILE" ]]; then
        cat "$BANDIT_STATE_FILE"
    else
        echo '{}'
    fi
}

_bandit_write_state() {
    local json="$1"
    _bandit_ensure_dir
    local tmp_file="${BANDIT_STATE_FILE}.tmp.$$"
    echo "$json" > "$tmp_file"
    mv "$tmp_file" "$BANDIT_STATE_FILE"
}

# ─── Arm Key Helpers ─────────────────────────────────────────────────────────

_arm_key() {
    # Create arm key from context:value pair, e.g. "build:haiku"
    echo "${1}:${2}"
}

# ─── Core Functions ──────────────────────────────────────────────────────────

# Initialize Beta(1,1) distributions for all model and template arms.
# Idempotent: does not overwrite existing arms.
bandit_init() {
    _bandit_ensure_dir
    local state
    state="$(_bandit_read_state)"

    # Ensure model_arms and template_arms keys exist
    local has_model_arms has_template_arms
    has_model_arms=$(echo "$state" | jq -r 'has("model_arms")' 2>/dev/null || echo "false")
    has_template_arms=$(echo "$state" | jq -r 'has("template_arms")' 2>/dev/null || echo "false")

    if [[ "$has_model_arms" != "true" ]]; then
        state=$(echo "$state" | jq '. + {"model_arms": {}}')
    fi
    if [[ "$has_template_arms" != "true" ]]; then
        state=$(echo "$state" | jq '. + {"template_arms": {}}')
    fi

    # Initialize model arms: stage × model
    local IFS_OLD="$IFS"
    IFS=','
    local stages_arr=($BANDIT_STAGES)
    local models_arr=($BANDIT_MODELS)
    local templates_arr=($BANDIT_TEMPLATES)
    local types_arr=($BANDIT_ISSUE_TYPES)
    IFS="$IFS_OLD"

    local stage model key existing
    for stage in "${stages_arr[@]}"; do
        for model in "${models_arr[@]}"; do
            key="$(_arm_key "$stage" "$model")"
            existing=$(echo "$state" | jq -r --arg k "$key" '.model_arms | has($k)' 2>/dev/null || echo "false")
            if [[ "$existing" != "true" ]]; then
                state=$(echo "$state" | jq --arg k "$key" \
                    '.model_arms[$k] = {"alpha": 1, "beta": 1, "pulls": 0, "successes": 0}')
            fi
        done
    done

    # Initialize template arms: issue_type × template
    local itype tmpl
    for itype in "${types_arr[@]}"; do
        for tmpl in "${templates_arr[@]}"; do
            key="$(_arm_key "$itype" "$tmpl")"
            existing=$(echo "$state" | jq -r --arg k "$key" '.template_arms | has($k)' 2>/dev/null || echo "false")
            if [[ "$existing" != "true" ]]; then
                state=$(echo "$state" | jq --arg k "$key" \
                    '.template_arms[$k] = {"alpha": 1, "beta": 1, "pulls": 0, "successes": 0}')
            fi
        done
    done

    # Add metadata
    state=$(echo "$state" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '. + {"initialized_at": $ts, "version": "3.2.4"}')

    _bandit_write_state "$state"
    info "Bandit arms initialized ($(echo "$state" | jq '.model_arms | length') model, $(echo "$state" | jq '.template_arms | length') template)"
}

# Select model for a given stage via Thompson sampling.
# Usage: bandit_select_model <stage> [models_csv]
# Output: model_name (to stdout)
# Returns 0 on success, 1 on error.
bandit_select_model() {
    local stage="${1:-build}"
    local models_csv="${2:-$BANDIT_MODELS}"

    local state
    state="$(_bandit_read_state)"

    # Check if state has model_arms
    local has_arms
    has_arms=$(echo "$state" | jq -r 'has("model_arms")' 2>/dev/null || echo "false")
    if [[ "$has_arms" != "true" ]]; then
        # Auto-init if missing
        bandit_init >/dev/null 2>&1
        state="$(_bandit_read_state)"
    fi

    local IFS_OLD="$IFS"
    IFS=','
    local models_arr=($models_csv)
    IFS="$IFS_OLD"

    local best_model="" best_sample="-1"
    local model key alpha beta sample

    for model in "${models_arr[@]}"; do
        key="$(_arm_key "$stage" "$model")"
        alpha=$(echo "$state" | jq -r --arg k "$key" '.model_arms[$k].alpha // 1' 2>/dev/null)
        beta=$(echo "$state" | jq -r --arg k "$key" '.model_arms[$k].beta // 1' 2>/dev/null)
        sample=$(_beta_sample "$alpha" "$beta")

        # Compare floats in awk
        local is_better
        is_better=$(awk -v s="$sample" -v b="$best_sample" 'BEGIN { print (s > b) ? "1" : "0" }')
        if [[ "$is_better" == "1" ]]; then
            best_sample="$sample"
            best_model="$model"
        fi
    done

    if [[ -z "$best_model" ]]; then
        # Fallback to first model
        best_model="${models_arr[0]}"
    fi

    echo "$best_model"
}

# Select template for a given issue type via Thompson sampling.
# Usage: bandit_select_template <issue_type> [templates_csv]
# Output: template_name (to stdout)
bandit_select_template() {
    local issue_type="${1:-bug}"
    local templates_csv="${2:-$BANDIT_TEMPLATES}"

    local state
    state="$(_bandit_read_state)"

    local has_arms
    has_arms=$(echo "$state" | jq -r 'has("template_arms")' 2>/dev/null || echo "false")
    if [[ "$has_arms" != "true" ]]; then
        bandit_init >/dev/null 2>&1
        state="$(_bandit_read_state)"
    fi

    local IFS_OLD="$IFS"
    IFS=','
    local templates_arr=($templates_csv)
    IFS="$IFS_OLD"

    local best_template="" best_sample="-1"
    local tmpl key alpha beta sample

    for tmpl in "${templates_arr[@]}"; do
        key="$(_arm_key "$issue_type" "$tmpl")"
        alpha=$(echo "$state" | jq -r --arg k "$key" '.template_arms[$k].alpha // 1' 2>/dev/null)
        beta=$(echo "$state" | jq -r --arg k "$key" '.template_arms[$k].beta // 1' 2>/dev/null)
        sample=$(_beta_sample "$alpha" "$beta")

        local is_better
        is_better=$(awk -v s="$sample" -v b="$best_sample" 'BEGIN { print (s > b) ? "1" : "0" }')
        if [[ "$is_better" == "1" ]]; then
            best_sample="$sample"
            best_template="$tmpl"
        fi
    done

    if [[ -z "$best_template" ]]; then
        best_template="${templates_arr[0]}"
    fi

    echo "$best_template"
}

# Update arm after pipeline completion.
# Usage: bandit_update <arm_type> <key> <outcome>
#   arm_type: "model" or "template"
#   key: e.g. "build:opus" or "bug:fast"
#   outcome: "success" or "failure"
bandit_update() {
    local arm_type="${1:-model}"
    local key="${2:-}"
    local outcome="${3:-failure}"

    if [[ -z "$key" ]]; then
        error "bandit_update: arm key required"
        return 1
    fi

    local state
    state="$(_bandit_read_state)"

    local section
    if [[ "$arm_type" == "model" ]]; then
        section="model_arms"
    else
        section="template_arms"
    fi

    # Check arm exists
    local arm_exists
    arm_exists=$(echo "$state" | jq -r --arg s "$section" --arg k "$key" '.[$s] | has($k)' 2>/dev/null || echo "false")
    if [[ "$arm_exists" != "true" ]]; then
        # Create arm on the fly with Beta(1,1)
        state=$(echo "$state" | jq --arg s "$section" --arg k "$key" \
            '.[$s][$k] = {"alpha": 1, "beta": 1, "pulls": 0, "successes": 0}')
    fi

    # Update based on outcome
    if [[ "$outcome" == "success" ]]; then
        state=$(echo "$state" | jq --arg s "$section" --arg k "$key" \
            '.[$s][$k].alpha += 1 | .[$s][$k].pulls += 1 | .[$s][$k].successes += 1')
    else
        state=$(echo "$state" | jq --arg s "$section" --arg k "$key" \
            '.[$s][$k].beta += 1 | .[$s][$k].pulls += 1')
    fi

    # Add last_updated timestamp
    state=$(echo "$state" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '. + {"last_updated": $ts}')

    _bandit_write_state "$state"
}

# Return exploration rate for a given arm set.
# Exploration rate = proportion of arms where pulls < threshold (default 10).
# As arms accumulate data, exploration naturally decreases.
# Usage: bandit_explore_rate [arm_type] [threshold]
# Output: float between 0 and 1
bandit_explore_rate() {
    local arm_type="${1:-model}"
    local threshold="${2:-10}"

    local state
    state="$(_bandit_read_state)"

    local section
    if [[ "$arm_type" == "model" ]]; then
        section="model_arms"
    else
        section="template_arms"
    fi

    echo "$state" | jq -r --arg s "$section" --arg t "$threshold" '
        .[$s] // {} | to_entries |
        if length == 0 then "1.0000"
        else
            (map(select(.value.pulls < ($t | tonumber))) | length) as $under |
            (length) as $total |
            ($under / $total) | tostring | .[0:6]
        end
    ' 2>/dev/null || echo "1.0000"
}

# Show arm statistics with success rates.
# Usage: bandit_report [arm_type] [filter_prefix]
bandit_report() {
    local arm_type="${1:-model}"
    local filter_prefix="${2:-}"

    local state
    state="$(_bandit_read_state)"

    local section
    if [[ "$arm_type" == "model" ]]; then
        section="model_arms"
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║  Model Arm Statistics                                       ║"
        echo "╚═══════════════════════════════════════════════════════════════╝"
    else
        section="template_arms"
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║  Template Arm Statistics                                    ║"
        echo "╚═══════════════════════════════════════════════════════════════╝"
    fi

    local jq_filter
    if [[ -n "$filter_prefix" ]]; then
        jq_filter='.[$s] // {} | to_entries | map(select(.key | startswith($p)))'
    else
        jq_filter='.[$s] // {} | to_entries'
    fi

    # Get sorted arms (by success rate descending)
    local arms_json
    arms_json=$(echo "$state" | jq -r --arg s "$section" --arg p "$filter_prefix" "
        $jq_filter |
        sort_by(-(.value.successes / ([.value.pulls, 1] | max))) |
        .[] |
        .key + \"|\" +
        (.value.alpha | tostring) + \"|\" +
        (.value.beta | tostring) + \"|\" +
        (.value.pulls | tostring) + \"|\" +
        (.value.successes | tostring)
    " 2>/dev/null || true)

    if [[ -z "$arms_json" ]]; then
        echo "  No arms found."
        return 0
    fi

    local first=1
    echo ""
    printf "  %-25s %8s %8s %8s %10s\n" "Arm" "α" "β" "Pulls" "Success%"
    printf "  %-25s %8s %8s %8s %10s\n" "-------------------------" "--------" "--------" "--------" "----------"

    echo "$arms_json" | while IFS='|' read -r key alpha beta pulls successes; do
        local rate
        if [[ "$pulls" -gt 0 ]]; then
            rate=$(awk -v s="$successes" -v p="$pulls" 'BEGIN { printf "%.1f%%", (s/p)*100 }')
        else
            rate="N/A"
        fi
        local marker=""
        if [[ "$first" -eq 1 ]] && [[ "$pulls" -gt 0 ]]; then
            marker=" ★"
            first=0
        fi
        printf "  %-25s %8s %8s %8s %10s%s\n" "$key" "$alpha" "$beta" "$pulls" "$rate" "$marker"
    done

    echo ""
    local explore_rate
    explore_rate=$(bandit_explore_rate "$arm_type")
    echo "  Exploration rate: $explore_rate"
}

# Get arm statistics as JSON for a specific arm.
# Usage: bandit_get_arm <arm_type> <key>
bandit_get_arm() {
    local arm_type="${1:-model}"
    local key="${2:-}"

    local state
    state="$(_bandit_read_state)"

    local section
    if [[ "$arm_type" == "model" ]]; then
        section="model_arms"
    else
        section="template_arms"
    fi

    echo "$state" | jq -r --arg s "$section" --arg k "$key" '.[$s][$k] // empty' 2>/dev/null
}

# Reset a specific arm back to Beta(1,1).
# Usage: bandit_reset_arm <arm_type> <key>
bandit_reset_arm() {
    local arm_type="${1:-model}"
    local key="${2:-}"

    local state
    state="$(_bandit_read_state)"

    local section
    if [[ "$arm_type" == "model" ]]; then
        section="model_arms"
    else
        section="template_arms"
    fi

    state=$(echo "$state" | jq --arg s "$section" --arg k "$key" \
        '.[$s][$k] = {"alpha": 1, "beta": 1, "pulls": 0, "successes": 0}')

    _bandit_write_state "$state"
}
