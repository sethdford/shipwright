# daemon-patrol.sh — Patrol and patrol_* (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires state, helpers.
[[ -n "${_DAEMON_PATROL_LOADED:-}" ]] && return 0
_DAEMON_PATROL_LOADED=1

# Ensure NO_GITHUB is set (parent sw-daemon.sh / sw-pipeline.sh normally sets it,
# but under set -u bare references crash if this file is sourced standalone).
NO_GITHUB="${NO_GITHUB:-false}"
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
EVENTS_FILE="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

# Defaults for patrol configuration (normally set by sw-daemon.sh, but must be
# safe under set -u when this file is sourced in other contexts like tests).
PATROL_INTERVAL="${PATROL_INTERVAL:-3600}"
PATROL_MAX_ISSUES="${PATROL_MAX_ISSUES:-5}"
PATROL_LABEL="${PATROL_LABEL:-auto-patrol}"
PATROL_DRY_RUN="${PATROL_DRY_RUN:-false}"
PATROL_AUTO_WATCH="${PATROL_AUTO_WATCH:-false}"
PATROL_FAILURES_THRESHOLD="${PATROL_FAILURES_THRESHOLD:-3}"
PATROL_DORA_ENABLED="${PATROL_DORA_ENABLED:-true}"
PATROL_UNTESTED_ENABLED="${PATROL_UNTESTED_ENABLED:-true}"
PATROL_RETRY_ENABLED="${PATROL_RETRY_ENABLED:-true}"
PATROL_RETRY_THRESHOLD="${PATROL_RETRY_THRESHOLD:-2}"
PATROL_OVERSIZED_ENABLED="${PATROL_OVERSIZED_ENABLED:-true}"
PATROL_OVERSIZED_THRESHOLD="${PATROL_OVERSIZED_THRESHOLD:-2000}"

# Shared script-size scanner (also backs `shipwright hygiene script-size`).
_HYGIENE_SIZE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hygiene-size.sh"
# shellcheck source=hygiene-size.sh
[[ -f "$_HYGIENE_SIZE_LIB" ]] && source "$_HYGIENE_SIZE_LIB"

# ─── Decision Engine Signal Mode ─────────────────────────────────────────────
# When DECISION_ENGINE_ENABLED=true, patrol writes candidates to the pending
# signals file instead of creating GitHub issues directly. The decision engine
# collects, scores, and acts on these signals with tiered autonomy.
SIGNALS_PENDING_FILE="${HOME}/.shipwright/signals/pending.jsonl"

_patrol_emit_signal() {
    local id="$1" signal="$2" category="$3" title="$4" description="$5"
    local risk="${6:-50}" confidence="${7:-0.80}" dedup_key="$8"
    mkdir -p "$(dirname "$SIGNALS_PENDING_FILE")"
    local ts
    ts=$(now_iso)
    local candidate
    candidate=$(jq -n \
        --arg id "$id" --arg signal "$signal" --arg category "$category" \
        --arg title "$title" --arg desc "$description" \
        --argjson risk "$risk" --arg conf "$confidence" \
        --arg dedup "$dedup_key" --arg ts "$ts" \
        '{id:$id, signal:$signal, category:$category, title:$title, description:$desc, evidence:{}, risk_score:$risk, confidence:$conf, dedup_key:$dedup, collected_at:$ts}')
    echo "$candidate" >> "$SIGNALS_PENDING_FILE"
}

patrol_build_labels() {
    local check_label="$1"
    local labels="${PATROL_LABEL},${check_label}"
    if [[ "$PATROL_AUTO_WATCH" == "true" && -n "${WATCH_LABEL:-}" ]]; then
        labels="${labels},${WATCH_LABEL}"
    fi
    echo "$labels"
}

# ─── Oversized Script Detection ──────────────────────────────────────────────
# Top-level (not nested in daemon_patrol) so it is directly unit-testable.
# When called from daemon_patrol it reads that function's locals via bash
# dynamic scoping; standalone callers get the ${...:-} defaults below.
patrol_oversized_scripts() {
    if [[ "$PATROL_OVERSIZED_ENABLED" != "true" ]]; then return; fi
    local threshold="$PATROL_OVERSIZED_THRESHOLD"
    [[ "$threshold" =~ ^[0-9]+$ ]] && [[ "$threshold" -gt 0 ]] || threshold=2000
    daemon_log INFO "Patrol: checking for scripts over ${threshold} lines"

    local scripts_dir="$SCRIPT_DIR"
    if [[ ! -d "$scripts_dir" ]]; then
        daemon_log INFO "Patrol: scripts directory not found — skipping"
        return
    fi
    if ! type hygiene_oversized_scripts >/dev/null 2>&1; then
        daemon_log WARN "Patrol: lib/hygiene-size.sh not loaded — skipping oversized-script check"
        return
    fi

    local oversized findings
    oversized=$(hygiene_oversized_scripts "$threshold" "$scripts_dir")
    findings=$(echo "$oversized" | jq 'length' 2>/dev/null || true)
    findings="${findings:-0}"
    [[ "$findings" =~ ^[0-9]+$ ]] || findings=0

    if [[ "$findings" -eq 0 ]]; then
        daemon_log INFO "Patrol: no scripts exceed ${threshold} lines"
        return
    fi

    local oversized_list=""
    while IFS='|' read -r script lines; do
        [[ -n "$script" ]] || continue
        oversized_list="${oversized_list}\n- \`${script}\` (${lines} lines)"
        emit_event "patrol.finding" "check=oversized_script" "script=$script" "lines=$lines"
        if [[ "${dry_run:-$PATROL_DRY_RUN}" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
            echo -e "    ${YELLOW}●${RESET} ${CYAN}${script}${RESET} (${lines} lines)"
        fi
    done < <(echo "$oversized" | jq -r '.[] | "\(.script)|\(.lines)"' 2>/dev/null)

    total_findings=$(( ${total_findings:-0} + findings ))

    if [[ "${DECISION_ENGINE_ENABLED:-false}" == "true" ]]; then
        _patrol_emit_signal "hygiene-oversized-${findings}" "hygiene" "oversized_scripts" \
            "Decompose ${findings} oversized script(s)" \
            "Scripts exceeding ${threshold} lines" \
            35 "0.95" "hygiene:oversized:${threshold}"
    elif [[ "$NO_GITHUB" != "true" ]] && [[ "${dry_run:-$PATROL_DRY_RUN}" != "true" ]]; then
        # Dedup fails closed: this patrol runs hourly, so an errored `gh`
        # query must never be read as "nothing filed yet" — that would turn
        # the check into an hourly issue generator. Only an affirmative "0"
        # authorizes filing.
        local existing
        existing=$(gh issue list --label "$PATROL_LABEL" --label "hygiene" \
            --search "Decompose oversized scripts" --json number -q 'length' 2>/dev/null || true)
        if [[ "$existing" != "0" ]]; then
            daemon_log WARN "Patrol: oversized-script dedup query returned '${existing:-<empty>}' (expected \"0\") — not filing"
        elif [[ "${issues_created:-0}" -lt "$PATROL_MAX_ISSUES" ]]; then
            gh issue create \
                --title "Decompose oversized scripts (${findings} over ${threshold} lines)" \
                --body "## Decompose oversized scripts

The following scripts exceed the ${threshold}-line hygiene threshold:
$(echo -e "$oversized_list")

### Why this matters
Large scripts are harder to review, test, and reason about. Extract cohesive
sections into \`scripts/lib/*.sh\` modules with a load guard, sourced by the
original script — see \`scripts/lib/hygiene-size.sh\` for the pattern.

### Verifying
\`\`\`
shipwright hygiene script-size --max-script-lines ${threshold}
\`\`\`

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                --label "$(patrol_build_labels "hygiene")" 2>/dev/null || true
            issues_created=$(( ${issues_created:-0} + 1 ))
            emit_event "patrol.issue_created" "check=oversized_scripts" "count=$findings"
        fi
    fi

    daemon_log INFO "Patrol: found ${findings} script(s) over ${threshold} lines"
}
# ─── Proactive Patrol Mode ───────────────────────────────────────────────────

daemon_patrol() {
    local once=false
    local dry_run="$PATROL_DRY_RUN"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --once)    once=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            *)         shift ;;
        esac
    done

    echo -e "${PURPLE}${BOLD}━━━ Codebase Patrol ━━━${RESET}"
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo -e "  ${YELLOW}DRY RUN${RESET} — findings will be reported but no issues created"
        echo ""
    fi

    emit_event "patrol.started" "dry_run=$dry_run"

    local total_findings=0
    local issues_created=0

    # ── 1. Dependency Security Audit ──
    patrol_security_audit() {
        daemon_log INFO "Patrol: running dependency security audit"
        local findings=0

        # npm audit
        if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
            local audit_json
            audit_json=$(npm audit --json 2>/dev/null || echo '{}')
            local audit_version
            audit_version=$(echo "$audit_json" | jq -r '.auditReportVersion // 1')

            local vuln_list
            if [[ "$audit_version" == "2" ]]; then
                # npm 7+ format: .vulnerabilities is an object keyed by package name
                vuln_list=$(echo "$audit_json" | jq -c '[.vulnerabilities | to_entries[] | .value | {name: .name, severity: .severity, url: (.via[0].url // "N/A"), title: (.via[0].title // .name)}]' 2>/dev/null || echo '[]')
            else
                # npm 6 format: .advisories is an object keyed by advisory ID
                vuln_list=$(echo "$audit_json" | jq -c '[.advisories | to_entries[] | .value | {name: .module_name, severity: .severity, url: .url, title: .title}]' 2>/dev/null || echo '[]')
            fi

            if [[ -n "$vuln_list" && "$vuln_list" != "[]" ]]; then
                while IFS= read -r vuln; do
                    local severity name advisory_url title
                    severity=$(echo "$vuln" | jq -r '.severity // "unknown"')
                    name=$(echo "$vuln" | jq -r '.name // "unknown"')
                    advisory_url=$(echo "$vuln" | jq -r '.url // ""')
                    title=$(echo "$vuln" | jq -r '.title // "vulnerability"')

                    # Only report critical/high
                    if [[ "$severity" != "critical" ]] && [[ "$severity" != "high" ]]; then
                        continue
                    fi

                    findings=$((findings + 1))
                    emit_event "patrol.finding" "check=security" "severity=$severity" "package=$name"

                    # Route to decision engine or create issue directly
                    if [[ "${DECISION_ENGINE_ENABLED:-false}" == "true" ]]; then
                        local _cat="security_patch"
                        [[ "$severity" == "critical" ]] && _cat="security_critical"
                        _patrol_emit_signal "sec-${name}" "security" "$_cat" \
                            "Security: ${title} in ${name}" \
                            "Fix ${severity} vulnerability in ${name}" \
                            "$([[ "$severity" == "critical" ]] && echo 80 || echo 50)" \
                            "0.95" "security:${name}:${title}"
                    elif [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
                        local existing
                        existing=$(gh issue list --label "$PATROL_LABEL" --label "security" \
                            --search "Security: $name" --json number -q 'length' 2>/dev/null || echo "0")
                        if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                            gh issue create \
                                --title "Security: ${title} in ${name}" \
                                --body "## Dependency Security Finding

| Field | Value |
|-------|-------|
| Package | \`${name}\` |
| Severity | **${severity}** |
| Advisory | ${advisory_url} |
| Found by | Shipwright patrol |
| Date | $(now_iso) |

Auto-detected by \`shipwright daemon patrol\`." \
                                --label "$(patrol_build_labels "security")" 2>/dev/null || true
                            issues_created=$((issues_created + 1))
                            emit_event "patrol.issue_created" "check=security" "package=$name"
                        fi
                    else
                        echo -e "    ${RED}●${RESET} ${BOLD}${severity}${RESET}: ${title} in ${CYAN}${name}${RESET}"
                    fi
                done < <(echo "$vuln_list" | jq -c '.[]' 2>/dev/null)
            fi
        fi

        # pip-audit
        if [[ -f "requirements.txt" ]] && command -v pip-audit >/dev/null 2>&1; then
            local pip_json
            pip_json=$(pip-audit --format=json 2>/dev/null || true)
            if [[ -n "$pip_json" ]]; then
                local vuln_count
                vuln_count=$(echo "$pip_json" | jq '[.dependencies[] | select(.vulns | length > 0)] | length' 2>/dev/null || echo "0")
                findings=$((findings + ${vuln_count:-0}))
            fi
        fi

        # cargo audit
        if [[ -f "Cargo.toml" ]] && command -v cargo-audit >/dev/null 2>&1; then
            local cargo_json
            cargo_json=$(cargo audit --json 2>/dev/null || true)
            if [[ -n "$cargo_json" ]]; then
                local vuln_count
                vuln_count=$(echo "$cargo_json" | jq '.vulnerabilities.found' 2>/dev/null || echo "0")
                findings=$((findings + ${vuln_count:-0}))
            fi
        fi

        # Enrich with GitHub security alerts
        if type gh_security_alerts >/dev/null 2>&1 && [[ "${NO_GITHUB:-false}" != "true" ]]; then
            if type _gh_detect_repo >/dev/null 2>&1; then
                _gh_detect_repo 2>/dev/null || true
            fi
            local gh_owner="${GH_OWNER:-}" gh_repo="${GH_REPO:-}"
            if [[ -n "$gh_owner" && -n "$gh_repo" ]]; then
                local gh_alerts
                gh_alerts=$(gh_security_alerts "$gh_owner" "$gh_repo" 2>/dev/null || echo "[]")
                local gh_alert_count
                gh_alert_count=$(echo "$gh_alerts" | jq 'length' 2>/dev/null || echo "0")
                if [[ "${gh_alert_count:-0}" -gt 0 ]]; then
                    daemon_log WARN "Patrol: $gh_alert_count GitHub security alert(s) found"
                    findings=$((findings + gh_alert_count))
                fi
            fi
        fi

        # Enrich with GitHub Dependabot alerts
        if type gh_dependabot_alerts >/dev/null 2>&1 && [[ "${NO_GITHUB:-false}" != "true" ]]; then
            local gh_owner="${GH_OWNER:-}" gh_repo="${GH_REPO:-}"
            if [[ -n "$gh_owner" && -n "$gh_repo" ]]; then
                local dep_alerts
                dep_alerts=$(gh_dependabot_alerts "$gh_owner" "$gh_repo" 2>/dev/null || echo "[]")
                local dep_alert_count
                dep_alert_count=$(echo "$dep_alerts" | jq 'length' 2>/dev/null || echo "0")
                if [[ "${dep_alert_count:-0}" -gt 0 ]]; then
                    daemon_log WARN "Patrol: $dep_alert_count Dependabot alert(s) found"
                    findings=$((findings + dep_alert_count))
                fi
            fi
        fi

        total_findings=$((total_findings + findings))
        if [[ "$findings" -gt 0 ]]; then
            daemon_log INFO "Patrol: found ${findings} security vulnerability(ies)"
        else
            daemon_log INFO "Patrol: no security vulnerabilities found"
        fi
    }

    # ── 2. Stale Dependency Check ──
    patrol_stale_dependencies() {
        daemon_log INFO "Patrol: checking for stale dependencies"
        local findings=0

        if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
            local outdated_json
            outdated_json=$(npm outdated --json 2>/dev/null || true)
            if [[ -n "$outdated_json" ]] && [[ "$outdated_json" != "{}" ]]; then
                local stale_packages=""
                while IFS= read -r pkg; do
                    local name current latest current_major latest_major
                    name=$(echo "$pkg" | jq -r '.key')
                    current=$(echo "$pkg" | jq -r '.value.current // "0.0.0"')
                    latest=$(echo "$pkg" | jq -r '.value.latest // "0.0.0"')
                    current_major="${current%%.*}"
                    latest_major="${latest%%.*}"

                    # Only flag if > 2 major versions behind
                    if [[ "$latest_major" =~ ^[0-9]+$ ]] && [[ "$current_major" =~ ^[0-9]+$ ]]; then
                        local diff=$((latest_major - current_major))
                        if [[ "$diff" -ge 2 ]]; then
                            findings=$((findings + 1))
                            stale_packages="${stale_packages}\n- \`${name}\`: ${current} → ${latest} (${diff} major versions behind)"
                            emit_event "patrol.finding" "check=stale_dependency" "package=$name" "current=$current" "latest=$latest"

                            if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                                echo -e "    ${YELLOW}●${RESET} ${CYAN}${name}${RESET}: ${current} → ${latest} (${diff} major versions behind)"
                            fi
                        fi
                    fi
                done < <(echo "$outdated_json" | jq -c 'to_entries[]' 2>/dev/null)

                # Route to decision engine or create issue
                if [[ "$findings" -gt 0 ]] && [[ "${DECISION_ENGINE_ENABLED:-false}" == "true" ]]; then
                    _patrol_emit_signal "deps-stale-${findings}" "deps" "deps_major" \
                        "Update ${findings} stale dependencies" \
                        "Packages 2+ major versions behind" \
                        45 "0.90" "deps:stale:${findings}"
                elif [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
                    local existing
                    existing=$(gh issue list --label "$PATROL_LABEL" --label "dependencies" \
                        --search "Stale dependencies" --json number -q 'length' 2>/dev/null || echo "0")
                    if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                        gh issue create \
                            --title "Update ${findings} stale dependencies" \
                            --body "## Stale Dependencies

The following packages are 2+ major versions behind:
$(echo -e "$stale_packages")

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                            --label "$(patrol_build_labels "dependencies")" 2>/dev/null || true
                        issues_created=$((issues_created + 1))
                        emit_event "patrol.issue_created" "check=stale_dependency" "count=$findings"
                    fi
                fi
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} stale dependency(ies)"
    }

    # ── 3. Dead Code Detection ──
    patrol_dead_code() {
        daemon_log INFO "Patrol: scanning for dead code"
        local findings=0
        local dead_files=""

        # For JS/TS projects: find exported files not imported anywhere
        if [[ -f "package.json" ]] || [[ -f "tsconfig.json" ]]; then
            local src_dirs=("src" "lib" "app")
            for dir in "${src_dirs[@]}"; do
                [[ -d "$dir" ]] || continue
                while IFS= read -r file; do
                    local basename_no_ext
                    basename_no_ext=$(basename "$file" | sed 's/\.\(ts\|js\|tsx\|jsx\)$//')
                    # Skip index files and test files
                    [[ "$basename_no_ext" == "index" ]] && continue
                    [[ "$basename_no_ext" =~ \.(test|spec)$ ]] && continue

                    # Check if this file is imported anywhere
                    local import_count
                    import_count=$(grep -rlE "(from|require).*['\"].*${basename_no_ext}['\"]" \
                        --include="*.ts" --include="*.js" --include="*.tsx" --include="*.jsx" \
                        . 2>/dev/null | grep -cv "$file" || true)
                    import_count=${import_count:-0}

                    if [[ "$import_count" -eq 0 ]]; then
                        findings=$((findings + 1))
                        dead_files="${dead_files}\n- \`${file}\`"
                        if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                            echo -e "    ${DIM}●${RESET} ${file} ${DIM}(not imported)${RESET}"
                        fi
                    fi
                done < <(find "$dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" \) \
                    ! -name "*.test.*" ! -name "*.spec.*" ! -name "*.d.ts" 2>/dev/null)
            done
        fi

        if [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "tech-debt" \
                --search "Dead code candidates" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Dead code candidates (${findings} files)" \
                    --body "## Dead Code Detection

These files appear to have no importers — they may be unused:
$(echo -e "$dead_files")

> **Note:** Some files may be entry points or dynamically loaded. Verify before removing.

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "tech-debt")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=dead_code" "count=$findings"
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} dead code candidate(s)"
    }

    # ── 4. Test Coverage Gaps ──
    patrol_coverage_gaps() {
        daemon_log INFO "Patrol: checking test coverage gaps"
        local findings=0
        local low_cov_files=""

        # Look for coverage reports from last pipeline run
        local coverage_file=""
        for candidate in \
            ".claude/pipeline-artifacts/coverage/coverage-summary.json" \
            "coverage/coverage-summary.json" \
            ".coverage/coverage-summary.json"; do
            if [[ -f "$candidate" ]]; then
                coverage_file="$candidate"
                break
            fi
        done

        if [[ -z "$coverage_file" ]]; then
            daemon_log INFO "Patrol: no coverage report found — skipping"
            return
        fi

        while IFS= read -r entry; do
            local file_path line_pct
            file_path=$(echo "$entry" | jq -r '.key')
            line_pct=$(echo "$entry" | jq -r '.value.lines.pct // 100')

            # Skip total and well-covered files
            [[ "$file_path" == "total" ]] && continue
            if awk "BEGIN{exit !($line_pct >= 50)}" 2>/dev/null; then continue; fi

            findings=$((findings + 1))
            low_cov_files="${low_cov_files}\n- \`${file_path}\`: ${line_pct}% line coverage"

            if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                echo -e "    ${YELLOW}●${RESET} ${file_path}: ${line_pct}% coverage"
            fi
        done < <(jq -c 'to_entries[]' "$coverage_file" 2>/dev/null)

        if [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "testing" \
                --search "Test coverage gaps" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Improve test coverage for ${findings} file(s)" \
                    --body "## Test Coverage Gaps

These files have < 50% line coverage:
$(echo -e "$low_cov_files")

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "testing")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=coverage" "count=$findings"
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} low-coverage file(s)"
    }

    # ── 5. Documentation Staleness ──
    patrol_doc_staleness() {
        daemon_log INFO "Patrol: checking documentation staleness"
        local findings=0
        local stale_docs=""

        # Check if README is older than recent source changes
        if [[ -f "README.md" ]]; then
            local readme_epoch src_epoch
            readme_epoch=$(git log -1 --format=%ct -- README.md 2>/dev/null || echo "0")
            src_epoch=$(git log -1 --format=%ct -- "*.ts" "*.js" "*.py" "*.go" "*.rs" "*.sh" 2>/dev/null || echo "0")

            if [[ "$src_epoch" -gt 0 ]] && [[ "$readme_epoch" -gt 0 ]]; then
                local drift=$((src_epoch - readme_epoch))
                # Flag if README is > 30 days behind source
                if [[ "$drift" -gt 2592000 ]]; then
                    findings=$((findings + 1))
                    local days_behind=$((drift / 86400))
                    stale_docs="${stale_docs}\n- \`README.md\`: ${days_behind} days behind source code"
                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${YELLOW}●${RESET} README.md is ${days_behind} days behind source code"
                    fi
                fi
            fi
        fi

        # Check if CHANGELOG is behind latest tag
        if [[ -f "CHANGELOG.md" ]]; then
            local latest_tag changelog_epoch tag_epoch
            latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
            if [[ -n "$latest_tag" ]]; then
                changelog_epoch=$(git log -1 --format=%ct -- CHANGELOG.md 2>/dev/null || echo "0")
                tag_epoch=$(git log -1 --format=%ct "$latest_tag" 2>/dev/null || echo "0")
                if [[ "$tag_epoch" -gt "$changelog_epoch" ]] && [[ "$changelog_epoch" -gt 0 ]]; then
                    findings=$((findings + 1))
                    stale_docs="${stale_docs}\n- \`CHANGELOG.md\`: not updated since tag \`${latest_tag}\`"
                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${YELLOW}●${RESET} CHANGELOG.md not updated since ${latest_tag}"
                    fi
                fi
            fi
        fi

        # Check CLAUDE.md staleness (same pattern as README)
        if [[ -f ".claude/CLAUDE.md" ]]; then
            local claudemd_epoch claudemd_src_epoch
            claudemd_src_epoch=$(git log -1 --format=%ct -- "*.ts" "*.js" "*.py" "*.go" "*.rs" "*.sh" 2>/dev/null || echo "0")
            claudemd_epoch=$(git log -1 --format=%ct -- ".claude/CLAUDE.md" 2>/dev/null || echo "0")
            if [[ "$claudemd_src_epoch" -gt 0 ]] && [[ "$claudemd_epoch" -gt 0 ]]; then
                local claude_drift=$((claudemd_src_epoch - claudemd_epoch))
                if [[ "$claude_drift" -gt 2592000 ]]; then
                    findings=$((findings + 1))
                    local claude_days_behind=$((claude_drift / 86400))
                    stale_docs="${stale_docs}\n- \`.claude/CLAUDE.md\`: ${claude_days_behind} days behind source code"
                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${YELLOW}●${RESET} CLAUDE.md is ${claude_days_behind} days behind source code"
                    fi
                fi
            fi
        fi

        # Check AUTO section freshness (if sw-docs.sh available)
        if [[ -x "$SCRIPT_DIR/sw-docs.sh" ]]; then
            local docs_stale=false
            bash "$SCRIPT_DIR/sw-docs.sh" check >/dev/null 2>&1 || docs_stale=true
            if [[ "$docs_stale" == "true" ]]; then
                findings=$((findings + 1))
                stale_docs="${stale_docs}\n- AUTO sections: some documentation sections are stale"
                if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                    echo -e "    ${YELLOW}●${RESET} AUTO documentation sections are stale"
                fi
                # Auto-sync if not dry run
                if [[ "$dry_run" != "true" ]] && [[ "$NO_GITHUB" != "true" ]]; then
                    daemon_log INFO "Auto-syncing stale documentation sections"
                    bash "$SCRIPT_DIR/sw-docs.sh" sync 2>/dev/null || true
                    if ! git diff --quiet -- '*.md' 2>/dev/null; then
                        git add -A '*.md' 2>/dev/null || true
                        git commit -m "docs: auto-sync stale documentation sections" 2>/dev/null || true
                    fi
                fi
            fi
        fi

        if [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "documentation" \
                --search "Stale documentation" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Stale documentation detected" \
                    --body "## Documentation Staleness

The following docs may need updating:
$(echo -e "$stale_docs")

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "documentation")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=documentation" "count=$findings"
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} stale documentation item(s)"
    }

    # ── 6. Performance Baseline ──
    patrol_performance_baseline() {
        daemon_log INFO "Patrol: checking performance baseline"

        # Look for test timing in recent pipeline events
        if [[ ! -f "$EVENTS_FILE" ]]; then
            daemon_log INFO "Patrol: no events file — skipping performance check"
            return
        fi

        local baseline_file="$DAEMON_DIR/patrol-perf-baseline.json"
        local recent_test_dur
        recent_test_dur=$(tail -500 "$EVENTS_FILE" | \
            jq -s '[.[] | select(.type == "stage.completed" and .stage == "test") | .duration_s] | if length > 0 then .[-1] else null end' \
            2>/dev/null || echo "null")

        if [[ "$recent_test_dur" == "null" ]] || [[ -z "$recent_test_dur" ]]; then
            daemon_log INFO "Patrol: no recent test duration found — skipping"
            return
        fi

        if [[ -f "$baseline_file" ]]; then
            local baseline_dur
            baseline_dur=$(jq -r '.test_duration_s // 0' "$baseline_file" 2>/dev/null || echo "0")
            if [[ "$baseline_dur" -gt 0 ]]; then
                local threshold=$(( baseline_dur * 130 / 100 ))  # 30% slower
                if [[ "$recent_test_dur" -gt "$threshold" ]]; then
                    total_findings=$((total_findings + 1))
                    local pct_slower=$(( (recent_test_dur - baseline_dur) * 100 / baseline_dur ))
                    emit_event "patrol.finding" "check=performance" "baseline=${baseline_dur}s" "current=${recent_test_dur}s" "regression=${pct_slower}%"

                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${RED}●${RESET} Test suite ${pct_slower}% slower than baseline (${baseline_dur}s → ${recent_test_dur}s)"
                    elif [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                        local existing
                        existing=$(gh issue list --label "$PATROL_LABEL" --label "performance" \
                            --search "Test suite performance regression" --json number -q 'length' 2>/dev/null || echo "0")
                        if [[ "${existing:-0}" -eq 0 ]]; then
                            gh issue create \
                                --title "Test suite performance regression (${pct_slower}% slower)" \
                                --body "## Performance Regression

| Metric | Value |
|--------|-------|
| Baseline | ${baseline_dur}s |
| Current | ${recent_test_dur}s |
| Regression | ${pct_slower}% |

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                                --label "$(patrol_build_labels "performance")" 2>/dev/null || true
                            issues_created=$((issues_created + 1))
                            emit_event "patrol.issue_created" "check=performance"
                        fi
                    fi

                    daemon_log WARN "Patrol: test suite ${pct_slower}% slower than baseline"
                    return
                fi
            fi
        fi

        # Save/update baseline
        jq -n --argjson dur "$recent_test_dur" --arg ts "$(now_iso)" \
            '{test_duration_s: $dur, updated_at: $ts}' > "$baseline_file"
        daemon_log INFO "Patrol: performance baseline updated (${recent_test_dur}s)"
    }

    # ── 7. Recurring Failure Patterns ──
    patrol_recurring_failures() {
        if [[ "$PATROL_FAILURES_THRESHOLD" -le 0 ]]; then return; fi
        daemon_log INFO "Patrol: checking recurring failure patterns"
        local findings=0

        # Source memory functions if available
        local memory_script="$SCRIPT_DIR/sw-memory.sh"
        if [[ ! -f "$memory_script" ]]; then
            daemon_log INFO "Patrol: memory script not found — skipping recurring failures"
            return
        fi

        # Get actionable failures from memory
        # Note: sw-memory.sh runs its CLI router on source, so we must redirect
        # the source's stdout to /dev/null and only capture the function's output
        local failures_json
        failures_json=$(
            (
                source "$memory_script" > /dev/null 2>&1 || true
                if command -v memory_get_actionable_failures >/dev/null 2>&1; then
                    memory_get_actionable_failures "$PATROL_FAILURES_THRESHOLD"
                else
                    echo "[]"
                fi
            )
        )

        local count
        count=$(echo "$failures_json" | jq 'length' 2>/dev/null || echo "0")
        if [[ "${count:-0}" -eq 0 ]]; then
            daemon_log INFO "Patrol: no recurring failures above threshold ($PATROL_FAILURES_THRESHOLD)"
            return
        fi

        while IFS= read -r failure; do
            local pattern stage seen_count last_seen root_cause
            pattern=$(echo "$failure" | jq -r '.pattern // "unknown"')
            stage=$(echo "$failure" | jq -r '.stage // "unknown"')
            seen_count=$(echo "$failure" | jq -r '.seen_count // 0')
            last_seen=$(echo "$failure" | jq -r '.last_seen // "unknown"')
            root_cause=$(echo "$failure" | jq -r '.root_cause // "Not yet identified"')

            # Truncate pattern for title (first 60 chars)
            local short_pattern
            short_pattern=$(echo "$pattern" | cut -c1-60)

            findings=$((findings + 1))
            emit_event "patrol.finding" "check=recurring_failure" "pattern=$short_pattern" "seen_count=$seen_count"

            if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
                # Deduplicate
                local existing
                existing=$(gh issue list --label "$PATROL_LABEL" --label "recurring-failure" \
                    --search "Fix recurring: ${short_pattern}" --json number -q 'length' 2>/dev/null || echo "0")
                if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                    gh issue create \
                        --title "Fix recurring: ${short_pattern}" \
                        --body "## Recurring Failure Pattern

| Field | Value |
|-------|-------|
| Stage | \`${stage}\` |
| Pattern | \`${pattern}\` |
| Seen count | **${seen_count}** |
| Last seen | ${last_seen} |
| Root cause | ${root_cause} |
| Found by | Shipwright patrol |
| Date | $(now_iso) |

### Suggested Actions
- Investigate the root cause in the \`${stage}\` stage
- Check if recent changes introduced the failure
- Add a targeted test to prevent regression

Auto-detected by \`shipwright daemon patrol\`." \
                        --label "$(patrol_build_labels "recurring-failure")" 2>/dev/null || true
                    issues_created=$((issues_created + 1))
                    emit_event "patrol.issue_created" "check=recurring_failure" "pattern=$short_pattern"
                fi
            else
                echo -e "    ${RED}●${RESET} ${BOLD}recurring${RESET}: ${short_pattern} (${seen_count}x in ${CYAN}${stage}${RESET})"
            fi
        done < <(echo "$failures_json" | jq -c '.[]' 2>/dev/null)

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} recurring failure pattern(s)"
    }

    # ── 8. DORA Metric Degradation ──
    patrol_dora_degradation() {
        if [[ "$PATROL_DORA_ENABLED" != "true" ]]; then return; fi
        daemon_log INFO "Patrol: checking DORA metric degradation"

        if [[ ! -f "$EVENTS_FILE" ]]; then
            daemon_log INFO "Patrol: no events file — skipping DORA check"
            return
        fi

        local now_e
        now_e=$(now_epoch)

        # Current 7-day window
        local current_start=$((now_e - 604800))
        # Previous 7-day window
        local prev_start=$((now_e - 1209600))
        local prev_end=$current_start

        # Get events for both windows
        local current_events prev_events
        current_events=$(jq -s --argjson start "$current_start" \
            '[.[] | select(.ts_epoch >= $start)]' "$EVENTS_FILE" 2>/dev/null || echo "[]")
        prev_events=$(jq -s --argjson start "$prev_start" --argjson end "$prev_end" \
            '[.[] | select(.ts_epoch >= $start and .ts_epoch < $end)]' "$EVENTS_FILE" 2>/dev/null || echo "[]")

        # Helper: calculate DORA metrics from an event set
        calc_dora() {
            local events="$1"
            local total successes failures
            total=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed")] | length' 2>/dev/null || echo "0")
            successes=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length' 2>/dev/null || echo "0")
            failures=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length' 2>/dev/null || echo "0")

            local deploy_freq="0"
            [[ "$total" -gt 0 ]] && deploy_freq=$(echo "$successes 7" | awk '{printf "%.1f", $1 / ($2 / 7)}')

            local cfr="0"
            [[ "$total" -gt 0 ]] && cfr=$(echo "$failures $total" | awk '{printf "%.1f", ($1 / $2) * 100}')

            local cycle_time="0"
            cycle_time=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "success") | .duration_s] | sort | if length > 0 then .[length/2 | floor] else 0 end' 2>/dev/null || echo "0")

            echo "{\"deploy_freq\":$deploy_freq,\"cfr\":$cfr,\"cycle_time\":$cycle_time,\"total\":$total}"
        }

        local current_metrics prev_metrics
        current_metrics=$(calc_dora "$current_events")
        prev_metrics=$(calc_dora "$prev_events")

        local prev_total
        prev_total=$(echo "$prev_metrics" | jq '.total' 2>/dev/null || echo "0")
        local current_total
        current_total=$(echo "$current_metrics" | jq '.total' 2>/dev/null || echo "0")

        # Need data in both windows to compare
        if [[ "${prev_total:-0}" -lt 3 ]] || [[ "${current_total:-0}" -lt 3 ]]; then
            daemon_log INFO "Patrol: insufficient data for DORA comparison (prev=$prev_total, current=$current_total)"
            return
        fi

        # Grade each metric using dora_grade (defined in daemon_metrics, redefined here inline)
        local_dora_grade() {
            local metric="$1" value="$2"
            case "$metric" in
                deploy_freq)
                    if awk "BEGIN{exit !($value >= 7)}" 2>/dev/null; then echo "Elite"; return; fi
                    if awk "BEGIN{exit !($value >= 1)}" 2>/dev/null; then echo "High"; return; fi
                    if awk "BEGIN{exit !($value >= 0.25)}" 2>/dev/null; then echo "Medium"; return; fi
                    echo "Low" ;;
                cfr)
                    if awk "BEGIN{exit !($value < 5)}" 2>/dev/null; then echo "Elite"; return; fi
                    if awk "BEGIN{exit !($value < 10)}" 2>/dev/null; then echo "High"; return; fi
                    if awk "BEGIN{exit !($value < 15)}" 2>/dev/null; then echo "Medium"; return; fi
                    echo "Low" ;;
                cycle_time)
                    [[ "$value" -lt 3600 ]] && echo "Elite" && return
                    [[ "$value" -lt 86400 ]] && echo "High" && return
                    [[ "$value" -lt 604800 ]] && echo "Medium" && return
                    echo "Low" ;;
            esac
        }

        grade_rank() {
            case "$1" in
                Elite) echo 4 ;; High) echo 3 ;; Medium) echo 2 ;; Low) echo 1 ;; *) echo 0 ;;
            esac
        }

        local degraded_metrics=""
        local degradation_details=""

        # Check deploy frequency
        local prev_df curr_df
        prev_df=$(echo "$prev_metrics" | jq -r '.deploy_freq')
        curr_df=$(echo "$current_metrics" | jq -r '.deploy_freq')
        local prev_df_grade curr_df_grade
        prev_df_grade=$(local_dora_grade deploy_freq "$prev_df")
        curr_df_grade=$(local_dora_grade deploy_freq "$curr_df")
        if [[ "$(grade_rank "$curr_df_grade")" -lt "$(grade_rank "$prev_df_grade")" ]]; then
            degraded_metrics="${degraded_metrics}deploy_freq "
            degradation_details="${degradation_details}\n| Deploy Frequency | ${prev_df_grade} (${prev_df}/wk) | ${curr_df_grade} (${curr_df}/wk) | Check for blocked PRs, increase automation |"
        fi

        # Check CFR
        local prev_cfr curr_cfr
        prev_cfr=$(echo "$prev_metrics" | jq -r '.cfr')
        curr_cfr=$(echo "$current_metrics" | jq -r '.cfr')
        local prev_cfr_grade curr_cfr_grade
        prev_cfr_grade=$(local_dora_grade cfr "$prev_cfr")
        curr_cfr_grade=$(local_dora_grade cfr "$curr_cfr")
        if [[ "$(grade_rank "$curr_cfr_grade")" -lt "$(grade_rank "$prev_cfr_grade")" ]]; then
            degraded_metrics="${degraded_metrics}cfr "
            degradation_details="${degradation_details}\n| Change Failure Rate | ${prev_cfr_grade} (${prev_cfr}%) | ${curr_cfr_grade} (${curr_cfr}%) | Investigate recent failures, improve test coverage |"
        fi

        # Check Cycle Time
        local prev_ct curr_ct
        prev_ct=$(echo "$prev_metrics" | jq -r '.cycle_time')
        curr_ct=$(echo "$current_metrics" | jq -r '.cycle_time')
        local prev_ct_grade curr_ct_grade
        prev_ct_grade=$(local_dora_grade cycle_time "$prev_ct")
        curr_ct_grade=$(local_dora_grade cycle_time "$curr_ct")
        if [[ "$(grade_rank "$curr_ct_grade")" -lt "$(grade_rank "$prev_ct_grade")" ]]; then
            degraded_metrics="${degraded_metrics}cycle_time "
            degradation_details="${degradation_details}\n| Cycle Time | ${prev_ct_grade} (${prev_ct}s) | ${curr_ct_grade} (${curr_ct}s) | Profile slow stages, check for new slow tests |"
        fi

        if [[ -z "$degraded_metrics" ]]; then
            daemon_log INFO "Patrol: no DORA degradation detected"
            return
        fi

        local findings=0
        findings=1
        total_findings=$((total_findings + findings))
        emit_event "patrol.finding" "check=dora_regression" "metrics=$degraded_metrics"

        if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local trimmed
            trimmed=$(echo "$degraded_metrics" | sed 's/ *$//' | tr ' ' ',')
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "dora-regression" \
                --search "DORA regression" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "DORA regression: ${trimmed}" \
                    --body "## DORA Metric Degradation

| Metric | Previous (7d) | Current (7d) | Suggested Action |
|--------|---------------|--------------|------------------|$(echo -e "$degradation_details")

> Compared: previous 7-day window vs current 7-day window.

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "dora-regression")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=dora_regression" "metrics=$trimmed"
            fi
        else
            local trimmed
            trimmed=$(echo "$degraded_metrics" | sed 's/ *$//')
            echo -e "    ${RED}●${RESET} ${BOLD}DORA regression${RESET}: ${trimmed}"
        fi

        daemon_log INFO "Patrol: DORA degradation detected in: ${degraded_metrics}"
    }

    # ── 9. Untested Scripts ──
    patrol_untested_scripts() {
        if [[ "$PATROL_UNTESTED_ENABLED" != "true" ]]; then return; fi
        daemon_log INFO "Patrol: checking for untested scripts"
        local findings=0
        local untested_list=""

        local scripts_dir="$SCRIPT_DIR"
        if [[ ! -d "$scripts_dir" ]]; then
            daemon_log INFO "Patrol: scripts directory not found — skipping"
            return
        fi

        # Collect untested scripts with usage counts
        local untested_entries=""
        while IFS= read -r script; do
            local basename
            basename=$(basename "$script")
            # Skip test scripts themselves
            [[ "$basename" == *-test.sh ]] && continue
            # Skip the main CLI router
            [[ "$basename" == "sw" ]] && continue

            # Extract the name part (sw-NAME.sh -> NAME)
            local name
            name=$(echo "$basename" | sed 's/^sw-//' | sed 's/\.sh$//')

            # Check if a test file exists
            if [[ ! -f "$scripts_dir/sw-${name}-test.sh" ]]; then
                # Count usage across other scripts
                local usage_count
                usage_count=$(grep -rl "sw-${name}" "$scripts_dir"/sw-*.sh 2>/dev/null | grep -cv "$basename" 2>/dev/null || true)
                usage_count=${usage_count:-0}

                local line_count
                line_count=$(wc -l < "$script" 2>/dev/null | tr -d ' ' || true)
                line_count="${line_count:-0}"

                untested_entries="${untested_entries}${usage_count}|${basename}|${line_count}\n"
                findings=$((findings + 1))
            fi
        done < <(find "$scripts_dir" -maxdepth 1 -name "sw-*.sh" -type f 2>/dev/null | sort)

        if [[ "$findings" -eq 0 ]]; then
            daemon_log INFO "Patrol: all scripts have test files"
            return
        fi

        # Sort by usage count descending
        local sorted_entries
        sorted_entries=$(echo -e "$untested_entries" | sort -t'|' -k1 -rn | head -10)

        while IFS='|' read -r usage_count basename line_count; do
            [[ -z "$basename" ]] && continue
            untested_list="${untested_list}\n- \`${basename}\` (${line_count} lines, referenced by ${usage_count} scripts)"
            emit_event "patrol.finding" "check=untested_script" "script=$basename" "lines=$line_count" "usage=$usage_count"

            if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                echo -e "    ${YELLOW}●${RESET} ${CYAN}${basename}${RESET} (${line_count} lines, ${usage_count} refs)"
            fi
        done <<< "$sorted_entries"

        total_findings=$((total_findings + findings))

        if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "test-coverage" \
                --search "Add tests for untested scripts" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Add tests for ${findings} untested script(s)" \
                    --body "## Untested Scripts

The following scripts have no corresponding test file (\`sw-*-test.sh\`):
$(echo -e "$untested_list")

### How to Add Tests
Each test file should follow the pattern in existing test scripts (e.g., \`sw-daemon-test.sh\`):
- Mock environment with TEMP_DIR
- PASS/FAIL counters
- \`run_test\` harness
- Register in \`package.json\` test script

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "test-coverage")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=untested_scripts" "count=$findings"
            fi
        fi

        daemon_log INFO "Patrol: found ${findings} untested script(s)"
    }

    # ── 10. Retry Exhaustion Patterns ──
    patrol_retry_exhaustion() {
        if [[ "$PATROL_RETRY_ENABLED" != "true" ]]; then return; fi
        daemon_log INFO "Patrol: checking retry exhaustion patterns"
        local findings=0

        if [[ ! -f "$EVENTS_FILE" ]]; then
            daemon_log INFO "Patrol: no events file — skipping retry check"
            return
        fi

        local seven_days_ago
        seven_days_ago=$(($(now_epoch) - 604800))

        # Find retry_exhausted events in last 7 days
        local exhausted_events
        exhausted_events=$(jq -s --argjson since "$seven_days_ago" \
            '[.[] | select(.type == "daemon.retry_exhausted" and (.ts_epoch // 0) >= $since)]' \
            "$EVENTS_FILE" 2>/dev/null || echo "[]")

        local exhausted_count
        exhausted_count=$(echo "$exhausted_events" | jq 'length' 2>/dev/null || echo "0")

        if [[ "${exhausted_count:-0}" -lt "$PATROL_RETRY_THRESHOLD" ]]; then
            daemon_log INFO "Patrol: retry exhaustions ($exhausted_count) below threshold ($PATROL_RETRY_THRESHOLD)"
            return
        fi

        findings=1
        total_findings=$((total_findings + findings))

        # Get unique issue patterns
        local issue_list
        issue_list=$(echo "$exhausted_events" | jq -r '[.[] | .issue // "unknown"] | unique | join(", ")' 2>/dev/null || echo "unknown")

        local first_ts last_ts
        first_ts=$(echo "$exhausted_events" | jq -r '[.[] | .ts] | sort | first // "unknown"' 2>/dev/null || echo "unknown")
        last_ts=$(echo "$exhausted_events" | jq -r '[.[] | .ts] | sort | last // "unknown"' 2>/dev/null || echo "unknown")

        emit_event "patrol.finding" "check=retry_exhaustion" "count=$exhausted_count" "issues=$issue_list"

        if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "reliability" \
                --search "Retry exhaustion pattern" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Retry exhaustion pattern (${exhausted_count} in 7 days)" \
                    --body "## Retry Exhaustion Pattern

| Field | Value |
|-------|-------|
| Exhaustions (7d) | **${exhausted_count}** |
| Threshold | ${PATROL_RETRY_THRESHOLD} |
| Affected issues | ${issue_list} |
| First occurrence | ${first_ts} |
| Latest occurrence | ${last_ts} |

### Investigation Steps
1. Check the affected issues for common patterns
2. Review pipeline logs for root cause
3. Consider if max_retries needs adjustment
4. Investigate if an external dependency is flaky

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "reliability")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=retry_exhaustion" "count=$exhausted_count"
            fi
        else
            echo -e "    ${RED}●${RESET} ${BOLD}retry exhaustion${RESET}: ${exhausted_count} exhaustions in 7 days (issues: ${issue_list})"
        fi

        daemon_log INFO "Patrol: found retry exhaustion pattern (${exhausted_count} in 7 days)"
    }

    # ── Stage 1: Run all grep-based patrol checks (fast pre-filter) ──
    local patrol_findings_summary=""
    local pre_check_findings=0

    echo -e "  ${BOLD}Security Audit${RESET}"
    pre_check_findings=$total_findings
    patrol_security_audit
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}security: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Stale Dependencies${RESET}"
    pre_check_findings=$total_findings
    patrol_stale_dependencies
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}stale_deps: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Dead Code Detection${RESET}"
    pre_check_findings=$total_findings
    patrol_dead_code
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}dead_code: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Test Coverage Gaps${RESET}"
    pre_check_findings=$total_findings
    patrol_coverage_gaps
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}coverage: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Documentation Staleness${RESET}"
    pre_check_findings=$total_findings
    patrol_doc_staleness
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}docs: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Performance Baseline${RESET}"
    pre_check_findings=$total_findings
    patrol_performance_baseline
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}performance: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Recurring Failures${RESET}"
    pre_check_findings=$total_findings
    patrol_recurring_failures
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}recurring_failures: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}DORA Degradation${RESET}"
    pre_check_findings=$total_findings
    patrol_dora_degradation
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}dora: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Untested Scripts${RESET}"
    pre_check_findings=$total_findings
    patrol_untested_scripts
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}untested: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Retry Exhaustion${RESET}"
    pre_check_findings=$total_findings
    patrol_retry_exhaustion
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}retry_exhaustion: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Oversized Scripts${RESET}"
    pre_check_findings=$total_findings
    patrol_oversized_scripts
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}oversized_scripts: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Dead Pane Reaping${RESET}"
    pre_check_findings=$total_findings
    if [[ -x "$SCRIPT_DIR/sw-reaper.sh" ]] && [[ -n "${TMUX:-}" ]]; then
        local reaper_output
        reaper_output=$(bash "$SCRIPT_DIR/sw-reaper.sh" --once 2>/dev/null) || true
        local reaped_count=0
        reaped_count=$(echo "$reaper_output" | grep -c "Reaped" 2>/dev/null || true)
        if [[ "${reaped_count:-0}" -gt 0 ]]; then
            total_findings=$((total_findings + reaped_count))
            echo -e "    ${CYAN}●${RESET} Reaped ${reaped_count} dead agent pane(s)"
        else
            echo -e "    ${GREEN}●${RESET} No dead panes found"
        fi
    else
        echo -e "    ${DIM}●${RESET} Skipped (no tmux session or reaper not found)"
    fi
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}reaper: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    # ── Stage 2: AI-Powered Confirmation (if enabled) ──
    if [[ "${PREDICTION_ENABLED:-false}" == "true" ]] && type patrol_ai_analyze >/dev/null 2>&1; then
        daemon_log INFO "Intelligence: using AI patrol analysis (prediction enabled)"
        echo -e "  ${BOLD}AI Deep Analysis${RESET}"
        # Sample recent source files for AI analysis
        local sample_files=""
        local git_log_recent=""
        sample_files=$(git diff --name-only HEAD~5 2>/dev/null | head -10 | tr '\n' ',' || echo "")
        git_log_recent=$(git log --oneline -10 2>/dev/null || echo "")
        # Include grep-based findings summary as context for AI confirmation
        if [[ -n "$patrol_findings_summary" ]]; then
            git_log_recent="${git_log_recent}

Patrol pre-filter findings to confirm: ${patrol_findings_summary}"
            daemon_log INFO "Patrol: passing ${total_findings} grep findings to AI for confirmation"
        fi
        if [[ -n "$sample_files" ]]; then
            local ai_findings
            ai_findings=$(patrol_ai_analyze "$sample_files" "$git_log_recent" 2>/dev/null || echo "[]")
            if [[ -n "$ai_findings" && "$ai_findings" != "[]" ]]; then
                local ai_count
                ai_count=$(echo "$ai_findings" | jq 'length' 2>/dev/null || echo "0")
                ai_count=${ai_count:-0}
                total_findings=$((total_findings + ai_count))
                echo -e "    ${CYAN}●${RESET} AI confirmed findings + found ${ai_count} additional issue(s)"
                emit_event "patrol.ai_analysis" "findings=$ai_count" "grep_findings=${patrol_findings_summary:-none}"
            else
                echo -e "    ${GREEN}●${RESET} AI analysis: grep findings confirmed, no additional issues"
            fi
        fi
        echo ""
    else
        daemon_log INFO "Intelligence: using grep-only patrol (prediction disabled, enable with intelligence.prediction_enabled=true)"
    fi

    # ── Meta Self-Improvement Patrol ──
    if [[ -f "$SCRIPT_DIR/sw-patrol-meta.sh" ]]; then
        # shellcheck source=sw-patrol-meta.sh
        source "$SCRIPT_DIR/sw-patrol-meta.sh"
        patrol_meta_run
    fi

    # ── Strategic Intelligence Patrol (requires CLAUDE_CODE_OAUTH_TOKEN) ──
    if [[ -f "$SCRIPT_DIR/sw-strategic.sh" ]] && [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        # shellcheck source=sw-strategic.sh
        source "$SCRIPT_DIR/sw-strategic.sh"
        strategic_patrol_run || true
    fi

    # ── Summary ──
    emit_event "patrol.completed" "findings=$total_findings" "issues_created=$issues_created" "dry_run=$dry_run"

    echo -e "${PURPLE}${BOLD}━━━ Patrol Summary ━━━${RESET}"
    echo -e "  Findings:       ${total_findings}"
    echo -e "  Issues created: ${issues_created}"
    if [[ "$dry_run" == "true" ]]; then
        echo -e "  ${DIM}(dry run — no issues were created)${RESET}"
    fi
    echo ""

    daemon_log INFO "Patrol complete: ${total_findings} findings, ${issues_created} issues created"

    # Adapt patrol limits based on hit rate (requires daemon-adaptive.sh)
    if type adapt_patrol_limits >/dev/null 2>&1; then
        adapt_patrol_limits "$total_findings" "$PATROL_MAX_ISSUES"
    fi
}

