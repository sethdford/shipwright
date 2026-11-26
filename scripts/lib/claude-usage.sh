#!/usr/bin/env bash
# Module: claude-usage
# Token and USD accounting for claude CLI calls made by pipeline stages. Sourced by every stage module
# that calls claude, so a stage cannot run without it (a missing parser used to mean $0, silently).
[[ -n "${_CLAUDE_USAGE_LOADED:-}" ]] && return 0
_CLAUDE_USAGE_LOADED=1
SW_AGENT_EXEC="${SW_AGENT_EXEC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh}"

# The claude CLI reports usage only in its JSON output (`--output-format json`): one result object,
# or an array of messages ending in one with --verbose. Text mode prints no usage on stdout or
# stderr, so a stage that runs in text mode costs nothing in the ledger. Stages run through
# claude_run_json below; parse_claude_tokens accepts that JSON and still takes legacy text logs.

# _add_usd A B — prints A + B (decimal USD; empty or non-numeric counts as 0).
_add_usd() {
    awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if (a !~ /^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) a = 0;
        if (b !~ /^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) b = 0; printf "%.6f", a + b }'
}

# _usd_positive V — exit 0 when V is a number above zero.
_usd_positive() {
    awk -v v="${1:-0}" 'BEGIN{ exit !(v ~ /^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/ && v + 0 > 0) }'
}

# parse_claude_usage FILE — adds a claude JSON result's tokens and total_cost_usd to the run totals.
# Input tokens include cache reads and writes (they are billed input). Returns 1 when FILE holds no
# JSON result, so the caller can fall back to text parsing.
parse_claude_usage() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local row
    row=$(jq -r '
        (if type == "array" then (map(select(type == "object" and .type == "result")) | last)
         elif type == "object" then . else null end) as $r
        | if $r == null or ($r.usage | type) != "object" then empty else
          [ (($r.usage.input_tokens // 0) + ($r.usage.cache_read_input_tokens // 0)
             + ($r.usage.cache_creation_input_tokens // 0)),
            ($r.usage.output_tokens // 0),
            ($r.total_cost_usd // 0) ] | map(tostring) | join(" ") end' "$file" 2>/dev/null) || return 1
    [[ -n "$row" ]] || return 1
    local in_tok out_tok usd
    read -r in_tok out_tok usd <<< "$row"
    [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
    [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
    TOTAL_INPUT_TOKENS=$(( ${TOTAL_INPUT_TOKENS:-0} + in_tok ))
    TOTAL_OUTPUT_TOKENS=$(( ${TOTAL_OUTPUT_TOKENS:-0} + out_tok ))
    TOTAL_COST_USD=$(_add_usd "${TOTAL_COST_USD:-0}" "$usd")
    return 0
}

# claude_run_json OUT_FILE USAGE_FILE ERR_FILE CLAUDE_ARGS... — runs `claude CLAUDE_ARGS...` through
# agent-exec with --output-format json, keeps the raw JSON in USAGE_FILE, writes the result text to
# OUT_FILE ("-" for stdout, as text mode would print it), and adds the usage to the run totals.
# Output that is not JSON (an auth error, a stub) is passed through unchanged. Returns claude's status.
claude_run_json() {
    local out_file="$1" usage_file="$2" err_file="$3"
    shift 3
    local rc=0
    "$SW_AGENT_EXEC" claude --output-format json "$@" < /dev/null > "$usage_file" 2>"$err_file" || rc=$?
    local text=""
    local first=""
    first=$(head -c1 "$usage_file" 2>/dev/null || true)
    if [[ ( "$first" == "{" || "$first" == "[" ) ]] && command -v jq >/dev/null 2>&1 \
        && text=$(jq -r 'if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end
                         | .result // empty' "$usage_file" 2>/dev/null); then
        parse_claude_usage "$usage_file" || true
    else
        text=$(cat "$usage_file" 2>/dev/null || true)
    fi
    if [[ "$out_file" == "-" ]]; then
        printf '%s\n' "$text"
    else
        printf '%s\n' "$text" > "$out_file"
    fi
    return "$rc"
}

# _pipeline_add_loop_tokens FILE: adds the build loop's totals (loop-tokens.json from sw-loop) to the
# pipeline totals. The loop's USD is added to the spend of earlier stages, never substituted for it.
_pipeline_add_loop_tokens() {
    local file="$1"
    [[ -f "$file" ]] && command -v jq >/dev/null 2>&1 || return 0
    local _loop_in _loop_out _loop_cost
    _loop_in=$(jq -r '.input_tokens // 0' "$file" 2>/dev/null || echo "0")
    _loop_out=$(jq -r '.output_tokens // 0' "$file" 2>/dev/null || echo "0")
    _loop_cost=$(jq -r '.cost_usd // 0' "$file" 2>/dev/null || echo "0")
    [[ "$_loop_in" =~ ^[0-9]+$ ]] || _loop_in=0
    [[ "$_loop_out" =~ ^[0-9]+$ ]] || _loop_out=0
    TOTAL_INPUT_TOKENS=$(( ${TOTAL_INPUT_TOKENS:-0} + _loop_in ))
    TOTAL_OUTPUT_TOKENS=$(( ${TOTAL_OUTPUT_TOKENS:-0} + _loop_out ))
    TOTAL_COST_USD=$(_add_usd "${TOTAL_COST_USD:-0}" "$_loop_cost")
    if [[ "$_loop_in" -gt 0 || "$_loop_out" -gt 0 ]]; then
        info "Build loop tokens: in=${_loop_in} out=${_loop_out} cost=\$${_loop_cost}"
    fi
    return 0
}

# ─── Build loop (sw-loop) ──────────────────────────────────────────────────
# Parse token counts from Claude CLI JSON output and accumulate running totals.
# `claude -p --output-format json` prints ONE result object; with --verbose it prints an array whose
# last "result" element carries the totals. Both hold usage.{input,output,cache_*}_tokens and
# total_cost_usd. Only the array form used to be parsed, so every plain run recorded 0 tokens and $0.
accumulate_loop_tokens() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return 0

    local first_char
    first_char=$(head -c1 "$log_file" 2>/dev/null || true)
    local row=""
    if command -v jq >/dev/null 2>&1 && [[ "$first_char" == "[" || "$first_char" == "{" ]]; then
        row=$(jq -r '
            (if type == "array" then (map(select(type == "object" and .type == "result")) | last)
             else . end) as $r
            | if $r == null or ($r.usage | type) != "object" then empty else
              [ ($r.usage.input_tokens // 0), ($r.usage.output_tokens // 0),
                ($r.usage.cache_read_input_tokens // 0), ($r.usage.cache_creation_input_tokens // 0),
                ($r.total_cost_usd // 0) ] | map(tostring) | join(" ") end' "$log_file" 2>/dev/null || true)
    fi

    if [[ -n "$row" ]]; then
        local input_tok output_tok cache_read cache_create cost_usd
        read -r input_tok output_tok cache_read cache_create cost_usd <<< "$row"
        [[ "$input_tok" =~ ^[0-9]+$ ]] || input_tok=0
        [[ "$output_tok" =~ ^[0-9]+$ ]] || output_tok=0
        [[ "$cache_read" =~ ^[0-9]+$ ]] || cache_read=0
        [[ "$cache_create" =~ ^[0-9]+$ ]] || cache_create=0

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + input_tok + cache_read + cache_create ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + output_tok ))
        # Accumulate cost in millicents for integer arithmetic
        local cost_millicents
        if awk -v v="$cost_usd" 'BEGIN{ exit !(v ~ /^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/ && v + 0 > 0) }'; then
            cost_millicents=$(awk -v v="$cost_usd" 'BEGIN{printf "%.0f", v * 100000}' 2>/dev/null || echo "0")
        else
            # Estimate from tokens when Claude reports no cost (USD per million tokens; cache reads
            # bill at 0.1x input, cache writes at 1.25x). Keep in step with sw-cost.sh defaults.
            local in_rate out_rate cost
            case "${MODEL:-${CLAUDE_MODEL:-sonnet}}" in
                *opus*)  in_rate=5;  out_rate=25 ;;
                *haiku*) in_rate=1;  out_rate=5 ;;
                *)       in_rate=3;  out_rate=15 ;;
            esac
            cost=$(awk -v i="$input_tok" -v cr="$cache_read" -v cc="$cache_create" -v o="$output_tok" \
                -v ir="$in_rate" -v orate="$out_rate" \
                'BEGIN{printf "%.6f", ((i + cc * 1.25 + cr * 0.1) * ir + o * orate) / 1000000}')
            cost_millicents=$(awk -v v="$cost" 'BEGIN{printf "%.0f", v * 100000}' 2>/dev/null || echo "0")
        fi
        LOOP_COST_MILLICENTS=$(( ${LOOP_COST_MILLICENTS:-0} + ${cost_millicents:-0} ))
    else
        # Fallback: regex-based parsing for non-JSON output
        local input_tok output_tok
        input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
        output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + ${input_tok:-0} ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + ${output_tok:-0} ))
    fi
}
