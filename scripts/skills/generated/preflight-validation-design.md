## Preflight Validation Gate Design

When adding preflight validation to build harnesses or similar systems, follow these principles:

### 1. Error Classification & Logging
- **Pre-flight failures** (env var missing, test command unresolvable, working tree broken) are **distinct** from mid-loop test failures.
- Log pre-flight failures to a separate channel or with a distinct prefix (e.g., `[PREFLIGHT]`) so they don't pollute build metrics.
- Pre-flight failures must **not** increment `circuit_breaker_threshold` counters; they're setup errors, not code errors.
- Implement this by capturing pre-flight failures in a separate error classification before entering the main loop logic.

### 2. Scope Clarity
Define what belongs in preflight vs. mid-loop validation:
- **Preflight**: Static checks that don't require running code—env var existence, command resolution via `command -v`, basic dependency presence checks, working tree accessibility.
- **Mid-loop**: Dynamic checks that require execution—test output parsing, compilation verification, runtime errors.

### 3. Config Gating
- Gate pre-flight behavior with a config option (e.g., `loop.preflight_enabled`, default `true`).
- Allow disabling without code changes; this is critical for emergency bypasses or unusual environments.
- Store the config in `.claude/daemon-config.json` or equivalent; read it early in the script.

### 4. Error Messages
- **Actionable**: Tell the user exactly what's missing and how to fix it. "TEST_CMD is not set: export TEST_CMD='npm test'" beats "validation failed".
- **Secret-safe**: Never echo env var values in error messages (even if they're not secrets). Use "TEST_CMD" not "TEST_CMD=secret_value".
- **Non-blocking on edge cases**: If a check has a genuine false-positive risk (e.g., unusual directory layouts), make it a warning, not a hard failure, and log it distinctly.

### 5. Performance
- Pre-flight checks must complete in <1 second. Avoid spawning heavy processes or waiting for long operations.
- Use `command -v` to check command existence (instant). Avoid actually running the test command just to validate it.

### 6. Testing Pre-flight Validation
Test cases must cover:
- **Missing env var**: Pre-flight fails with actionable message, does not enter loop.
- **Unresolvable command**: Pre-flight catches missing test command, fails cleanly.
- **Healthy pass-through**: All checks pass, loop proceeds normally.
- **Partial setup** (optional): Some env vars missing, but `preflight_enabled=false` allows bypass (tests this gating).
- **False positive guards** (if applicable): Unusual but valid setups are not rejected.

### 7. Integration with Loop State
- Pre-flight runs **before** any state files are created (e.g., before `progress.md` is written).
- If pre-flight fails, leave the working tree unmodified; a human can retry or debug.
- Log pre-flight results to a distinct field in error logs so CI/dashboards can trend pre-flight vs. runtime failures separately.
