#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Autonomous Code Review Agent — Clean Code & Architecture Analysis      ║
# ║  Quality enforcement: code smells, SOLID, layer boundaries, complexity   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

emit_event() {
    local type="$1"; shift
    local entry="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$type\""
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"; local val="${1#*=}"
        val="${val//\"/\\\"}"
        entry="$entry,\"${key}\":\"${val}\""
        shift
    done
    entry="$entry}"
    mkdir -p "$HOME/.shipwright"
    echo "$entry" >> "$HOME/.shipwright/events.jsonl"
}

# ─── Configuration ───────────────────────────────────────────────────────
REVIEW_CONFIG="${REPO_DIR}/.claude/code-review.json"
QUALITY_METRICS_FILE="${REPO_DIR}/.claude/pipeline-artifacts/quality-metrics.json"
TRENDS_FILE="${HOME}/.shipwright/code-review-trends.jsonl"
STRICTNESS="${STRICTNESS:-normal}"  # relaxed, normal, strict

init_config() {
    [[ -f "$REVIEW_CONFIG" ]] && return 0
    mkdir -p "${REPO_DIR}/.claude"
    cat > "$REVIEW_CONFIG" <<'EOF'
{
  "strictness": "normal",
  "ignore_patterns": ["test", "vendor", "node_modules", "dist", "build"],
  "rules": {
    "max_function_lines": 60,
    "max_nesting_depth": 4,
    "max_cyclomatic_complexity": 10,
    "long_variable_name_chars": 25,
    "magic_number_detection": true
  },
  "enabled_checks": [
    "code_smells",
    "solid_violations",
    "architecture_boundaries",
    "complexity_metrics",
    "style_consistency",
    "auto_fix_simple"
  ]
}
EOF
}

load_config() {
    if [[ -f "$REVIEW_CONFIG" ]]; then
        STRICTNESS=$(jq -r '.strictness // "normal"' "$REVIEW_CONFIG" 2>/dev/null || echo "normal")
    fi
}

# ─── Code Smell Detection ────────────────────────────────────────────────────

detect_code_smells() {
    local target_file="$1"
    local issues=()

    [[ ! -f "$target_file" ]] && return 0

    local ext="${target_file##*.}"
    [[ "$ext" != "sh" ]] && return 0

    # Check 1: Long functions (>60 lines in bash)
    local func_count
    func_count=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*().*{" "$target_file" 2>/dev/null || echo "0")
    if [[ "$func_count" -gt 0 ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*\(\).*\{ ]]; then
                local func_name="${line%%(*}"
                local start_line
                start_line=$(grep -n "^${func_name}()" "$target_file" | head -1 | cut -d: -f1)
                local end_line
                end_line=$(awk "NR>$start_line && /^}/ {print NR; exit}" "$target_file")
                local func_lines=$((end_line - start_line))
                if [[ $func_lines -gt 60 ]]; then
                    issues+=("LONG_FUNCTION: $func_name at line $start_line ($func_lines lines)")
                fi
            fi
        done < <(grep "^[a-zA-Z_][a-zA-Z0-9_]*().*{" "$target_file" 2>/dev/null || true)
    fi

    # Check 2: Deep nesting (>4 levels)
    local max_indent=0
    while IFS= read -r line; do
        local indent=0
        while [[ "${line:0:1}" == " " || "${line:0:1}" == "	" ]]; do
            indent=$((indent + 1))
            line="${line:1}"
        done
        [[ $indent -gt $max_indent ]] && max_indent=$indent
    done < "$target_file"
    local nesting_level=$((max_indent / 4))
    if [[ $nesting_level -gt 4 ]]; then
        issues+=("DEEP_NESTING: Maximum $nesting_level levels detected (threshold: 4)")
    fi

    # Check 3: Duplicate code patterns (repeated >3 times)
    local dup_count=0
    dup_count=$(grep -c '^\s*\(cd\|cd\|mkdir\|rm\|echo\)' "$target_file" 2>/dev/null || echo "0")
    if [[ $dup_count -gt 3 ]]; then
        issues+=("REPEATED_PATTERNS: Common operations appear $dup_count times (consider helper functions)")
    fi

    # Check 4: Magic numbers
    if grep -qE '\s[0-9]{3,}\s' "$target_file" 2>/dev/null; then
        issues+=("MAGIC_NUMBERS: Found numeric literals without clear purpose")
    fi

    # Check 5: Poor naming (single letter variables in conditionals)
    if grep -qE 'for\s+[a-z]\s+in|if.*\[\[\s*[a-z]\s*(==|-\w)' "$target_file" 2>/dev/null; then
        issues+=("POOR_NAMING: Single-letter variables in conditionals")
    fi

    for issue in "${issues[@]}"; do
        echo "$issue"
    done
}

# ─── SOLID Violations ────────────────────────────────────────────────────────

check_solid_principles() {
    local target_file="$1"
    local violations=()

    [[ ! -f "$target_file" ]] && return 0

    local ext="${target_file##*.}"
    [[ "$ext" != "sh" ]] && return 0

    # Single Responsibility: Check if scripts do multiple unrelated things
    local sourced_count
    sourced_count=$(grep -c '^\s*source\|^\s*\.\s' "$target_file" 2>/dev/null || echo "0")
    if [[ $sourced_count -gt 3 ]]; then
        violations+=("SRP_VIOLATION: Script sources $sourced_count modules (too many responsibilities)")
    fi

    # Open/Closed: Check for hardcoded config values
    if grep -qE '^\s*(HARDCODED|MAGIC|CONFIG)=' "$target_file" 2>/dev/null; then
        violations+=("OCP_VIOLATION: Hardcoded configuration values (use config files instead)")
    fi

    # Liskov Substitution: Check for function parameter assumptions
    if grep -qE 'if.*type\s+\$|if.*\[\[\s*-x' "$target_file" 2>/dev/null; then
        violations+=("LSP_CONCERN: Possible type checking in function (breaks substitution)")
    fi

    # Interface Segregation: Check if functions have too many parameters
    while IFS= read -r line; do
        if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*\(\) ]]; then
            local func_name="${line%%(*}"
            local body
            body=$(awk "/^${func_name}\\(\\)/,/^}/" "$target_file" | grep -c '\$[0-9]' || echo "0")
            if [[ $body -gt 5 ]]; then
                violations+=("ISP_VIOLATION: Function $func_name uses >5 parameters")
            fi
        fi
    done < <(grep "^[a-zA-Z_][a-zA-Z0-9_]*().*{" "$target_file" 2>/dev/null || true)

    for violation in "${violations[@]}"; do
        echo "$violation"
    done
}

# ─── Architecture Boundary Checks ────────────────────────────────────────────

check_architecture_boundaries() {
    local target_file="$1"
    local violations=()

    [[ ! -f "$target_file" ]] && return 0

    # Providers should not call each other directly
    if [[ "$target_file" =~ sw-tracker-.*\.sh ]] || [[ "$target_file" =~ .*provider.*\.sh ]]; then
        if grep -qE 'source.*provider|source.*tracker-' "$target_file" 2>/dev/null; then
            violations+=("ARCH_VIOLATION: Provider sourcing another provider (use router pattern)")
        fi
    fi

    # Non-router scripts shouldn't bypass the router
    if [[ ! "$target_file" =~ /sw$ ]] && [[ ! "$target_file" =~ /sw-.*router.*\.sh ]]; then
        if grep -qE 'exec\s+\$SCRIPT_DIR/sw-' "$target_file" 2>/dev/null; then
            violations+=("ARCH_VIOLATION: Direct exec to script (use router pattern)")
        fi
    fi

    # Tests shouldn't call production scripts
    if [[ "$target_file" =~ -test\.sh$ ]]; then
        if grep -qE 'source.*[^-test]\.sh' "$target_file" 2>/dev/null; then
            violations+=("ARCH_VIOLATION: Test file sourcing production code directly")
        fi
    fi

    for violation in "${violations[@]}"; do
        echo "$violation"
    done
}

# ─── Complexity Metrics ──────────────────────────────────────────────────────

analyze_complexity() {
    local target_file="$1"

    [[ ! -f "$target_file" ]] && return 0

    local ext="${target_file##*.}"
    [[ "$ext" != "sh" ]] && return 0

    local metrics="{\"file\":\"$target_file\",\"functions\":[]}"

    while IFS= read -r line; do
        if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*\(\) ]]; then
            local func_name="${line%%(*}"
            local start_line
            start_line=$(grep -n "^${func_name}()" "$target_file" | head -1 | cut -d: -f1)
            local end_line
            end_line=$(awk "NR>$start_line && /^}/ {print NR; exit}" "$target_file")

            # Cyclomatic complexity: count decision points (if, elif, case, &&, ||)
            local cc=1
            cc=$((cc + $(sed -n "${start_line},${end_line}p" "$target_file" | grep -cE '\s(if|elif|case|&&|\|\|)' || echo 0)))

            # Lines of code
            local loc=$((end_line - start_line))

            # Cognitive complexity: nested decision depth
            local max_depth=0
            local curr_depth=0
            while IFS= read -r func_line; do
                if [[ "$func_line" =~ \[\[ ]] || [[ "$func_line" =~ if.*then ]]; then
                    curr_depth=$((curr_depth + 1))
                    [[ $curr_depth -gt $max_depth ]] && max_depth=$curr_depth
                fi
                [[ "$func_line" =~ fi ]] && [[ $curr_depth -gt 0 ]] && curr_depth=$((curr_depth - 1))
            done < <(sed -n "${start_line},${end_line}p" "$target_file")

            metrics=$(echo "$metrics" | jq --arg fn "$func_name" --arg cc "$cc" --arg loc "$loc" --arg cd "$max_depth" \
                '.functions += [{"name": $fn, "cyclomatic_complexity": $cc, "lines": $loc, "cognitive_complexity": $cd}]' 2>/dev/null || echo "$metrics")
        fi
    done < <(grep "^[a-zA-Z_][a-zA-Z0-9_]*().*{" "$target_file" 2>/dev/null || true)

    echo "$metrics"
}

# ─── Style Consistency ───────────────────────────────────────────────────────

check_style_consistency() {
    local target_file="$1"
    local issues=()

    [[ ! -f "$target_file" ]] && return 0

    local ext="${target_file##*.}"
    [[ "$ext" != "sh" ]] && return 0

    # Check error handling consistency
    local has_trap=false
    local has_set_e=false

    [[ $(grep -c 'trap.*ERR' "$target_file" 2>/dev/null || echo 0) -gt 0 ]] && has_trap=true
    [[ $(grep -c 'set -e' "$target_file" 2>/dev/null || echo 0) -gt 0 ]] && has_set_e=true

    if [[ "$has_set_e" == "true" ]] && [[ "$has_trap" == "false" ]]; then
        issues+=("STYLE: Missing ERR trap despite 'set -e' (inconsistent error handling)")
    fi

    # Check for inconsistent quote usage
    local single_quotes
    local double_quotes
    single_quotes=$(grep -o "'" "$target_file" 2>/dev/null | wc -l || echo 0)
    double_quotes=$(grep -o '"' "$target_file" 2>/dev/null | wc -l || echo 0)
    if [[ $single_quotes -gt $((double_quotes * 3)) ]] || [[ $double_quotes -gt $((single_quotes * 3)) ]]; then
        issues+=("STYLE: Inconsistent quote style (mix of single and double quotes)")
    fi

    # Check for inconsistent spacing/indentation
    local tab_count
    local space_count
    tab_count=$(grep -c $'^\t' "$target_file" 2>/dev/null || echo 0)
    space_count=$(grep -c '^  ' "$target_file" 2>/dev/null || echo 0)
    if [[ $tab_count -gt 0 ]] && [[ $space_count -gt 0 ]]; then
        issues+=("STYLE: Mixed tabs and spaces")
    fi

    # Check variable naming consistency
    if grep -qE '\$\{[a-z]+_[a-z]+\}' "$target_file" && grep -qE '\$\{[A-Z]+\}' "$target_file"; then
        if ! grep -qE '\$\{[A-Z]+_[A-Z]+\}' "$target_file"; then
            issues+=("STYLE: Inconsistent variable naming (snake_case vs UPPERCASE)")
        fi
    fi

    for issue in "${issues[@]}"; do
        echo "$issue"
    done
}

# ─── Auto-fix Simple Issues ─────────────────────────────────────────────────

auto_fix() {
    local target_file="$1"
    local fixed=0

    [[ ! -f "$target_file" ]] && return 0

    local ext="${target_file##*.}"
    [[ "$ext" != "sh" ]] && return 0

    local backup="${target_file}.review-backup"
    cp "$target_file" "$backup"

    # Fix 1: Run shellcheck and capture warnings
    if command -v shellcheck &>/dev/null; then
        local shellcheck_fixes=0
        local warnings_file
        warnings_file=$(mktemp)
        shellcheck -f json "$target_file" > "$warnings_file" 2>/dev/null || true

        if [[ -s "$warnings_file" ]]; then
            shellcheck_fixes=$(jq 'length' "$warnings_file" 2>/dev/null || echo "0")
            info "shellcheck found $shellcheck_fixes issues in $target_file"
            fixed=$((fixed + shellcheck_fixes))
        fi
        rm -f "$warnings_file"
    fi

    # Fix 2: Trailing whitespace
    local trailing_ws
    trailing_ws=$(grep -c '[[:space:]]$' "$target_file" 2>/dev/null || echo "0")
    if [[ $trailing_ws -gt 0 ]]; then
        sed -i '' 's/[[:space:]]*$//' "$target_file"
        info "Removed $trailing_ws lines of trailing whitespace"
        fixed=$((fixed + trailing_ws))
    fi

    # Fix 3: Ensure final newline
    if [[ -n "$(tail -c1 "$target_file" 2>/dev/null)" ]]; then
        echo "" >> "$target_file"
        info "Added final newline"
        fixed=$((fixed + 1))
    fi

    # Fix 4: Consistent spacing around operators (simple cases)
    local spacing_fixes=0
    spacing_fixes=$(grep -c '==' "$target_file" 2>/dev/null || echo "0")
    if [[ $spacing_fixes -gt 0 ]]; then
        info "Flagged $spacing_fixes operator spacing cases (manual review recommended)"
    fi

    echo "$fixed"
}

# ─── Claude-powered semantic review (logic, race conditions, API usage, requirements) ──
run_claude_semantic_review() {
    local diff_content="$1"
    local requirements="${2:-}"
    [[ -z "$diff_content" ]] && return 0
    if ! command -v claude &>/dev/null; then
        return 0
    fi

    local prompt="You are a senior code reviewer. Review this git diff for semantic issues (not just style).

Focus on:
1. Logic errors and edge cases (off-by-one, null/empty handling, wrong conditions)
2. Race conditions and concurrency issues (shared state, ordering, locks)
3. Incorrect or unsafe API usage (wrong arguments, missing error handling, deprecated APIs)
4. Security issues (injection, auth bypass, sensitive data exposure)
5. Requirements alignment: does the change match the intended behavior?

For each issue use this format on its own line:
- **[SEVERITY]** file:line — brief description

Severity: Critical, Bug, Security, Warning, Suggestion.
If no issues found, reply with exactly: Review clean — no semantic issues found.

## Diff
${diff_content}
"
    [[ -n "$requirements" ]] && prompt="${prompt}

## Requirements / intended behavior
${requirements}
"

    local claude_out
    claude_out=$(claude -p "$prompt" --max-turns 3 2>/dev/null || true)
    [[ -z "$claude_out" ]] && return 0

    if echo "$claude_out" | grep -qi "Review clean — no semantic issues found"; then
        return 0
    fi
    echo "$claude_out" | grep -oE '\*\*\[?(Critical|Bug|Security|Warning|Suggestion)\]?\*\*[^—]*—[^$]+' 2>/dev/null || \
        echo "$claude_out" | grep -oE '-\s+\*\*[^*]+\*\*[^\n]+' 2>/dev/null || true
}

# ─── Review Subcommand ───────────────────────────────────────────────────────

review_changes() {
    local pr_number="${1:-}"
    local review_scope="staged"

    if [[ -n "$pr_number" ]]; then
        review_scope="pr:$pr_number"
    fi

    info "Reviewing code changes ($review_scope)..."

    mkdir -p "${REPO_DIR}/.claude/pipeline-artifacts"

    local review_output="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"scope\":\"$review_scope\",\"findings\":{}}"
    local total_issues=0

    # Get changed files
    local changed_files=()
    if [[ "$review_scope" == "staged" ]]; then
        mapfile -t changed_files < <(cd "$REPO_DIR" && git diff --cached --name-only 2>/dev/null || true)
    else
        # For PR: get diff against main
        mapfile -t changed_files < <(cd "$REPO_DIR" && git diff main...HEAD --name-only 2>/dev/null || true)
    fi

    [[ ${#changed_files[@]} -eq 0 ]] && { success "No changes to review"; return 0; }

    # Claude-powered semantic review (logic, race conditions, API usage) when available
    local diff_content
    if [[ "$review_scope" == "staged" ]]; then
        diff_content=$(cd "$REPO_DIR" && git diff --cached 2>/dev/null || true)
    else
        diff_content=$(cd "$REPO_DIR" && git diff main...HEAD 2>/dev/null || true)
    fi
    local semantic_issues=()
    if [[ -n "$diff_content" ]] && command -v claude &>/dev/null; then
        info "Running Claude semantic review (logic, race conditions, API usage)..."
        mapfile -t semantic_issues < <(run_claude_semantic_review "$diff_content" "${REVIEW_REQUIREMENTS:-}" || true)
        if [[ ${#semantic_issues[@]} -gt 0 ]]; then
            total_issues=$((total_issues + ${#semantic_issues[@]}))
            review_output=$(echo "$review_output" | jq --argjson arr "$(printf '%s\n' "${semantic_issues[@]}" | jq -R . | jq -s .)" '.semantic_findings = $arr' 2>/dev/null || echo "$review_output")
        fi
    fi

    for file in "${changed_files[@]}"; do
        local file_path="${REPO_DIR}/${file}"
        [[ ! -f "$file_path" ]] && continue

        info "Analyzing $file..."

        local smells=()
        local solids=()
        local arch_issues=()
        local style_issues=()

        mapfile -t smells < <(detect_code_smells "$file_path")
        mapfile -t solids < <(check_solid_principles "$file_path")
        mapfile -t arch_issues < <(check_architecture_boundaries "$file_path")
        mapfile -t style_issues < <(check_style_consistency "$file_path")

        local file_issues=$((${#smells[@]} + ${#solids[@]} + ${#arch_issues[@]} + ${#style_issues[@]}))
        total_issues=$((total_issues + file_issues))

        if [[ $file_issues -gt 0 ]]; then
            local file_summary="{\"code_smells\":"
            file_summary+=$(printf '%s\n' "${smells[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
            file_summary+=",\"solid_violations\":"
            file_summary+=$(printf '%s\n' "${solids[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
            file_summary+=",\"architecture_issues\":"
            file_summary+=$(printf '%s\n' "${arch_issues[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
            file_summary+=",\"style_issues\":"
            file_summary+=$(printf '%s\n' "${style_issues[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
            file_summary+="}"

            review_output=$(echo "$review_output" | jq --arg fname "$file" --argjson summary "$file_summary" \
                '.findings[$fname] = $summary' 2>/dev/null || echo "$review_output")
        fi
    done

    review_output=$(echo "$review_output" | jq --arg tc "$total_issues" '.total_issues = $tc' 2>/dev/null || echo "$review_output")

    echo "$review_output" | jq '.' 2>/dev/null || echo "$review_output"

    mkdir -p "$(dirname "$QUALITY_METRICS_FILE")"
    echo "$review_output" | jq '.' > "$QUALITY_METRICS_FILE" 2>/dev/null || true

    emit_event "code_review.complete" "scope=$review_scope" "total_issues=$total_issues" "file_count=${#changed_files[@]}"

    [[ $total_issues -gt 0 ]] && warn "Review found $total_issues issues"
    [[ $total_issues -eq 0 ]] && success "No issues found"
}

# ─── Scan Subcommand ────────────────────────────────────────────────────────

scan_codebase() {
    info "Running full codebase quality scan..."

    local scan_output="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"files\":[]}"
    local total_issues=0

    find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | while read -r file; do
        local file_rel="${file#$REPO_DIR/}"
        local smells=0
        local solids=0
        local arch_issues=0

        smells=$(detect_code_smells "$file" 2>/dev/null | wc -l || echo 0)
        solids=$(check_solid_principles "$file" 2>/dev/null | wc -l || echo 0)
        arch_issues=$(check_architecture_boundaries "$file" 2>/dev/null | wc -l || echo 0)

        local file_issues=$((smells + solids + arch_issues))
        total_issues=$((total_issues + file_issues))

        if [[ $file_issues -gt 0 ]]; then
            echo "$file_rel: $file_issues issues (smells: $smells, SOLID: $solids, arch: $arch_issues)"
        fi
    done

    success "Scan complete: $total_issues total issues found"
    emit_event "code_review.scan" "total_issues=$total_issues"
}

# ─── Complexity Subcommand ──────────────────────────────────────────────────

complexity_report() {
    info "Analyzing code complexity metrics..."

    local complexity_data="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"files\":[]}"

    find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | while read -r file; do
        local file_metrics
        file_metrics=$(analyze_complexity "$file" 2>/dev/null || echo "{}")
        complexity_data=$(echo "$complexity_data" | jq --argjson metrics "$file_metrics" '.files += [$metrics]' 2>/dev/null || echo "$complexity_data")

        # Output per-file summary
        echo "$file_metrics" | jq -r '.functions[] | "\(.name): CC=\(.cyclomatic_complexity), LOC=\(.lines), Cog=\(.cognitive_complexity)"' 2>/dev/null || true
    done

    success "Complexity analysis complete"
}

# ─── Trends Subcommand ──────────────────────────────────────────────────────

show_trends() {
    [[ ! -f "$TRENDS_FILE" ]] && { info "No trend data available yet"; return 0; }

    info "Code Quality Trends:"
    echo ""

    tail -10 "$TRENDS_FILE" | jq -r '.timestamp + ": " + (.total_issues | tostring) + " issues"' 2>/dev/null || cat "$TRENDS_FILE"
}

# ─── Config Subcommand ──────────────────────────────────────────────────────

manage_config() {
    local action="${1:-show}"

    case "$action" in
        show)
            init_config
            cat "$REVIEW_CONFIG" | jq '.' 2>/dev/null || cat "$REVIEW_CONFIG"
            ;;
        set)
            local key="$2" value="$3"
            init_config
            jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$REVIEW_CONFIG" > "${REVIEW_CONFIG}.tmp"
            mv "${REVIEW_CONFIG}.tmp" "$REVIEW_CONFIG"
            success "Updated $key = $value"
            ;;
        *)
            error "Unknown config action: $action"
            return 1
            ;;
    esac
}

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${BOLD}Autonomous Code Review Agent${RESET} — Issue #76"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}sw code-review${RESET} <subcommand> [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS${RESET}"
    echo -e "  ${CYAN}review${RESET} [--pr N]       Review staged changes (or specific PR)"
    echo -e "  ${CYAN}scan${RESET}                 Full codebase quality scan"
    echo -e "  ${CYAN}complexity${RESET}           Show complexity metrics per function"
    echo -e "  ${CYAN}boundaries${RESET}           Check architecture boundary violations"
    echo -e "  ${CYAN}fix${RESET}                  Auto-fix simple code quality issues"
    echo -e "  ${CYAN}trends${RESET}               Show code quality trends over time"
    echo -e "  ${CYAN}config${RESET} [show|set K V] Manage review configuration"
    echo -e "  ${CYAN}help${RESET}                 Show this help message"
    echo ""
    echo -e "${BOLD}CHECKS${RESET}"
    echo -e "  • Code smells: long functions, deep nesting, duplication, magic numbers"
    echo -e "  • SOLID principles: SRP, OCP, LSP, ISP violations"
    echo -e "  • Architecture: layer boundaries, provider isolation"
    echo -e "  • Complexity: cyclomatic, cognitive, function length"
    echo -e "  • Style: consistency in error handling, quotes, indentation"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}sw code-review review${RESET}              # Review staged changes"
    echo -e "  ${DIM}sw code-review review --pr 42${RESET}     # Review specific PR"
    echo -e "  ${DIM}sw code-review complexity${RESET}         # Show complexity metrics"
    echo -e "  ${DIM}sw code-review fix${RESET}                # Auto-fix simple issues"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    local subcommand="${1:-help}"

    init_config
    load_config

    case "$subcommand" in
        review)
            shift || true
            local pr_opt=""
            [[ "${1:-}" == "--pr" ]] && pr_opt="${2:-}"
            review_changes "$pr_opt"
            ;;
        scan)
            scan_codebase
            ;;
        complexity)
            complexity_report
            ;;
        boundaries)
            info "Checking architecture boundaries..."
            find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | while read -r file; do
                check_architecture_boundaries "$file" 2>/dev/null | grep . && echo "  in $file"
            done
            success "Architecture check complete"
            ;;
        fix)
            info "Auto-fixing simple issues..."
            local fixed_count=0
            find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | while read -r file; do
                local fixes
                fixes=$(auto_fix "$file" 2>/dev/null || echo "0")
                [[ "$fixes" -gt 0 ]] && fixed_count=$((fixed_count + fixes))
            done
            success "Auto-fix complete: $fixed_count issues addressed"
            emit_event "code_review.autofix" "issues_fixed=$fixed_count"
            ;;
        trends)
            show_trends
            ;;
        config)
            shift || true
            manage_config "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown subcommand: $subcommand"
            show_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
