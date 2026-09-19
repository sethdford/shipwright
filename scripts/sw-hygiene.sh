#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright hygiene — Repository Organization & Cleanup                 ║
# ║  Dead code detection · Structure enforcement · Dependency audit         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Policy (config/policy.json) — tunables override defaults when present
[[ -f "$SCRIPT_DIR/lib/policy.sh" ]] && source "$SCRIPT_DIR/lib/policy.sh"
# Canonical helpers (colors, output, events)
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Shared script-size scanning (also used by the daemon patrol)
# shellcheck source=lib/hygiene-size.sh
[[ -f "$SCRIPT_DIR/lib/hygiene-size.sh" ]] && source "$SCRIPT_DIR/lib/hygiene-size.sh"
# Fallback when helpers.sh not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Default Settings (policy overrides when config/policy.json exists) ──────
SUBCOMMAND="${1:-help}"
AUTO_FIX=false
VERBOSE=false
ARTIFACT_AGE_DAYS=$(_config_get_int "cleanup.artifact_age_days" 7)
MAX_SCRIPT_LINES=$(_config_get_int "hygiene.max_script_lines" 1500)
MAX_SCRIPT_LINES=${MAX_SCRIPT_LINES:-1500}
[[ "$MAX_SCRIPT_LINES" =~ ^[0-9]+$ ]] && [[ "$MAX_SCRIPT_LINES" -gt 0 ]] || MAX_SCRIPT_LINES=1500
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
    echo -e "  ${CYAN}script-size${RESET}   Flag scripts exceeding size threshold (for decomposition)"
    echo -e "  ${CYAN}platform-refactor${RESET}  Scan for hardcoded/fallback/TODO/FIXME — for AGI-level self-improvement"
    echo -e "  ${CYAN}fix${RESET}           Auto-fix safe issues (naming, whitespace)"
    echo -e "  ${CYAN}report${RESET}        Generate comprehensive hygiene report"
    echo -e "  ${CYAN}help${RESET}          Show this help message"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--fix${RESET}               Auto-fix issues (use with caution)"
    echo -e "  ${CYAN}--verbose, -v${RESET}       Verbose output"
    echo -e "  ${CYAN}--json${RESET}              JSON output format"
    echo -e "  ${CYAN}--artifact-age${RESET}      Max age for artifacts in days (default: 7)"
    echo -e "  ${CYAN}--max-script-lines${RESET}  Script size threshold for decomposition (default: 1500)"
    echo -e "  ${CYAN}--help, -h${RESET}          Show this help"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright hygiene scan${RESET}                           # Full scan"
    echo -e "  ${DIM}shipwright hygiene dead-code${RESET}                      # Find unused code"
    echo -e "  ${DIM}shipwright hygiene script-size${RESET}                    # Check script sizes"
    echo -e "  ${DIM}shipwright hygiene script-size --max-script-lines 2000${RESET}  # Custom threshold"
    echo -e "  ${DIM}shipwright hygiene fix${RESET}                            # Auto-fix safe issues"
    echo -e "  ${DIM}shipwright hygiene report --json${RESET}                  # JSON report"
    echo ""
}

# ─── Dead Code Detection ────────────────────────────────────────────────────

detect_dead_code() {
    info "Scanning for dead code..."

    local unused_functions=0
    local unused_scripts=0
    local orphaned_tests=0
    local func_limit
    func_limit=$(_config_get_int "limits.function_scan_limit" 0)

    # Unused functions and scripts are resolved in two linear passes rather than
    # one recursive grep per symbol.
    #
    # The previous shape was O(symbols x tree): every one of the ~4,200 function
    # definitions ran a fresh `grep -r` across the whole scripts/ tree plus ~4
    # subprocess spawns, so the scan grew quadratically with the repo. It took
    # ~190s on an M-series Mac and overran the 300s per-suite budget on
    # macos-latest — where fork() and BSD grep are both slower than on Linux —
    # so sw-hygiene-test timed out there while passing on ubuntu-latest. One
    # pass to list definitions plus one pass to index identifier usage is
    # O(symbols + tree) and completes in under a second.
    #
    # Usage is counted per identifier token instead of per substring, so a
    # helper named `run` is no longer counted as "used" by an unrelated line
    # containing the word "running". The unused rule itself is unchanged: a
    # definition mentions its own name once, so a total of <=1 means nothing
    # references it.
    local defs_file names_file scan_out
    defs_file=$(mktemp "${TMPDIR:-/tmp}/sw-hygiene-defs.XXXXXX")
    names_file=$(mktemp "${TMPDIR:-/tmp}/sw-hygiene-names.XXXXXX")
    local files_file
    files_file=$(mktemp "${TMPDIR:-/tmp}/sw-hygiene-files.XXXXXX")

    find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null | LC_ALL=C sort > "$files_file"

    # funcname<TAB>defining-file, from a single grep over the tree
    find "$REPO_DIR/scripts" -name "*.sh" -type f -exec \
        grep -HE '^[a-z_][a-z0-9_]*\(\)' {} + 2>/dev/null \
        | awk -F: 'match($2, /^[a-z_][a-z0-9_]*/) {
              print substr($2, RSTART, RLENGTH) "\t" $1
          }' > "$defs_file" || true

    # Candidate scripts, minus the ones the old loop deliberately skipped
    find "$REPO_DIR/scripts" -maxdepth 1 -name "sw-*.sh" -type f 2>/dev/null \
        | awk -F/ '{ b = $NF
              if (b ~ /-test\.sh$/) next
              if (b == "sw-hygiene.sh") next
              print b
          }' > "$names_file" || true

    scan_out=$(awk -v defs="$defs_file" -v names="$names_file" \
                   -v filelist="$files_file" -v limit="$func_limit" '
        # Count each distinct token once per line, matching the old
        # "lines that mention this symbol" semantics.
        function index_line(line,   s, t, seen) {
            split("", seen)
            s = line
            while (match(s, /[A-Za-z_][A-Za-z0-9_]*/)) {
                t = substr(s, RSTART, RLENGTH)
                if (!(t in seen)) { seen[t] = 1; fcnt[t]++ }
                s = substr(s, RSTART + RLENGTH)
            }
            split("", seen)
            s = line
            while (match(s, /[A-Za-z0-9_][A-Za-z0-9_.-]*/)) {
                t = substr(s, RSTART, RLENGTH)
                if (!(t in seen)) { seen[t] = 1; scnt[t]++ }
                s = substr(s, RSTART + RLENGTH)
            }
        }
        BEGIN {
            while ((getline l < defs) > 0) {
                if (limit > 0 && ndef >= limit) break
                split(l, p, "\t")
                ndef++; dname[ndef] = p[1]; dfile[ndef] = p[2]
            }
            close(defs)
            while ((getline l < names) > 0) { nscr++; sname[nscr] = l }
            close(names)

            while ((getline f < filelist) > 0) {
                while ((getline l < f) > 0) index_line(l)
                close(f)
            }
            close(filelist)

            uf = 0
            for (i = 1; i <= ndef; i++) {
                n = (dname[i] in fcnt) ? fcnt[dname[i]] : 0
                if (n <= 1) { uf++; print "FUNC\t" dname[i] "\t" dfile[i] }
            }
            us = 0
            for (i = 1; i <= nscr; i++) {
                n = (sname[i] in scnt) ? scnt[sname[i]] : 0
                if (n <= 1) { us++; print "SCRIPT\t" sname[i] }
            }
            print "TOTALS\t" uf "\t" us
        }')

    rm -f "$defs_file" "$names_file" "$files_file"

    unused_functions=$(printf '%s\n' "$scan_out" | awk -F'\t' '$1=="TOTALS" { print $2; exit }')
    unused_scripts=$(printf '%s\n' "$scan_out" | awk -F'\t' '$1=="TOTALS" { print $3; exit }')
    unused_functions="${unused_functions:-0}"
    unused_scripts="${unused_scripts:-0}"

    if [[ $VERBOSE == true ]]; then
        while IFS=$'\t' read -r kind field_a field_b; do
            case "$kind" in
                FUNC)   warn "Unused function: $field_a (in $(basename "$field_b"))" ;;
                SCRIPT) warn "Potentially unused script: $field_a" ;;
            esac
        done <<< "$scan_out"
    fi

    # Find test fixtures without corresponding tests
    while IFS= read -r fixture; do
        local test_name
        test_name=$(basename "$fixture" .fixture)

        if ! grep -r "$test_name" "$REPO_DIR/scripts" --include="*-test.sh" 2>/dev/null | grep -q .; then
            warn "Orphaned test fixture: $(basename "$fixture")"
            orphaned_tests=$((orphaned_tests + 1))
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
            structure_issues=$((structure_issues + 1))
        fi
    done < <(find "$REPO_DIR" -name "*.sh" -type f ! -path "*/node_modules/*" ! -path "*/.git/*" 2>/dev/null | grep -E '(sw-|shipwright)' || true)

    # Check test naming conventions
    while IFS= read -r test; do
        local basename_test
        basename_test=$(basename "$test")

        if [[ ! "$basename_test" =~ -test\.sh$ ]]; then
            warn "Test file not named *-test.sh: $basename_test"
            structure_issues=$((structure_issues + 1))
        fi
    done < <(find "$REPO_DIR/scripts" -path "*test*" -name "*.sh" -type f 2>/dev/null)

    # Check directory organization
    if [[ ! -d "$REPO_DIR/scripts" ]]; then
        error "scripts/ directory missing"
        structure_issues=$((structure_issues + 1))
    fi

    if [[ ! -d "$REPO_DIR/.claude" ]]; then
        error ".claude/ directory missing"
        structure_issues=$((structure_issues + 1))
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
    local dep_limit
    dep_limit=$(_config_get_int "limits.dependency_scan_limit" 0)

    # Check for unused npm/yarn dependencies
    if [[ -f "$REPO_DIR/package.json" ]]; then
        local deps
        deps=$(jq -r '.dependencies, .devDependencies | keys[]?' "$REPO_DIR/package.json" 2>/dev/null || true)
        if [[ "$dep_limit" -gt 0 ]]; then
            deps=$(echo "$deps" | head -"$dep_limit")
        fi

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue

            # Simple check: does the dep appear in source files?
            if ! grep -r "$dep" "$REPO_DIR/scripts" --include="*.sh" 2>/dev/null | grep -q .; then
                [[ $VERBOSE == true ]] && warn "Potentially unused npm dependency: $dep"
                unused_deps=$((unused_deps + 1))
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
                circular_deps=$((circular_deps + 1))
            fi
        done <<< "$sourced_by"
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null)

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
            naming_issues=$((naming_issues + 1))
        fi
    done < <(find "$REPO_DIR/scripts" -maxdepth 1 -name "*.sh" -type f 2>/dev/null)

    # Check for functions not using snake_case
    while IFS= read -r script; do
        local bad_functions
        bad_functions=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$script" 2>/dev/null | grep -E '[A-Z]' | sed 's/()$//' || true)

        while IFS= read -r func; do
            [[ -z "$func" ]] && continue
            [[ $VERBOSE == true ]] && warn "Function not using snake_case: $func (in $(basename "$script"))"
            naming_issues=$((naming_issues + 1))
        done <<< "$bad_functions"
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null)

    [[ $VERBOSE == true ]] && {
        info "Naming validation: $naming_issues issues found"
    }

    return 0
}

# ─── Stale Branch Detection ────────────────────────────────────────────────

list_stale_branches() {
    info "Scanning for stale branches..."

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
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
            stale_count=$((stale_count + 1))
        done <<< "$merged_branches"
    fi

    # Find branches not updated in 30 days
    local old_branches
    # shellcheck disable=SC2046
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

# ─── Script Size Helpers ────────────────────────────────────────────────────

# _emit_script_sizes / check_script_sizes live in lib/hygiene-size.sh

report_script_sizes() {
    local threshold="$MAX_SCRIPT_LINES" oversized count

    if [[ "$JSON_OUTPUT" != true ]]; then
        info "Checking script sizes (threshold: ${threshold} lines)..."
    fi

    oversized=$(check_script_sizes "$threshold")
    count=$(echo "$oversized" | jq 'length' 2>/dev/null || echo "0")
    count=${count:-0}

    if [[ "$JSON_OUTPUT" == true ]]; then
        echo "$oversized" | jq .
    else
        if [[ "$count" -eq 0 ]]; then
            success "No scripts exceed ${threshold} lines"
        else
            warn "${count} script(s) exceed ${threshold} lines — decomposition candidates:"
            echo "$oversized" | jq -r '.[] | "  \(.lines)\t\(.script)"' 2>/dev/null | \
                while IFS=$'\t' read -r lines script; do
                    echo -e "  ${DIM}${lines} lines${RESET}  ${script}"
                done
        fi
    fi

    emit_event "hygiene_script_size" "threshold=$threshold" "oversized=$count"
    return 0
}

# ─── Size Analysis ─────────────────────────────────────────────────────────

analyze_size() {
    info "Analyzing repository size..."

    # shellcheck disable=SC2034
    local total_size=0

    # Find large files
    info "Largest files:"
    # shellcheck disable=SC2038
    find "$REPO_DIR" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' 2>/dev/null | \
        xargs ls -lh 2>/dev/null | \
        awk '{print $5, $9}' | \
        sort -h | \
        tail -10 | \
        while read -r size file; do
            echo -e "  ${DIM}$size${RESET} $(basename "$file")"
        done

    # Find bloated directories
    info "Largest directories:"
    du -sh "$REPO_DIR"/* 2>/dev/null | sort -h | tail -10 | while read -r size dir; do
        echo -e "  ${DIM}$size${RESET} $(basename "$dir")"
    done

    # Check for binary files
    info "Checking for unexpected binary files..."
    local binary_count=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        warn "Binary file in repo: $(basename "$file")"
        binary_count=$((binary_count + 1))
    done < <(find "$REPO_DIR" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.claude/*' \
        -exec file {} \; 2>/dev/null | grep -i "executable\|binary" | cut -d: -f1 || true)

    [[ $VERBOSE == true ]] && info "Found $binary_count binary files"

    return 0
}

# ─── Platform Refactor / Hardcoded Scan (AGI-Level Self-Improvement) ───
# Outputs JSON to REPO_DIR/.claude/platform-hygiene.json for strategic agent.
scan_platform_refactor() {
    info "Scanning for hardcoded/static/platform-refactor signals..."

    mkdir -p "$REPO_DIR/.claude"
    local out_file="$REPO_DIR/.claude/platform-hygiene.json"
    local scripts_dir="${REPO_DIR}/scripts"

    local hardcoded_count fallback_count todo_count fixme_count hack_count
    hardcoded_count=$(grep -rE "hardcoded|Hardcoded|HARDCODED" "$scripts_dir" --include="*.sh" 2>/dev/null | wc -l | tr -d ' ')
    fallback_count=$(grep -rE "Fallback:|fallback:" "$scripts_dir" --include="*.sh" 2>/dev/null | wc -l | tr -d ' ')
    todo_count=$(grep -rE "TODO" "$scripts_dir" --include="*.sh" 2>/dev/null | wc -l | tr -d ' ')
    fixme_count=$(grep -rE "FIXME" "$scripts_dir" --include="*.sh" 2>/dev/null | wc -l | tr -d ' ')
    hack_count=$(grep -rE "HACK|KLUDGE" "$scripts_dir" --include="*.sh" 2>/dev/null | wc -l | tr -d ' ')
    hardcoded_count=${hardcoded_count:-0}
    fallback_count=${fallback_count:-0}
    todo_count=${todo_count:-0}
    fixme_count=${fixme_count:-0}
    hack_count=${hack_count:-0}

    # Sample findings: file:line (first 25) for strategic context (grep -n gives file:line:content)
    local findings_file findings_raw
    findings_file=$(mktemp)
    findings_raw=$(mktemp)
    grep -rnE "hardcoded|Hardcoded|Fallback:|fallback:|TODO|FIXME|HACK|KLUDGE" "$scripts_dir" --include="*.sh" 2>/dev/null > "$findings_raw" || true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Split across statements: in a single `local a=… b="${a}"`, bash
        # declares every name first and only then evaluates the right-hand
        # sides, so "$rest" resolved to the newly-declared *unset* local and
        # aborted the function with "rest: unbound variable" under `set -u`.
        # The loop redirects stderr to /dev/null, so this failed silently and
        # `hygiene platform-refactor` just exited 1 with no message.
        # SC2318 is exactly this warning — it was suppressed here rather than fixed.
        local f="${line%%:*}"
        local rest="${line#*:}"
        local ln="${rest%%:*}"
        ln="${ln:-0}"
        printf '{"file":"%s","line":%s}\n' "${f#$REPO_DIR/}" "$ln"
    done < "$findings_raw" > "$findings_file.raw" 2>/dev/null || true
    jq -s '.' "$findings_file.raw" 2>/dev/null > "$findings_file" || echo "[]" > "$findings_file"
    local findings
    findings=$(cat "$findings_file" 2>/dev/null || echo "[]")
    rm -f "$findings_file" "$findings_file.raw" "$findings_raw"

    # Script sizes (lines) for hotspot detection
    local sizes_file script_sizes
    sizes_file=$(mktemp)
    _emit_script_sizes "$scripts_dir" | jq -s 'sort_by(-.lines) | .[0:15]' 2>/dev/null > "$sizes_file"
    script_sizes=$(cat "$sizes_file" 2>/dev/null || echo "[]")
    rm -f "$sizes_file"

    # Oversized scripts (exceeding threshold)
    local oversized oversized_count
    oversized=$(check_script_sizes "$MAX_SCRIPT_LINES")
    oversized_count=$(echo "$oversized" | jq 'length' 2>/dev/null || echo "0")
    oversized_count=${oversized_count:-0}

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local report
    report=$(jq -n \
        --arg ts "$timestamp" \
        --arg repo "$(basename "$REPO_DIR")" \
        --argjson hc "$hardcoded_count" \
        --argjson fb "$fallback_count" \
        --argjson todo "$todo_count" \
        --argjson fixme "$fixme_count" \
        --argjson hack "$hack_count" \
        --argjson findings "$findings" \
        --argjson script_sizes "$script_sizes" \
        --argjson oversized "$oversized" \
        --argjson oc "$oversized_count" \
        --argjson threshold "$MAX_SCRIPT_LINES" \
        '{timestamp:$ts,repository:$repo,counts:{hardcoded:$hc,fallback:$fb,todo:$todo,fixme:$fixme,hack:$hack,oversized_scripts:$oc},thresholds:{max_script_lines:$threshold},findings_sample:$findings,script_size_hotspots:$script_sizes,oversized_scripts:$oversized}' 2>/dev/null)
    if [[ -n "$report" ]]; then
        printf '%s\n' "$report" > "$out_file.tmp" && mv -f "$out_file.tmp" "$out_file"
        success "Platform refactor scan saved to: $out_file"
        if [[ "$JSON_OUTPUT" == true ]]; then
            echo "$report" | jq .
        else
            info "  hardcoded: $hardcoded_count  fallback: $fallback_count  TODO: $todo_count  FIXME: $fixme_count  HACK/KLUDGE: $hack_count  oversized: $oversized_count"
        fi
    else
        warn "Could not build platform-hygiene JSON (jq missing?)"
    fi
    emit_event "hygiene_platform_refactor" "hardcoded=$hardcoded_count" "fallback=$fallback_count" "todo=$todo_count" "oversized=$oversized_count"
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
            fixed_count=$((fixed_count + 1))
        fi
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null)

    # Remove trailing whitespace
    info "Removing trailing whitespace..."
    while IFS= read -r file; do
        if grep -q '[[:space:]]$' "$file" 2>/dev/null; then
            sed -i.bak 's/[[:space:]]*$//' "$file" 2>/dev/null || sed -i '' 's/[[:space:]]*$//' "$file"
            rm -f "${file}.bak" 2>/dev/null || true
            success "Cleaned whitespace: $(basename "$file")"
            fixed_count=$((fixed_count + 1))
        fi
    done < <(find "$REPO_DIR/scripts" -name "*.sh" -type f 2>/dev/null)

    # Clean up temp files
    info "Removing temporary files..."
    find "$REPO_DIR" -name "*.tmp" -o -name "*.bak" -o -name "*~" 2>/dev/null | while read -r tmpfile; do
        rm -f "$tmpfile"
        success "Removed: $(basename "$tmpfile")"
        fixed_count=$((fixed_count + 1))
    done

    # Remove old build artifacts
    info "Removing old build artifacts (>$ARTIFACT_AGE_DAYS days)..."
    find "$REPO_DIR" -type f \( -name "*.o" -o -name "*.a" -o -name "*.out" \) \
        -mtime "+$ARTIFACT_AGE_DAYS" 2>/dev/null | while read -r artifact; do
        rm -f "$artifact"
        success "Removed: $(basename "$artifact")"
        fixed_count=$((fixed_count + 1))
    done

    success "Auto-fixed $fixed_count issues"

    # Create a commit if changes were made
    if [[ $fixed_count -gt 0 ]] && git rev-parse --git-dir >/dev/null 2>&1; then
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

    # Include platform-hygiene if available (for strategic agent)
    local platform_refactor="{}"
    if [[ -f "$REPO_DIR/.claude/platform-hygiene.json" ]]; then
        platform_refactor=$(jq -c '.' "$REPO_DIR/.claude/platform-hygiene.json" 2>/dev/null || echo "{}")
    fi

    # Build JSON report
    local report
    report=$(jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg repo "$(basename "$REPO_DIR")" \
        --arg ver "$VERSION" \
        --argjson platform "$platform_refactor" \
        '{timestamp:$ts,repository:$repo,version:$ver,sections:{dead_code:{},structure:{},dependencies:{},naming:{},branches:{},size:{}},platform_refactor:$platform}' 2>/dev/null)
    if [[ -z "$report" ]]; then
        report=$(cat <<EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "repository": "$(basename "$REPO_DIR")",
    "version": "$VERSION",
    "sections": {
        "dead_code": {},
        "structure": {},
        "dependencies": {},
        "naming": {},
        "branches": {},
        "size": {},
        "platform_refactor": $platform_refactor
    }
}
EOF
)
    fi

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
    report_script_sizes
    scan_platform_refactor

    echo -e "${CYAN}${BOLD}╰────────────────────────────────────────────────────────────────╯${RESET}"

    emit_event "hygiene_scan" "status=complete"
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    # Shift off the subcommand to allow option parsing
    shift || true

    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)              AUTO_FIX=true; shift ;;
            --verbose|-v)       VERBOSE=true; shift ;;
            --json)             JSON_OUTPUT=true; shift ;;
            --artifact-age)     ARTIFACT_AGE_DAYS="$2"; shift 2 ;;
            --max-script-lines) MAX_SCRIPT_LINES="$2"; shift 2 ;;
            *)                  break ;;
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
        script-size|script-sizes)
            report_script_sizes
            ;;
        platform-refactor)
            scan_platform_refactor
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
