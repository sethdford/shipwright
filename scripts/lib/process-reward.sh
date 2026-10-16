#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_PROCESS_REWARD_LOADED:-}" ]] && return 0
_PROCESS_REWARD_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright process-reward — Per-Step Iteration Scoring (Phase 3)       ║
# ║  Score each loop iteration on 5 dimensions for dense learning signals   ║
# ║  Weights: test_progress 30%, code_quality 25%, convergence 20%,         ║
# ║           architecture 15%, security 10%                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="3.3.0"

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

PROCESS_REWARD_FILE="${PROCESS_REWARD_FILE:-.claude/pipeline-artifacts/process-rewards.jsonl}"

# Dimension weights (must sum to 100)
REWARD_WEIGHT_TEST="${REWARD_WEIGHT_TEST:-30}"
REWARD_WEIGHT_CODE="${REWARD_WEIGHT_CODE:-25}"
REWARD_WEIGHT_CONVERGENCE="${REWARD_WEIGHT_CONVERGENCE:-20}"
REWARD_WEIGHT_ARCH="${REWARD_WEIGHT_ARCH:-15}"
REWARD_WEIGHT_SECURITY="${REWARD_WEIGHT_SECURITY:-10}"

# ─── Dimension Scorers ──────────────────────────────────────────────────────

# Score test progress (0-100)
# Inputs: test_passed (true/false/""), test_output, previous test state
_reward_score_test_progress() {
    local test_passed="${1:-}"
    local test_output="${2:-}"
    local prev_passed="${3:-}"
    local score=50  # neutral default

    # No test command — return neutral
    if [[ -z "$test_passed" ]]; then
        echo "$score"
        return 0
    fi

    if [[ "$test_passed" == "true" ]]; then
        score=90
        # Bonus if previously failing
        if [[ "$prev_passed" == "false" ]]; then
            score=100
        fi
    elif [[ "$test_passed" == "false" ]]; then
        score=20
        # Check if test count improved (partial progress)
        local pass_count=0
        if [[ -n "$test_output" ]]; then
            pass_count=$(echo "$test_output" | grep -ciE '(pass|passed|ok|✓)' || true)
            pass_count="${pass_count:-0}"
        fi
        if [[ "$pass_count" -gt 0 ]]; then
            # Some tests passing — partial credit
            score=40
        fi
        # Previously also failing — at least not regressing
        if [[ "$prev_passed" == "false" ]]; then
            score=$(( score + 5 ))
        fi
    fi

    echo "$score"
}

# Score code quality (0-100)
# Checks: diff size, duplication, complexity indicators
_reward_score_code_quality() {
    local project_root="${1:-.}"
    local score=70  # default: decent

    # Check recent diff for quality signals
    local diff_text
    diff_text=$(git -C "$project_root" diff HEAD~1 --unified=0 2>/dev/null || true)

    if [[ -z "$diff_text" ]]; then
        echo "$score"
        return 0
    fi

    # Count additions and deletions
    local additions deletions
    additions=$(echo "$diff_text" | grep -c '^+[^+]' || true)
    additions="${additions:-0}"
    deletions=$(echo "$diff_text" | grep -c '^-[^-]' || true)
    deletions="${deletions:-0}"

    # Penalize very large diffs (>500 lines added = likely unfocused)
    if [[ "$additions" -gt 500 ]]; then
        score=$(( score - 15 ))
    elif [[ "$additions" -gt 200 ]]; then
        score=$(( score - 5 ))
    fi

    # Reward cleanup (more deletions than additions)
    if [[ "$deletions" -gt "$additions" ]] && [[ "$additions" -gt 0 ]]; then
        score=$(( score + 10 ))
    fi

    # Check for TODO/FIXME/HACK in new code
    local hack_count
    hack_count=$(echo "$diff_text" | grep -c '^+.*\(TODO\|FIXME\|HACK\|XXX\)' || true)
    hack_count="${hack_count:-0}"
    if [[ "$hack_count" -gt 3 ]]; then
        score=$(( score - 10 ))
    elif [[ "$hack_count" -gt 0 ]]; then
        score=$(( score - 5 ))
    fi

    # Check for debug/console statements left in
    local debug_count
    debug_count=$(echo "$diff_text" | grep -c '^+.*\(console\.log\|debugger\|print(\|echo "DEBUG\)' || true)
    debug_count="${debug_count:-0}"
    if [[ "$debug_count" -gt 0 ]]; then
        score=$(( score - 10 ))
    fi

    # Clamp 0-100
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100

    echo "$score"
}

# Score convergence (0-100)
# Is the diff getting smaller? Are we approaching the goal?
_reward_score_convergence() {
    local iteration="${1:-1}"
    local project_root="${2:-.}"
    local reward_file="${3:-$PROCESS_REWARD_FILE}"
    local score=50  # neutral default

    # First iteration — no history to compare
    if [[ "$iteration" -le 1 ]]; then
        echo "60"
        return 0
    fi

    # Get current diff stat
    local current_diff_lines
    current_diff_lines=$(git -C "$project_root" diff HEAD~1 --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | head -2 | paste -sd+ - | bc 2>/dev/null || echo "0")
    current_diff_lines="${current_diff_lines:-0}"

    # Get previous iteration's convergence score from reward history
    local prev_convergence
    prev_convergence=$(tail -1 "$reward_file" 2>/dev/null | jq -r '.scores.convergence // 50' 2>/dev/null || echo "50")

    # Smaller diffs = more convergent (likely finishing touches)
    if [[ "$current_diff_lines" -lt 20 ]]; then
        score=85
    elif [[ "$current_diff_lines" -lt 50 ]]; then
        score=70
    elif [[ "$current_diff_lines" -lt 100 ]]; then
        score=55
    elif [[ "$current_diff_lines" -lt 300 ]]; then
        score=40
    else
        score=25
    fi

    # Bonus for sustained convergence trend
    if [[ "$prev_convergence" -ge 70 ]] && [[ "$score" -ge 70 ]]; then
        score=$(( score + 10 ))
    fi

    # Clamp 0-100
    [[ "$score" -gt 100 ]] && score=100

    echo "$score"
}

# Score architecture adherence (0-100)
# Check naming, file placement, patterns
_reward_score_architecture() {
    local project_root="${1:-.}"
    local score=80  # default: good

    # Get list of files changed in last commit
    local changed_files
    changed_files=$(git -C "$project_root" diff --name-only HEAD~1 2>/dev/null || true)

    if [[ -z "$changed_files" ]]; then
        echo "$score"
        return 0
    fi

    # Check for test files alongside source (good practice)
    local has_test=false
    if echo "$changed_files" | grep >/dev/null -E '(test|spec|_test\.)'; then
        has_test=true
        score=$(( score + 10 ))
    fi

    # Penalize changes to too many directories (unfocused)
    local dir_count
    dir_count=$(echo "$changed_files" | sed 's|/[^/]*$||' | sort -u | wc -l | tr -d ' ')
    dir_count="${dir_count:-0}"
    if [[ "$dir_count" -gt 10 ]]; then
        score=$(( score - 15 ))
    elif [[ "$dir_count" -gt 5 ]]; then
        score=$(( score - 5 ))
    fi

    # Check architecture rules file if it exists
    local repo_hash
    repo_hash=$(echo -n "$project_root" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_file="${HOME}/.shipwright/memory/${repo_hash}/architecture.json"
    if [[ -f "$arch_file" ]]; then
        # Check if any rules are violated (simple heuristic: file in wrong layer)
        local violations
        violations=$(jq -r '.rules[]? // empty' "$arch_file" 2>/dev/null | wc -l | tr -d ' ')
        # Having rules is good — we can only check heuristically here
        score=$(( score + 5 ))
    fi

    # Clamp 0-100
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100

    echo "$score"
}

# Score security (0-100)
# Grep for obvious issues in new code
_reward_score_security() {
    local project_root="${1:-.}"
    local score=90  # default: no issues

    local diff_text
    diff_text=$(git -C "$project_root" diff HEAD~1 2>/dev/null || true)

    if [[ -z "$diff_text" ]]; then
        echo "$score"
        return 0
    fi

    # Only check added lines
    local added_lines
    added_lines=$(echo "$diff_text" | grep '^+[^+]' || true)

    if [[ -z "$added_lines" ]]; then
        echo "$score"
        return 0
    fi

    # Check for hardcoded secrets patterns
    local secret_count
    secret_count=$(echo "$added_lines" | grep -ciE '(password\s*=\s*["\x27][^"\x27]+|api_key\s*=\s*["\x27]|secret\s*=\s*["\x27][^"\x27]+|token\s*=\s*["\x27][A-Za-z0-9])' || true)
    secret_count="${secret_count:-0}"
    if [[ "$secret_count" -gt 0 ]]; then
        score=$(( score - 30 ))
    fi

    # Check for eval/exec usage
    local eval_count
    eval_count=$(echo "$added_lines" | grep -cE '(^|\s)(eval|exec)\s' || true)
    eval_count="${eval_count:-0}"
    if [[ "$eval_count" -gt 0 ]]; then
        score=$(( score - 15 ))
    fi

    # Check for SQL injection patterns (string concat in queries)
    local sql_count
    sql_count=$(echo "$added_lines" | grep -ciE '(query\(.*\+|execute\(.*\+|sql.*\+.*\$)' || true)
    sql_count="${sql_count:-0}"
    if [[ "$sql_count" -gt 0 ]]; then
        score=$(( score - 20 ))
    fi

    # Check for command injection patterns
    local cmd_count
    cmd_count=$(echo "$added_lines" | grep -cE 'system\(\s*\$|`\$|exec\(\s*\$' || true)
    cmd_count="${cmd_count:-0}"
    if [[ "$cmd_count" -gt 0 ]]; then
        score=$(( score - 20 ))
    fi

    # Clamp 0-100
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100

    echo "$score"
}

# ─── Core Functions ──────────────────────────────────────────────────────────

# Score a completed iteration on all 5 dimensions
# Returns JSON: {"composite":N, "scores":{"test_progress":N,...}}
process_reward_score_iteration() {
    local iteration="${1:-1}"
    local test_passed="${2:-}"
    local test_output="${3:-}"
    local prev_test_passed="${4:-}"
    local project_root="${5:-.}"

    local test_score code_score conv_score arch_score sec_score

    test_score=$(_reward_score_test_progress "$test_passed" "$test_output" "$prev_test_passed")
    code_score=$(_reward_score_code_quality "$project_root")
    conv_score=$(_reward_score_convergence "$iteration" "$project_root" "$PROCESS_REWARD_FILE")
    arch_score=$(_reward_score_architecture "$project_root")
    sec_score=$(_reward_score_security "$project_root")

    # Weighted composite (integer math — multiply by weight then divide by 100)
    local composite
    composite=$(( (test_score * REWARD_WEIGHT_TEST + code_score * REWARD_WEIGHT_CODE + conv_score * REWARD_WEIGHT_CONVERGENCE + arch_score * REWARD_WEIGHT_ARCH + sec_score * REWARD_WEIGHT_SECURITY) / 100 ))

    # Clamp
    [[ "$composite" -lt 0 ]] && composite=0
    [[ "$composite" -gt 100 ]] && composite=100

    # Return as JSON
    printf '{"composite":%d,"scores":{"test_progress":%d,"code_quality":%d,"convergence":%d,"architecture":%d,"security":%d}}' \
        "$composite" "$test_score" "$code_score" "$conv_score" "$arch_score" "$sec_score"
}

# Record iteration reward data to JSONL file
process_reward_record() {
    local iteration="${1:-1}"
    local scores_json="${2:-"{}"}"
    local action_taken="${3:-unknown}"
    local outcome="${4:-unknown}"

    # Ensure directory exists
    local reward_dir
    reward_dir=$(dirname "$PROCESS_REWARD_FILE")
    mkdir -p "$reward_dir" 2>/dev/null || true

    local timestamp
    timestamp=$(now_iso)

    # Build record using jq for safe JSON construction
    local record
    record=$(jq -c -n \
        --arg ts "$timestamp" \
        --argjson iter "$iteration" \
        --argjson scores "$scores_json" \
        --arg action "$action_taken" \
        --arg outcome "$outcome" \
        '{timestamp: $ts, iteration: $iter, scores: $scores, action: $action, outcome: $outcome}' 2>/dev/null)

    if [[ -z "$record" ]]; then
        warn "process-reward: failed to build JSON record"
        return 1
    fi

    # Atomic write via temp file + mv
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/process-reward-$$.tmp")
    if [[ -f "$PROCESS_REWARD_FILE" ]]; then
        cat "$PROCESS_REWARD_FILE" > "$tmp_file"
    fi
    echo "$record" >> "$tmp_file"
    mv "$tmp_file" "$PROCESS_REWARD_FILE"

    emit_event "process_reward.recorded" "iteration=$iteration" "composite=$(echo "$scores_json" | jq -r '.composite // 0' 2>/dev/null || echo 0)"
}

# Suggest next action based on reward trajectory (last 3 iterations)
process_reward_suggest_action() {
    local reward_file="${1:-$PROCESS_REWARD_FILE}"

    if [[ ! -f "$reward_file" ]]; then
        echo "No reward history yet — proceed with the goal."
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$reward_file" 2>/dev/null | tr -d ' ')
    line_count="${line_count:-0}"

    if [[ "$line_count" -lt 2 ]]; then
        echo "Not enough history for suggestions — keep working on the goal."
        return 0
    fi

    # Get last 3 records
    local recent
    recent=$(tail -3 "$reward_file")

    # Extract composite scores
    local composites
    composites=$(echo "$recent" | jq -r '.scores.composite // .composite // 0' 2>/dev/null || true)

    # Extract dimension scores from latest
    local latest
    latest=$(echo "$recent" | tail -1)
    local test_score code_score conv_score
    test_score=$(echo "$latest" | jq -r '.scores.test_progress // 50' 2>/dev/null || echo "50")
    code_score=$(echo "$latest" | jq -r '.scores.code_quality // 50' 2>/dev/null || echo "50")
    conv_score=$(echo "$latest" | jq -r '.scores.convergence // 50' 2>/dev/null || echo "50")

    # Check for declining trend
    local first_score last_score
    first_score=$(echo "$composites" | head -1)
    first_score="${first_score:-50}"
    last_score=$(echo "$composites" | tail -1)
    last_score="${last_score:-50}"

    # Decision logic
    if [[ "$test_score" -le 30 ]]; then
        echo "Tests are failing badly (score: ${test_score}/100). Focus on making tests pass before anything else."
        return 0
    fi

    if [[ "$code_score" -le 40 ]]; then
        echo "Code quality is low (score: ${code_score}/100). Refactor and clean up before adding more features."
        return 0
    fi

    if [[ "$conv_score" -le 30 ]]; then
        echo "Changes are diverging, not converging (score: ${conv_score}/100). Make smaller, more focused changes."
        return 0
    fi

    if [[ "$last_score" -lt "$first_score" ]] && [[ $(( first_score - last_score )) -ge 10 ]]; then
        echo "Reward trajectory is declining (${first_score} -> ${last_score}). Try a different approach — current strategy is making things worse."
        return 0
    fi

    if [[ "$last_score" -ge 80 ]]; then
        echo "Strong progress (score: ${last_score}/100). Keep the current approach — you're converging well."
        return 0
    fi

    echo "Moderate progress (score: ${last_score}/100). Continue working toward the goal."
}

# Format reward history as markdown for injection into iteration prompts
process_reward_inject_context() {
    local reward_file="${1:-$PROCESS_REWARD_FILE}"
    local max_entries="${2:-5}"

    if [[ ! -f "$reward_file" ]]; then
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$reward_file" 2>/dev/null | tr -d ' ')
    line_count="${line_count:-0}"

    if [[ "$line_count" -eq 0 ]]; then
        return 0
    fi

    local recent
    recent=$(tail -"$max_entries" "$reward_file")

    local output="## Iteration Rewards (Process Reward Model)
| Iter | Composite | Test | Quality | Converge | Arch | Security |
|------|-----------|------|---------|----------|------|----------|"

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local iter comp ts cs cvs as ss
        iter=$(echo "$line" | jq -r '.iteration // "?"' 2>/dev/null || echo "?")
        comp=$(echo "$line" | jq -r '.scores.composite // .composite // "?"' 2>/dev/null || echo "?")
        ts=$(echo "$line" | jq -r '.scores.test_progress // "?"' 2>/dev/null || echo "?")
        cs=$(echo "$line" | jq -r '.scores.code_quality // "?"' 2>/dev/null || echo "?")
        cvs=$(echo "$line" | jq -r '.scores.convergence // "?"' 2>/dev/null || echo "?")
        as=$(echo "$line" | jq -r '.scores.architecture // "?"' 2>/dev/null || echo "?")
        ss=$(echo "$line" | jq -r '.scores.security // "?"' 2>/dev/null || echo "?")
        output="${output}
| ${iter} | ${comp} | ${ts} | ${cs} | ${cvs} | ${as} | ${ss} |"
    done <<< "$recent"

    # Add suggestion
    local suggestion
    suggestion=$(process_reward_suggest_action "$reward_file")
    if [[ -n "$suggestion" ]]; then
        output="${output}

**Reward signal:** ${suggestion}"
    fi

    echo "$output"
}
