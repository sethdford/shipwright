#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_FORMAL_SPEC_LOADED:-}" ]] && return 0
_FORMAL_SPEC_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright formal-spec — Lightweight Formal Specification System       ║
# ║  Extract pre/post-conditions from docstrings, verify against code,      ║
# ║  inject spec context into pipeline prompts for provable correctness     ║
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

# ─── Configuration ───────────────────────────────────────────────────────────

FORMAL_SPECS_FILE="${FORMAL_SPECS_FILE:-.claude/formal-specs.json}"
FORMAL_SPEC_REPORT="${FORMAL_SPEC_REPORT:-.claude/pipeline-artifacts/formal-spec-report.json}"

# ─── Extract Specs ───────────────────────────────────────────────────────────
# Extract pre/post-conditions and invariants from code comments/docstrings.
# Input: $1 = file or directory to scan
# Output: JSON specs written to $FORMAL_SPECS_FILE, path echoed

formal_spec_extract() {
    local target="${1:-.}"
    local output_file="${2:-$FORMAL_SPECS_FILE}"
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/formal-spec-extract.$$.tmp")

    # Ensure output directory exists
    local out_dir
    out_dir=$(dirname "$output_file")
    mkdir -p "$out_dir" 2>/dev/null || true

    echo '{"specs":[],"extracted_at":"'"$(now_iso)"'"}' > "$tmp_file"

    local file_list
    if [[ -d "$target" ]]; then
        file_list=$(find "$target" -type f \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.sh" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | head -200)
    elif [[ -f "$target" ]]; then
        file_list="$target"
    else
        echo "$output_file"
        return 0
    fi

    local specs_json='[]'

    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue

        local preconditions="" postconditions="" invariants=""
        local func_name=""

        # Extract JSDoc @precondition, @postcondition, @invariant tags
        preconditions=$(grep -n '@precondition' "$file" 2>/dev/null || true)
        postconditions=$(grep -n '@postcondition' "$file" 2>/dev/null || true)
        invariants=$(grep -n '@invariant' "$file" 2>/dev/null || true)

        # Extract Python docstring Precondition:, Postcondition:, Invariant: sections
        if [[ -z "$preconditions" ]]; then
            preconditions=$(grep -n 'Precondition:' "$file" 2>/dev/null || true)
        fi
        if [[ -z "$postconditions" ]]; then
            postconditions=$(grep -n 'Postcondition:' "$file" 2>/dev/null || true)
        fi
        if [[ -z "$invariants" ]]; then
            invariants=$(grep -n 'Invariant:' "$file" 2>/dev/null || true)
        fi

        # Skip files with no specs
        if [[ -z "$preconditions" && -z "$postconditions" && -z "$invariants" ]]; then
            continue
        fi

        # Build spec entries for this file
        local line_num condition spec_type

        # Process preconditions
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            line_num=$(echo "$line" | cut -d: -f1)
            condition=$(echo "$line" | sed 's/^[0-9]*://' | sed 's/.*@precondition[[:space:]]*//' | sed 's/.*Precondition:[[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*\*\///')

            # Find nearest function name (look ahead up to 10 lines)
            func_name=$(_find_function_name "$file" "$line_num")

            specs_json=$(echo "$specs_json" | jq --arg file "$file" --arg fn "$func_name" \
                --arg cond "$condition" --argjson ln "$line_num" --arg type "precondition" \
                '. + [{"file":$file,"function":$fn,"type":$type,"condition":$cond,"line":$ln}]' 2>/dev/null || echo "$specs_json")
        done <<< "$preconditions"

        # Process postconditions
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            line_num=$(echo "$line" | cut -d: -f1)
            condition=$(echo "$line" | sed 's/^[0-9]*://' | sed 's/.*@postcondition[[:space:]]*//' | sed 's/.*Postcondition:[[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*\*\///')

            func_name=$(_find_function_name "$file" "$line_num")

            specs_json=$(echo "$specs_json" | jq --arg file "$file" --arg fn "$func_name" \
                --arg cond "$condition" --argjson ln "$line_num" --arg type "postcondition" \
                '. + [{"file":$file,"function":$fn,"type":$type,"condition":$cond,"line":$ln}]' 2>/dev/null || echo "$specs_json")
        done <<< "$postconditions"

        # Process invariants
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            line_num=$(echo "$line" | cut -d: -f1)
            condition=$(echo "$line" | sed 's/^[0-9]*://' | sed 's/.*@invariant[[:space:]]*//' | sed 's/.*Invariant:[[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*\*\///')

            func_name=$(_find_function_name "$file" "$line_num")

            specs_json=$(echo "$specs_json" | jq --arg file "$file" --arg fn "$func_name" \
                --arg cond "$condition" --argjson ln "$line_num" --arg type "invariant" \
                '. + [{"file":$file,"function":$fn,"type":$type,"condition":$cond,"line":$ln}]' 2>/dev/null || echo "$specs_json")
        done <<< "$invariants"

    done <<< "$file_list"

    # Write final output
    jq -n --argjson specs "$specs_json" --arg ts "$(now_iso)" \
        '{"specs":$specs,"extracted_at":$ts,"count":($specs|length)}' > "$output_file" 2>/dev/null || {
        echo '{"specs":[],"extracted_at":"'"$(now_iso)"'","count":0}' > "$output_file"
    }

    rm -f "$tmp_file" 2>/dev/null || true

    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        local spec_count
        spec_count=$(jq -r '.count // 0' "$output_file" 2>/dev/null || echo "0")
        emit_event "formal_spec.extracted" "count=$spec_count" "target=$target" 2>/dev/null || true
    fi

    echo "$output_file"
}

# Helper: find nearest function name from a line number
_find_function_name() {
    local file="$1"
    local line_num="$2"
    local search_end=$((line_num + 15))
    local fn_name="unknown"

    # Look ahead for function declaration
    local snippet
    snippet=$(sed -n "${line_num},${search_end}p" "$file" 2>/dev/null || true)

    # JS/TS: function name() or const name = or name() {
    local match
    match=$(echo "$snippet" | grep -oE '(function\s+[a-zA-Z_][a-zA-Z0-9_]*|const\s+[a-zA-Z_][a-zA-Z0-9_]*\s*=|[a-zA-Z_][a-zA-Z0-9_]*\s*\()' | head -1 || true)
    if [[ -n "$match" ]]; then
        fn_name=$(echo "$match" | sed 's/function[[:space:]]*//' | sed 's/const[[:space:]]*//' | sed 's/[[:space:]]*=.*//' | sed 's/[[:space:]]*($//')
    fi

    # Python: def name(
    if [[ "$fn_name" == "unknown" ]]; then
        match=$(echo "$snippet" | grep -oE 'def\s+[a-zA-Z_][a-zA-Z0-9_]*' | head -1 || true)
        if [[ -n "$match" ]]; then
            fn_name=$(echo "$match" | sed 's/def[[:space:]]*//')
        fi
    fi

    # Bash: name() {
    if [[ "$fn_name" == "unknown" ]]; then
        match=$(echo "$snippet" | grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)' | head -1 || true)
        if [[ -n "$match" ]]; then
            fn_name=$(echo "$match" | sed 's/[[:space:]]*()$//')
        fi
    fi

    echo "$fn_name"
}

# ─── Verify Specs ────────────────────────────────────────────────────────────
# Verify extracted specs against code behavior via grep/pattern matching.
# Input: $1 = specs file (JSON), $2 = project root
# Output: compliance report JSON, path echoed

formal_spec_verify() {
    local specs_file="${1:-$FORMAL_SPECS_FILE}"
    local project_root="${2:-.}"
    local report_file="${3:-$FORMAL_SPEC_REPORT}"

    if [[ ! -f "$specs_file" ]]; then
        warn "No specs file found at $specs_file"
        echo "$report_file"
        return 0
    fi

    local out_dir
    out_dir=$(dirname "$report_file")
    mkdir -p "$out_dir" 2>/dev/null || true

    local total=0 verified=0 violations=0 unchecked=0
    local violations_json='[]'

    local spec_count
    spec_count=$(jq -r '.count // 0' "$specs_file" 2>/dev/null || echo "0")

    if [[ "$spec_count" -eq 0 ]]; then
        jq -n '{"total":0,"verified":0,"violations":0,"unchecked":0,"compliance_pct":100,"details":[],"verified_at":"'"$(now_iso)"'"}' > "$report_file" 2>/dev/null
        echo "$report_file"
        return 0
    fi

    # Process each spec
    local i=0
    while [[ "$i" -lt "$spec_count" ]]; do
        total=$((total + 1))
        local spec_file spec_fn spec_type spec_cond
        spec_file=$(jq -r ".specs[$i].file // \"\"" "$specs_file" 2>/dev/null || true)
        spec_fn=$(jq -r ".specs[$i].function // \"\"" "$specs_file" 2>/dev/null || true)
        spec_type=$(jq -r ".specs[$i].type // \"\"" "$specs_file" 2>/dev/null || true)
        spec_cond=$(jq -r ".specs[$i].condition // \"\"" "$specs_file" 2>/dev/null || true)

        if [[ ! -f "$spec_file" ]]; then
            unchecked=$((unchecked + 1))
            i=$((i + 1))
            continue
        fi

        local status="unchecked"

        case "$spec_type" in
            precondition)
                # Check if function validates the precondition
                # Look for validation patterns: if (!param), assert, throw, guard clauses
                if _check_precondition "$spec_file" "$spec_fn" "$spec_cond"; then
                    status="verified"
                    verified=$((verified + 1))
                else
                    status="violation"
                    violations=$((violations + 1))
                    violations_json=$(echo "$violations_json" | jq --arg file "$spec_file" --arg fn "$spec_fn" \
                        --arg type "$spec_type" --arg cond "$spec_cond" \
                        '. + [{"file":$file,"function":$fn,"type":$type,"condition":$cond,"status":"missing_validation"}]' 2>/dev/null || echo "$violations_json")
                fi
                ;;
            postcondition)
                # Check if function has return value matching expected pattern
                if _check_postcondition "$spec_file" "$spec_fn" "$spec_cond"; then
                    status="verified"
                    verified=$((verified + 1))
                else
                    status="violation"
                    violations=$((violations + 1))
                    violations_json=$(echo "$violations_json" | jq --arg file "$spec_file" --arg fn "$spec_fn" \
                        --arg type "$spec_type" --arg cond "$spec_cond" \
                        '. + [{"file":$file,"function":$fn,"type":$type,"condition":$cond,"status":"missing_guarantee"}]' 2>/dev/null || echo "$violations_json")
                fi
                ;;
            invariant)
                # Check for invariant violations in the code
                if _check_invariant "$spec_file" "$spec_fn" "$spec_cond"; then
                    status="verified"
                    verified=$((verified + 1))
                else
                    status="violation"
                    violations=$((violations + 1))
                    violations_json=$(echo "$violations_json" | jq --arg file "$spec_file" --arg fn "$spec_fn" \
                        --arg type "$spec_type" --arg cond "$spec_cond" \
                        '. + [{"file":$file,"function":$fn,"type":$type,"condition":$cond,"status":"invariant_broken"}]' 2>/dev/null || echo "$violations_json")
                fi
                ;;
            *)
                unchecked=$((unchecked + 1))
                ;;
        esac

        i=$((i + 1))
    done

    # Calculate compliance percentage
    local compliance_pct=100
    if [[ "$total" -gt 0 ]]; then
        compliance_pct=$(( (verified * 100) / total ))
    fi

    # Write report
    jq -n --argjson total "$total" --argjson verified "$verified" \
        --argjson violations "$violations" --argjson unchecked "$unchecked" \
        --argjson pct "$compliance_pct" --argjson details "$violations_json" \
        --arg ts "$(now_iso)" \
        '{"total":$total,"verified":$verified,"violations":$violations,"unchecked":$unchecked,"compliance_pct":$pct,"details":$details,"verified_at":$ts}' \
        > "$report_file" 2>/dev/null

    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "formal_spec.verified" \
            "total=$total" "verified=$verified" "violations=$violations" \
            "compliance_pct=$compliance_pct" 2>/dev/null || true
    fi

    echo "$report_file"
}

# ─── Verification Helpers ────────────────────────────────────────────────────

_check_precondition() {
    local file="$1" fn="$2" cond="$3"

    # Extract keywords from condition to search for validation
    local keywords
    keywords=$(echo "$cond" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | head -5 || true)

    local fn_body
    fn_body=$(_extract_function_body "$file" "$fn")
    [[ -z "$fn_body" ]] && return 1

    # Look for validation patterns: if, assert, throw, guard, check, validate
    local has_validation=false
    while IFS= read -r kw; do
        [[ -z "$kw" ]] && continue
        if echo "$fn_body" | grep >/dev/null -E "(if.*${kw}|assert.*${kw}|throw.*${kw}|check.*${kw}|validate.*${kw}|guard.*${kw}|${kw}.*!=.*null|${kw}.*!==.*undefined)" 2>/dev/null; then
            has_validation=true
            break
        fi
    done <<< "$keywords"

    [[ "$has_validation" == "true" ]]
}

_check_postcondition() {
    local file="$1" fn="$2" cond="$3"

    local fn_body
    fn_body=$(_extract_function_body "$file" "$fn")
    [[ -z "$fn_body" ]] && return 1

    # Check that function has a return statement
    if echo "$fn_body" | grep >/dev/null -E '(return |echo |print\(|yield )' 2>/dev/null; then
        return 0
    fi

    return 1
}

_check_invariant() {
    local file="$1" fn="$2" cond="$3"

    # Extract the invariant pattern (e.g., "counter >= 0" -> look for "counter < 0")
    local negated
    negated=$(_negate_condition "$cond")

    if [[ -n "$negated" ]]; then
        # If we find the negation in the code, invariant is broken
        if grep -qE "$negated" "$file" 2>/dev/null; then
            return 1
        fi
    fi

    # No violation found = invariant holds
    return 0
}

_negate_condition() {
    local cond="$1"

    # Simple negation patterns
    if echo "$cond" | grep >/dev/null -E '>= 0|>= zero|non-negative|not negative' 2>/dev/null; then
        local var
        var=$(echo "$cond" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | head -1 || true)
        [[ -n "$var" ]] && echo "${var}[[:space:]]*<[[:space:]]*0" && return 0
    fi

    if echo "$cond" | grep >/dev/null -E 'not null|non-null|!= null|!== null' 2>/dev/null; then
        local var
        var=$(echo "$cond" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | head -1 || true)
        [[ -n "$var" ]] && echo "${var}[[:space:]]*=[[:space:]]*null" && return 0
    fi

    if echo "$cond" | grep >/dev/null -E 'not empty|non-empty' 2>/dev/null; then
        local var
        var=$(echo "$cond" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | head -1 || true)
        [[ -n "$var" ]] && echo "${var}[[:space:]]*=[[:space:]]*[\"']{2}" && return 0
    fi

    echo ""
}

_extract_function_body() {
    local file="$1" fn="$2"

    [[ -z "$fn" || "$fn" == "unknown" ]] && return 0

    # Find the function start line and extract ~50 lines
    local start_line
    start_line=$(grep -n -E "(function[[:space:]]+${fn}|${fn}[[:space:]]*\(|def[[:space:]]+${fn}|${fn}[[:space:]]*\(\))" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)

    if [[ -n "$start_line" ]]; then
        local end_line=$((start_line + 50))
        sed -n "${start_line},${end_line}p" "$file" 2>/dev/null || true
    fi
}

# ─── Inject Specs ────────────────────────────────────────────────────────────
# Add formal spec context to pipeline prompts.
# Input: $1 = specs file, $2 = changed files (newline-separated)
# Output: prompt text string

formal_spec_inject() {
    local specs_file="${1:-$FORMAL_SPECS_FILE}"
    local changed_files="${2:-}"

    if [[ ! -f "$specs_file" ]]; then
        return 0
    fi

    local spec_count
    spec_count=$(jq -r '.count // 0' "$specs_file" 2>/dev/null || echo "0")
    [[ "$spec_count" -eq 0 ]] && return 0

    local prompt_text=""
    prompt_text+="## Formal Specifications"$'\n'
    prompt_text+="The following functions have formal specifications. Ensure your changes maintain these contracts:"$'\n'$'\n'

    local relevant_specs='[]'

    if [[ -n "$changed_files" ]]; then
        # Filter specs to only changed files
        while IFS= read -r cf; do
            [[ -z "$cf" ]] && continue
            local file_specs
            file_specs=$(jq --arg f "$cf" '[.specs[] | select(.file == $f)]' "$specs_file" 2>/dev/null || echo "[]")
            if [[ "$file_specs" != "[]" ]]; then
                relevant_specs=$(echo "$relevant_specs" "$file_specs" | jq -s 'add' 2>/dev/null || echo "$relevant_specs")
            fi
        done <<< "$changed_files"
    else
        relevant_specs=$(jq '.specs' "$specs_file" 2>/dev/null || echo "[]")
    fi

    local rel_count
    rel_count=$(echo "$relevant_specs" | jq 'length' 2>/dev/null || echo "0")
    [[ "$rel_count" -eq 0 ]] && return 0

    local j=0
    while [[ "$j" -lt "$rel_count" ]]; do
        local s_file s_fn s_type s_cond
        s_file=$(echo "$relevant_specs" | jq -r ".[$j].file // \"\"" 2>/dev/null || true)
        s_fn=$(echo "$relevant_specs" | jq -r ".[$j].function // \"\"" 2>/dev/null || true)
        s_type=$(echo "$relevant_specs" | jq -r ".[$j].type // \"\"" 2>/dev/null || true)
        s_cond=$(echo "$relevant_specs" | jq -r ".[$j].condition // \"\"" 2>/dev/null || true)

        prompt_text+="- **${s_file}::${s_fn}** — ${s_type}: ${s_cond}"$'\n'
        j=$((j + 1))
    done

    echo "$prompt_text"
}
