## Build Environment Validation Pattern

Pre-build validation catches environment failures (broken dependencies, syntax errors, test-runner startup) before wasting a full loop iteration. The pattern integrates tightly with the build loop's error-feedback system.

### Core Contract

**Inputs:**
- Changed files (from git diff)
- Project type detection (package.json, Cargo.toml, etc.)
- Config flag `loop.pre_build_validate_enabled` (default: true)

**Outputs on failure:**
- `error-summary.json` matching the shape the loop already reads
- Each error entry: `{"line": "...", "message": "..."}`
- Exit code 1 (non-fatal; loop treats it as a failed pre-flight, not a fatal error)

**Outputs on success:**
- Clean exit code 0
- Optional validation log file for observability

### Check Categories

1. **Dependency Install** — Run package manager (npm ci, cargo fetch, pip install --dry-run) with a short timeout (10s). Catches missing deps, lockfile corruption, network issues.

2. **Syntax Check** — Lint only changed files using the project's existing linter (eslint, cargo check, mypy) if available. Skip if no linter configured. Report first 5 errors to avoid overwhelming context.

3. **Test Runner Startup** — Run test command with `--help` or `--list` (or equivalent) to verify the test runner even starts. Catches test config errors without running actual tests.

### Integration Points

- **Error Feedback**: When validation fails, `sw-loop.sh` reads `error-summary.json` and injects it as structured context into the next iteration. Pre-flight failures surface the same way as loop errors.

- **Conditional Execution**: Check `daemon-config.json` for `loop.pre_build_validate_enabled`. Respect the flag; allow skipping for environments where pre-flight is not applicable.

- **No Retry**: Pre-flight failures don't auto-retry the validation itself. The loop's normal retry logic handles re-attempts on the full build.

### Implementation Checklist

- [ ] Read project type from context (already available in loop)
- [ ] Implement `pre_build_validate()` in sw-loop.sh
- [ ] Generate `error-summary.json` on failure with full file path + error message per check
- [ ] Add `pre_build_validate_enabled` config flag (default true)
- [ ] Test with mock projects: working env, missing deps, syntax error, broken test config
- [ ] Document in CLAUDE.md Build Loop section: "Pre-Build Validation" subsection
- [ ] Wire into loop's error injection: `pre_build_validate() || { cat error-summary.json | inject_to_prompt; }`

### Failure Handling

Pre-flight failures are logged but not fatal—the loop enters with the validation error as structured context, giving the agent a chance to fix and retry. If pre-flight fails 3 times in a row, the loop's circuit-breaker trips as normal (treating it like any other error).
