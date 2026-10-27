#!/usr/bin/env bash
# Module guard - prevent double-sourcing
# Test commands run without credentials (#8608).
# shellcheck source=lib/test-gate-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-gate-env.sh"
[[ -n "${_TEST_HOLDOUT_LOADED:-}" ]] && return 0
_TEST_HOLDOUT_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright test-holdout — Test-as-Holdout Validation System            ║
# ║  Prevents agent overfitting by partitioning tests into visible/sealed   ║
# ║  Based on StrongDM pattern: agents can't game what they can't see       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="4.0.0"

# ─── Output Helpers (fallback if not already loaded) ─────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# ─── Configuration ───────────────────────────────────────────────────────────

HOLDOUT_RATIO="${HOLDOUT_RATIO:-30}"          # % of tests to hold out (default 30%)
HOLDOUT_DIR="${HOLDOUT_DIR:-.claude/test-holdout}"
HOLDOUT_SEALED_DIR="${HOLDOUT_DIR}/.sealed"
HOLDOUT_MANIFEST="${HOLDOUT_DIR}/manifest.json"
HOLDOUT_RESULTS="${HOLDOUT_DIR}/results.json"

# ─── Test Discovery ─────────────────────────────────────────────────────────
# Find test files in a project. Returns newline-separated list of test file paths.

holdout_discover_tests() {
    local project_dir="${1:-.}"
    local language="${2:-}"

    # Auto-detect language if not provided
    if [[ -z "$language" ]] && type detect_primary_language >/dev/null 2>&1; then
        language=$(detect_primary_language "$project_dir")
    fi

    case "$language" in
        typescript|javascript)
            find "$project_dir" \
                -type f \( -name "*.test.ts" -o -name "*.test.js" -o -name "*.spec.ts" -o -name "*.spec.js" \) \
                ! -path "*/node_modules/*" ! -path "*/.claude/*" \
                2>/dev/null | sort
            ;;
        python)
            find "$project_dir" \
                -type f \( -name "test_*.py" -o -name "*_test.py" \) \
                ! -path "*/__pycache__/*" ! -path "*/.claude/*" \
                2>/dev/null | sort
            ;;
        go)
            find "$project_dir" \
                -type f -name "*_test.go" \
                ! -path "*/.claude/*" \
                2>/dev/null | sort
            ;;
        rust)
            # Rust tests are typically in the same files or tests/ dir
            find "$project_dir" \
                -type f -name "*.rs" -path "*/tests/*" \
                ! -path "*/.claude/*" \
                2>/dev/null | sort
            ;;
        *)
            # Generic: find files with "test" in name
            find "$project_dir" \
                -type f \( -name "*test*" -o -name "*spec*" \) \
                ! -path "*/node_modules/*" ! -path "*/.claude/*" ! -path "*/.git/*" \
                ! -name "*.md" ! -name "*.json" ! -name "*.yml" \
                2>/dev/null | sort
            ;;
    esac
}

# ─── Partition ───────────────────────────────────────────────────────────────
# Split discovered tests into visible (agent can see) and holdout (sealed).
# Uses deterministic hashing so same files always get same partition.

holdout_partition() {
    local project_dir="${1:-.}"
    local language="${2:-}"
    local ratio="${3:-$HOLDOUT_RATIO}"

    local all_tests
    all_tests=$(holdout_discover_tests "$project_dir" "$language")

    if [[ -z "$all_tests" ]]; then
        warn "No test files discovered in $project_dir"
        return 1
    fi

    local total_tests visible_count holdout_count
    total_tests=$(echo "$all_tests" | wc -l | tr -d ' ')
    holdout_count=$(( total_tests * ratio / 100 ))
    # Minimum 1 holdout test if we have at least 2 tests
    if [[ "$holdout_count" -eq 0 ]] && [[ "$total_tests" -ge 2 ]]; then
        holdout_count=1
    fi
    visible_count=$(( total_tests - holdout_count ))

    # Deterministic partition using hash of filename
    local visible_tests=""
    local holdout_tests=""
    local idx=0

    while IFS= read -r test_file; do
        local hash_val
        # Use md5 for deterministic partitioning
        if command -v md5 >/dev/null 2>&1; then
            hash_val=$(printf '%s' "$test_file" | md5 -q 2>/dev/null)
        else
            hash_val=$(printf '%s' "$test_file" | md5sum 2>/dev/null | cut -d' ' -f1)
        fi

        # Use last 2 hex chars to get a number 0-255, partition by ratio
        local hash_num
        hash_num=$(printf '%d' "0x${hash_val:30:2}" 2>/dev/null || echo "0")
        local threshold=$(( 256 * ratio / 100 ))

        if [[ "$hash_num" -lt "$threshold" ]] && [[ -n "$holdout_tests" || "$idx" -gt 0 ]]; then
            if [[ -n "$holdout_tests" ]]; then
                holdout_tests="${holdout_tests}"$'\n'"${test_file}"
            else
                holdout_tests="${test_file}"
            fi
        else
            if [[ -n "$visible_tests" ]]; then
                visible_tests="${visible_tests}"$'\n'"${test_file}"
            else
                visible_tests="${test_file}"
            fi
        fi
        idx=$((idx + 1))
    done <<< "$all_tests"

    # Ensure we have at least one holdout if possible
    if [[ -z "$holdout_tests" ]] && [[ "$total_tests" -ge 2 ]]; then
        # Move last visible test to holdout
        holdout_tests=$(echo "$visible_tests" | tail -1)
        # BSD head doesn't support -n -1; use sed to remove last line
        visible_tests=$(echo "$visible_tests" | sed '$ d')
    fi

    # Ensure we have at least one visible test
    if [[ -z "$visible_tests" ]] && [[ -n "$holdout_tests" ]]; then
        visible_tests=$(echo "$holdout_tests" | head -1)
        holdout_tests=$(echo "$holdout_tests" | tail -n +2)
    fi

    local actual_holdout actual_visible
    actual_holdout=$(echo "$holdout_tests" | grep -c '.' 2>/dev/null) || actual_holdout=0
    actual_visible=$(echo "$visible_tests" | grep -c '.' 2>/dev/null) || actual_visible=0

    info "Test partition: ${actual_visible} visible, ${actual_holdout} holdout (${ratio}% target)"

    # Store partition info
    mkdir -p "$HOLDOUT_DIR"
    echo "$visible_tests" > "$HOLDOUT_DIR/visible-tests.txt"

    # Export for callers
    HOLDOUT_VISIBLE_TESTS="$visible_tests"
    HOLDOUT_SEALED_TESTS="$holdout_tests"
    HOLDOUT_TOTAL="$total_tests"
    HOLDOUT_VISIBLE_COUNT="$actual_visible"
    HOLDOUT_SEALED_COUNT="$actual_holdout"

    return 0
}

# ─── Seal ────────────────────────────────────────────────────────────────────
# Move holdout tests to sealed directory where agents can't read them.
# Creates a manifest tracking original locations for restoration.

holdout_seal() {
    local project_dir="${1:-.}"

    if [[ -z "${HOLDOUT_SEALED_TESTS:-}" ]]; then
        error "No holdout tests to seal. Run holdout_partition first."
        return 1
    fi

    mkdir -p "$HOLDOUT_SEALED_DIR"

    local manifest_entries=""
    local sealed_count=0

    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        [[ ! -f "$test_file" ]] && continue

        # Create relative path for storage
        local rel_path
        rel_path=$(echo "$test_file" | sed "s|^${project_dir}/||")
        local sealed_path="${HOLDOUT_SEALED_DIR}/${rel_path}"
        local sealed_parent
        sealed_parent=$(dirname "$sealed_path")

        mkdir -p "$sealed_parent"

        # Copy test to sealed location (don't move — agent might notice missing files)
        cp "$test_file" "$sealed_path"

        # Build manifest entry
        local entry
        entry=$(printf '{"original":"%s","sealed":"%s","hash":"%s"}' \
            "$rel_path" "$sealed_path" \
            "$(md5 -q "$test_file" 2>/dev/null || md5sum "$test_file" 2>/dev/null | cut -d' ' -f1)")

        if [[ -n "$manifest_entries" ]]; then
            manifest_entries="${manifest_entries},${entry}"
        else
            manifest_entries="${entry}"
        fi
        sealed_count=$((sealed_count + 1))
    done <<< "$HOLDOUT_SEALED_TESTS"

    # Write manifest
    cat > "$HOLDOUT_MANIFEST" <<EOF
{
  "created": "$(now_iso)",
  "ratio": ${HOLDOUT_RATIO},
  "total_tests": ${HOLDOUT_TOTAL:-0},
  "visible_count": ${HOLDOUT_VISIBLE_COUNT:-0},
  "sealed_count": ${sealed_count},
  "tests": [${manifest_entries}]
}
EOF

    # Add sealed directory to .gitignore if not already there
    local gitignore="${project_dir}/.gitignore"
    if [[ -f "$gitignore" ]]; then
        if ! grep -q "test-holdout/.sealed" "$gitignore" 2>/dev/null; then
            echo "" >> "$gitignore"
            echo "# Shipwright test holdout (sealed tests hidden from agents)" >> "$gitignore"
            echo ".claude/test-holdout/.sealed/" >> "$gitignore"
        fi
    fi

    success "Sealed ${sealed_count} holdout tests"

    if type emit_event >/dev/null 2>&1; then
        emit_event "test_holdout_sealed" \
            "total=${HOLDOUT_TOTAL:-0}" \
            "visible=${HOLDOUT_VISIBLE_COUNT:-0}" \
            "sealed=${sealed_count}" \
            "ratio=${HOLDOUT_RATIO}"
    fi

    return 0
}

# ─── Validate ────────────────────────────────────────────────────────────────
# Run holdout tests AFTER agent claims completion. This is the critical gate.
# Returns 0 if all holdout tests pass, 1 if any fail.

holdout_validate() {
    local project_dir="${1:-.}"
    local test_cmd="${2:-}"

    if [[ ! -f "$HOLDOUT_MANIFEST" ]]; then
        warn "No holdout manifest found — skipping holdout validation"
        return 0
    fi

    if [[ -z "$test_cmd" ]]; then
        # Auto-detect test command
        if type detect_test_framework >/dev/null 2>&1; then
            local framework
            framework=$(detect_test_framework "$project_dir")
            case "$framework" in
                vitest)   test_cmd="npx vitest run" ;;
                jest)     test_cmd="npx jest" ;;
                pytest)   test_cmd="pytest" ;;
                "go test") test_cmd="go test" ;;
                "cargo test") test_cmd="cargo test" ;;
                *)        test_cmd="" ;;
            esac
        fi
    fi

    if [[ -z "$test_cmd" ]]; then
        warn "No test command available — cannot validate holdout tests"
        return 0
    fi

    info "Running holdout validation (sealed tests the agent never saw)..."

    local sealed_tests
    sealed_tests=$(jq -r '.tests[].original' "$HOLDOUT_MANIFEST" 2>/dev/null)

    if [[ -z "$sealed_tests" ]]; then
        warn "No sealed tests in manifest"
        return 0
    fi

    local pass_count=0
    local fail_count=0
    local total_count=0
    local failed_tests=""

    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        total_count=$((total_count + 1))

        local full_path="${project_dir}/${test_file}"
        if [[ ! -f "$full_path" ]]; then
            warn "Holdout test missing: ${test_file} (may have been deleted by agent)"
            fail_count=$((fail_count + 1))
            if [[ -n "$failed_tests" ]]; then
                failed_tests="${failed_tests},\"${test_file}\""
            else
                failed_tests="\"${test_file}\""
            fi
            continue
        fi

        # Run the individual test (quote path to handle spaces), without credentials
        local test_result=0
        if ( sw_test_gate_scrub && eval "${test_cmd} \"${full_path}\"" ) >/dev/null 2>&1; then
            pass_count=$((pass_count + 1))
        else
            test_result=$?
            fail_count=$((fail_count + 1))
            if [[ -n "$failed_tests" ]]; then
                failed_tests="${failed_tests},\"${test_file}\""
            else
                failed_tests="\"${test_file}\""
            fi
        fi
    done <<< "$sealed_tests"

    # Write results
    cat > "$HOLDOUT_RESULTS" <<EOF
{
  "validated_at": "$(now_iso)",
  "total": ${total_count},
  "passed": ${pass_count},
  "failed": ${fail_count},
  "pass_rate": $(( total_count > 0 ? pass_count * 100 / total_count : 0 )),
  "failed_tests": [${failed_tests}]
}
EOF

    if type emit_event >/dev/null 2>&1; then
        emit_event "test_holdout_validated" \
            "total=${total_count}" \
            "passed=${pass_count}" \
            "failed=${fail_count}" \
            "pass_rate=$(( total_count > 0 ? pass_count * 100 / total_count : 0 ))"
    fi

    if [[ "$fail_count" -gt 0 ]]; then
        error "Holdout validation FAILED: ${fail_count}/${total_count} sealed tests failed"
        error "Failed tests: ${failed_tests}"
        return 1
    fi

    success "Holdout validation PASSED: ${pass_count}/${total_count} sealed tests passed"
    return 0
}

# ─── Reveal ──────────────────────────────────────────────────────────────────
# Show holdout results and clean up sealed directory.

holdout_reveal() {
    if [[ -f "$HOLDOUT_RESULTS" ]]; then
        local pass_rate
        pass_rate=$(jq -r '.pass_rate // 0' "$HOLDOUT_RESULTS" 2>/dev/null || echo "0")
        local passed failed total
        passed=$(jq -r '.passed // 0' "$HOLDOUT_RESULTS" 2>/dev/null || echo "0")
        failed=$(jq -r '.failed // 0' "$HOLDOUT_RESULTS" 2>/dev/null || echo "0")
        total=$(jq -r '.total // 0' "$HOLDOUT_RESULTS" 2>/dev/null || echo "0")

        if [[ "$failed" -gt 0 ]]; then
            error "Holdout Results: ${passed}/${total} passed (${pass_rate}%)"
            local failed_list
            failed_list=$(jq -r '.failed_tests[]' "$HOLDOUT_RESULTS" 2>/dev/null || true)
            if [[ -n "$failed_list" ]]; then
                echo "  Failed tests:"
                echo "$failed_list" | while IFS= read -r t; do
                    echo "    - $t"
                done
            fi
        else
            success "Holdout Results: ${passed}/${total} passed (${pass_rate}%)"
        fi
    else
        warn "No holdout results available"
    fi
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
# Remove sealed tests and holdout artifacts.

