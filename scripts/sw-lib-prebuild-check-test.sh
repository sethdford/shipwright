#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/prebuild-check test — Unit tests for pre-build toolchain  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: prebuild-check Tests"

setup_test_env "sw-lib-prebuild-check-test"
trap cleanup_test_env EXIT

# ─── Hermetic PATH: mocks + only the system tools the lib needs ──────────────
# The runner has real node/npm/cargo installed; tests must not see them.
SYSBIN="$TEST_TEMP_DIR/sysbin"
mkdir -p "$SYSBIN"
for tool in bash env jq mktemp date rm mv mkdir cat tr sed head cut sleep timeout gtimeout chmod ln grep touch printf; do
    real=$(PATH="$ORIG_PATH" command -v "$tool" 2>/dev/null || true)
    [[ -n "$real" && "$real" == /* ]] && ln -sf "$real" "$SYSBIN/$tool"
done
export PATH="$TEST_TEMP_DIR/bin:$SYSBIN"

EVENTS_LOG="$TEST_TEMP_DIR/events.log"
info()    { echo "INFO: $*"; }
success() { echo "OK: $*"; }
warn()    { echo "WARN: $*"; }
error()   { echo "ERROR: $*"; }
emit_event() { echo "$*" >> "$EVENTS_LOG"; }

source "$SCRIPT_DIR/lib/pipeline-detection.sh"
_PREBUILD_CHECK_LOADED=""
source "$SCRIPT_DIR/lib/prebuild-check.sh"

PROJ="$TEST_TEMP_DIR/proj"
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
ARTIFACT="$ARTIFACTS_DIR/prebuild-check.json"

# reset_case — fresh project dir, artifacts, mocks and config
reset_case() {
    rm -rf "$PROJ" "$ARTIFACTS_DIR" "$EVENTS_LOG"
    rm -f "$TEST_TEMP_DIR/bin"/*
    ln -sf "$SYSBIN/jq" "$TEST_TEMP_DIR/bin/jq"
    mkdir -p "$PROJ"
    unset SHIPWRIGHT_PIPELINE_PREBUILD_MODE SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK \
        SHIPWRIGHT_PIPELINE_PREBUILD_CHECK_TIMEOUT_SECONDS 2>/dev/null || true
}

mock_node() { mock_binary node "echo v$1"; }

# run_check <lang> — runs prebuild_check in a subshell, sets RC and OUT
run_check() {
    RC=0
    OUT=$(prebuild_check "$1" "$PROJ" 2>&1) || RC=$?
}

finding_ids() { jq -r '[.findings[].id] | join(",")' "$ARTIFACT" 2>/dev/null || echo ""; }
finding_sev() { jq -r --arg id "$1" '[.findings[] | select(.id == $id) | .severity][0] // ""' "$ARTIFACT" 2>/dev/null || echo ""; }

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_pbc_semver_satisfies"

semver_case() {
    local installed="$1" range="$2" expected="$3" rc=0
    _pbc_semver_satisfies "$installed" "$range" || rc=$?
    assert_eq "semver $installed vs \"$range\" → $expected" "$expected" "$rc"
}
semver_case 20.11.1 ">=18" 0
semver_case 16.20.0 ">=18" 1
semver_case 18.0.0 ">=18.0.0" 0
semver_case 18.16.9 ">=18.17" 1
semver_case 20.11.1 "^20" 0
semver_case 21.0.0 "^20" 1
semver_case 20.10.0 "^20.11" 1
semver_case 20.11.5 "~20.11" 0
semver_case 20.12.0 "~20.11" 1
semver_case 20.11.1 "20" 0
semver_case 20.11.1 "v20" 0
semver_case 20.11.1 "20.x" 0
semver_case 22.1.0 "20.x" 1
semver_case 20.11.1 "20.11.x" 0
semver_case 20.11.1 "20.11.1" 0
semver_case 20.11.2 "20.11.1" 1
semver_case 22.3.0 "^18 || ^20 || >=22" 0
semver_case 19.0.0 "^18 || ^20" 1
semver_case 20.0.0 ">=18.17 <21" 2
semver_case 20.0.0 "lts/*" 2
semver_case 20.0.0 "1.0.0 - 2.0.0" 2
semver_case 20.0.0 ">=99 || weird" 2

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Node checks"

reset_case
echo '{"name":"x"}' > "$PROJ/package.json"
run_check nodejs
assert_exit_code "node missing under enforce fails" 1 "$RC"
assert_eq "node missing → runtime_missing critical" "critical" "$(finding_sev runtime_missing)"
assert_json_key "artifact status fail" "$(cat "$ARTIFACT")" ".status" "fail"
assert_contains "failed event emitted" "$(cat "$EVENTS_LOG")" "prebuild_check.failed"
assert_contains "critical finding printed with remedy" "$OUT" "nodejs.org"

reset_case
echo '{"name":"x"}' > "$PROJ/package.json"
export SHIPWRIGHT_PIPELINE_PREBUILD_MODE=warn
run_check nodejs
assert_exit_code "node missing under warn mode proceeds" 0 "$RC"
assert_json_key "warn mode status warn" "$(cat "$ARTIFACT")" ".status" "warn"
assert_contains "completed event emitted in warn mode" "$(cat "$EVENTS_LOG")" "prebuild_check.completed"

reset_case
mock_node 16.20.0; mock_binary npm "exit 0"
echo '{"engines":{"node":">=18"}}' > "$PROJ/package.json"
touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
export SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK=false
run_check typescript
assert_exit_code "engine mismatch fails" 1 "$RC"
assert_eq "engines >=18 with v16 → engine_mismatch critical" "critical" "$(finding_sev engine_mismatch)"

reset_case
mock_node 20.11.1; mock_binary npm "exit 0"
echo '{"engines":{"node":"^20"}}' > "$PROJ/package.json"
touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
export SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK=false
run_check nodejs
assert_exit_code "^20 with v20.11.1 passes" 0 "$RC"
assert_json_key "clean project status pass" "$(cat "$ARTIFACT")" ".status" "pass"
assert_eq "clean project has no findings" "" "$(finding_ids)"

reset_case
mock_node 20.11.1; mock_binary npm "exit 0"
echo '{"engines":{"node":">=18.17 <21"}}' > "$PROJ/package.json"
touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
export SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK=false
run_check nodejs
assert_exit_code "unparseable range never blocks" 0 "$RC"
assert_eq "unparseable range → engine_unparseable info" "info" "$(finding_sev engine_unparseable)"

reset_case
mock_node 18.19.0; mock_binary npm "exit 0"
echo '{"name":"x"}' > "$PROJ/package.json"
echo "20" > "$PROJ/.nvmrc"
touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
export SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK=false
run_check nodejs
assert_eq ".nvmrc used as fallback engine source" "critical" "$(finding_sev engine_mismatch)"
assert_contains ".nvmrc named in message" "$(jq -r '.findings[0].message' "$ARTIFACT")" ".nvmrc"

reset_case
mock_node 20.11.1; mock_binary npm "exit 0"
echo '{"name":"x"}' > "$PROJ/package.json"
touch "$PROJ/pnpm-lock.yaml"
run_check nodejs
assert_exit_code "pnpm lockfile without pnpm fails" 1 "$RC"
assert_eq "pnpm missing → pkg_manager_missing critical" "critical" "$(finding_sev pkg_manager_missing)"
assert_contains "pnpm remedy uses corepack" "$(jq -r '.findings[0].remedy' "$ARTIFACT")" "corepack enable pnpm"

reset_case
mock_node 20.11.1; mock_binary npm "exit 0"
echo '{"name":"x"}' > "$PROJ/package.json"
touch "$PROJ/package-lock.json"
run_check nodejs
assert_exit_code "missing node_modules only warns" 0 "$RC"
assert_eq "missing node_modules → deps_not_installed warning" "warning" "$(finding_sev deps_not_installed)"
assert_contains "npm ci suggested when lockfile present" "$(jq -r '.findings[0].remedy' "$ARTIFACT")" "npm ci"

reset_case
mock_node 20.11.1; mock_binary npm "exit 0"
echo '{"name":"x"}' > "$PROJ/package.json"
mkdir -p "$PROJ/node_modules"
export SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK=false
run_check nodejs
assert_eq "no lockfile → lockfile_missing info" "info" "$(finding_sev lockfile_missing)"

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    reset_case
    mock_node 20.11.1
    mock_binary npm 'echo "{\"problems\":[\"missing: left-pad@^1.0.0, required by x@1.0.0\"]}"; exit 1'
    echo '{"name":"x"}' > "$PROJ/package.json"
    touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
    run_check nodejs
    assert_exit_code "npm ls problems only warn" 0 "$RC"
    assert_eq "npm ls problems → deps_inconsistent warning" "warning" "$(finding_sev deps_inconsistent)"
    assert_contains "problem text surfaced" "$(jq -r '.findings[0].message' "$ARTIFACT")" "left-pad"

    reset_case
    mock_node 20.11.1
    mock_binary npm 'echo "{}"; exit 1'
    echo '{"name":"x"}' > "$PROJ/package.json"
    touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
    run_check nodejs
    assert_eq "npm ls non-zero exit without problems → no finding" "" "$(finding_ids)"

    reset_case
    mock_node 20.11.1
    mock_binary npm 'sleep 5; echo "{}"'
    echo '{"name":"x"}' > "$PROJ/package.json"
    touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
    export SHIPWRIGHT_PIPELINE_PREBUILD_CHECK_TIMEOUT_SECONDS=1
    t0=$(date +%s)
    run_check nodejs
    elapsed=$(( $(date +%s) - t0 ))
    assert_exit_code "hung npm ls does not block" 0 "$RC"
    assert_eq "hung npm ls → check_timeout info" "info" "$(finding_sev check_timeout)"
    if [[ "$elapsed" -le 3 ]]; then
        assert_pass "timeout honored (${elapsed}s ≤ budget+2s)"
    else
        assert_fail "timeout honored" "took ${elapsed}s"
    fi
else
    assert_pass "npm ls tests skipped: no timeout binary on this host"
fi

reset_case
mock_node 20.11.1; mock_binary npm "exit 0"
echo '{ this is not json' > "$PROJ/package.json"
touch "$PROJ/package-lock.json"; mkdir -p "$PROJ/node_modules"
export SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK=false
run_check nodejs
assert_exit_code "malformed package.json does not crash" 0 "$RC"
assert_file_exists "malformed package.json still writes artifact" "$ARTIFACT"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Other languages"

reset_case
run_check rust
assert_eq "rust without cargo → runtime_missing" "critical" "$(finding_sev runtime_missing)"
mock_binary cargo "exit 0"
run_check rust
assert_exit_code "rust with cargo passes" 0 "$RC"

reset_case
run_check go
assert_exit_code "go without go fails" 1 "$RC"

reset_case
mock_binary python3 "exit 0"
run_check python
assert_exit_code "python with python3 passes" 0 "$RC"

reset_case
mock_binary ruby "exit 0"
touch "$PROJ/Gemfile"
run_check ruby
assert_eq "Gemfile without bundler → pkg_manager_missing" "critical" "$(finding_sev pkg_manager_missing)"

reset_case
mock_binary java "exit 0"
touch "$PROJ/pom.xml"
printf '#!/bin/sh\n' > "$PROJ/mvnw"; chmod +x "$PROJ/mvnw"
run_check java
assert_exit_code "java with mvnw wrapper passes without mvn" 0 "$RC"

reset_case
run_check unknown
assert_exit_code "unknown lang passes" 0 "$RC"
assert_json_key "unknown lang status pass" "$(cat "$ARTIFACT")" ".status" "pass"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Orchestrator behavior"

reset_case
export SHIPWRIGHT_PIPELINE_PREBUILD_MODE=off
run_check nodejs
assert_exit_code "mode=off proceeds" 0 "$RC"
assert_file_not_exists "mode=off writes no artifact" "$ARTIFACT"

reset_case
export SHIPWRIGHT_PIPELINE_PREBUILD_MODE=bogus
run_check go
assert_exit_code "unknown mode falls back to enforce" 1 "$RC"

reset_case
mkdir -p "$TEST_TEMP_DIR/ro"
touch "$TEST_TEMP_DIR/ro/blocker"
RC=0
OUT=$(ARTIFACTS_DIR="$TEST_TEMP_DIR/ro/blocker/sub" prebuild_check unknown "$PROJ" 2>&1) || RC=$?
assert_exit_code "unwritable artifacts dir fails open" 0 "$RC"
assert_contains "unwritable artifacts dir warns" "$OUT" "could not write"

reset_case
mock_node 16.0.0; mock_binary npm "exit 0"
echo '{"engines":{"node":">=18"}}' > "$PROJ/package.json"
touch "$PROJ/pnpm-lock.yaml"
run_check nodejs
assert_eq "artifact matches PrebuildResult schema" "true" "$(jq -e '
    .version == 1 and (.mode | IN("off","warn","enforce")) and (.language | type == "string")
    and (.status | IN("pass","warn","fail","skipped")) and (.duration_ms | type == "number")
    and (.findings | type == "array")
    and all(.findings[]; (.id|type=="string") and (.severity|IN("critical","warning","info"))
        and (.message|type=="string") and (.remedy|type=="string"))' "$ARTIFACT" 2>/dev/null || echo false)"
assert_eq "every critical/warning finding has a remedy" "true" \
    "$(jq '[.findings[] | select(.severity != "info") | .remedy | length > 0] | all' "$ARTIFACT")"
assert_eq "multiple criticals collected" "engine_mismatch,pkg_manager_missing" \
    "$(jq -r '[.findings[] | select(.severity=="critical") | .id] | sort | join(",")' "$ARTIFACT")"

# Caller-visible globals when run in the current shell
reset_case
rc=0
prebuild_check go "$PROJ" >/dev/null 2>&1 || rc=$?
assert_eq "PREBUILD_STATUS set for caller" "fail" "$PREBUILD_STATUS"
assert_eq "PREBUILD_CRITICAL_IDS set for caller" "runtime_missing" "$PREBUILD_CRITICAL_IDS"

# Concurrent runs in separate artifact dirs
reset_case
mock_binary cargo "exit 0"
( ARTIFACTS_DIR="$TEST_TEMP_DIR/a1" prebuild_check rust "$PROJ" >/dev/null 2>&1 ) &
pid1=$!
( ARTIFACTS_DIR="$TEST_TEMP_DIR/a2" prebuild_check go "$PROJ" >/dev/null 2>&1 ) &
pid2=$!
wait "$pid1" || true
wait "$pid2" || true
assert_json_key "concurrent run 1 valid" "$(cat "$TEST_TEMP_DIR/a1/prebuild-check.json")" ".status" "pass"
assert_json_key "concurrent run 2 valid" "$(cat "$TEST_TEMP_DIR/a2/prebuild-check.json")" ".status" "fail"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Progress comment line"

source "$SCRIPT_DIR/lib/pipeline-github.sh"
reset_case
assert_eq "no artifact → no environment line" "" "$(_gh_prebuild_line)"
run_check unknown
assert_eq "pass → no environment line" "" "$(_gh_prebuild_line)"
export SHIPWRIGHT_PIPELINE_PREBUILD_MODE=warn
run_check go
line=$(_gh_prebuild_line)
assert_contains "warn → environment line" "$line" "**Environment:** ⚠️ prebuild warn"
assert_contains "warn line lists critical ids" "$line" '`runtime_missing`'

# Bash 3.2 compatibility of the lib itself
if grep -nE 'declare -A|readarray|mapfile|\$\{[a-zA-Z_]+(,,|\^\^)\}' "$SCRIPT_DIR/lib/prebuild-check.sh" >/dev/null; then
    assert_fail "lib is bash 3.2 compatible"
else
    assert_pass "lib is bash 3.2 compatible"
fi

print_test_results
