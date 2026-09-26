#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/loop-prebuild — Pre-build validation checks                ║
# ║                                                                         ║
# ║  Runs before the first build iteration to catch environment issues      ║
# ║  (missing dependencies, syntax errors, broken test runner) that would  ║
# ║  otherwise waste a full Claude iteration.                              ║
# ║                                                                         ║
# ║  Return codes:                                                          ║
# ║    0 = passed or skipped                                                ║
# ║    1 = failed, fixable by agent (error-summary.json written)            ║
# ║    2 = failed, fatal environment issue (abort without restart)          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard - prevent double-sourcing
[[ -n "${_LOOP_PREBUILD_LOADED:-}" ]] && return 0
_LOOP_PREBUILD_LOADED=1

# ─── Defaults and Config ────────────────────────────────────────────────────

# Disable pre-build validation checks via env var or config
: "${PRE_BUILD_VALIDATE:=${LOOP_PRE_BUILD_VALIDATE:-true}}"

# Timeout for pre-build checks (seconds). Prevents smoke test from becoming full test run
: "${PRE_BUILD_TIMEOUT:=15}"

# Checks to run (space-separated: deps, syntax, test_runner)
: "${PRE_BUILD_CHECKS:=deps syntax test_runner}"

# ─── Fallback output helpers (in case loop libs haven't loaded) ──────────────

_pbv_info() {
    echo "[pre-build] $*" >&2
}

_pbv_error() {
    echo "[pre-build:error] $*" >&2
}

# ─── Helper: Resolve base ref for git diff ──────────────────────────────────

_pbv_resolve_base_ref() {
    local root="${1:-.}"

    # Try origin/main first (common default), then main, then origin/master, then master
    for ref in "origin/main" "main" "origin/master" "master"; do
        if git -C "$root" rev-parse "$ref" >/dev/null 2>&1; then
            echo "$ref"
            return 0
        fi
    done

    # If no common ref, try HEAD~1
    if git -C "$root" rev-parse HEAD~1 >/dev/null 2>&1; then
        echo "HEAD~1"
        return 0
    fi

    # No base ref found
    return 1
}

# ─── Helper: Get list of changed files (capped) ──────────────────────────────

_pbv_changed_files() {
    local root="${1:-.}"
    local base_ref="${2:-}"

    if [[ -z "$base_ref" ]]; then
        return 1
    fi

    # Use process substitution to avoid subshell issues with set -e
    while read -r file; do
        echo "$file"
    done < <(git -C "$root" diff --name-only "$base_ref...HEAD" 2>/dev/null | head -50)
}

# ─── Helper: Classify test runner output ─────────────────────────────────────

_pbv_classify_runner_output() {
    local exit_code=$1
    local log_file="$2"

    [[ $exit_code -eq 0 ]] && echo "started" && return 0

    # Check for load-time errors (syntax, module not found) vs actual test failures
    if [[ -f "$log_file" ]]; then
        if grep -qiE "(SyntaxError|ModuleNotFoundError|Cannot find|not found|ENOENT)" "$log_file" 2>/dev/null; then
            echo "broken"
            return 0
        fi
    fi

    # Assume it's a test failure (not a runner startup issue)
    echo "started"
    return 0
}

# ─── Check 1: Dependencies ──────────────────────────────────────────────────

_pbv_check_deps() {
    local root="${1:-.}"

    # If no project detection lib, skip
    if ! type project_detect_type >/dev/null 2>&1; then
        return 3  # skipped
    fi

    local detect_json
    detect_json=$(project_detect_type "$root") || return 3

    local proj_type
    proj_type=$(echo "$detect_json" | jq -r '.type // empty' 2>/dev/null) || return 3

    [[ -z "$proj_type" ]] && return 0  # no identifiable project

    # Check for required toolchain by project type
    case "$proj_type" in
        nodejs)
            # Check for node executable
            if ! command -v node >/dev/null 2>&1; then
                echo "[pre-build:deps] node executable not found (required for package.json project)"
                return 2  # fatal
            fi

            # Check for package manager
            local build_tool
            build_tool=$(echo "$detect_json" | jq -r '.build_tool // "npm"' 2>/dev/null) || build_tool="npm"

            if ! command -v "$build_tool" >/dev/null 2>&1; then
                echo "[pre-build:deps] package manager '$build_tool' not found"
                return 2  # fatal
            fi

            # Try dependency resolution (npm install --dry-run or equivalent)
            if [[ -f "$root/package.json" ]]; then
                local install_test_cmd="$build_tool install --dry-run"
                if ! timeout "$PRE_BUILD_TIMEOUT" bash -c "cd '$root' && $install_test_cmd" >/dev/null 2>&1; then
                    echo "[pre-build:deps] dependency installation check failed (missing deps or lockfile corruption)"
                    return 1  # fixable
                fi
            fi
            ;;

        python)
            if ! command -v python3 >/dev/null 2>&1; then
                echo "[pre-build:deps] python3 executable not found"
                return 2  # fatal
            fi
            ;;

        rust)
            if ! command -v cargo >/dev/null 2>&1; then
                echo "[pre-build:deps] cargo executable not found"
                return 2  # fatal
            fi

            # Try cargo fetch with timeout
            if [[ -f "$root/Cargo.toml" ]]; then
                if ! timeout "$PRE_BUILD_TIMEOUT" cargo fetch -C "$root" >/dev/null 2>&1; then
                    echo "[pre-build:deps] cargo fetch failed (network or dependency issue)"
                    return 1  # fixable
                fi
            fi
            ;;

        golang)
            if ! command -v go >/dev/null 2>&1; then
                echo "[pre-build:deps] go executable not found"
                return 2  # fatal
            fi

            # Try go mod download
            if [[ -f "$root/go.mod" ]]; then
                if ! timeout "$PRE_BUILD_TIMEOUT" go mod download -C "$root" >/dev/null 2>&1; then
                    echo "[pre-build:deps] go mod download failed"
                    return 1  # fixable
                fi
            fi
            ;;

        ruby)
            if ! command -v ruby >/dev/null 2>&1; then
                echo "[pre-build:deps] ruby executable not found"
                return 2  # fatal
            fi
            ;;

        java)
            if ! command -v javac >/dev/null 2>&1; then
                echo "[pre-build:deps] java compiler (javac) not found"
                return 2  # fatal
            fi
            ;;

        dotnet)
            if ! command -v dotnet >/dev/null 2>&1; then
                echo "[pre-build:deps] dotnet executable not found"
                return 2  # fatal
            fi
            ;;
    esac

    return 0  # passed
}

# ─── Check 2: Syntax errors in changed files ────────────────────────────────

_pbv_check_syntax() {
    local root="${1:-.}"
    local base_ref="${2:-}"

    [[ -z "$base_ref" ]] && return 0  # skip if no base ref

    local error_count=0
    local error_lines=""

    # Get changed files
    while read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$root/$file" ]] && continue

        case "$file" in
            *.sh)
                # Bash syntax check (but only warn, don't fail — bash -n on sourced files is unreliable)
                if ! bash -n "$root/$file" >/dev/null 2>&1; then
                    error_lines="${error_lines}[pre-build:syntax:bash] $file has syntax errors"$'\n'
                    ((error_count++)) || true
                fi
                ;;

            *.js|*.ts|*.jsx|*.tsx)
                # JavaScript/TypeScript — try node --check
                if command -v node >/dev/null 2>&1; then
                    if ! node --check "$root/$file" >/dev/null 2>&1; then
                        error_lines="${error_lines}[pre-build:syntax:js] $file has syntax errors"$'\n'
                        ((error_count++)) || true
                    fi
                fi
                ;;

            *.json)
                # JSON syntax check
                if command -v jq >/dev/null 2>&1; then
                    if ! jq empty "$root/$file" >/dev/null 2>&1; then
                        error_lines="${error_lines}[pre-build:syntax:json] $file is invalid JSON"$'\n'
                        ((error_count++)) || true
                    fi
                fi
                ;;

            *.py)
                # Python syntax check
                if command -v python3 >/dev/null 2>&1; then
                    if ! python3 -m py_compile "$root/$file" >/dev/null 2>&1; then
                        error_lines="${error_lines}[pre-build:syntax:python] $file has syntax errors"$'\n'
                        ((error_count++)) || true
                    fi
                fi
                ;;
        esac

        # Limit to first 5 errors
        [[ $error_count -ge 5 ]] && break
    done < <(_pbv_changed_files "$root" "$base_ref")

    if [[ $error_count -gt 0 ]]; then
        echo -n "$error_lines"
        return 1  # fixable
    fi

    return 0  # passed
}

# ─── Check 3: Test runner startup ───────────────────────────────────────────

_pbv_check_test_runner() {
    local root="${1:-.}"
    local test_cmd="${2:-}"
    local timeout_secs="${3:-$PRE_BUILD_TIMEOUT}"

    [[ -z "$test_cmd" ]] && return 0  # no test command, skip

    # If no timeout binary available, skip (can't safely smoke-test)
    if ! type _timeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        return 3  # skipped
    fi

    # Run test command with --help or --list to verify startup
    # This is a smoke test: does the test runner even start?
    local test_log="${root}/.pre-build-test.log"

    local rc=0
    if _timeout >/dev/null 2>&1 && type _timeout >/dev/null 2>&1; then
        _timeout "$timeout_secs" bash -c "cd '$root' && $test_cmd --help >/dev/null 2>&1" >"$test_log" 2>&1 || rc=$?
    else
        timeout "$timeout_secs" bash -c "cd '$root' && $test_cmd --help >/dev/null 2>&1" >"$test_log" 2>&1 || rc=$?
    fi

    # Classify the failure
    if [[ $rc -ne 0 ]]; then
        local classification
        classification=$(_pbv_classify_runner_output "$rc" "$test_log")

        if [[ "$classification" == "broken" ]]; then
            echo "[pre-build:test_runner] test runner failed to start (load-time error)"
            rm -f "$test_log" 2>/dev/null || true
            return 1  # fixable
        fi
    fi

    rm -f "$test_log" 2>/dev/null || true
    return 0  # passed or skipped
}

# ─── Orchestrator: Run all checks and write results ──────────────────────────

pre_build_validate() {
    local project_root="${1:=${PROJECT_ROOT:-.}}"
    local log_dir="${2:=${LOG_DIR:-.}}"

    # Check if validation is disabled
    if [[ "$PRE_BUILD_VALIDATE" != "true" && "$PRE_BUILD_VALIDATE" != "1" ]]; then
        return 0  # skipped
    fi

    # Resolve base ref for changed files
    local base_ref
    base_ref=$(_pbv_resolve_base_ref "$project_root") || base_ref=""

    # Get test command (from loop context or project detection)
    local test_cmd="${TEST_CMD:-}"
    if [[ -z "$test_cmd" ]] && type project_detect_test_cmd >/dev/null 2>&1; then
        # Try to auto-detect from project
        if type project_detect_type >/dev/null 2>&1; then
            local detect_json
            detect_json=$(project_detect_type "$project_root") || true
            test_cmd=$(echo "$detect_json" | jq -r '.test_runner // empty' 2>/dev/null || true)
        fi
    fi

    # Track results
    local checks_passed=0
    local checks_failed=0
    local checks_skipped=0
    local error_lines=""
    local error_count=0
    local first_failure_category=""
    local fatal_failure=false

    local start_ms
    start_ms=$(($(date +%s%N) / 1000000))

    # Run each check
    for check in $PRE_BUILD_CHECKS; do
        local check_rc=0
        local check_output=""

        case "$check" in
            deps)
                check_output=$(_pbv_check_deps "$project_root" 2>&1) || check_rc=$?
                ;;
            syntax)
                check_output=$(_pbv_check_syntax "$project_root" "$base_ref" 2>&1) || check_rc=$?
                ;;
            test_runner)
                check_output=$(_pbv_check_test_runner "$project_root" "$test_cmd" "$PRE_BUILD_TIMEOUT" 2>&1) || check_rc=$?
                ;;
        esac

        if [[ $check_rc -eq 0 ]]; then
            ((checks_passed++)) || true
        elif [[ $check_rc -eq 2 ]]; then
            # Fatal failure
            fatal_failure=true
            ((checks_failed++)) || true
            [[ -z "$first_failure_category" ]] && first_failure_category="$check"
            error_lines="${error_lines}${check_output}"$'\n'
            ((error_count++)) || true
        elif [[ $check_rc -eq 1 ]]; then
            # Fixable failure
            ((checks_failed++)) || true
            [[ -z "$first_failure_category" ]] && first_failure_category="$check"
            error_lines="${error_lines}${check_output}"$'\n'
            ((error_count++)) || true
        else
            # Skipped (rc=3)
            ((checks_skipped++)) || true
        fi
    done

    local end_ms
    end_ms=$(($(date +%s%N) / 1000000))
    local duration_ms=$((end_ms - start_ms))

    # Determine overall status
    local status="pass"
    local return_code=0

    if [[ $checks_failed -gt 0 ]]; then
        status="fail"
        return_code=1

        # If any check was fatal, set return code to 2
        if [[ "$fatal_failure" == "true" ]]; then
            return_code=2
        fi
    elif [[ $checks_skipped -gt 0 && $checks_passed -eq 0 ]]; then
        status="skipped"
        return_code=0
    fi

    # Write validation report (always)
    local validation_report="$log_dir/pre-build-validation.json"
    local tmp_report="${validation_report}.tmp.$$"

    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg status "$status" \
            --argjson aborted "$([ "$return_code" -eq 2 ] && echo 'true' || echo 'false')" \
            --argjson duration_ms "$duration_ms" \
            --arg first_failure "$first_failure_category" \
            --argjson error_count "$error_count" \
            '{
                status: $status,
                aborted: $aborted,
                duration_ms: $duration_ms,
                first_failure_category: $first_failure,
                error_count: $error_count,
                checks_passed: '"$checks_passed"',
                checks_failed: '"$checks_failed"',
                checks_skipped: '"$checks_skipped"'
            }' > "$tmp_report" 2>/dev/null && mv "$tmp_report" "$validation_report" || rm -f "$tmp_report" 2>/dev/null
    fi

    # Write error-summary.json if validation failed (existing shape + pre_build fields)
    if [[ $return_code -ne 0 ]]; then
        local error_summary="$log_dir/error-summary.json"
        local tmp_summary="${error_summary}.tmp.$$"

        # Trim error lines to 10 max and remove trailing newlines
        local trimmed_errors
        trimmed_errors=$(echo -n "$error_lines" | head -10)

        if command -v jq >/dev/null 2>&1; then
            jq -n \
                --argjson iteration 0 \
                --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                --argjson error_count "$error_count" \
                --arg error_lines "$trimmed_errors" \
                --arg test_cmd "${TEST_CMD:-}" \
                --arg source "pre_build" \
                --arg category "$first_failure_category" \
                --argjson fatal "$([ "$return_code" -eq 2 ] && echo 'true' || echo 'false')" \
                '{
                    iteration: $iteration,
                    timestamp: $timestamp,
                    error_count: $error_count,
                    error_lines: ($error_lines | split("\n") | map(select(length > 0))),
                    test_cmd: $test_cmd,
                    source: $source,
                    category: $category,
                    fatal: $fatal
                }' > "$tmp_summary" 2>/dev/null && mv "$tmp_summary" "$error_summary" || rm -f "$tmp_summary" 2>/dev/null
        fi
    fi

    return $return_code
}
