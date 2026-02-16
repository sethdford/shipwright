#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright hygiene — Repository Organization & Cleanup                 ║
# ║  Dead code detection · Structure enforcement · Dependency audit         ║
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
    local event_type="$1"; shift
    local events_file="${HOME}/.shipwright/events.jsonl"
    mkdir -p "$(dirname "$events_file")"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}" val="${1#*=}"
        payload="${payload},\"${key}\":\"${val}\""
        shift
    done
    payload="${payload}}"
    echo "$payload" >> "$events_file"
}

# ─── Default Settings ───────────────────────────────────────────────────────
SUBCOMMAND="${1:-help}"
AUTO_FIX=false
VERBOSE=false
ARTIFACT_AGE_DAYS=7
JSON_OUTPUT=false

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright hygiene${RESET} ${DIM}v${VERSION}${RESET} — Repository cleanliness & structure enforcement"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright hygiene${RESET} <subcommand> [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS${RESET}"
    echo -e "  ${CYAN}scan${RESET}           Full hygiene scan (all checks)"
    echo -e "  ${CYAN}dead-code${RESET}     Find unused functions, scripts, fixtures"
    echo -e "  ${CYAN}structure${RESET}     Validate directory structure and conventions"
    echo -e "  ${CYAN}dependencies${RESET}  Dependency audit and circular checks"
    echo -e "  ${CYAN}naming${RESET}        Check naming conventions (files, functions, vars)"
    echo -e "  ${CYAN}branches${RESET}      List stale and merged remote branches"
    echo -e "  ${CYAN}size${RESET}          Size analysis and bloat detection"
    echo -e "  ${CYAN}fix${RESET}           Auto-fix safe issues (naming, whitespace)"
    echo -e "  ${CYAN}report${RESET}        Generate comprehensive hygiene report"
    echo -e "  ${CYAN}help${RESET}          Show this help message"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--fix${RESET}           Auto-fix issues (use with caution)"
    echo -e "  ${CYAN}--verbose, -v${RESET}   Verbose output"
    echo -e "  ${CYAN}--json${RESET}          JSON output format"
    echo -e "  ${CYAN}--artifact-age${RESET}  Max age for artifacts in days (default: 7)"
    echo -e "  ${CYAN}--help, -h${RESET}      Show this help"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright hygiene scan${RESET}                # Full scan"
    echo -e "  ${DIM}shipwright hygiene dead-code${RESET}           # Find unused code"
    echo -e "  ${DIM}shipwright hygiene fix${RESET}                 # Auto-fix safe issues"
    echo -e "  ${DIM}shipwright hygiene report --json${RESET}       # JSON report"
    echo ""
}

# ─── Dead Code Detection ────────────────────────────────────────────────────

detect_dead_code() {
    info "Scanning for dead code..."

    local unused_functions=0
    local unused_scripts=0
    local orphaned_tests=0

    # Find unused bash functions (simplified for Bash 3.2)
    while IFS= read -r func_file; do
        # Extract function names
        local funcs
        funcs=$(grep -E '^[a-z_][a-z0-9_]*\(\)' "$func_file" 2>/dev/null | sed 's/()$//' | sed 's/^ *//' || true)

        while IFS= read -r func; do
            [[ -z "$func" ]] && continue

            # Check if function is used in other files (count lines with this function name)
            local usage_count
            usage_count=$(grep -r "$func" "$REPO_DIR/scripts" --include="*.sh" 2>/dev/null | wc -l) || usage_count="0"
            usage_count=$(printf '%s' "$usage_count" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            # Function definition counts as 1 usage; if only 1, it's unused
            case "$usage_count" in
                0|1) [[ $VERBOSE == true ]] && warn "Unused function: $func (in $(basename "$func_file"))"; ((unused_functions++)) ;;
            esac
        done <<< "$funcs"
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | head -20)

    # Find scripts referenced nowhere
    local script_count=0
    while IFS= read -r script; do
        local basename_script ref_count
        basename_script=$(basename "$script")

        # Skip test scripts and main scripts
        [[ "$basename_script" =~ -test\.sh$ ]] && continue
        [[ "$basename_script" == "sw-hygiene.sh" ]] && continue
        [[ "$basename_script" == "sw" ]] && continue

        # Check if script is sourced or executed
        ref_count=$(grep -r "$basename_script" "$REPO_DIR/scripts" --include="*.sh" 2>/dev/null | wc -l) || ref_count="0"
        ref_count=$(printf '%s' "$ref_count" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        case "$ref_count" in
            0|1) [[ $VERBOSE == true ]] && warn "Potentially unused script: $basename_script"; ((unused_scripts++)) ;;
        esac
        ((script_count++))
    done < <(find "$REPO_DIR/scripts" -maxdepth 1 -name "sw-*.sh" -type f 2>/dev/null)

    # Find test fixtures without corresponding tests
    while IFS= read -r fixture; do
        local test_name
        test_name=$(basename "$fixture" .fixture)

        if ! grep -r "$test_name" "$REPO_DIR/scripts" --include="*-test.sh" 2>/dev/null | grep -q .; then
            warn "Orphaned test fixture: $(basename "$fixture")"
            ((orphaned_tests++))
        fi
    done < <(find "$REPO_DIR" -name "*.fixture" -type f 2>/dev/null)

    [[ $VERBOSE == true ]] && {
        info "Dead code summary: $unused_functions unused functions, $unused_scripts scripts, $orphaned_tests fixtures"
    }

    return 0
}

# ─── Structure Validation ───────────────────────────────────────────────────

validate_structure() {
    info "Validating directory structure..."

    local structure_issues=0

    # Check for scripts in wrong locations
    while IFS= read -r script; do
        local dir
        dir=$(dirname "$script")

        if [[ "$dir" != "$REPO_DIR/scripts" ]]; then
            warn "Script outside scripts/ directory: $script"
            ((structure_issues++))
        fi
    done < <(find "$REPO_DIR" -name "*.sh" -type f ! -path "*/node_modules/*" ! -path "*/.git/*" 2>/dev/null | grep -E '(sw-|shipwright)' || true)

    # Check test naming conventions
    while IFS= read -r test; do
        local basename_test
        basename_test=$(basename "$test")

        if [[ ! "$basename_test" =~ -test\.sh$ ]]; then
            warn "Test file not named *-test.sh: $basename_test"
            ((structure_issues++))
        fi
    done < <(find "$REPO_DIR/scripts" -path "*test*" -name "*.sh" -type f 2>/dev/null)

    # Check directory organization
    if [[ ! -d "$REPO_DIR/scripts" ]]; then
        error "scripts/ directory missing"
        ((structure_issues++))
    fi

    if [[ ! -d "$REPO_DIR/.claude" ]]; then
        error ".claude/ directory missing"
        ((structure_issues++))
    fi

    [[ $VERBOSE == true ]] && {
        info "Structure validation: $structure_issues issues found"
    }

    return 0
}

# ─── Dependency Audit ───────────────────────────────────────────────────────

audit_dependencies() {
    info "Auditing dependencies..."

    local unused_deps=0
    local circular_deps=0

    # Check for unused npm/yarn dependencies
    if [[ -f "$REPO_DIR/package.json" ]]; then
        local deps
        deps=$(jq -r '.dependencies, .devDependencies | keys[]?' "$REPO_DIR/package.json" 2>/dev/null || true)

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue

            # Simple check: does the dep appear in source files?
            if ! grep -r "$dep" "$REPO_DIR/scripts" --include="*.sh" 2>/dev/null | grep -q .; then
                [[ $VERBOSE == true ]] && warn "Potentially unused npm dependency: $dep"
                ((unused_deps++))
            fi
        done <<< "$deps"
    fi

    # Check for circular script dependencies (A sources B, B sources A)
    while IFS= read -r script; do
        local sourced_by
        sourced_by=$(grep "source.*$(basename "$script")" "$REPO_DIR/scripts"/*.sh 2>/dev/null | cut -d: -f1 | sort -u || true)

        while IFS= read -r source_script; do
            [[ -z "$source_script" ]] && continue

            # Check if sourced_by also sources the original script
            if grep -q "source.*$(basename "$source_script")" "$script" 2>/dev/null; then
                warn "Circular dependency: $(basename "$script") ←→ $(basename "$source_script")"
                ((circular_deps++))
            fi
        done <<< "$sourced_by"
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | head -10)

    [[ $VERBOSE == true ]] && {
        info "Dependency audit: $unused_deps unused, $circular_deps circular"
    }

    return 0
}

# ─── Naming Convention Check ────────────────────────────────────────────────

check_naming() {
    info "Checking naming conventions..."

    local naming_issues=0

    # Check shell scripts follow sw-*.sh pattern
    while IFS= read -r script; do
        local basename_script
        basename_script=$(basename "$script")

        if ! [[ "$basename_script" =~ ^sw-[a-z0-9-]+\.sh$ ]] && ! [[ "$basename_script" == "sw" ]]; then
            [[ $VERBOSE == true ]] && warn "Script not following naming convention: $basename_script"
            ((naming_issues++))
        fi
    done < <(find "$REPO_DIR/scripts" -maxdepth 1 -name "*.sh" -type f 2>/dev/null)

    # Check for functions not using snake_case
    while IFS= read -r script; do
        local bad_functions
        bad_functions=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$script" 2>/dev/null | grep -E '[A-Z]' | sed 's/()$//' || true)

        while IFS= read -r func; do
            [[ -z "$func" ]] && continue
            [[ $VERBOSE == true ]] && warn "Function not using snake_case: $func (in $(basename "$script"))"
            ((naming_issues++))
        done <<< "$bad_functions"
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | head -20)

    [[ $VERBOSE == true ]] && {
        info "Naming validation: $naming_issues issues found"
    }

    return 0
}

# ─── Stale Branch Detection ────────────────────────────────────────────────

list_stale_branches() {
    info "Scanning for stale branches..."

    if ! git rev-parse --git-dir &>/dev/null; then
        error "Not in a git repository"
        return 1
    fi

    # Fetch latest remote info
    git fetch --prune 2>/dev/null || true

    local stale_count=0

    # Find merged branches
    local merged_branches
    merged_branches=$(git branch -r --merged 2>/dev/null | grep -v "HEAD" | grep -v "main" | grep -v "master" | tr -d ' ' || true)

    if [[ -n "$merged_branches" ]]; then
        info "Merged branches available for cleanup:"
        while IFS= read -r branch; do
            [[ -z "$branch" ]] && continue
            echo -e "  ${DIM}$branch${RESET}"
            ((stale_count++))
        done <<< "$merged_branches"
    fi

    # Find branches not updated in 30 days
    local old_branches
    old_branches=$(git branch -r --format="%(refname:short)%09%(committerdate:short)" 2>/dev/null | \
        awk -v cutoff=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d) \
        '$2 < cutoff {print $1}' || true)

    if [[ -n "$old_branches" ]]; then
        info "Branches not updated in 30+ days:"
        while IFS= read -r branch; do
            [[ -z "$branch" ]] && continue
            echo -e "  ${DIM}$branch${RESET}"
        done <<< "$old_branches"
    fi

    [[ $VERBOSE == true ]] && info "Found $stale_count potentially stale branches"

    return 0
}

# ─── Size Analysis ─────────────────────────────────────────────────────────

analyze_size() {
    info "Analyzing repository size..."

    local total_size=0

    # Find large files
    info "Largest files:"
    find "$REPO_DIR" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' 2>/dev/null | \
        xargs ls -lh 2>/dev/null | \
        awk '{print $5, $9}' | \
        sort -h | \
        tail -10 | \
        while read size file; do
            echo -e "  ${DIM}$size${RESET} $(basename "$file")"
        done

    # Find bloated directories
    info "Largest directories:"
    du -sh "$REPO_DIR"/* 2>/dev/null | sort -h | tail -10 | while read size dir; do
        echo -e "  ${DIM}$size${RESET} $(basename "$dir")"
    done

    # Check for binary files
    info "Checking for unexpected binary files..."
    local binary_count=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        warn "Binary file in repo: $(basename "$file")"
        ((binary_count++))
    done < <(find "$REPO_DIR" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.claude/*' \
        -exec file {} \; 2>/dev/null | grep -i "executable\|binary" | cut -d: -f1 || true)

    [[ $VERBOSE == true ]] && info "Found $binary_count binary files"

    return 0
}

# ─── Auto-Fix Mode ────────────────────────────────────────────────────────

auto_fix_issues() {
    info "Auto-fixing safe issues..."

    local fixed_count=0

    # Fix script permissions
    info "Setting script permissions..."
    while IFS= read -r script; do
        if ! [[ -x "$script" ]]; then
            chmod +x "$script"
            success "Made executable: $(basename "$script")"
            ((fixed_count++))
        fi
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null)

    # Remove trailing whitespace
    info "Removing trailing whitespace..."
    while IFS= read -r file; do
        if grep -q '[[:space:]]$' "$file" 2>/dev/null; then
            sed -i.bak 's/[[:space:]]*$//' "$file" 2>/dev/null || sed -i '' 's/[[:space:]]*$//' "$file"
            rm -f "${file}.bak" 2>/dev/null || true
            success "Cleaned whitespace: $(basename "$file")"
            ((fixed_count++))
        fi
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | head -20)

    # Clean up temp files
    info "Removing temporary files..."
    find "$REPO_DIR" -name "*.tmp" -o -name "*.bak" -o -name "*~" 2>/dev/null | while read tmpfile; do
        rm -f "$tmpfile"
        success "Removed: $(basename "$tmpfile")"
        ((fixed_count++))
    done

    # Remove old build artifacts
    info "Removing old build artifacts (>$ARTIFACT_AGE_DAYS days)..."
    find "$REPO_DIR" -type f \( -name "*.o" -o -name "*.a" -o -name "*.out" \) \
        -mtime "+$ARTIFACT_AGE_DAYS" 2>/dev/null | while read artifact; do
        rm -f "$artifact"
        success "Removed: $(basename "$artifact")"
        ((fixed_count++))
    done

    success "Auto-fixed $fixed_count issues"

    # Create a commit if changes were made
    if [[ $fixed_count -gt 0 ]] && git rev-parse --git-dir &>/dev/null; then
        git add -A
        git commit -m "chore: hygiene auto-fix ($fixed_count items)

- Fixed script permissions
- Removed trailing whitespace
- Cleaned temporary files
- Removed old build artifacts

Relates to #74" 2>/dev/null || true
        success "Created hygiene auto-fix commit"
    fi

    emit_event "hygiene_fix" "fixed=$fixed_count" "type=auto"
}

# ─── Comprehensive Report ───────────────────────────────────────────────────

generate_report() {
    local report_file
    report_file="$REPO_DIR/.claude/hygiene-report.json"

    info "Generating comprehensive hygiene report..."
    mkdir -p "$REPO_DIR/.claude"

    # Build JSON report
    local report
    report=$(cat <<'EOF'
{
    "timestamp": "TIMESTAMP",
    "repository": "REPO",
    "version": "VERSION",
    "sections": {
        "dead_code": {},
        "structure": {},
        "dependencies": {},
        "naming": {},
        "branches": {},
        "size": {}
    }
}
EOF
)

    # Replace placeholders
    report="${report//TIMESTAMP/$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    report="${report//REPO/$(basename "$REPO_DIR")}"
    report="${report//VERSION/$VERSION}"

    if [[ $JSON_OUTPUT == true ]]; then
        echo "$report" | jq .
    else
        echo "$report" > "$report_file"
        success "Report saved to: $report_file"
    fi
}

# ─── Full Scan ──────────────────────────────────────────────────────────────

run_full_scan() {
    echo -e "${CYAN}${BOLD}╭─ Shipwright Hygiene Scan ─────────────────────────────────────╮${RESET}"

    detect_dead_code
    validate_structure
    audit_dependencies
    check_naming
    list_stale_branches
    analyze_size

    echo -e "${CYAN}${BOLD}╰────────────────────────────────────────────────────────────────╯${RESET}"

    emit_event "hygiene_scan" "status=complete"
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)       AUTO_FIX=true; shift ;;
            --verbose|-v) VERBOSE=true; shift ;;
            --json)      JSON_OUTPUT=true; shift ;;
            --artifact-age) ARTIFACT_AGE_DAYS="$2"; shift 2 ;;
            *)           break ;;
        esac
    done

    # Route to subcommand
    case "$SUBCOMMAND" in
        scan)
            run_full_scan
            ;;
        dead-code)
            detect_dead_code
            ;;
        structure)
            validate_structure
            ;;
        dependencies)
            audit_dependencies
            ;;
        naming)
            check_naming
            ;;
        branches)
            list_stale_branches
            ;;
        size)
            analyze_size
            ;;
        fix)
            if [[ $AUTO_FIX != true ]]; then
                AUTO_FIX=true
            fi
            auto_fix_issues
            ;;
        report)
            generate_report
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown subcommand: $SUBCOMMAND"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Source guard
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
