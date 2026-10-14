# Definition of Done — Shipwright Pipeline

Autonomous agents must verify all items before marking a task complete.

## Code Quality & Standards

- [ ] **Bash 3.2 Compatible**: No `declare -A`, `readarray`, `${var,,}`, `${var^^}`, or other bash 4+ syntax
- [ ] **Pipeline Compliance**: All shell scripts include `set -euo pipefail` at top
- [ ] **Version Updated**: `VERSION` variable at top of modified scripts matches or is incremented from last version
- [ ] **Color & Output Helpers**: New output uses `info()`, `success()`, `warn()`, `error()` functions (not raw `echo`)
- [ ] **Proper Quoting**: All variables quoted (`"$var"`) except where word splitting is intentional

## Bash Hygiene & Safety

- [ ] **No Hardcoded Secrets**: No API keys, tokens, or credentials in code; use `.env` or config files
- [ ] **Atomic File Writes**: Use temp file + `mv` pattern for state writes, never direct `echo > file`
- [ ] **JSON in Bash**: All JSON generation uses `jq --arg` for escaping, never string interpolation
- [ ] **Pipefail Safety**: No `grep -c` without `|| true`; use `${var:-0}` for defaults
- [ ] **Subshell Awareness**: No `cd` in helper functions that affect caller; use `( cd dir && ... )` when needed
- [ ] **NO_GITHUB Checks**: Any GitHub API calls wrapped with `[[ -z "$NO_GITHUB" ]]` guard for testing

## Testing

- [ ] **Existing Tests Pass**: Run `npm test` (or relevant test suite) and all pass
- [ ] **New Tests Added**: Functional changes include corresponding unit tests
- [ ] **Test Isolation**: Tests use temp directories, mock binaries, no side effects on real system
- [ ] **Mock Pattern**: CLI calls mocked in test harness, not real `claude` or `gh` binaries

## Documentation

- [ ] **CLAUDE.md Updated**: If behavior changes, update `docs/reference/legacy-guide.md`
- [ ] **Inline Comments**: Complex logic (jq filters, state machine transitions) has comments explaining intent
- [ ] **Function Headers**: New functions include 1-2 line description of purpose
- [ ] **CLI Help**: New commands registered in `scripts/sw` main() case statement with brief description

## No Regressions

- [ ] **Existing Pipelines Work**: Test a full `shipwright pipeline start` flow succeeds
- [ ] **Daemon Still Watches**: If daemon touched, verify `shipwright daemon start` still processes issues
- [ ] **Config Backward Compatible**: No breaking changes to `.claude/pipeline-state.md` or `daemon-config.json` format
- [ ] **Event Logging Intact**: `emit_event` calls still write to `~/.shipwright/events.jsonl`

## Security & Environment

- [ ] **No Credentials in Logs**: State files and events do not contain secrets
- [ ] **Proper Error Handling**: Failures exit with non-zero status and meaningful error message
- [ ] **Input Validation**: File paths, arguments, and external input checked before use
- [ ] **Temp Cleanup**: Temp files created with `mktemp` and cleaned up (or use `trap` for cleanup)

## Ready to Merge

- [ ] **Commit Message Clear**: Describes what changed and why (not just what files)
- [ ] **No Leftover Debug Code**: No `set -x`, commented-out blocks, or temporary debugging
- [ ] **Related Files Checked**: If modifying pipeline, check daemon; if modifying state, check all readers
- [ ] **This Checklist Passed**: All items above verified before task marked complete

---

**Usage**: Before marking a task complete, copy this checklist into the PR or commit message and check each box. Agents should fail tasks that don't meet these criteria and create follow-up tasks for gaps.
