#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/models test — deterministic model routing (W2-07, #8595)            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: a temp HOME, a claude shim on PATH that records its argv and environment (no real claude), no network.
# Behavioural: each case runs the real launcher, resolver or pipeline function and checks what claude would receive.
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

# ─── Resolver ────────────────────────────────────────────────────────────────
print_test_section "resolver: aliases and listed IDs"
assert_eq "alias opus resolves to its full ID" "claude-opus-5-5" "$(models_resolve opus)"
assert_eq "alias haiku resolves to its full ID" "claude-haiku-5-5" "$(models_resolve haiku)"
assert_eq "a listed full ID passes through" "claude-sonnet-5-5" "$(models_resolve claude-sonnet-5-5)"
assert_eq "the default alias is sonnet" "sonnet" "$(models_default_alias)"

print_test_section "resolver: fails closed for unknown, empty, missing and malformed input"
mdl_rc() { local rc=0; models_resolve "$1" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
assert_eq "an unknown name fails" "1" "$(mdl_rc gpt-4)"
assert_eq "a full ID that is not listed fails" "1" "$(mdl_rc claude-opus-4-1)"
assert_eq "an empty name fails" "1" "$(mdl_rc "")"
msg="$(models_resolve "gpt-4" 2>&1 || true)"
assert_contains "the refusal says what to do" "$msg" "use an alias or add the ID to config/models.json"
bad_dir="$TEST_TEMP_DIR/bad"
mkdir -p "$bad_dir"
printf '{not json' > "$bad_dir/malformed.json"
printf '{"version":1}' > "$bad_dir/no-aliases.json"
assert_eq "a missing models file fails" "1" "$(SW_MODELS_FILE="$bad_dir/none.json" mdl_rc opus)"
assert_eq "a malformed models file fails" "1" "$(SW_MODELS_FILE="$bad_dir/malformed.json" mdl_rc opus)"
assert_eq "a models file without .aliases fails" "1" "$(SW_MODELS_FILE="$bad_dir/no-aliases.json" mdl_rc opus)"

print_test_section "resolver: alias values must be non-empty strings matching ^claude-[a-z0-9-]+\$"
for bad_value in '123' '{"x":1}' '"  claude-opus-5-5"' '"gpt-4"' '""' '"claude-OPUS"' 'null' '["claude-opus-5-5"]'; do
    printf '{"aliases":{"opus":%s}}' "$bad_value" > "$bad_dir/bad-value.json"
    assert_eq "alias value $bad_value is refused" "1" "$(SW_MODELS_FILE="$bad_dir/bad-value.json" mdl_rc opus)"
done
printf '{"aliases":{"opus":"claude-opus-5-5"}}' > "$bad_dir/good-value.json"
assert_eq "a well-formed alias value is accepted" "claude-opus-5-5" "$(SW_MODELS_FILE="$bad_dir/good-value.json" models_resolve opus)"

print_test_section "efforts and the learned-routing gate"
if models_effort_valid xhigh; then assert_pass "xhigh is a valid effort"; else assert_fail "xhigh is a valid effort"; fi
if models_effort_valid ultra; then assert_fail "ultra is not a valid effort"; else assert_pass "ultra is not a valid effort"; fi
gate_rc() { local rc=0; ( models_legacy_routing_enabled ) || rc=$?; echo "$rc"; }
assert_eq "learned routing is off by default" "1" "$(env -u SW_LEGACY_MODEL_ROUTING bash -c 'source "$1"; ( models_legacy_routing_enabled ) || echo 1; true' _ "$SCRIPT_DIR/lib/models.sh" | tail -1)"
assert_eq "SW_LEGACY_MODEL_ROUTING=true turns it on" "0" "$(SW_LEGACY_MODEL_ROUTING=true gate_rc)"
assert_eq "SW_LEGACY_MODEL_ROUTING=1 is not enough" "1" "$(SW_LEGACY_MODEL_ROUTING=1 gate_rc)"

# ─── Launcher: what claude receives ──────────────────────────────────────────
bin="$TEST_TEMP_DIR/bin"
mkdir -p "$bin"
rec="$TEST_TEMP_DIR/rec.txt"
cat > "$bin/claude" <<SHIM
#!/bin/bash
{ printf '%s\0' "\$@"; } > '$rec.argv'
env | grep -E '^(ANTHROPIC_|CLAUDE_CODE_USE_)' > '$rec.env' || true
SHIM
chmod +x "$bin/claude"
CMD_WORD="$bin/claude"  # the shim; the launcher checks that the command word's basename is claude
run_exec() {  # run the launcher with the claude shim; prints the exit status
    rm -f "$rec.argv" "$rec.env"
    local rc=0
    ( cd "$TEST_TEMP_DIR" && env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
        PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TEST_TEMP_DIR/home" "$@" ) \
        >/dev/null 2>"$TEST_TEMP_DIR/exec-err.txt" || rc=$?
    echo "$rc"
}
launch() { "$REPO_ROOT/scripts/lib/agent-exec.sh" "$@"; }
argv_of() { tr '\0' '\n' < "$rec.argv" 2>/dev/null; }

print_test_section "launcher: --model is resolved and required"
assert_eq "an alias is accepted and sent as its full ID" "0" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus)"
assert_contains "the full ID reaches claude" "$(argv_of)" "claude-opus-5-5"
assert_eq "an unknown --model is refused" "1" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model gpt-4)"
assert_eq "--model=null is refused" "1" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model=null)"
assert_eq "an empty --model is refused" "1" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model "")"
assert_eq "a call with no --model gets the default alias (claude-sonnet-5-5)" "0" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi)"
assert_contains "the injected default is the sonnet ID" "$(argv_of)" "claude-sonnet-5-5"

print_test_section "launcher: --fallback-model is resolved, and dropped when it equals the model"
assert_eq "a fallback alias is resolved" "0" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus --fallback-model sonnet)"
assert_contains "the fallback reaches claude as a full ID" "$(argv_of)" "claude-sonnet-5-5"
assert_eq "an unlisted --fallback-model is refused" "1" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus --fallback-model claude-opus-4-1)"
assert_eq "an unlisted --fallback-model=VALUE is refused" "1" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus --fallback-model=claude-opus-4-1)"
assert_eq "a fallback equal to the model (alias vs full ID) is dropped" "0" "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model claude-sonnet-5-5 --fallback-model sonnet)"
assert_eq "the dropped fallback is not sent" "no" "$(if grep -aF -- '--fallback-model' "$rec.argv" >/dev/null 2>&1; then echo yes; else echo no; fi)"

print_test_section "launcher: no ambient model override reaches claude"
assert_eq "ANTHROPIC_MODEL in the caller is not passed" "0" "$(run_exec ANTHROPIC_MODEL=ambient "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus)"
assert_eq "ANTHROPIC_MODEL does not appear in the child environment" "no" "$(grep -q '^ANTHROPIC_MODEL=' "$rec.env" 2>/dev/null && echo yes || echo no)"

print_test_section "launcher: Bedrock and Vertex keep aliases for the CLI's own mapping"
assert_eq "with Bedrock selected, an alias goes to the CLI unchanged" "0" \
    "$(run_exec CLAUDE_CODE_USE_BEDROCK=1 "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus)"
assert_contains "the alias reaches claude with Bedrock" "$(argv_of)" "opus"
assert_eq "with Bedrock selected, an unlisted ID is still refused" "1" \
    "$(run_exec CLAUDE_CODE_USE_BEDROCK=1 "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model gpt-4)"

print_test_section "launcher: the trust boundary (a model table set from inside an agent run is refused)"
assert_eq "SW_MODELS_FILE inside an agent run is refused" "1" \
    "$(run_exec SHIPWRIGHT_IN_TEST_GATE=1 CLAUDE_AGENT_SDK_CLIENT_APP=shipwright SW_MODELS_FILE="$bad_dir/good-value.json" \
        "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus)"
assert_eq "SW_MODELS_FILE outside an agent run is honoured" "0" \
    "$(run_exec SW_MODELS_FILE="$bad_dir/good-value.json" "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus)"

print_test_section "--effort xhigh reaches claude (behavioural)"
assert_eq "agent-exec sends --effort xhigh through unchanged" "0" \
    "$(run_exec "$REPO_ROOT/scripts/lib/agent-exec.sh" "$CMD_WORD" -p hi --model opus --effort xhigh)"
effort_val="$(argv_of | sed -n '/^--effort$/{n;p;}')"
assert_eq "claude receives --effort xhigh" "xhigh" "$effort_val"
loop_repo="$TEST_TEMP_DIR/loop-repo"
mkdir -p "$loop_repo" && (cd "$loop_repo" && git init -q && git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init)
rm -f "$rec.argv"
( cd "$loop_repo" && PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TEST_TEMP_DIR/home" \
    perl -e 'alarm 25; exec @ARGV' bash "$REPO_ROOT/scripts/sw-loop.sh" --effort xhigh "Add a README" ) >"$TEST_TEMP_DIR/loop-out.txt" 2>&1 || true
loop_effort="$(tr '\0' '\n' < "$rec.argv" 2>/dev/null | sed -n '/^--effort$/{n;p;}' | head -1)"
assert_eq "sw loop --effort xhigh reaches the mocked claude" "xhigh" "$loop_effort"
assert_eq "sw loop does not reject xhigh" "no" "$(grep -q -- '--effort must be' "$TEST_TEMP_DIR/loop-out.txt" && echo yes || echo no)"

# ─── Learner gate, behaviourally: extract the real function and call it ─────
print_test_section "learned routing: select_audit_model is off by default (behavioural)"
audit_fn="$TEST_TEMP_DIR/select_audit_model.sh"
awk '/^select_audit_model\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO_ROOT/scripts/sw-loop.sh" > "$audit_fn"
mkdir -p "$TEST_TEMP_DIR/home/.shipwright/optimization"
echo '{"haiku_success_rate": 10}' > "$TEST_TEMP_DIR/home/.shipwright/optimization/audit-tuning.json"
audit_model() {
    env "$@" HOME="$TEST_TEMP_DIR/home" bash -c '_smart_model() { echo haiku; }; source "$1"; source "$2"; select_audit_model' _ \
        "$REPO_ROOT/scripts/lib/models.sh" "$audit_fn"
}
assert_eq "with a low success rate and the default setting, the audit model stays haiku" "haiku" "$(audit_model -u SW_LEGACY_MODEL_ROUTING)"
assert_eq "with SW_LEGACY_MODEL_ROUTING=true, the success-rate escalation runs (sonnet)" "sonnet" "$(audit_model SW_LEGACY_MODEL_ROUTING=true)"

# ─── Pipeline start validation ────────────────────────────────────────────────
print_test_section "pipeline start: --model, --fallback-model and SW_MODEL_* are checked before any stage"
(
    # shellcheck source=lib/pipeline-cli.sh
    source "$SCRIPT_DIR/lib/helpers.sh" >/dev/null 2>&1 || true
    source "$SCRIPT_DIR/lib/pipeline-cli.sh" >/dev/null 2>&1 || true
    MODEL="opus" PIPELINE_FALLBACK_MODEL="" validate_model_flags && echo ok-alias > "$TEST_TEMP_DIR/v1.txt" || echo bad > "$TEST_TEMP_DIR/v1.txt"
    MODEL="gpt-4" validate_model_flags 2>"$TEST_TEMP_DIR/v2.err" && echo ok > "$TEST_TEMP_DIR/v2.txt" || echo refused > "$TEST_TEMP_DIR/v2.txt"
    MODEL="" PIPELINE_FALLBACK_MODEL="claude-opus-4-1" validate_model_flags 2>/dev/null && echo ok > "$TEST_TEMP_DIR/v3.txt" || echo refused > "$TEST_TEMP_DIR/v3.txt"
    MODEL="" SW_MODEL_CLASSIFICATION="nope" validate_model_flags 2>/dev/null && echo ok > "$TEST_TEMP_DIR/v4.txt" || echo refused > "$TEST_TEMP_DIR/v4.txt"
) || true
assert_eq "a listed alias passes validation" "ok-alias" "$(cat "$TEST_TEMP_DIR/v1.txt" 2>/dev/null)"
assert_eq "an unlisted --model is refused at start" "refused" "$(cat "$TEST_TEMP_DIR/v2.txt" 2>/dev/null)"
assert_contains "the refusal says to use an alias or add the ID" "$(cat "$TEST_TEMP_DIR/v2.err" 2>/dev/null)" "add the ID to config/models.json"
assert_eq "an unlisted --fallback-model is refused at start" "refused" "$(cat "$TEST_TEMP_DIR/v3.txt" 2>/dev/null)"
assert_eq "an unlisted SW_MODEL_* override is refused at start" "refused" "$(cat "$TEST_TEMP_DIR/v4.txt" 2>/dev/null)"

print_test_section "_smart_model: a value that is not listed is refused, not sent"
smart_out="$(bash -c 'source "$1"; SW_MODEL_CLASSIFICATION=bogus-9 _smart_model classification haiku' _ "$REPO_ROOT/scripts/lib/compat.sh" 2>/dev/null || echo REFUSED)"
assert_eq "an unlisted SW_MODEL_* value prints nothing and fails" "REFUSED" "$smart_out"
assert_eq "a listed override is returned as given" "opus" "$(bash -c 'source "$1"; SW_MODEL_CLASSIFICATION=opus _smart_model classification haiku' _ "$REPO_ROOT/scripts/lib/compat.sh")"

# ─── Build stage: the template's resolved ID (#8595 exit criterion) ─────────
print_test_section "build stage: the template's model resolves to the full ID"
flags="$(bash -c '
    source "$1" >/dev/null 2>&1
    _stage_effort_level() { echo high; }
    _pipeline_claude_flags build "$(jq -r ".defaults.model" "$2")"
' _ "$REPO_ROOT/scripts/lib/pipeline-stages-build.sh" "$REPO_ROOT/templates/pipelines/autonomous.json" 2>/dev/null || echo FAILED)"
assert_eq "the build flags carry the template's full model ID" "--model claude-opus-5-5 --effort high" "$flags"

print_test_results
