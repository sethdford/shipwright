#!/usr/bin/env bash
# Module guard - prevent double-sourcing
# Test commands run without credentials (#8608).
# shellcheck source=lib/test-gate-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-gate-env.sh"
[[ -n "${_MUTATION_EXECUTOR_LOADED:-}" ]] && return 0
_MUTATION_EXECUTOR_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright mutation-executor — Real Mutation Testing Engine             ║
# ║  Generate code mutations via sed, run tests against each mutant,        ║
# ║  track killed/survived, report mutation score and weak tests            ║
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

MUTATION_DIR="${MUTATION_DIR:-.claude/mutations}"
MUTATION_REPORT_FILE="${MUTATION_REPORT_FILE:-.claude/pipeline-artifacts/mutation-report.json}"
MUTATION_MAX_MUTANTS="${MUTATION_MAX_MUTANTS:-50}"
MUTATION_TIMEOUT="${MUTATION_TIMEOUT:-60}"

# ─── Generate Mutations ─────────────────────────────────────────────────────
# Generate code mutations for a file using sed-based transformations.
# Input: $1 = source file to mutate
# Output: mutation descriptors in $MUTATION_DIR, count echoed

mutation_generate() {
    local source_file="${1:-}"
    local output_dir="${2:-$MUTATION_DIR}"

    if [[ -z "$source_file" || ! -f "$source_file" ]]; then
        echo "0"
        return 0
    fi

    mkdir -p "$output_dir" 2>/dev/null || true

    local file_hash
    file_hash=$(cksum "$source_file" 2>/dev/null | cut -d' ' -f1 || echo "$$")
    local mutation_count=0

    # ── Mutation operators ──

    # 1. Flip comparisons: == → !=, != → ==, > → <, < → >, >= → <=, <= → >=
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [[ "$mutation_count" -ge "$MUTATION_MAX_MUTANTS" ]] && break

        # Skip comments and strings (heuristic: lines starting with # or //)
        if echo "$line" | grep >/dev/null -E '^\s*(#|//)' 2>/dev/null; then
            continue
        fi

        # == → !=
        if echo "$line" | grep >/dev/null -E '==' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "comparison_flip" "== to !=" \
                "s/==/!=/" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # != → ==
        if echo "$line" | grep >/dev/null -E '!=' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "comparison_flip" "!= to ==" \
                "s/!=/==/" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # >= → <
        if echo "$line" | grep >/dev/null -E '>=' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "boundary_flip" ">= to <" \
                "s/>=/< /" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # <= → >
        if echo "$line" | grep >/dev/null -E '<=' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "boundary_flip" "<= to >" \
                "s/<=/> /" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # && → ||
        if echo "$line" | grep >/dev/null -E '&&' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "logical_flip" "&& to ||" \
                "s/&&/||/" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # || → &&
        if echo "$line" | grep >/dev/null -E '\|\|' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "logical_flip" "|| to &&" \
                "s/||/\&\&/" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # true → false
        if echo "$line" | grep >/dev/null -E '\btrue\b' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "boolean_flip" "true to false" \
                "s/\\btrue\\b/false/" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # false → true
        if echo "$line" | grep >/dev/null -E '\bfalse\b' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "boolean_flip" "false to true" \
                "s/\\bfalse\\b/true/" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

        # + → - (only in arithmetic context, not string concat)
        if echo "$line" | grep >/dev/null -E '[0-9]\s*\+\s*[0-9]' 2>/dev/null; then
            _write_mutation "$output_dir" "$source_file" "$line_num" \
                "arithmetic_flip" "+ to -" \
                "s/+/-/" "$file_hash" "$mutation_count"
            mutation_count=$((mutation_count + 1))
        fi

    done < "$source_file"

    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "mutation.generated" \
            "file=$source_file" "count=$mutation_count" 2>/dev/null || true
    fi

    echo "$mutation_count"
}

# Helper: write a mutation descriptor to disk
_write_mutation() {
    local dir="$1" file="$2" line="$3" category="$4" desc="$5" sed_expr="$6" hash="$7" idx="$8"

    local mut_id="mut_${hash}_${idx}"
    local mut_file="${dir}/${mut_id}.json"

    jq -n --arg id "$mut_id" --arg file "$file" --argjson line "$line" \
        --arg category "$category" --arg description "$desc" --arg sed "$sed_expr" \
        '{"id":$id,"file":$file,"line":$line,"category":$category,"description":$description,"sed_expression":$sed}' \
        > "$mut_file" 2>/dev/null || true
}

# ─── Execute Mutations ───────────────────────────────────────────────────────
# Run test suite against each mutant, track killed/survived.
# Input: $1 = mutation dir, $2 = test command, $3 = project root
# Output: results written to mutation dir, summary echoed as JSON

mutation_execute() {
    local mut_dir="${1:-$MUTATION_DIR}"
    local test_cmd="${2:-}"
    local project_root="${3:-.}"

    if [[ -z "$test_cmd" ]]; then
        error "mutation_execute requires a test command"
        echo '{"killed":0,"survived":0,"errors":0,"total":0}'
        return 1
    fi

    if [[ ! -d "$mut_dir" ]]; then
        echo '{"killed":0,"survived":0,"errors":0,"total":0}'
        return 0
    fi

    local total=0 killed=0 survived=0 errors=0

    # Process each mutation
    local mut_file
    for mut_file in "$mut_dir"/mut_*.json; do
        [[ ! -f "$mut_file" ]] && continue
        total=$((total + 1))

        local src_file line_num sed_expr mut_id
        mut_id=$(jq -r '.id // ""' "$mut_file" 2>/dev/null || true)
        src_file=$(jq -r '.file // ""' "$mut_file" 2>/dev/null || true)
        line_num=$(jq -r '.line // 0' "$mut_file" 2>/dev/null || true)
        sed_expr=$(jq -r '.sed_expression // ""' "$mut_file" 2>/dev/null || true)

        if [[ -z "$src_file" || ! -f "$src_file" || -z "$sed_expr" ]]; then
            errors=$((errors + 1))
            continue
        fi

        # Backup original file
        local backup_file
        backup_file=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mutation-backup.$$.tmp")
        cp "$src_file" "$backup_file" 2>/dev/null || {
            errors=$((errors + 1))
            continue
        }

        # Apply mutation (cross-platform sed -i)
        local sed_rc=0
        if type sed_i >/dev/null 2>&1; then
            sed_i "${line_num}${sed_expr}" "$src_file" 2>/dev/null || sed_rc=$?
        else
            # This branch runs only when sed_i (lib/compat.sh) was never
            # sourced, so it cannot call sed_i itself. `-i.bak` is the one
            # in-place form BSD and GNU sed both accept: `-i ''` is BSD-only
            # and makes GNU sed read '' as the script, while a bare `-i` is
            # GNU-only and makes BSD sed read the next argument as the suffix.
            sed -i.bak "${line_num}${sed_expr}" "$src_file" 2>/dev/null || sed_rc=$?
            rm -f "$src_file.bak" 2>/dev/null || true
        fi

        if [[ $sed_rc -ne 0 ]]; then
            # Revert on sed failure
            cp "$backup_file" "$src_file" 2>/dev/null || true
            rm -f "$backup_file" 2>/dev/null || true
            errors=$((errors + 1))
            continue
        fi

        # Run tests against mutant
        local test_exit=0
        (cd "$project_root" && sw_test_gate_env timeout "$MUTATION_TIMEOUT" bash -c "$test_cmd" > /dev/null 2>&1) || test_exit=$?

        # Revert mutation
        cp "$backup_file" "$src_file" 2>/dev/null || true
        rm -f "$backup_file" 2>/dev/null || true

        # Record result
        if [[ "$test_exit" -ne 0 ]]; then
            killed=$((killed + 1))
            # Update mutation file with result
            local tmp_mut
            tmp_mut=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mut-result.$$.tmp")
            jq '. + {"result":"killed"}' "$mut_file" > "$tmp_mut" 2>/dev/null && mv "$tmp_mut" "$mut_file" 2>/dev/null || rm -f "$tmp_mut" 2>/dev/null
        else
            survived=$((survived + 1))
            local tmp_mut
            tmp_mut=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mut-result.$$.tmp")
            jq '. + {"result":"survived"}' "$mut_file" > "$tmp_mut" 2>/dev/null && mv "$tmp_mut" "$mut_file" 2>/dev/null || rm -f "$tmp_mut" 2>/dev/null
        fi
    done

    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "mutation.executed" \
            "total=$total" "killed=$killed" "survived=$survived" "errors=$errors" 2>/dev/null || true
    fi

    jq -n --argjson total "$total" --argjson killed "$killed" \
        --argjson survived "$survived" --argjson errors "$errors" \
        '{"killed":$killed,"survived":$survived,"errors":$errors,"total":$total}'
}

# ─── Mutation Report ─────────────────────────────────────────────────────────
# Generate mutation testing report with score and weak test identification.
# Input: $1 = mutation dir, $2 = output file
# Output: report JSON path echoed

mutation_report() {
    local mut_dir="${1:-$MUTATION_DIR}"
    local report_file="${2:-$MUTATION_REPORT_FILE}"

    local out_dir
    out_dir=$(dirname "$report_file")
    mkdir -p "$out_dir" 2>/dev/null || true

    local total=0 killed=0 survived=0 errors=0
    local survived_json='[]'
    local categories_killed='{}'
    local categories_total='{}'

    local mut_file
    for mut_file in "$mut_dir"/mut_*.json; do
        [[ ! -f "$mut_file" ]] && continue
        total=$((total + 1))

        local result category description src_file line_num
        result=$(jq -r '.result // "unknown"' "$mut_file" 2>/dev/null || true)
        category=$(jq -r '.category // "unknown"' "$mut_file" 2>/dev/null || true)
        description=$(jq -r '.description // ""' "$mut_file" 2>/dev/null || true)
        src_file=$(jq -r '.file // ""' "$mut_file" 2>/dev/null || true)
        line_num=$(jq -r '.line // 0' "$mut_file" 2>/dev/null || true)

        # Track category totals
        local cat_count
        cat_count=$(echo "$categories_total" | jq --arg c "$category" '.[$c] // 0' 2>/dev/null || echo "0")
        categories_total=$(echo "$categories_total" | jq --arg c "$category" --argjson n "$((cat_count + 1))" '.[$c] = $n' 2>/dev/null || echo "$categories_total")

        case "$result" in
            killed)
                killed=$((killed + 1))
                local ck
                ck=$(echo "$categories_killed" | jq --arg c "$category" '.[$c] // 0' 2>/dev/null || echo "0")
                categories_killed=$(echo "$categories_killed" | jq --arg c "$category" --argjson n "$((ck + 1))" '.[$c] = $n' 2>/dev/null || echo "$categories_killed")
                ;;
            survived)
                survived=$((survived + 1))
                survived_json=$(echo "$survived_json" | jq --arg file "$src_file" --argjson line "$line_num" \
                    --arg cat "$category" --arg desc "$description" \
                    '. + [{"file":$file,"line":$line,"category":$cat,"description":$desc}]' 2>/dev/null || echo "$survived_json")
                ;;
            *)
                errors=$((errors + 1))
                ;;
        esac
    done

    # Calculate mutation score
    local mutation_score=0
    local effective_total=$((total - errors))
    if [[ "$effective_total" -gt 0 ]]; then
        mutation_score=$(( (killed * 100) / effective_total ))
    fi

    # Identify weak areas (files with surviving mutants)
    local weak_files='[]'
    weak_files=$(echo "$survived_json" | jq '[group_by(.file)[] | {"file":.[0].file,"surviving_count":length,"mutations":[.[] | .description]}]' 2>/dev/null || echo "[]")

    # Build report
    jq -n --argjson total "$total" --argjson killed "$killed" \
        --argjson survived "$survived" --argjson errors "$errors" \
        --argjson score "$mutation_score" \
        --argjson surviving "$survived_json" \
        --argjson weak "$weak_files" \
        --argjson cat_killed "$categories_killed" \
        --argjson cat_total "$categories_total" \
        --arg ts "$(now_iso)" \
        '{
            "mutation_score_pct": $score,
            "total": $total,
            "killed": $killed,
            "survived": $survived,
            "errors": $errors,
            "target_pct": 80,
            "meets_target": ($score >= 80),
            "surviving_mutants": $surviving,
            "weak_files": $weak,
            "categories_killed": $cat_killed,
            "categories_total": $cat_total,
            "generated_at": $ts
        }' > "$report_file" 2>/dev/null

    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "mutation.report" \
            "score=$mutation_score" "total=$total" "killed=$killed" \
            "survived=$survived" 2>/dev/null || true
    fi

    echo "$report_file"
}
