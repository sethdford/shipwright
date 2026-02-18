#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright evidence — Machine-Verifiable Proof for Agent Deliveries    ║
# ║  Browser · API · Database · CLI · Webhook · Custom collectors           ║
# ║  Capture · Verify · Manifest assertions · Artifact freshness            ║
# ║  Part of the Code Factory pattern for deterministic merge evidence      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
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

# Cross-platform timeout: macOS lacks GNU timeout
_run_with_timeout() {
    local secs="$1"; shift
    if command -v gtimeout &>/dev/null; then
        gtimeout "$secs" "$@"
    elif command -v timeout &>/dev/null; then
        timeout "$secs" "$@"
    else
        # Fallback: run without timeout
        "$@"
    fi
}

EVIDENCE_DIR="${REPO_DIR}/.claude/evidence"
MANIFEST_FILE="${EVIDENCE_DIR}/manifest.json"
POLICY_FILE="${REPO_DIR}/config/policy.json"

ensure_evidence_dir() {
    mkdir -p "$EVIDENCE_DIR"
}

# ─── Policy Accessors ────────────────────────────────────────────────────────

get_collectors() {
    local type_filter="${1:-}"
    if [[ -f "$POLICY_FILE" ]]; then
        if [[ -n "$type_filter" ]]; then
            jq -c ".evidence.collectors[]? | select(.type == \"${type_filter}\")" "$POLICY_FILE" 2>/dev/null
        else
            jq -c '.evidence.collectors[]?' "$POLICY_FILE" 2>/dev/null
        fi
    fi
}

get_max_age_minutes() {
    if [[ -f "$POLICY_FILE" ]]; then
        jq -r '.evidence.artifactMaxAgeMinutes // 30' "$POLICY_FILE" 2>/dev/null
    else
        echo "30"
    fi
}

get_require_fresh() {
    if [[ -f "$POLICY_FILE" ]]; then
        jq -r '.evidence.requireFreshArtifacts // true' "$POLICY_FILE" 2>/dev/null
    else
        echo "true"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# ASSERTION EVALUATION
# Checks response body against assertions defined in policy.json.
# Assertion names map to simple content checks (case-insensitive).
# Returns the count of failed assertions (0 = all passed).
# ═════════════════════════════════════════════════════════════════════════════

evaluate_assertions() {
    local collector_json="$1"
    local response_body="$2"
    local failed=0

    local assertions
    assertions=$(echo "$collector_json" | jq -r '.assertions[]? // empty' 2>/dev/null)
    [[ -z "$assertions" ]] && { echo "0"; return; }

    while IFS= read -r assertion; do
        [[ -z "$assertion" ]] && continue
        local check_passed="false"

        case "$assertion" in
            # Common assertion patterns — map names to body content checks
            page-title-visible)
                echo "$response_body" | grep -qi '<title>' && check_passed="true" ;;
            websocket-connected|websocket-active)
                echo "$response_body" | grep -qi 'websocket\|ws://' && check_passed="true" ;;
            status-ok)
                echo "$response_body" | grep -qi '"status"' && check_passed="true" ;;
            response-has-version)
                echo "$response_body" | grep -qi '"version"' && check_passed="true" ;;
            valid-json-output|valid-json)
                echo "$response_body" | jq empty 2>/dev/null && check_passed="true" ;;
            has-pipeline-state)
                echo "$response_body" | grep -qi 'pipeline\|status\|stage' && check_passed="true" ;;
            stage-list-rendered)
                echo "$response_body" | grep -qi 'stage\|pipeline' && check_passed="true" ;;
            progress-indicator-visible)
                echo "$response_body" | grep -qi 'progress\|percent\|stage' && check_passed="true" ;;
            schema-valid|db-accessible)
                echo "$response_body" | grep -qi 'schema\|version\|ok\|healthy' && check_passed="true" ;;
            *)
                # Generic: check if the assertion name (with hyphens as spaces) appears in body
                local search_term="${assertion//-/ }"
                echo "$response_body" | grep -qi "$search_term" && check_passed="true" ;;
        esac

        if [[ "$check_passed" != "true" ]]; then
            warn "[assertion] '${assertion}' not satisfied" >&2
            failed=$((failed + 1))
        fi
    done <<< "$assertions"

    echo "$failed"
}

# ═════════════════════════════════════════════════════════════════════════════
# TYPE-SPECIFIC COLLECTORS
# Each returns a JSON evidence record written to EVIDENCE_DIR/<name>.json
# ═════════════════════════════════════════════════════════════════════════════

# ─── Browser: HTTP page load against a URL path ──────────────────────────────

collect_browser() {
    local name="$1"
    local collector_json="$2"

    local entrypoint base_url url
    entrypoint=$(echo "$collector_json" | jq -r '.entrypoint // "/"')
    base_url=$(echo "$collector_json" | jq -r '.baseUrl // "http://localhost:3000"')
    url="${base_url}${entrypoint}"

    info "[browser] ${name}: ${url}"

    local http_status="0"
    local response_size="0"
    local response_body=""

    if command -v curl &>/dev/null; then
        local tmpfile="/tmp/sw-evidence-${name}.txt"
        http_status=$(curl -s -o "$tmpfile" -w "%{http_code}" --max-time 30 "$url" 2>/dev/null || echo "0")
        if [[ -f "$tmpfile" ]]; then
            response_size=$(wc -c < "$tmpfile" 2>/dev/null || echo "0")
            response_body=$(cat "$tmpfile" 2>/dev/null || echo "")
            rm -f "$tmpfile"
        fi
    fi

    local passed="false"
    [[ "$http_status" -ge 200 && "$http_status" -lt 400 ]] && passed="true"

    # Evaluate assertions against response body (if status check passed)
    local assertion_failures=0
    if [[ "$passed" == "true" && -n "$response_body" ]]; then
        assertion_failures=$(evaluate_assertions "$collector_json" "$response_body")
        [[ "$assertion_failures" -gt 0 ]] && passed="false"
    fi

    write_evidence_record "$name" "browser" "$passed" \
        "$(jq -n --arg url "$url" --argjson status "$http_status" --argjson size "$response_size" \
        --argjson assertion_failures "$assertion_failures" \
        '{url: $url, http_status: $status, response_size: $size, assertion_failures: $assertion_failures}')"
}

# ─── API: REST/GraphQL endpoint verification ─────────────────────────────────

collect_api() {
    local name="$1"
    local collector_json="$2"

    local url method expected_status headers_json body timeout
    url=$(echo "$collector_json" | jq -r '.url // ""')
    method=$(echo "$collector_json" | jq -r '.method // "GET"')
    expected_status=$(echo "$collector_json" | jq -r '.expectedStatus // 200')
    body=$(echo "$collector_json" | jq -r '.body // ""')
    timeout=$(echo "$collector_json" | jq -r '.timeout // 30')

    if [[ -z "$url" ]]; then
        local base_url entrypoint
        base_url=$(echo "$collector_json" | jq -r '.baseUrl // "http://localhost:3000"')
        entrypoint=$(echo "$collector_json" | jq -r '.entrypoint // "/"')
        url="${base_url}${entrypoint}"
    fi

    info "[api] ${name}: ${method} ${url}"

    local http_status="0"
    local response_size="0"
    local response_body=""
    local content_type=""

    if command -v curl &>/dev/null; then
        local tmpfile="/tmp/sw-evidence-${name}.txt"
        local header_file="/tmp/sw-evidence-${name}-headers.txt"
        local curl_args=(-s -o "$tmpfile" -D "$header_file" -w "%{http_code}" -X "$method" --max-time "$timeout")

        # Add custom headers
        local custom_headers
        custom_headers=$(echo "$collector_json" | jq -r '.headers // {} | to_entries[] | "-H\n\(.key): \(.value)"' 2>/dev/null || true)
        if [[ -n "$custom_headers" ]]; then
            while IFS= read -r line; do
                [[ "$line" == "-H" ]] && continue
                curl_args+=(-H "$line")
            done <<< "$custom_headers"
        fi

        # Add body for POST/PUT/PATCH
        if [[ -n "$body" && "$method" != "GET" && "$method" != "HEAD" ]]; then
            curl_args+=(-d "$body")
        fi

        http_status=$(curl "${curl_args[@]}" "$url" 2>/dev/null || echo "0")

        if [[ -f "$tmpfile" ]]; then
            response_size=$(wc -c < "$tmpfile" 2>/dev/null || echo "0")
            response_body=$(cat "$tmpfile" 2>/dev/null || echo "")
            rm -f "$tmpfile"
        fi
        if [[ -f "$header_file" ]]; then
            content_type=$(grep -i "^content-type:" "$header_file" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | tr -d '\r' || echo "")
            rm -f "$header_file"
        fi
    fi

    local passed="false"
    [[ "$http_status" -eq "$expected_status" ]] && passed="true"

    # Check if response is valid JSON when content-type suggests it
    local valid_json="false"
    if echo "$response_body" | jq empty 2>/dev/null; then
        valid_json="true"
    fi

    # Evaluate assertions against response body (if status check passed)
    local assertion_failures=0
    if [[ "$passed" == "true" && -n "$response_body" ]]; then
        assertion_failures=$(evaluate_assertions "$collector_json" "$response_body")
        [[ "$assertion_failures" -gt 0 ]] && passed="false"
    fi

    write_evidence_record "$name" "api" "$passed" \
        "$(jq -n --arg url "$url" --arg method "$method" \
        --argjson status "$http_status" --argjson expected "$expected_status" \
        --argjson size "$response_size" --arg content_type "$content_type" \
        --arg valid_json "$valid_json" --argjson assertion_failures "$assertion_failures" \
        '{url: $url, method: $method, http_status: $status, expected_status: $expected, response_size: $size, content_type: $content_type, valid_json: ($valid_json == "true"), assertion_failures: $assertion_failures}')"
}

# ─── CLI: Execute a command and check exit code ──────────────────────────────

collect_cli() {
    local name="$1"
    local collector_json="$2"

    local command_str expected_exit timeout
    command_str=$(echo "$collector_json" | jq -r '.command // ""')
    expected_exit=$(echo "$collector_json" | jq -r '.expectedExitCode // 0')
    timeout=$(echo "$collector_json" | jq -r '.timeout // 60')

    if [[ -z "$command_str" ]]; then
        error "[cli] ${name}: no command specified"
        write_evidence_record "$name" "cli" "false" '{"error": "no command specified"}'
        return
    fi

    info "[cli] ${name}: ${command_str}"

    local exit_code=0
    local output=""
    local start_time
    start_time=$(date +%s)

    output=$(cd "$REPO_DIR" && _run_with_timeout "$timeout" bash -c "$command_str" 2>&1) || exit_code=$?

    local elapsed=$(( $(date +%s) - start_time ))

    local passed="false"
    [[ "$exit_code" -eq "$expected_exit" ]] && passed="true"

    local valid_json="false"
    if echo "$output" | jq empty 2>/dev/null; then
        valid_json="true"
    fi

    # Evaluate assertions against command output (if exit code check passed)
    local assertion_failures=0
    if [[ "$passed" == "true" && -n "$output" ]]; then
        assertion_failures=$(evaluate_assertions "$collector_json" "$output")
        [[ "$assertion_failures" -gt 0 ]] && passed="false"
    fi

    local output_size=${#output}
    # Truncate output for the evidence record (keep first 2000 chars)
    local output_preview="${output:0:2000}"

    write_evidence_record "$name" "cli" "$passed" \
        "$(jq -n --arg cmd "$command_str" --argjson exit_code "$exit_code" \
        --argjson expected "$expected_exit" --argjson elapsed "$elapsed" \
        --argjson output_size "$output_size" --arg valid_json "$valid_json" \
        --arg output_preview "$output_preview" \
        '{command: $cmd, exit_code: $exit_code, expected_exit_code: $expected, elapsed_seconds: $elapsed, output_size: $output_size, valid_json: ($valid_json == "true"), output_preview: $output_preview}')"
}

# ─── Database: Schema/migration check via command ─────────────────────────────

collect_database() {
    local name="$1"
    local collector_json="$2"

    local command_str expected_exit timeout
    command_str=$(echo "$collector_json" | jq -r '.command // ""')
    expected_exit=$(echo "$collector_json" | jq -r '.expectedExitCode // 0')
    timeout=$(echo "$collector_json" | jq -r '.timeout // 30')

    if [[ -z "$command_str" ]]; then
        error "[database] ${name}: no command specified"
        write_evidence_record "$name" "database" "false" '{"error": "no command specified"}'
        return
    fi

    info "[database] ${name}: ${command_str}"

    local exit_code=0
    local output=""
    output=$(cd "$REPO_DIR" && _run_with_timeout "$timeout" bash -c "$command_str" 2>&1) || exit_code=$?

    local passed="false"
    [[ "$exit_code" -eq "$expected_exit" ]] && passed="true"

    # Evaluate assertions against command output (if exit code check passed)
    local assertion_failures=0
    if [[ "$passed" == "true" && -n "$output" ]]; then
        assertion_failures=$(evaluate_assertions "$collector_json" "$output")
        [[ "$assertion_failures" -gt 0 ]] && passed="false"
    fi

    local output_preview="${output:0:2000}"

    write_evidence_record "$name" "database" "$passed" \
        "$(jq -n --arg cmd "$command_str" --argjson exit_code "$exit_code" \
        --argjson expected "$expected_exit" --arg output_preview "$output_preview" \
        --argjson assertion_failures "$assertion_failures" \
        '{command: $cmd, exit_code: $exit_code, expected_exit_code: $expected, output_preview: $output_preview, assertion_failures: $assertion_failures}')"
}

# ─── Webhook: Issue a callback and verify response ───────────────────────────

collect_webhook() {
    local name="$1"
    local collector_json="$2"

    local url method expected_status body timeout
    url=$(echo "$collector_json" | jq -r '.url // ""')
    method=$(echo "$collector_json" | jq -r '.method // "POST"')
    expected_status=$(echo "$collector_json" | jq -r '.expectedStatus // 200')
    body=$(echo "$collector_json" | jq -r '.body // "{}"')
    timeout=$(echo "$collector_json" | jq -r '.timeout // 15')

    if [[ -z "$url" ]]; then
        error "[webhook] ${name}: no URL specified"
        write_evidence_record "$name" "webhook" "false" '{"error": "no URL specified"}'
        return
    fi

    info "[webhook] ${name}: ${method} ${url}"

    local http_status="0"
    local response_body=""

    if command -v curl &>/dev/null; then
        local tmpfile="/tmp/sw-evidence-${name}.txt"
        http_status=$(curl -s -o "$tmpfile" -w "%{http_code}" -X "$method" \
            -H "Content-Type: application/json" -d "$body" \
            --max-time "$timeout" "$url" 2>/dev/null || echo "0")
        if [[ -f "$tmpfile" ]]; then
            response_body=$(cat "$tmpfile" 2>/dev/null || echo "")
            rm -f "$tmpfile"
        fi
    fi

    local passed="false"
    [[ "$http_status" -eq "$expected_status" ]] && passed="true"

    write_evidence_record "$name" "webhook" "$passed" \
        "$(jq -n --arg url "$url" --arg method "$method" \
        --argjson status "$http_status" --argjson expected "$expected_status" \
        '{url: $url, method: $method, http_status: $status, expected_status: $expected}')"
}

# ─── Custom: User-defined script execution ───────────────────────────────────

collect_custom() {
    local name="$1"
    local collector_json="$2"

    local command_str expected_exit timeout
    command_str=$(echo "$collector_json" | jq -r '.command // ""')
    expected_exit=$(echo "$collector_json" | jq -r '.expectedExitCode // 0')
    timeout=$(echo "$collector_json" | jq -r '.timeout // 60')

    if [[ -z "$command_str" ]]; then
        error "[custom] ${name}: no command specified"
        write_evidence_record "$name" "custom" "false" '{"error": "no command specified"}'
        return
    fi

    info "[custom] ${name}: ${command_str}"

    local exit_code=0
    local output=""
    output=$(cd "$REPO_DIR" && _run_with_timeout "$timeout" bash -c "$command_str" 2>&1) || exit_code=$?

    local passed="false"
    [[ "$exit_code" -eq "$expected_exit" ]] && passed="true"

    local output_preview="${output:0:2000}"

    write_evidence_record "$name" "custom" "$passed" \
        "$(jq -n --arg cmd "$command_str" --argjson exit_code "$exit_code" \
        --argjson expected "$expected_exit" --arg output_preview "$output_preview" \
        '{command: $cmd, exit_code: $exit_code, expected_exit_code: $expected, output_preview: $output_preview}')"
}

# ═════════════════════════════════════════════════════════════════════════════
# EVIDENCE RECORD WRITER
# ═════════════════════════════════════════════════════════════════════════════

write_evidence_record() {
    local name="$1"
    local type="$2"
    local passed="$3"
    local details="$4"

    local evidence_file="${EVIDENCE_DIR}/${name}.json"
    local captured_at
    captured_at=$(now_iso)

    jq -n --arg name "$name" --arg type "$type" --arg passed "$passed" \
        --arg captured_at "$captured_at" --argjson captured_epoch "$(now_epoch)" \
        --argjson details "$details" \
        '{
            name: $name,
            type: $type,
            passed: ($passed == "true"),
            captured_at: $captured_at,
            captured_epoch: $captured_epoch,
            details: $details
        }' > "$evidence_file"

    if [[ "$passed" == "true" ]]; then
        success "[${type}] ${name}: passed"
    else
        error "[${type}] ${name}: failed"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMANDS
# ═════════════════════════════════════════════════════════════════════════════

cmd_capture() {
    local type_filter="${1:-}"
    ensure_evidence_dir

    info "Capturing evidence${type_filter:+ (type: ${type_filter})}..."

    local collectors
    collectors=$(get_collectors "$type_filter")

    if [[ -z "$collectors" ]]; then
        warn "No evidence collectors defined in policy — nothing to capture"
        return 0
    fi

    local total=0
    local passed=0
    local failed=0
    local manifest_entries="[]"

    while IFS= read -r collector; do
        [[ -z "$collector" ]] && continue

        local cname ctype
        cname=$(echo "$collector" | jq -r '.name')
        ctype=$(echo "$collector" | jq -r '.type')

        case "$ctype" in
            browser)   collect_browser "$cname" "$collector" ;;
            api)       collect_api "$cname" "$collector" ;;
            cli)       collect_cli "$cname" "$collector" ;;
            database)  collect_database "$cname" "$collector" ;;
            webhook)   collect_webhook "$cname" "$collector" ;;
            custom)    collect_custom "$cname" "$collector" ;;
            *)         warn "Unknown collector type: ${ctype} (skipping ${cname})" ; continue ;;
        esac

        ((total++))

        local evidence_file="${EVIDENCE_DIR}/${cname}.json"
        local cpassed="false"
        if [[ -f "$evidence_file" ]]; then
            cpassed=$(jq -r '.passed' "$evidence_file" 2>/dev/null || echo "false")
        fi

        if [[ "$cpassed" == "true" ]]; then
            ((passed++))
        else
            ((failed++))
        fi

        manifest_entries=$(echo "$manifest_entries" | jq \
            --arg name "$cname" --arg type "$ctype" --arg file "$evidence_file" --arg passed "$cpassed" \
            '. + [{"name": $name, "type": $type, "file": $file, "passed": ($passed == "true")}]')

    done <<< "$collectors"

    # Write manifest
    jq -n --arg captured_at "$(now_iso)" --argjson captured_epoch "$(now_epoch)" \
        --argjson total "$total" --argjson passed "$passed" --argjson failed "$failed" \
        --argjson collectors "$manifest_entries" \
        '{
            captured_at: $captured_at,
            captured_epoch: $captured_epoch,
            collector_count: $total,
            passed: $passed,
            failed: $failed,
            collectors: $collectors
        }' > "$MANIFEST_FILE"

    echo ""
    if [[ "$failed" -eq 0 ]]; then
        success "All ${total} collector(s) passed"
    else
        warn "${passed}/${total} passed, ${failed} failed"
    fi

    emit_event "evidence.captured" "total=${total}" "passed=${passed}" "failed=${failed}" "type=${type_filter:-all}"
}

cmd_verify() {
    ensure_evidence_dir

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        error "No evidence manifest found — run 'capture' first"
        return 1
    fi

    info "Verifying evidence..."

    local all_passed="true"
    local checked=0
    local failed=0

    # Check freshness
    local require_fresh
    require_fresh=$(get_require_fresh)
    local max_age_minutes
    max_age_minutes=$(get_max_age_minutes)
    local max_age_seconds=$((max_age_minutes * 60))

    local captured_epoch
    captured_epoch=$(jq -r '.captured_epoch' "$MANIFEST_FILE" 2>/dev/null || echo "0")
    local current_epoch
    current_epoch=$(now_epoch)
    local age_seconds=$((current_epoch - captured_epoch))

    if [[ "$require_fresh" == "true" && "$age_seconds" -gt "$max_age_seconds" ]]; then
        error "Evidence is stale: captured ${age_seconds}s ago (max: ${max_age_seconds}s)"
        all_passed="false"
        ((failed++))
    else
        local age_minutes=$((age_seconds / 60))
        info "Evidence age: ${age_minutes}m (max: ${max_age_minutes}m)"
    fi

    # Check all collectors in manifest
    local collector_count
    collector_count=$(jq -r '.collector_count' "$MANIFEST_FILE" 2>/dev/null || echo "0")

    local collectors_json
    collectors_json=$(jq -c '.collectors[]?' "$MANIFEST_FILE" 2>/dev/null)

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        ((checked++))

        local cname ctype cpassed
        cname=$(echo "$entry" | jq -r '.name')
        ctype=$(echo "$entry" | jq -r '.type')
        cpassed=$(echo "$entry" | jq -r '.passed')

        if [[ "$cpassed" != "true" ]]; then
            error "Collector '${cname}' (${ctype}) failed"
            all_passed="false"
            ((failed++))
        else
            success "Collector '${cname}' (${ctype}) passed"
        fi
    done <<< "$collectors_json"

    echo ""
    if [[ "$all_passed" == "true" ]]; then
        success "All ${checked} evidence check(s) passed"
        emit_event "evidence.verified" "total=${checked}" "result=pass"
        return 0
    else
        error "${failed} of ${checked} evidence check(s) failed"
        emit_event "evidence.verified" "total=${checked}" "result=fail" "failed=${failed}"
        return 1
    fi
}

cmd_pre_pr() {
    local type_filter="${1:-}"
    info "Running pre-PR evidence check..."
    cmd_capture "$type_filter"
    cmd_verify
}

cmd_status() {
    ensure_evidence_dir

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        warn "No evidence manifest found"
        return 0
    fi

    local captured_at collector_count passed_count failed_count
    captured_at=$(jq -r '.captured_at' "$MANIFEST_FILE" 2>/dev/null || echo "unknown")
    collector_count=$(jq -r '.collector_count' "$MANIFEST_FILE" 2>/dev/null || echo "0")
    passed_count=$(jq -r '.passed' "$MANIFEST_FILE" 2>/dev/null || echo "0")
    failed_count=$(jq -r '.failed' "$MANIFEST_FILE" 2>/dev/null || echo "0")

    echo "Evidence Status"
    echo "━━━━━━━━━━━━━━━"
    echo "Manifest:    ${MANIFEST_FILE}"
    echo "Captured at: ${captured_at}"
    echo "Collectors:  ${collector_count} (${passed_count} passed, ${failed_count} failed)"
    echo ""

    # Group by type
    local types
    types=$(jq -r '.collectors[].type' "$MANIFEST_FILE" 2>/dev/null | sort -u)

    while IFS= read -r type; do
        [[ -z "$type" ]] && continue
        echo "  ${type}:"
        jq -r ".collectors[] | select(.type == \"${type}\") | \"    \\(if .passed then \"✓\" else \"✗\" end) \\(.name)\"" "$MANIFEST_FILE" 2>/dev/null || true
    done <<< "$types"
}

cmd_list_types() {
    echo "Supported evidence types:"
    echo ""
    echo "  browser    HTTP page load — verifies UI renders correctly"
    echo "  api        REST/GraphQL endpoint — verifies response status, body, content-type"
    echo "  database   Schema/migration check — verifies DB integrity via command"
    echo "  cli        Command execution — verifies exit code and output"
    echo "  webhook    Callback verification — verifies webhook endpoint responds"
    echo "  custom     User-defined script — any verification logic"
    echo ""
    echo "Configure collectors in config/policy.json under the 'evidence' section."
}

show_help() {
    cat << 'EOF'
Usage: shipwright evidence <command> [args]

Commands:
  capture [type]    Capture evidence (optionally filter by type)
  verify            Verify evidence manifest and freshness
  pre-pr [type]     Capture + verify (run before PR creation)
  status            Show current evidence state grouped by type
  types             List supported evidence types

Evidence Types:
  browser     HTTP page load verification
  api         REST/GraphQL endpoint checks
  database    Schema/migration integrity
  cli         Command execution and exit code
  webhook     Callback endpoint verification
  custom      User-defined verification scripts

Evidence collectors are defined in config/policy.json under the
'evidence.collectors' array. Each collector specifies a type,
target, and assertions.

Part of the Code Factory pattern for machine-verifiable proof.
EOF
}

main() {
    local subcommand="${1:-help}"
    shift || true

    case "$subcommand" in
        capture)
            cmd_capture "$@"
            ;;
        verify)
            cmd_verify "$@"
            ;;
        pre-pr)
            cmd_pre_pr "$@"
            ;;
        status)
            cmd_status
            ;;
        types)
            cmd_list_types
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
