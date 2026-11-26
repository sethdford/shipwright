#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/repo-model test — ADR-0016 brief and MCP attach           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun is a mock (the TypeScript command has its own tests), a temp git repo, temp HOME, no network.
# Checks what the bash side owns: the root and task it passes, the MCP config it writes, the events and the
# SHIPWRIGHT_REPO_MODEL switch that is the control arm of a paired eval run.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: repo-model Tests"

setup_test_env "lib-repo-model"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log" TASK_COPY="$TEST_TEMP_DIR/task.txt" BUN_EXIT=0
# The mock logs its argv, copies the --task file and answers like the real command.
mock_binary "bun" '
printf "%s\n" "$@" >> "$BUN_LOG"; printf -- "--\n" >> "$BUN_LOG"
prev=""
for a in "$@"; do
    [[ "$prev" == "--task" ]] && cat "$a" >> "$TASK_COPY"
    prev="$a"
done
[[ "$BUN_EXIT" == 0 ]] || exit "$BUN_EXIT"
case " $* " in
    *" brief "*) printf "%s\n" "{\"brief\":\"## Repository model\\n- src/a.ts\",\"files\":[\"src/a.ts\",\"src/b.ts\"],\"stats\":{\"extracted\":2},\"arm\":\"on\"}" ;;
    *" build "*) echo "built" ;;
    *" impact "*) printf "%s\n" "{\"text\":\"## Change impact (repository model)\\n- src/a.ts\",\"files\":[{}],\"untested\":[\"src/a.ts\"],\"orphaned\":[],\"arm\":\"on\"}" ;;
esac'

# The shipwright CLI lives outside the repository the agent works in, as it does for any target repository.
mkdir -p "$TEST_TEMP_DIR/sw/src"
: > "$TEST_TEMP_DIR/sw/src/cli.ts"
export SW_TS_CLI="$TEST_TEMP_DIR/sw/src/cli.ts" REPO_MODEL_MCP_DIR="$TEST_TEMP_DIR"
source "$SCRIPT_DIR/lib/repo-model.sh"
EVENTS_LOG="$TEST_TEMP_DIR/events.log"
emit_event() { printf '%s\n' "$*" >> "$EVENTS_LOG"; }
reset_logs() { : > "$BUN_LOG"; : > "$TASK_COPY"; : > "$EVENTS_LOG"; }

repo="$TEST_TEMP_DIR/repo"
mkdir -p "$repo"
cd "$repo"
git init -q -b main .
repo_abs="$(pwd -P)"
unset PROJECT_ROOT

print_test_section "switch"
assert_eq "library is executable like its siblings" "755" \
    "$(stat -c %a "$SCRIPT_DIR/lib/repo-model.sh" 2>/dev/null || stat -f %Lp "$SCRIPT_DIR/lib/repo-model.sh")"
assert_eq "on by default" "on" "$(repo_model_arm)"
for v in off OFF 0 false No " off "; do
    assert_eq "SHIPWRIGHT_REPO_MODEL='$v' is the off arm" "off" "$(SHIPWRIGHT_REPO_MODEL="$v" repo_model_arm)"
done
assert_eq "any other value stays on" "on" "$(SHIPWRIGHT_REPO_MODEL=yes repo_model_arm)"

print_test_section "brief"
reset_logs
brief="$(repo_model_brief_section "Fix the budget cap" --with-tools)"
assert_contains "the brief is the command's .brief" "$brief" "## Repository model"
assert_contains "the command gets the absolute repository root" "$(tr '\n' ' ' < "$BUN_LOG")" "repomodel brief --root ${repo_abs} --task"
assert_contains "and --with-tools when the tools are attached" "$(tr '\n' ' ' < "$BUN_LOG")" "--json --with-tools"
assert_contains "the goal is the task text" "$(cat "$TASK_COPY")" "Fix the budget cap"
assert_contains "an event records the arm and the files named" "$(cat "$EVENTS_LOG")" "repo_model.brief arm=on files=src/a.ts,src/b.ts semantic=off"
reset_logs
SHIPWRIGHT_REPO_MODEL_SEMANTIC=on repo_model_brief_section "x" >/dev/null
assert_contains "and the semantic arm" "$(cat "$EVENTS_LOG")" "semantic=on"
reset_logs
assert_eq "off: no brief" "" "$(SHIPWRIGHT_REPO_MODEL=off repo_model_brief_section "x")"
assert_eq "off: the command does not run" "" "$(cat "$BUN_LOG")"
assert_contains "off: the event still records the arm" "$(cat "$EVENTS_LOG")" "repo_model.brief arm=off"
reset_logs
assert_eq "a failing command gives no brief" "" "$(BUN_EXIT=1 repo_model_brief_section x)"
assert_contains "and says why" "$(cat "$EVENTS_LOG")" "repo_model.brief_unavailable"
assert_eq "no Bun gives no brief" "" "$(SW_BUN=/nonexistent/bun repo_model_brief_section x)"

print_test_section "impact"
reset_logs
printf 'diff --git a/src/a.ts b/src/a.ts\n' > "$TEST_TEMP_DIR/change.diff"
impact="$(repo_model_impact_section "$TEST_TEMP_DIR/change.diff")"
assert_contains "the section is the command's .text" "$impact" "## Change impact (repository model)"
assert_contains "the command gets the root and the diff" "$(tr '\n' ' ' < "$BUN_LOG")" \
    "repomodel impact --root ${repo_abs} --diff ${TEST_TEMP_DIR}/change.diff --json"
assert_contains "an event records the arm and counts" "$(cat "$EVENTS_LOG")" "repo_model.impact arm=on files=1 untested=1 orphaned=0"
reset_logs
assert_eq "off: no section" "" "$(SHIPWRIGHT_REPO_MODEL=off repo_model_impact_section "$TEST_TEMP_DIR/change.diff")"
assert_eq "off: the command does not run" "" "$(cat "$BUN_LOG")"
assert_eq "an empty diff gives nothing" "" "$(repo_model_impact_section /nonexistent)"
reset_logs
assert_eq "a failing command gives nothing" "" "$(BUN_EXIT=1 repo_model_impact_section "$TEST_TEMP_DIR/change.diff")"
assert_contains "and says why" "$(cat "$EVENTS_LOG")" "repo_model.impact_unavailable"

print_test_section "MCP server"
reset_logs
flags="$(repo_model_mcp_flags)"
cfg="${flags#--mcp-config }"
assert_eq "flags are --mcp-config and a file" "--mcp-config ${TEST_TEMP_DIR}/sw-repo-model-mcp.$$.json" "$flags"
assert_eq "the server is the repomodel command for this root" \
    "repomodel mcp --root ${repo_abs}" "$(jq -r '.mcpServers.repomodel.args[1:] | join(" ")' "$cfg")"
assert_eq "it runs the CLI outside the worktree" "$(cd "$TEST_TEMP_DIR/sw/src" && pwd -P)/cli.ts" \
    "$(jq -r '.mcpServers.repomodel.args[0]' "$cfg")"
assert_eq "with the resolved bun" "$TEST_TEMP_DIR/bin/bun" "$(jq -r '.mcpServers.repomodel.command' "$cfg")"
assert_contains "the model is built before the agent starts" "$(tr '\n' ' ' < "$BUN_LOG")" "repomodel build --root ${repo_abs}"
assert_contains "an event records the attach" "$(cat "$EVENTS_LOG")" "repo_model.mcp_attached arm=on"
repo_model_mcp_flags > /dev/null
assert_eq "repeated calls reuse one config file" "1" "$(find "$TEST_TEMP_DIR" -maxdepth 1 -name 'sw-repo-model-mcp*' | wc -l | tr -d ' ')"
assert_eq "off: no flags" "" "$(SHIPWRIGHT_REPO_MODEL=off repo_model_mcp_flags)"
reset_logs
mkdir -p "$repo/src" && : > "$repo/src/cli.ts"
assert_eq "a CLI inside the agent's worktree is never started as a server" "" \
    "$(SW_TS_CLI="$repo/src/cli.ts" repo_model_mcp_flags)"
assert_contains "and the skip is recorded" "$(cat "$EVENTS_LOG")" "repo_model.mcp_skipped"
if SW_TS_CLI="$repo/src/cli.ts" repo_model_tools_available; then avail=yes; else avail=no; fi
assert_eq "so the brief does not advertise the tools" "no" "$avail"

print_test_section "wiring"
assert_contains "the loop sources the library" "$(cat "$SCRIPT_DIR/sw-loop.sh")" 'source "$SCRIPT_DIR/lib/repo-model.sh"'
assert_contains "build iterations get the MCP flags" "$(cat "$SCRIPT_DIR/lib/loop-iteration.sh")" 'repo_model_mcp_flags'
assert_contains "pipeline stages get the MCP flags" "$(cat "$SCRIPT_DIR/lib/pipeline-stages-build.sh")" 'repo_model_mcp_flags'
assert_contains "the review stage gets the impact section" "$(cat "$SCRIPT_DIR/lib/pipeline-stages-review.sh")" 'repo_model_impact_section "$diff_file"'
assert_contains "the merge critic gets it too" "$(cat "$SCRIPT_DIR/lib/verifier-gate.sh")" '--impact-file'
assert_contains "the policy allows the server's tools" "$(cat "$SCRIPT_DIR/../config/agent-permissions.json")" '"mcp__repomodel"'

print_test_results
