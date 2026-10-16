#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright evidence — Machine-Verifiable Proof for Agent Deliveries    ║
# ║  Browser · API · Database · CLI · Webhook · Custom collectors           ║
# ║  Capture · Verify · Manifest assertions · Artifact freshness            ║
# ║  Part of the Code Factory pattern for deterministic merge evidence      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# Cross-platform timeout: macOS lacks GNU timeout
_run_with_timeout() {
    local secs="$1"; shift
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    elif command -v timeout >/dev/null 2>&1; then
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
                echo "$response_body" | grep >/dev/null -i '<title>' && check_passed="true" ;;
            websocket-connected|websocket-active)
                echo "$response_body" | grep >/dev/null -i 'websocket\|ws://' && check_passed="true" ;;
            status-ok)
                echo "$response_body" | grep >/dev/null -i '"status"' && check_passed="true" ;;
            response-has-version)
                echo "$response_body" | grep >/dev/null -i '"version"' && check_passed="true" ;;
            valid-json-output|valid-json)
                echo "$response_body" | jq empty 2>/dev/null && check_passed="true" ;;
            has-pipeline-state)
                echo "$response_body" | grep >/dev/null -i 'pipeline\|status\|stage' && check_passed="true" ;;
            stage-list-rendered)
                echo "$response_body" | grep >/dev/null -i 'stage\|pipeline' && check_passed="true" ;;
            progress-indicator-visible)
                echo "$response_body" | grep >/dev/null -i 'progress\|percent\|stage' && check_passed="true" ;;
            schema-valid|db-accessible)
                echo "$response_body" | grep >/dev/null -i 'schema\|version\|ok\|healthy' && check_passed="true" ;;
            *)
                # Generic: check if the assertion name (with hyphens as spaces) appears in body
                local search_term="${assertion//-/ }"
                echo "$response_body" | grep >/dev/null -i "$search_term" && check_passed="true" ;;
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
    base_url=$(echo "$collector_json" | jq -r '.baseUrl // ""')
    [[ -z "$base_url" ]] && base_url="http://localhost:$(_config_get_int "dashboard.port" 8767)"
    url="${base_url}${entrypoint}"

    info "[browser] ${name}: ${url}"

    local http_status="0"
    local response_size="0"
    local response_body=""

    if command -v curl >/dev/null 2>&1; then
        local tmpfile
        tmpfile=$(mktemp "${TMPDIR:-/tmp}/sw-evidence-browser.XXXXXX")
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

    # shellcheck disable=SC2034
    local url method expected_status headers_json body timeout
    url=$(echo "$collector_json" | jq -r '.url // ""')
    method=$(echo "$collector_json" | jq -r '.method // "GET"')
    expected_status=$(echo "$collector_json" | jq -r '.expectedStatus // 200')
    body=$(echo "$collector_json" | jq -r '.body // ""')
    timeout=$(echo "$collector_json" | jq -r '.timeout // 30')

    if [[ -z "$url" ]]; then
        local base_url entrypoint
        base_url=$(echo "$collector_json" | jq -r '.baseUrl // ""')
        [[ -z "$base_url" ]] && base_url="http://localhost:$(_config_get_int "dashboard.port" 8767)"
        entrypoint=$(echo "$collector_json" | jq -r '.entrypoint // "/"')
        url="${base_url}${entrypoint}"
    fi

    info "[api] ${name}: ${method} ${url}"

    local http_status="0"
    local response_size="0"
    local response_body=""
    local content_type=""

    if command -v curl >/dev/null 2>&1; then
        local tmpfile header_file
        tmpfile=$(mktemp "${TMPDIR:-/tmp}/sw-evidence-api.XXXXXX")
        header_file=$(mktemp "${TMPDIR:-/tmp}/sw-evidence-api-headers.XXXXXX")
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
        rm -f "$tmpfile"
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

    if command -v curl >/dev/null 2>&1; then
        local tmpfile
        tmpfile=$(mktemp "${TMPDIR:-/tmp}/sw-evidence-webhook.XXXXXX")
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

# ─── Mutation Testing: Verify mutations are caught by test suite ───────────────

collect_mutation() {
    local name="$1"
    local collector_json="$2"

    local test_cmd target_files threshold
    test_cmd=$(echo "$collector_json" | jq -r '.testCommand // ""')
    target_files=$(echo "$collector_json" | jq -r '.targetFiles // ""')
    threshold=$(echo "$collector_json" | jq -r '.mutationThreshold // 60')

    if [[ -z "$test_cmd" ]] || [[ -z "$target_files" ]]; then
        error "[mutation] ${name}: testCommand and targetFiles required"
        write_evidence_record "$name" "mutation" "false" '{"error": "testCommand and targetFiles required"}'
        return
    fi

    info "[mutation] ${name}: testing mutation coverage (threshold: ${threshold}%)"

    local mutation_dir
    mutation_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-evidence-mutations.XXXXXX")
    trap 'rm -rf "$mutation_dir"' RETURN

    local total_mutants=0
    local killed_mutants=0

    # For each target file, create mutations
    local file
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$REPO_DIR/$file" ]] && continue

        # Copy file to mutation dir for testing
        local file_copy
        file_copy="$mutation_dir/$(basename "$file")"
        cp "$REPO_DIR/$file" "$file_copy"

        # Apply mutations: swap operators, negate conditions, change exit codes
        local mutations=()

        # Mutation 1: swap == to !=
        if grep -q "==" "$file_copy"; then
            mutations+=("sed 's/==/!=/g'")
        fi

        # Mutation 2: swap != to ==
        if grep -q "!=" "$file_copy"; then
            mutations+=("sed 's/!=/==/g'")
        fi

        # Mutation 3: change -gt to -lt
        if grep -q "\-gt" "$file_copy"; then
            mutations+=("sed 's/-gt/-lt/g'")
        fi

        # Mutation 4: change -lt to -gt
        if grep -q "\-lt" "$file_copy"; then
            mutations+=("sed 's/-lt/-gt/g'")
        fi

        # Mutation 5: change exit 0 to exit 1
        if grep -q "exit 0" "$file_copy"; then
            mutations+=("sed 's/exit 0/exit 1/g'")
        fi

        # Mutation 6: comment out error traps
        if grep -q "trap.*ERR" "$file_copy"; then
            mutations+=("sed 's/^trap /#trap /g'")
        fi

        # Apply each mutation and test
        for i in "${!mutations[@]}"; do
            total_mutants=$((total_mutants + 1))
            local mutated_copy="$file_copy.mutant.$i"
            cp "$file_copy" "$mutated_copy"

            # Apply mutation
            eval "${mutations[$i]} \"$mutated_copy\" > \"${mutated_copy}.tmp\" && mv \"${mutated_copy}.tmp\" \"$mutated_copy\"" 2>/dev/null || true

            # Run test with mutation — test should fail (mutation caught)
            local test_result=0
            (cd "$REPO_DIR" && _run_with_timeout 30 bash -c "$test_cmd" > /dev/null 2>&1) || test_result=$?

            # If test failed (non-zero), mutation was caught
            if [[ "$test_result" -ne 0 ]]; then
                killed_mutants=$((killed_mutants + 1))
            fi

            rm -f "$mutated_copy"
        done

    done <<< "$target_files"

    local mutation_score=0
    local passed="false"
    if [[ "$total_mutants" -gt 0 ]]; then
        mutation_score=$((killed_mutants * 100 / total_mutants))
        [[ "$mutation_score" -ge "$threshold" ]] && passed="true"
    fi

    write_evidence_record "$name" "mutation" "$passed" \
        "$(jq -n --argjson total "$total_mutants" --argjson killed "$killed_mutants" \
        --argjson score "$mutation_score" --argjson threshold "$threshold" \
        '{total_mutants: $total, killed_mutants: $killed, mutation_score: $score, threshold: $threshold}')"
}

# ─── Property-Based Testing: Verify properties hold over iterations ──────────

collect_property() {
    local name="$1"
    local collector_json="$2"

    local property_cmd iterations
    property_cmd=$(echo "$collector_json" | jq -r '.propertyCommand // ""')
    iterations=$(echo "$collector_json" | jq -r '.iterations // 100')

    if [[ -z "$property_cmd" ]]; then
        error "[property] ${name}: propertyCommand required"
        write_evidence_record "$name" "property" "false" '{"error": "propertyCommand required"}'
        return
    fi

    info "[property] ${name}: running property test (${iterations} iterations)"

    local passed_count=0
    local failed_count=0
    local counterexamples="[]"

    # Run property test multiple times
    local i
    for ((i = 0; i < iterations; i++)); do
        local output=0
        local result_output=""
        result_output=$(cd "$REPO_DIR" && _run_with_timeout 10 bash -c "$property_cmd" 2>&1) || output=$?

        if [[ "$output" -eq 0 ]]; then
            passed_count=$((passed_count + 1))
        else
            failed_count=$((failed_count + 1))
            # Capture counterexample (first 200 chars of output)
            counterexamples=$(echo "$counterexamples" | jq \
                --arg ce "${result_output:0:200}" \
                '. += [{"iteration": '$i', "output": $ce}]')
        fi
    done

    local passed="false"
    [[ "$failed_count" -eq 0 ]] && passed="true"

    write_evidence_record "$name" "property" "$passed" \
        "$(jq -n --argjson passed_count "$passed_count" --argjson failed_count "$failed_count" \
        --argjson iterations "$iterations" --argjson counterexamples "$counterexamples" \
        '{passed_count: $passed_count, failed_count: $failed_count, total_iterations: $iterations, counterexamples: $counterexamples}')"
}

# ─── Invariant Checking: Verify system invariants ────────────────────────────

collect_invariant() {
    local name="$1"
    local collector_json="$2"

    local check_cmd invariant_name
    check_cmd=$(echo "$collector_json" | jq -r '.checkCommand // ""')
    invariant_name=$(echo "$collector_json" | jq -r '.invariantName // "unnamed"')

    if [[ -z "$check_cmd" ]]; then
        error "[invariant] ${name}: checkCommand required"
        write_evidence_record "$name" "invariant" "false" '{"error": "checkCommand required"}'
        return
    fi

    info "[invariant] ${name}: checking invariant '${invariant_name}'"

    local exit_code=0
    local output=""
    output=$(cd "$REPO_DIR" && _run_with_timeout 30 bash -c "$check_cmd" 2>&1) || exit_code=$?

    local passed="false"
    [[ "$exit_code" -eq 0 ]] && passed="true"

    write_evidence_record "$name" "invariant" "$passed" \
        "$(jq -n --arg invariant_name "$invariant_name" --argjson exit_code "$exit_code" \
        --arg output "${output:0:2000}" \
        '{invariant_name: $invariant_name, check_exit_code: $exit_code, output: $output}')"
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
# ARTIFACT CAPTURE
# Stores build logs, test reports, coverage as evidence artifacts with manifest
# ═════════════════════════════════════════════════════════════════════════════

evidence_capture_artifact() {
    local artifact_name="$1"
    local artifact_path="$2"

    if [[ ! -f "$artifact_path" ]]; then
        warn "[artifact] ${artifact_name}: file not found"
        return 1
    fi

    local artifacts_dir="${EVIDENCE_DIR}/artifacts"
    mkdir -p "$artifacts_dir"

    # Copy artifact to artifacts directory
    local dest_file="$artifacts_dir/${artifact_name}"
    cp "$artifact_path" "$dest_file"

    # Compute SHA-256 of artifact
    local artifact_sha256
    if command -v shasum >/dev/null 2>&1; then
        artifact_sha256=$(shasum -a 256 "$dest_file" | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
        artifact_sha256=$(sha256sum "$dest_file" | awk '{print $1}')
    else
        artifact_sha256="unknown"
    fi

    info "[artifact] ${artifact_name}: captured (${artifact_sha256:0:16}...)"

    # Append to artifacts manifest
    local artifacts_manifest="${EVIDENCE_DIR}/artifacts-manifest.json"
    if [[ ! -f "$artifacts_manifest" ]]; then
        echo "[]" > "$artifacts_manifest"
    fi

    local tmp_manifest
    tmp_manifest=$(mktemp "${TMPDIR:-/tmp}/sw-evidence-artifacts.XXXXXX")
    jq \
        --arg name "$artifact_name" \
        --arg path "$dest_file" \
        --arg sha256 "$artifact_sha256" \
        --arg captured_at "$(now_iso)" \
        '. += [{"name": $name, "path": $path, "sha256": $sha256, "captured_at": $captured_at}]' \
        "$artifacts_manifest" > "$tmp_manifest"
    mv "$tmp_manifest" "$artifacts_manifest"

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# QUALITY SCORE COMPUTATION
# Weights: mutation (30%), property tests (25%), invariants (25%), collectors (20%)
# ═════════════════════════════════════════════════════════════════════════════

evidence_quality_score() {
    ensure_evidence_dir

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        echo "0"
        return 1
    fi

    # Extract collector results
    local mutation_score=0
    local property_score=0
    local invariant_score=0
    local collector_pass_rate=0

    # Mutation test score (from manifest)
    local mutation_evidence="${EVIDENCE_DIR}/mutation_test.json"
    if [[ -f "$mutation_evidence" ]]; then
        local mutation_passed
        mutation_passed=$(jq -r '.passed // false' "$mutation_evidence" 2>/dev/null || echo "false")
        if [[ "$mutation_passed" == "true" ]]; then
            mutation_score=$(jq -r '.details.mutation_score // 0' "$mutation_evidence" 2>/dev/null || echo "0")
            [[ -z "$mutation_score" ]] && mutation_score="0"
        fi
    fi

    # Property test score (failed_count == 0 => 100, else 0)
    local property_evidence="${EVIDENCE_DIR}/property_test.json"
    if [[ -f "$property_evidence" ]]; then
        local prop_failed
        prop_failed=$(jq -r '.details.failed_count // 0' "$property_evidence" 2>/dev/null || echo "0")
        [[ -z "$prop_failed" ]] && prop_failed="0"
        if [[ "$prop_failed" -eq 0 ]]; then
            property_score=100
        fi
    fi

    # Invariant score (all pass => 100, else 50)
    local invariant_evidence="${EVIDENCE_DIR}/invariant_check.json"
    if [[ -f "$invariant_evidence" ]]; then
        local invariant_passed
        invariant_passed=$(jq -r '.passed // false' "$invariant_evidence" 2>/dev/null || echo "false")
        if [[ "$invariant_passed" == "true" ]]; then
            invariant_score=100
        else
            invariant_score=50
        fi
    fi

    # Collector pass rate
    local collector_count
    collector_count=$(jq -r '.collector_count // 0' "$MANIFEST_FILE" 2>/dev/null || echo "0")
    [[ -z "$collector_count" ]] && collector_count="0"

    local passed_count
    passed_count=$(jq -r '.passed // 0' "$MANIFEST_FILE" 2>/dev/null || echo "0")
    [[ -z "$passed_count" ]] && passed_count="0"

    if [[ "$collector_count" -gt 0 ]]; then
        collector_pass_rate=$((passed_count * 100 / collector_count))
    fi

    # Weighted score: 30% mutation + 25% property + 25% invariant + 20% collector
    local weighted_score=0
    weighted_score=$((
        (mutation_score * 30) +
        (property_score * 25) +
        (invariant_score * 25) +
        (collector_pass_rate * 20)
    ))
    weighted_score=$((weighted_score / 100))

    # Cap at 100
    [[ "$weighted_score" -gt 100 ]] && weighted_score=100

    echo "$weighted_score"
    return 0
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
            mutation)  collect_mutation "$cname" "$collector" ;;
            property)  collect_property "$cname" "$collector" ;;
            invariant) collect_invariant "$cname" "$collector" ;;
            *)         warn "Unknown collector type: ${ctype} (skipping ${cname})" ; continue ;;
        esac

        total=$((total + 1))

        local evidence_file="${EVIDENCE_DIR}/${cname}.json"
        local cpassed="false"
        if [[ -f "$evidence_file" ]]; then
            cpassed=$(jq -r '.passed' "$evidence_file" 2>/dev/null || echo "false")
        fi

        if [[ "$cpassed" == "true" ]]; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
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
        failed=$((failed + 1))
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
        checked=$((checked + 1))

        local cname ctype cpassed
        cname=$(echo "$entry" | jq -r '.name')
        ctype=$(echo "$entry" | jq -r '.type')
        cpassed=$(echo "$entry" | jq -r '.passed')

        if [[ "$cpassed" != "true" ]]; then
            error "Collector '${cname}' (${ctype}) failed"
            all_passed="false"
            failed=$((failed + 1))
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
    echo "  browser     HTTP page load — verifies UI renders correctly"
    echo "  api         REST/GraphQL endpoint — verifies response status, body, content-type"
    echo "  database    Schema/migration check — verifies DB integrity via command"
    echo "  cli         Command execution — verifies exit code and output"
    echo "  webhook     Callback verification — verifies webhook endpoint responds"
    echo "  custom      User-defined script — any verification logic"
    echo "  mutation    Mutation testing — verifies test suite catches code mutations"
    echo "  property    Property-based testing — verifies properties hold over iterations"
    echo "  invariant   Invariant checking — verifies system invariants hold"
    echo ""
    echo "Configure collectors in config/policy.json under the 'evidence' section."
}

cmd_quality_score() {
    ensure_evidence_dir
    local score
    score=$(evidence_quality_score)
    echo "Evidence-based quality score: ${score}/100"
    emit_event "evidence.quality_score" "score=${score}"
    return 0
}

show_help() {
    cat << 'EOF'
Usage: shipwright evidence <command> [args]

Commands:
  capture [type]      Capture evidence (optionally filter by type)
  verify              Verify evidence manifest and freshness
  pre-pr [type]       Capture + verify (run before PR creation)
  status              Show current evidence state grouped by type
  types               List supported evidence types
  quality-score       Compute quality score from evidence
  artifact <name> <path>  Capture artifact with SHA-256 manifest

Evidence Types:
  browser     HTTP page load verification
  api         REST/GraphQL endpoint checks
  database    Schema/migration integrity
  cli         Command execution and exit code
  webhook     Callback endpoint verification
  custom      User-defined verification scripts
  mutation    Mutation testing (verify test suite catches mutations)
  property    Property-based testing (verify properties hold)
  invariant   Invariant checking (verify system invariants)

Evidence collectors are defined in config/policy.json under the
'evidence.collectors' array. Each collector specifies a type,
target, and assertions.

Machine-verifiable proof: mutation testing, property-based testing,
invariant checking, artifact capture with SHA-256 manifests.

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
        quality-score)
            cmd_quality_score
            ;;
        artifact)
            evidence_capture_artifact "$@"
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
