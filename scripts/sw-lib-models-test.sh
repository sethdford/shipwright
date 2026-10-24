#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/models test — deterministic model routing (W2-07, #8595)            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: a temp HOME, a claude shim on PATH (no real claude), no network. Covers the resolver's fail-closed
# cases, the build stage's resolved ID, the agent-exec --model guard, the SW_LEGACY_MODEL_ROUTING gate, and
# `--effort xhigh` through sw loop's validation.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: models (deterministic routing) Tests"
setup_test_env "lib-models"
trap 'cleanup_test_env; sw_test_teardown' EXIT

source "$SCRIPT_DIR/lib/models.sh"

print_test_section "resolver: aliases and full IDs"
assert_eq "alias opus resolves to its full ID" "claude-opus-5-5" "$(models_resolve opus)"
assert_eq "alias haiku resolves to its full ID" "claude-haiku-5-5" "$(models_resolve haiku)"
assert_eq "a full ID that is an alias value passes through" "claude-sonnet-5-5" "$(models_resolve claude-sonnet-5-5)"

print_test_section "resolver: fails closed"
mdl_rc() { local rc=0; models_resolve "$1" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
assert_eq "an unknown name fails" "1" "$(mdl_rc gpt-4)"
assert_eq "an old-format ID that is not an alias value fails" "1" "$(mdl_rc claude-3-5-sonnet-20241022)"
assert_eq "an empty name fails" "1" "$(mdl_rc "")"
msg="$(models_resolve "" 2>&1 || true)"
assert_contains "an empty name says so" "$msg" "empty model name"

bad_dir="$TEST_TEMP_DIR/bad"
mkdir -p "$bad_dir"
printf '{not json' > "$bad_dir/malformed.json"
printf '{"version":1}' > "$bad_dir/no-aliases.json"
assert_eq "a missing models file fails" "1" "$(SW_MODELS_FILE="$bad_dir/none.json" mdl_rc opus)"
assert_eq "a malformed models file fails" "1" "$(SW_MODELS_FILE="$bad_dir/malformed.json" mdl_rc opus)"
assert_eq "a models file without .aliases fails" "1" "$(SW_MODELS_FILE="$bad_dir/no-aliases.json" mdl_rc opus)"
assert_eq "an empty alias value never prints" "" "$(SW_MODELS_FILE="$bad_dir/no-aliases.json" models_resolve opus 2>/dev/null || true)"

print_test_section "efforts come from config/models.json"
if models_effort_valid xhigh; then assert_pass "xhigh is a valid effort"; else assert_fail "xhigh is a valid effort"; fi
if models_effort_valid ultra; then assert_fail "ultra is not a valid effort"; else assert_pass "ultra is not a valid effort"; fi

print_test_section "build stage: the template's resolved ID (#8595 exit criterion)"
(
    # shellcheck source=lib/pipeline-stages-build.sh
    source "$SCRIPT_DIR/lib/pipeline-stages-build.sh" >/dev/null 2>&1
    _stage_effort_level() { echo "high"; }
    tmpl_model="$(jq -r '.defaults.model' "$REPO_ROOT/templates/pipelines/autonomous.json")"
    flags="$(_pipeline_claude_flags build "$tmpl_model")"
    echo "$flags" > "$TEST_TEMP_DIR/build-flags.txt"
    bad="$(_pipeline_claude_flags build no-such-model 2>/dev/null || echo FAILED)"
    echo "$bad" > "$TEST_TEMP_DIR/build-bad.txt"
) || true
assert_eq "the build flags carry the template's full model ID" "--model claude-opus-5-5 --effort high" \
    "$(cat "$TEST_TEMP_DIR/build-flags.txt")"
assert_eq "an unresolvable build model stops the flags" "FAILED" "$(cat "$TEST_TEMP_DIR/build-bad.txt")"

print_test_section "agent-exec: every --model is resolved, and an empty or unknown one never reaches claude"
bin="$TEST_TEMP_DIR/bin"
CMD_WORD="$bin/claude"  # the shim; the launcher checks that the basename is claude
mkdir -p "$bin"
argv_file="$TEST_TEMP_DIR/argv.txt"
cat > "$bin/claude" <<SHIM
#!/bin/bash
printf '%s\0' "\$@" > '$argv_file'
SHIM
chmod +x "$bin/claude"
run_exec() {
    rm -f "$argv_file"
    local rc=0
    (cd "$TEST_TEMP_DIR" && PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TEST_TEMP_DIR/home" \
        SW_AGENT_EXEC_TEST=1 "$REPO_ROOT/scripts/lib/agent-exec.sh" "$@" >/dev/null 2>"$TEST_TEMP_DIR/exec-err.txt") || rc=$?
    echo "$rc"
}
rc="$(run_exec "$CMD_WORD" -p hi --model opus)"
assert_eq "agent-exec accepts an alias" "0" "$rc"
assert_contains "agent-exec sends the full ID for the alias" "$(tr '\0' '\n' < "$argv_file")" "claude-opus-5-5"
rc="$(run_exec "$CMD_WORD" -p hi --model "")"
assert_eq "an empty --model is refused" "1" "$rc"
assert_eq "an empty --model never reaches claude" "no" "$([[ -f "$argv_file" ]] && echo yes || echo no)"
rc="$(run_exec "$CMD_WORD" -p hi --model gpt-4)"
assert_eq "an unknown --model is refused" "1" "$rc"
rc="$(run_exec "$CMD_WORD" -p hi --model=null)"
assert_eq "a null --model=VALUE is refused" "1" "$rc"

print_test_section "SW_LEGACY_MODEL_ROUTING gates the learners (default off)"
pe="$REPO_ROOT/scripts/lib/pipeline-execution.sh"
ps="$REPO_ROOT/scripts/lib/pipeline-stages-build.sh"
sl="$REPO_ROOT/scripts/sw-loop.sh"
assert_contains "UCB1 selection is behind the flag" "$(cat "$pe")" 'SW_LEGACY_MODEL_ROUTING:-false}" == "true" ]] && type ucb1_select_model'
assert_contains "the recruit model override is behind the flag" "$(cat "$ps")" 'SW_LEGACY_MODEL_ROUTING:-false}" == "true" ]] && [[ -z "$MODEL" ]] && [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]'
assert_contains "select_adaptive_model is behind the flag" "$(cat "$sl")" 'SW_LEGACY_MODEL_ROUTING:-false}" != "true" ]]'

print_test_section "sw loop: --effort xhigh passes validation (CLI mocked)"
loop_repo="$TEST_TEMP_DIR/loop-repo"
mkdir -p "$loop_repo" && (cd "$loop_repo" && git init -q && git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init)
out="$(cd "$loop_repo" && PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TEST_TEMP_DIR/home" \
    perl -e 'alarm 20; exec @ARGV' bash "$REPO_ROOT/scripts/sw-loop.sh" --effort xhigh "Add a README" 2>&1 || true)"
assert_eq "xhigh is not rejected by validation" "no" "$(grep -q -- '--effort must be' <<<"$out" && echo yes || echo no)"

print_test_results
