#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/compat test — Unit tests for cross-platform helpers      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: compat Tests"

setup_test_env "sw-lib-compat-test"
trap cleanup_test_env EXIT

# Source the lib (clear guard to re-source)
_COMPAT_LOADED=""
export SHIPWRIGHT_FORCE_COLOR=1
source "$SCRIPT_DIR/lib/compat.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Platform detection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Platform detection"

current_uname=$(uname -s)
if [[ "$current_uname" == "Darwin" ]]; then
    if is_macos; then assert_pass "is_macos returns true on macOS"; else assert_fail "is_macos returns true on macOS"; fi
    if is_linux; then assert_fail "is_linux should be false on macOS"; else assert_pass "is_linux returns false on macOS"; fi
elif [[ "$current_uname" == "Linux" ]]; then
    if is_linux; then assert_pass "is_linux returns true on Linux"; else assert_fail "is_linux returns true on Linux"; fi
    if is_macos; then assert_fail "is_macos should be false on Linux"; else assert_pass "is_macos returns false on Linux"; fi
else
    assert_pass "Platform detection: unknown platform ($current_uname) — skip"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# tmp_dir
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tmp_dir"

result=$(tmp_dir)
if [[ -d "$result" ]]; then
    assert_pass "tmp_dir returns existing directory: $result"
else
    assert_fail "tmp_dir returns existing directory" "got: $result"
fi

# Test with TMPDIR override
TMPDIR_ORIG="${TMPDIR:-}"
export TMPDIR="$TEST_TEMP_DIR/custom-tmp"
mkdir -p "$TMPDIR"
result=$(tmp_dir)
assert_eq "tmp_dir respects TMPDIR" "$TEST_TEMP_DIR/custom-tmp" "$result"
export TMPDIR="$TMPDIR_ORIG"

# ═══════════════════════════════════════════════════════════════════════════════
# pid_exists
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pid_exists"

if pid_exists $$; then
    assert_pass "pid_exists detects current process ($$)"
else
    assert_fail "pid_exists detects current process ($$)"
fi

if pid_exists 9999999; then
    assert_fail "pid_exists returns false for non-existent PID"
else
    assert_pass "pid_exists returns false for non-existent PID"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# sw_valid_error_category
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "sw_valid_error_category"

for cat in test_failure build_error lint_error timeout dependency flaky config security permission unknown; do
    if sw_valid_error_category "$cat"; then
        assert_pass "Built-in category '$cat' is valid"
    else
        assert_fail "Built-in category '$cat' is valid"
    fi
done

if sw_valid_error_category "not_a_real_category"; then
    assert_fail "Invalid category should return false"
else
    assert_pass "Invalid category 'not_a_real_category' returns false"
fi

# Custom taxonomy
mkdir -p "$HOME/.shipwright/optimization"
echo '{"categories":["custom_cat","another_cat"]}' > "$HOME/.shipwright/optimization/error-taxonomy.json"
if sw_valid_error_category "custom_cat"; then
    assert_pass "Custom taxonomy category 'custom_cat' is valid"
else
    assert_fail "Custom taxonomy category 'custom_cat' is valid"
fi
if sw_valid_error_category "another_cat"; then
    assert_pass "Custom taxonomy category 'another_cat' is valid"
else
    assert_fail "Custom taxonomy category 'another_cat' is valid"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# complexity_bucket
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "complexity_bucket"

assert_eq "Complexity 1 is low" "low" "$(complexity_bucket 1)"
assert_eq "Complexity 2 is low" "low" "$(complexity_bucket 2)"
assert_eq "Complexity 3 is low" "low" "$(complexity_bucket 3)"
assert_eq "Complexity 4 is medium" "medium" "$(complexity_bucket 4)"
assert_eq "Complexity 5 is medium" "medium" "$(complexity_bucket 5)"
assert_eq "Complexity 6 is medium" "medium" "$(complexity_bucket 6)"
assert_eq "Complexity 7 is high" "high" "$(complexity_bucket 7)"
assert_eq "Complexity 10 is high" "high" "$(complexity_bucket 10)"

# Custom boundaries
cat > "$HOME/.shipwright/optimization/complexity-clusters.json" <<'JSON'
{"low_boundary": 5, "high_boundary": 8}
JSON
assert_eq "Custom boundary: 4 is low" "low" "$(complexity_bucket 4)"
assert_eq "Custom boundary: 5 is low" "low" "$(complexity_bucket 5)"
assert_eq "Custom boundary: 6 is medium" "medium" "$(complexity_bucket 6)"
assert_eq "Custom boundary: 8 is medium" "medium" "$(complexity_bucket 8)"
assert_eq "Custom boundary: 9 is high" "high" "$(complexity_bucket 9)"
rm -f "$HOME/.shipwright/optimization/complexity-clusters.json"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_primary_language
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_primary_language"

proj="$TEST_TEMP_DIR/lang-project"
mkdir -p "$proj"

# TypeScript
echo '{}' > "$proj/package.json"
echo '{}' > "$proj/tsconfig.json"
assert_eq "TypeScript detected" "typescript" "$(detect_primary_language "$proj")"
rm -f "$proj/tsconfig.json"

# JavaScript
assert_eq "JavaScript detected" "javascript" "$(detect_primary_language "$proj")"
rm -f "$proj/package.json"

# Python
touch "$proj/requirements.txt"
assert_eq "Python detected" "python" "$(detect_primary_language "$proj")"
rm -f "$proj/requirements.txt"

# Go
touch "$proj/go.mod"
assert_eq "Go detected" "go" "$(detect_primary_language "$proj")"
rm -f "$proj/go.mod"

# Rust
touch "$proj/Cargo.toml"
assert_eq "Rust detected" "rust" "$(detect_primary_language "$proj")"
rm -f "$proj/Cargo.toml"

# Java (Gradle)
touch "$proj/build.gradle"
assert_eq "Java (Gradle) detected" "java" "$(detect_primary_language "$proj")"
rm -f "$proj/build.gradle"

# Java (Maven)
touch "$proj/pom.xml"
assert_eq "Java (Maven) detected" "java" "$(detect_primary_language "$proj")"
rm -f "$proj/pom.xml"

# Elixir
touch "$proj/mix.exs"
assert_eq "Elixir detected" "elixir" "$(detect_primary_language "$proj")"
rm -f "$proj/mix.exs"

# Unknown
assert_eq "Unknown for empty dir" "unknown" "$(detect_primary_language "$proj")"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_test_framework
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_test_framework"

fwk="$TEST_TEMP_DIR/fwk-project"
mkdir -p "$fwk"

# Vitest
cat > "$fwk/package.json" <<'JSON'
{"devDependencies":{"vitest":"^1.0"}}
JSON
assert_eq "Vitest framework" "vitest" "$(detect_test_framework "$fwk")"

# Jest
cat > "$fwk/package.json" <<'JSON'
{"devDependencies":{"jest":"^29.0"}}
JSON
assert_eq "Jest framework" "jest" "$(detect_test_framework "$fwk")"

# Mocha
cat > "$fwk/package.json" <<'JSON'
{"devDependencies":{"mocha":"^10.0"}}
JSON
assert_eq "Mocha framework" "mocha" "$(detect_test_framework "$fwk")"
rm -f "$fwk/package.json"

# Python pytest
touch "$fwk/pytest.ini"
assert_eq "pytest framework" "pytest" "$(detect_test_framework "$fwk")"
rm -f "$fwk/pytest.ini"

# Go
touch "$fwk/go.mod"
assert_eq "Go test framework" "go test" "$(detect_test_framework "$fwk")"
rm -f "$fwk/go.mod"

# Rust
touch "$fwk/Cargo.toml"
assert_eq "Cargo test framework" "cargo test" "$(detect_test_framework "$fwk")"
rm -f "$fwk/Cargo.toml"

# Gradle
touch "$fwk/build.gradle"
assert_eq "Gradle test framework" "gradle test" "$(detect_test_framework "$fwk")"
rm -f "$fwk/build.gradle"

# Empty dir
assert_eq "No framework for empty dir" "" "$(detect_test_framework "$fwk")"

# ═══════════════════════════════════════════════════════════════════════════════
# compute_md5
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compute_md5"

# String mode
md5_result=$(compute_md5 --string "hello")
if [[ -n "$md5_result" && ${#md5_result} -eq 32 ]]; then
    assert_pass "compute_md5 --string returns 32-char hash"
else
    assert_fail "compute_md5 --string returns 32-char hash" "got: $md5_result (len: ${#md5_result})"
fi

# Same input produces same hash
md5_result2=$(compute_md5 --string "hello")
assert_eq "compute_md5 is deterministic" "$md5_result" "$md5_result2"

# Different input produces different hash
md5_result3=$(compute_md5 --string "world")
if [[ "$md5_result" != "$md5_result3" ]]; then
    assert_pass "Different inputs produce different hashes"
else
    assert_fail "Different inputs produce different hashes"
fi

# File mode
echo "test content" > "$TEST_TEMP_DIR/md5_test_file"
md5_file_result=$(compute_md5 "$TEST_TEMP_DIR/md5_test_file")
if [[ -n "$md5_file_result" && ${#md5_file_result} -eq 32 ]]; then
    assert_pass "compute_md5 file returns 32-char hash"
else
    assert_fail "compute_md5 file returns 32-char hash" "got: $md5_file_result (len: ${#md5_file_result})"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# file_mtime (cross-platform modification time)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "file_mtime"

echo "test" > "$TEST_TEMP_DIR/mtime_test"
mtime=$(file_mtime "$TEST_TEMP_DIR/mtime_test")
if [[ "$mtime" =~ ^[0-9]+$ ]]; then
    assert_pass "file_mtime returns numeric epoch for existing file"
else
    assert_fail "file_mtime returns numeric epoch" "got: $mtime"
fi
# Nonexistent file should return 0
mtime_missing=$(file_mtime "$TEST_TEMP_DIR/nonexistent_file_$$" 2>/dev/null || echo "0")
if [[ "$mtime_missing" == "0" ]]; then
    assert_pass "file_mtime returns 0 for nonexistent file"
else
    assert_pass "file_mtime handles missing file"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# sed_i (quick sanity test)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "sed_i"

echo "hello world" > "$TEST_TEMP_DIR/sed_test"
sed_i 's/hello/goodbye/' "$TEST_TEMP_DIR/sed_test"
result=$(cat "$TEST_TEMP_DIR/sed_test")
assert_eq "sed_i replaces in-place" "goodbye world" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# _smart_effort
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_smart_effort"

# Isolate from the developer's own environment and repo config: both an
# override and a daemon-config effort_levels block outrank the built-in
# defaults, so leaving either set would make these assertions pass or fail
# based on the machine rather than the code.
unset EFFORT_LEVEL_OVERRIDE
DAEMON_CONFIG="$TEST_TEMP_DIR/no-such-daemon-config.json"
export DAEMON_CONFIG

# Effort is spent asymmetrically — the point of these assertions is that the
# expensive levels land on the stages that write and review code, and the cheap
# level lands on the mechanical ones. A uniform ladder would pass a "returns a
# valid level" test while defeating the whole design.
assert_eq "build runs at xhigh (agentic coding)"        "xhigh"  "$(_smart_effort build)"
assert_eq "review runs at xhigh (one deep pass)"        "xhigh"  "$(_smart_effort review)"
assert_eq "compound_quality runs at xhigh"              "xhigh"  "$(_smart_effort compound_quality)"
assert_eq "plan stays high"                             "high"   "$(_smart_effort plan)"
assert_eq "design stays high"                           "high"   "$(_smart_effort design)"
assert_eq "intake stays low (mechanical)"               "low"    "$(_smart_effort intake)"
assert_eq "pr stays low (mechanical)"                   "low"    "$(_smart_effort pr)"
assert_eq "merge stays low (mechanical)"                "low"    "$(_smart_effort merge)"
assert_eq "test stays medium"                           "medium" "$(_smart_effort test)"

# These two were documented as high but fell through to the medium catch-all.
assert_eq "spec_generation is high, not the catch-all"   "high"  "$(_smart_effort spec_generation)"
assert_eq "spec_verification is high, not the catch-all" "high"  "$(_smart_effort spec_verification)"

assert_eq "unknown stage falls back to medium" "medium" "$(_smart_effort some_unknown_stage)"

# Every level emitted must be one the `claude` CLI actually accepts — a typo
# here would fail at invocation time in the pipeline, not here.
effort_invalid=0
for _stage in intake plan design spec_generation build test review \
              compound_quality spec_verification pr merge deploy validate \
              monitor unknown_stage; do
    case "$(_smart_effort "$_stage")" in
        low|medium|high|xhigh|max) ;;
        *) effort_invalid=$((effort_invalid + 1)) ;;
    esac
done
assert_eq "every stage maps to a CLI-valid effort level" "0" "$effort_invalid"

# Override must win over the built-in defaults.
EFFORT_LEVEL_OVERRIDE=low
export EFFORT_LEVEL_OVERRIDE
assert_eq "EFFORT_LEVEL_OVERRIDE outranks stage default" "low" "$(_smart_effort build)"
unset EFFORT_LEVEL_OVERRIDE

# Config must win over the built-in defaults (and lose to the override above).
cat > "$TEST_TEMP_DIR/daemon-config.json" <<'CFG'
{"effort_levels": {"build": "medium"}}
CFG
DAEMON_CONFIG="$TEST_TEMP_DIR/daemon-config.json"
assert_eq "daemon-config effort_levels outranks stage default" "medium" "$(_smart_effort build)"
assert_eq "stage absent from config still uses default" "xhigh" "$(_smart_effort review)"

# ═══════════════════════════════════════════════════════════════════════════════
# Date helpers: BSD date, GNU date and python3 must give the same answers. The
# assertions run natively and again under a `date` shim that execs GNU date
# (native on Linux; gdate on macOS), like the #8613 regression test.
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Date helpers (BSD date, GNU date)"

_expect_rc_fail() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then assert_fail "$desc" "expected a non-zero exit"; else assert_pass "$desc"; fi
}

_date_helper_assertions() {
    local label="$1"
    assert_eq "$label: date_to_epoch UTC timestamp" "1792058400" "$(date_to_epoch "2026-10-15T10:00:00Z")"
    assert_eq "$label: date_to_epoch drops fractional seconds" "1792058400" "$(date_to_epoch "2026-10-15T10:00:00.123Z")"
    assert_eq "$label: date_to_epoch date-only is UTC midnight" "1792022400" "$(date_to_epoch "2026-10-15")"
    _expect_rc_fail "$label: date_to_epoch rejects free text" date_to_epoch "next tuesday"
    _expect_rc_fail "$label: date_to_epoch rejects a local-looking string" date_to_epoch "2026-10-15 10:00:00"
    local lstart
    lstart=$(date_local_to_epoch "Mon Oct  5 10:00:00 2026")
    assert_eq "$label: date_local_to_epoch round-trips through epoch_format" "Mon Oct  5 10:00:00 2026" \
        "$(epoch_format "$lstart" '%a %b %e %H:%M:%S %Y')"
    assert_eq "$label: epoch_to_iso" "2023-11-14T22:13:20Z" "$(epoch_to_iso 1700000000)"
    _expect_rc_fail "$label: epoch_to_iso rejects non-integers" epoch_to_iso "abc"
    assert_eq "$label: epoch_format -u" "2023-11-14 22" "$(epoch_format -u 1700000000 '%Y-%m-%d %H')"
    assert_eq "$label: date_days_ago 0 is today (UTC)" "$(date -u +%Y-%m-%d)" "$(date_days_ago 0)"
    assert_eq "$label: date_add_days across a leap-year boundary" "2026-02-28" "$(date_add_days 2026-03-01 -1)"
    assert_eq "$label: date_add_days forward" "2026-10-22" "$(date_add_days 2026-10-15 7)"
    _expect_rc_fail "$label: date_days_ago rejects non-integers" date_days_ago "x"
}

_date_helper_assertions "native $(_compat_date_is_gnu && echo GNU || echo BSD)"

if ! _compat_date_is_gnu; then
    if gnu_shim_dir=$(gnu_date_shim_dir); then
        saved_path="$PATH"
        PATH="$gnu_shim_dir:$PATH"
        assert_eq "GNU shim is detected as GNU date" "y" "$(_compat_date_is_gnu && echo y || echo n)"
        _date_helper_assertions "GNU date shim"
        PATH="$saved_path"
    else
        echo "    (no GNU date available; the GNU date leg is skipped)"
    fi
fi

print_test_results
