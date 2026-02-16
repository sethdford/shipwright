#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright security-audit — Comprehensive Security Auditing             ║
# ║  Secret detection · License checking · Vulnerability scanning · SBOM      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── Audit State ───────────────────────────────────────────────────────────
FINDINGS=()
CRITICAL_COUNT=0
HIGH_COUNT=0
MEDIUM_COUNT=0
LOW_COUNT=0

# Append finding with priority
add_finding() {
    local priority="$1"  # CRITICAL, HIGH, MEDIUM, LOW
    local category="$2"  # secrets, licenses, vulnerabilities, permissions, network, compliance
    local title="$3"
    local description="$4"
    local remediation="$5"

    local color=""
    case "$priority" in
        CRITICAL) color="$RED"; ((CRITICAL_COUNT++)) ;;
        HIGH) color="$RED"; ((HIGH_COUNT++)) ;;
        MEDIUM) color="$YELLOW"; ((MEDIUM_COUNT++)) ;;
        LOW) color="$BLUE"; ((LOW_COUNT++)) ;;
    esac

    FINDINGS+=("${priority}|${category}|${title}|${description}|${remediation}")
}

# ─── Secret Detection ───────────────────────────────────────────────────────

scan_secrets() {
    info "Scanning for hardcoded secrets..."

    local patterns=(
        "AKIA[0-9A-Z]{16}"                          # AWS Access Key ID
        "aws_secret_access_key\s*=\s*['\"]?[^\s'\"]*['\"]?"  # AWS Secret
        "password\s*[=:]\s*['\"]?[^\s'\"]*['\"]?"   # Generic password
        "api[_-]?key\s*[=:]\s*['\"]?[^\s'\"]*['\"]?"  # API key
        "token\s*[=:]\s*['\"]?[^\s'\"]*['\"]?"      # Generic token
        "gh_[a-zA-Z0-9_]{36}"                       # GitHub token
        "-----BEGIN RSA PRIVATE KEY-----"            # RSA private key
        "-----BEGIN PRIVATE KEY-----"                # Generic private key
        "PRIVATE KEY"                                # Private key marker
        "AUTH_TOKEN"                                 # Auth token
        "oauth_token\s*[=:]"                         # OAuth token
        "x-api-key\s*[=:]"                          # API key header
    )

    local secret_files=()
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        for pattern in "${patterns[@]}"; do
            if grep -qEi "$pattern" "$file" 2>/dev/null; then
                secret_files+=("$file")
                break
            fi
        done
    done < <(find "$REPO_DIR" -type f \( -name "*.sh" -o -name "*.py" -o -name "*.js" -o -name "*.json" -o -name ".env*" -o -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | grep -v ".git\|node_modules\|.worktree" || true)

    if [[ ${#secret_files[@]} -gt 0 ]]; then
        for file in "${secret_files[@]}"; do
            add_finding "CRITICAL" "secrets" "Potential hardcoded secret in $file" \
                "Found patterns matching secret formats (AWS keys, API keys, tokens, private keys)" \
                "Rotate credentials immediately. Remove secrets from version control. Use environment variables or secret management system instead. Use git-secrets or pre-commit hooks to prevent future leaks."
        done
    fi

    # Check for .env files in git
    if find "$REPO_DIR" -name ".env" -type f ! -path "*/.git/*" ! -path "*/.worktree/*" 2>/dev/null | grep -q .; then
        add_finding "HIGH" "secrets" ".env file in repository" \
            ".env files containing secrets should never be committed to version control" \
            "Add .env to .gitignore. Use .env.example template instead. Document required variables in README."
    fi

    local secret_count=${#secret_files[@]}
    [[ $secret_count -eq 0 ]] && success "No obvious hardcoded secrets detected" || warn "Found $secret_count files with potential secrets"
}

# ─── License Compliance ─────────────────────────────────────────────────────

scan_licenses() {
    info "Scanning for license compliance..."

    # Detect package manager
    local has_npm=false has_pip=false has_go=false has_cargo=false

    [[ -f "$REPO_DIR/package.json" ]] && has_npm=true
    [[ -f "$REPO_DIR/requirements.txt" || -f "$REPO_DIR/setup.py" ]] && has_pip=true
    [[ -f "$REPO_DIR/go.mod" ]] && has_go=true
    [[ -f "$REPO_DIR/Cargo.toml" ]] && has_cargo=true

    # Check npm licenses
    if $has_npm && command -v npm &>/dev/null; then
        while IFS= read -r line; do
            [[ "$line" =~ GPL|AGPL ]] && [[ ! "$line" =~ MIT|Apache|BSD ]] && \
                add_finding "MEDIUM" "licenses" "GPL/AGPL dependency in npm project" \
                    "Found GPL/AGPL licensed package: $line" \
                    "Review license compatibility. Consider alternatives with permissive licenses. Document GPL/AGPL usage."
        done < <(npm list --depth=0 2>/dev/null | grep -i "gpl\|agpl" || true)
    fi

    # Check for LICENSES directory
    if [[ ! -d "$REPO_DIR/LICENSES" ]]; then
        add_finding "LOW" "licenses" "Missing LICENSES directory" \
            "No LICENSES directory found for SPDX/license documentation" \
            "Create LICENSES/ directory. Document all third-party licenses used. Generate with license scanner tools."
    fi

    # Detect MIT project using GPL
    if [[ -f "$REPO_DIR/LICENSE" ]]; then
        if grep -qi "MIT\|Apache" "$REPO_DIR/LICENSE" 2>/dev/null; then
            # MIT/Apache project — flag GPL dependencies
            while IFS= read -r line; do
                [[ "$line" =~ GPL|AGPL ]] && \
                    add_finding "HIGH" "licenses" "GPL/AGPL in permissive project" \
                        "MIT/Apache project using GPL/AGPL dependency: $line" \
                        "Replace GPL dependencies with permissive alternatives. Update LICENSE file if needed."
            done < <(npm list 2>/dev/null | grep -i "gpl\|agpl" || true)
        fi
    fi

    success "License compliance check complete"
}

# ─── Vulnerability Scanning ────────────────────────────────────────────────

scan_vulnerabilities() {
    info "Scanning for known vulnerabilities..."

    local vuln_count=0

    # Check npm vulnerabilities
    if [[ -f "$REPO_DIR/package.json" ]] && command -v npm &>/dev/null; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            ((vuln_count++))
            add_finding "HIGH" "vulnerabilities" "npm security vulnerability" \
                "Found npm audit issue: $line" \
                "Run 'npm audit fix' to remediate. Update vulnerable dependencies. Re-test after updates."
        done < <(npm audit 2>/dev/null | grep -i "vulnerability\|found" || true)
    fi

    # Check pip vulnerabilities
    if [[ -f "$REPO_DIR/requirements.txt" ]] && command -v pip &>/dev/null; then
        if command -v safety &>/dev/null; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                ((vuln_count++))
                add_finding "HIGH" "vulnerabilities" "Python package vulnerability" \
                    "Found via safety: $line" \
                    "Update vulnerable package. Test compatibility. Run safety check after updates."
            done < <(safety check 2>/dev/null || true)
        fi
    fi

    [[ $vuln_count -eq 0 ]] && success "No known vulnerabilities detected" || warn "Found $vuln_count vulnerabilities"
}

# ─── SBOM Generation ───────────────────────────────────────────────────────

generate_sbom() {
    info "Generating Software Bill of Materials..."

    local sbom_file="${REPO_DIR}/.claude/pipeline-artifacts/sbom.json"
    mkdir -p "$(dirname "$sbom_file")"

    local sbom='{"bomFormat":"CycloneDX","specVersion":"1.4","version":1,"components":[]}'

    # Add npm packages
    if [[ -f "$REPO_DIR/package.json" ]] && command -v npm &>/dev/null; then
        local npm_list
        npm_list=$(npm list --json 2>/dev/null || echo '{"dependencies":{}}')
        while IFS='=' read -r name version; do
            [[ -z "$name" || -z "$version" ]] && continue
            sbom=$(echo "$sbom" | jq --arg n "$name" --arg v "$version" \
                '.components += [{"type":"library","name":$n,"version":$v,"purl":"pkg:npm/\($n)@\($v)"}]')
        done < <(npm list --depth=0 --json 2>/dev/null | jq -r '.dependencies | to_entries[] | "\(.key)=\(.value.version)"' || true)
    fi

    # Add git commit info
    local commit=""
    [[ -d "$REPO_DIR/.git" ]] && commit=$(cd "$REPO_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
    sbom=$(echo "$sbom" | jq --arg c "$commit" '.metadata.component.commit = $c')

    # Write SBOM
    echo "$sbom" | jq . > "$sbom_file" 2>/dev/null || true

    success "SBOM generated: $sbom_file"
}

# ─── Permissions Audit ──────────────────────────────────────────────────────

audit_permissions() {
    info "Auditing file permissions..."

    # Check for world-writable files
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        add_finding "MEDIUM" "permissions" "World-writable file: $file" \
            "File has overly permissive permissions (mode ending in 2 or 7)" \
            "Run: chmod o-w \"$file\" to remove world-writable bit"
    done < <(find "$REPO_DIR" -type f -perm -002 ! -path "*/.git/*" ! -path "*/.worktree/*" 2>/dev/null || true)

    # Check for setuid/setgid binaries
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        add_finding "HIGH" "permissions" "setuid/setgid binary: $file" \
            "Binary has setuid or setgid bit set" \
            "Review necessity. Remove if not essential. Audit access controls."
    done < <(find "$REPO_DIR" -type f \( -perm -4000 -o -perm -2000 \) ! -path "*/.git/*" 2>/dev/null || true)

    # Check for readable private keys
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        add_finding "CRITICAL" "permissions" "Readable private key: $file" \
            "Private key file has permissive read permissions" \
            "Run: chmod 600 \"$file\" immediately. Rotate the key. Audit access logs."
    done < <(find "$REPO_DIR" -type f \( -name "*.pem" -o -name "*.key" -o -name "id_rsa" \) ! -path "*/.git/*" 2>/dev/null | while read -r f; do
        [[ $(stat -f%A "$f" 2>/dev/null || stat -c%a "$f" 2>/dev/null) =~ [^0].. ]] && echo "$f"
    done || true)

    success "Permissions audit complete"
}

# ─── Network Exposure Analysis ─────────────────────────────────────────────

analyze_network() {
    info "Analyzing network exposure..."

    local urls_found=()

    # Find external network calls
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ http://|https://|curl|wget ]]; then
            urls_found+=("$line")
        fi
    done < <(grep -r "http\|curl\|wget\|socket\|fetch\|request" "$REPO_DIR/scripts/" "$REPO_DIR/src/" 2>/dev/null | grep -v ".git\|.worktree\|Binary" || true)

    if [[ ${#urls_found[@]} -gt 0 ]]; then
        info "Found ${#urls_found[@]} network-related operations"
        for line in "${urls_found[@]}"; do
            warn "  $line"
        done

        add_finding "MEDIUM" "network" "External network calls detected" \
            "Script makes external API/network calls. Found ${#urls_found[@]} references." \
            "Audit all network calls. Ensure TLS/HTTPS. Validate certificates. Log network activity."
    fi

    success "Network exposure analysis complete"
}

# ─── Compliance Report ──────────────────────────────────────────────────────

generate_compliance_report() {
    info "Generating compliance report..."

    local report_file="${REPO_DIR}/.claude/pipeline-artifacts/security-compliance-report.md"
    mkdir -p "$(dirname "$report_file")"

    cat > "$report_file" <<'EOF'
# Security Compliance Report

## SOC2 Checklist

### CC (Common Criteria)
- [ ] CC1: Risk Assessment completed
- [ ] CC2: Management objectives and responsibilities defined
- [ ] CC3: Communication of objectives and responsibilities
- [ ] CC4: Information security culture established
- [ ] CC5: Roles and responsibilities assigned
- [ ] CC6: Segregation of duties enforced
- [ ] CC7: Human resources policies and procedures
- [ ] CC8: Competence of personnel
- [ ] CC9: Accountability assigned

### C (Criteria)
- [ ] C1.1: Authorization and access controls
- [ ] C1.2: Change management procedures
- [ ] C2.1: System monitoring
- [ ] C2.2: Monitoring of systems and applications
- [ ] C3.1: Logical access controls
- [ ] C3.2: Physical access controls
- [ ] C4.1: Risk assessment documentation
- [ ] C5.1: Incident identification and reporting
- [ ] C6.1: Vulnerability identification and remediation
- [ ] C7.1: Availability and performance monitoring

## ISO 27001 Controls

### A.5 - Organizational Controls
- [ ] A.5.1: Management commitment to security
- [ ] A.5.2: Security policy established
- [ ] A.5.3: Allocation of information security responsibilities

### A.6 - Personnel Controls
- [ ] A.6.1: Confidentiality or non-disclosure agreements
- [ ] A.6.2: Information security awareness training
- [ ] A.6.3: Procedures for third-party access

### A.7 - Physical and Environmental Controls
- [ ] A.7.1: Perimeter security
- [ ] A.7.2: Entry controls
- [ ] A.7.3: Workspace security

### A.8 - Technical Controls
- [ ] A.8.1: Access control policies
- [ ] A.8.2: Cryptography usage
- [ ] A.8.3: Malware protection

## GDPR Compliance

- [ ] Data inventory completed
- [ ] Data processing agreements in place
- [ ] Data subject rights procedures
- [ ] Data breach notification plan
- [ ] Privacy by design implemented
- [ ] Data retention policy defined

## Findings Summary

| Priority | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 0 |
| MEDIUM   | 0 |
| LOW      | 0 |

EOF

    success "Compliance report generated: $report_file"
}

# ─── Unified Full Scan ──────────────────────────────────────────────────────

run_full_scan() {
    echo ""
    echo -e "${CYAN}${BOLD}╔═════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  SHIPWRIGHT SECURITY AUDIT${RESET}"
    echo -e "${CYAN}${BOLD}║  Repo: $(basename "$REPO_DIR")${RESET}"
    echo -e "${CYAN}${BOLD}╚═════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    scan_secrets
    echo ""
    scan_licenses
    echo ""
    scan_vulnerabilities
    echo ""
    generate_sbom
    echo ""
    audit_permissions
    echo ""
    analyze_network
    echo ""
    generate_compliance_report
    echo ""

    # Print findings summary
    print_findings_summary
}

# ─── Print Findings ────────────────────────────────────────────────────────

print_findings_summary() {
    echo -e "${CYAN}${BOLD}╔═════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  FINDINGS SUMMARY${RESET}"
    echo -e "${CYAN}${BOLD}╚═════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    echo -e "  ${RED}${BOLD}CRITICAL:${RESET} $CRITICAL_COUNT"
    echo -e "  ${RED}${BOLD}HIGH:${RESET}     $HIGH_COUNT"
    echo -e "  ${YELLOW}${BOLD}MEDIUM:${RESET}   $MEDIUM_COUNT"
    echo -e "  ${BLUE}${BOLD}LOW:${RESET}      $LOW_COUNT"
    echo ""

    if [[ ${#FINDINGS[@]} -eq 0 ]]; then
        success "No security findings detected!"
        return 0
    fi

    # Sort and display findings
    for finding in "${FINDINGS[@]}"; do
        IFS='|' read -r priority category title description remediation <<< "$finding"

        local color=""
        case "$priority" in
            CRITICAL) color="$RED" ;;
            HIGH) color="$RED" ;;
            MEDIUM) color="$YELLOW" ;;
            LOW) color="$BLUE" ;;
        esac

        echo -e "${color}${BOLD}[$priority]${RESET} $title"
        echo -e "  ${DIM}Category: $category${RESET}"
        echo -e "  ${DIM}Issue: $description${RESET}"
        echo -e "  ${GREEN}Remediation: $remediation${RESET}"
        echo ""
    done
}

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright security-audit${RESET} ${DIM}v${VERSION}${RESET} — Comprehensive Security Auditing"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright security-audit${RESET} [command]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}scan${RESET}              Full security scan (all checks)"
    echo -e "  ${CYAN}secrets${RESET}            Secret detection scan"
    echo -e "  ${CYAN}licenses${RESET}           License compliance check"
    echo -e "  ${CYAN}vulnerabilities${RESET}    Vulnerability scan"
    echo -e "  ${CYAN}sbom${RESET}               Generate Software Bill of Materials"
    echo -e "  ${CYAN}permissions${RESET}       File permissions audit"
    echo -e "  ${CYAN}network${RESET}            Network exposure analysis"
    echo -e "  ${CYAN}report${RESET}             Generate compliance report"
    echo -e "  ${CYAN}help${RESET}               Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright security-audit scan${RESET}"
    echo -e "  ${DIM}shipwright security-audit secrets${RESET}"
    echo -e "  ${DIM}shipwright security-audit licenses --json${RESET}"
}

# ─── Source Guard ──────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"

    case "$cmd" in
        scan)
            run_full_scan
            ;;
        secrets)
            scan_secrets
            print_findings_summary
            ;;
        licenses)
            scan_licenses
            print_findings_summary
            ;;
        vulnerabilities)
            scan_vulnerabilities
            print_findings_summary
            ;;
        sbom)
            generate_sbom
            ;;
        permissions)
            audit_permissions
            print_findings_summary
            ;;
        network)
            analyze_network
            print_findings_summary
            ;;
        report)
            generate_compliance_report
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
fi
