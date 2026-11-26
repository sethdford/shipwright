#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/lessons-loop test — mine and reflect (ADR-0010)          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun and the agent launcher are mocks (the TypeScript side has its own tests); temp HOME, no network.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: lessons-loop Tests"

setup_test_env "lib-lessons-loop"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log" AGENT_LOG="$TEST_TEMP_DIR/agent.log" AGENT_EXIT=0 APPLY_EXIT=0
mock_binary "bun" '
printf "%s\n" "$*" >> "$BUN_LOG"
case " $* " in
    *" mine "*) printf "%s\n" "{\"runs\":3,\"drafts\":[{\"id\":\"L-0003\",\"markdown\":\"---\\nid: L-0003\\nstatus: proposed\\n---\\n# TODO\"},{\"id\":\"../evil\",\"markdown\":\"x\"}]}" ;;
    *" reflect "*) echo "REFLECT PROMPT" ;;
    *" apply-reflection "*) [[ "$APPLY_EXIT" == 0 ]] || exit "$APPLY_EXIT"; echo "REFLECTED L-0003" ;;
esac'
cat > "$TEST_TEMP_DIR/agent-exec" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENT_LOG"
[[ "$AGENT_EXIT" == 0 ]] || exit "$AGENT_EXIT"
echo '{"title":"t","rule":"r","hypothesis":"h"}'
MOCK
chmod +x "$TEST_TEMP_DIR/agent-exec"
export SW_AGENT_EXEC="$TEST_TEMP_DIR/agent-exec"
export SW_TS_CLI="$SCRIPT_DIR/../src/cli.ts"
source "$SCRIPT_DIR/lib/lessons-loop.sh"
EVENTS_LOG="$TEST_TEMP_DIR/events.log"
emit_event() { printf '%s\n' "$*" >> "$EVENTS_LOG"; }
: > "$TEST_TEMP_DIR/manifest"

print_test_section "mine and reflect"
assert_eq "library is executable like its siblings" "755" \
    "$(stat -c %a "$SCRIPT_DIR/lib/lessons-loop.sh" 2>/dev/null || stat -f %Lp "$SCRIPT_DIR/lib/lessons-loop.sh")"
out_dir="$TEST_TEMP_DIR/drafts"
written="$(lessons_draft_from_failures "$TEST_TEMP_DIR/manifest" "$out_dir")"
assert_eq "one draft is written, named by its id" "$out_dir/L-0003.md" "$written"
assert_eq "the reflected text replaces the draft" "REFLECTED L-0003" "$(cat "$out_dir/L-0003.md")"
assert_eq "an id that is not L-NNNN is never used as a file name" "false" "$([[ -e "$TEST_TEMP_DIR/evil.md" || -e "$out_dir/../evil.md" ]] && echo true || echo false)"
assert_contains "the agent runs one turn with no tools beyond the policy" "$(cat "$AGENT_LOG")" "claude --print --max-turns 1 REFLECT PROMPT"
assert_contains "mine gets the manifest" "$(cat "$BUN_LOG")" "governance mine --manifest $TEST_TEMP_DIR/manifest --json"
assert_contains "an event says it was reflected" "$(cat "$EVENTS_LOG")" "id=L-0003 reflected=true"

print_test_section "a failed reflection keeps the draft"
rm -rf "$out_dir"; : > "$EVENTS_LOG"
AGENT_EXIT=1 lessons_draft_from_failures "$TEST_TEMP_DIR/manifest" "$out_dir" > /dev/null
assert_contains "the agent failing keeps the placeholder draft" "$(cat "$out_dir/L-0003.md")" "# TODO"
assert_contains "and says so" "$(cat "$EVENTS_LOG")" "reflected=false"
rm -rf "$out_dir"
APPLY_EXIT=1 lessons_draft_from_failures "$TEST_TEMP_DIR/manifest" "$out_dir" > /dev/null
assert_contains "a rejected reply keeps the placeholder draft" "$(cat "$out_dir/L-0003.md")" "# TODO"

print_test_section "mining fails closed"
assert_eq "a failing mine returns non-zero" "1" "$(SW_BUN=/nonexistent/bun lessons_draft_from_failures "$TEST_TEMP_DIR/manifest" "$out_dir" >/dev/null 2>&1; echo $?)"

print_test_results
