---
goal: "shipwright doctor should validate dashboard dependencies and port availability

Implementation plan (follow this exactly):
The implementation is already complete. Here's my analysis:

## Implementation Plan — Already Implemented

The feature described in the issue is **already fully implemented** in the current codebase on this branch. Here's what exists:

### Files Already Modified

**`scripts/cct-doctor.sh`** — Section 12 (lines 703-802) contains a complete `DASHBOARD` validation section with:

1. **Bun runtime check** (lines 710-716): Detects if `bun` is installed, shows version, and provides install instructions if missing
2. **Dashboard server.ts location** (lines 719-737): Searches three paths — the repo directory, `~/.local/share/shipwright/dashboard/`, and `~/.shipwright/dashboard/`
3. **Dashboard public assets** (lines 740-765): Validates `index.html`, `app.js`, and `styles.css` exist
4. **Port availability** (lines 767-802): Checks port 8767 (the actual default, not 3000 as the issue originally stated) using `lsof`, `ss`, and `netstat` fallbacks
5. **Dashboard PID file** (lines 769-778): Detects running dashboard or stale PID files

**`scripts/cct-doctor-test.sh`** — A 238-line test suite with 14 tests covering all dashboard doctor checks, wired into `npm test`.

### Acceptance Criteria Status

- [x] `shipwright doctor` shows Bun check with install instructions if missing
- [x] Dashboard file existence verified (server.ts + public assets)
- [x] Port availability checked (with lsof/ss/netstat fallbacks)
- [x] Tests exist and are part of `npm test`

### Note on Port Number

The issue mentions port 3000 but the actual dashboard default port is **8767** (matching `cct-dashboard.sh` line 42 and `server.ts` line 15-17). The implementation correctly uses 8767.

There is no additional work needed — this branch already contains the complete implementation. If there's a specific gap or enhancement you'd like beyond what's implemented, let me know.

Follow the approved design document:


# Design: shipwright doctor should validate dashboard dependencies and port availability

## Context

The `shipwright doctor` command (`scripts/cct-doctor.sh`, ~820 lines) is the diagnostic entry point for validating a Shipwright installation. It runs sequentially numbered check sections (1–12+) covering tmux, Claude CLI, git, GitHub CLI, configuration files, and more. The dashboard subsystem (`scripts/cct-dashboard.sh` + `dashboard/server.ts` + `dashboard/public/`) requires Bun as a runtime, serves on port 8767 by default, and has file assets that must be locatable at runtime. Without a doctor check, users hitting dashboard failures get no actionable guidance.

**Constraints from the codebase:**
- All scripts must be Bash 3.2 compatible — no associative arrays, no `readarray`, no `${var,,}` / `${var^^}`
- Scripts use `set -euo pipefail`, so every `grep` or command that may return non-zero must be guarded (`|| true`, `|| echo "0"`)
- Output uses standardized helpers: `info()`, `success()`, `warn()`, `error()` with Unicode box-drawing headers
- Port detection must work across Linux and macOS, where available tools differ (`lsof`, `ss`, `netstat`)
- The dashboard default port is **8767** (defined in `cct-dashboard.sh` line 42 and `server.ts` lines 15–17), not 3000 as the originating issue stated
- The doctor script tracks pass/warn/fail counts and emits a summary section at the end

## Decision

Add a **Section 12: DASHBOARD** to `scripts/cct-doctor.sh` that validates four concerns in order:

### 1. Bun runtime detection (lines ~710–716)
- Run `command -v bun` to check availability
- On success: display version via `bun --version`, increment pass count
- On failure: warn with install instructions (`curl -fsSL https://bun.sh/install | bash`), increment warn count (not fail — dashboard is optional)

### 2. Dashboard server.ts location (lines ~719–737)
- Search three paths in priority order:
  1. `$SCRIPT_DIR/../dashboard/server.ts` (development / repo checkout)
  2. `~/.local/share/shipwright/dashboard/server.ts` (XDG install)
  3. `~/.shipwright/dashboard/server.ts` (legacy install)
- First match wins; store resolved path for display
- If none found: warn (not fail) with guidance on running `shipwright upgrade --apply`

### 3. Public asset validation (lines ~740–765)
- From the resolved dashboard directory, check existence of `public/index.html`, `public/app.js`, `public/styles.css`
- Each missing file increments warn count with a specific message
- All present: single success message

### 4. Port 8767 availability (lines ~767–802)
- **PID file check first**: read `~/.claude-teams/dashboard.pid`, verify process is alive via `kill -0`; if stale, warn about stale PID file
- **Port probe** using a three-tool fallback chain (covers macOS + Linux minimal containers):
  1. `lsof -i :8767 -sTCP:LISTEN` — preferred, available on macOS and most Linux
  2. `ss -tlnp | grep :8767` — modern Linux fallback
  3. `netstat -tlnp | grep :8767` — legacy Linux fallback
- If port is occupied and no Shipwright dashboard PID matches: warn that another process holds the port, show the process name/PID
- If port is free: success message
- If no tool is available: info-level skip message (not a failure)

**Error handling pattern**: All external commands are wrapped in `if command ... 2>/dev/null; then` blocks to prevent `pipefail` exits. Port-check results are captured into variables before conditional testing to avoid subshell variable loss.

**Data flow**: Each sub-check updates the shared `PASS_COUNT`, `WARN_COUNT`, or `FAIL_COUNT` variables. The existing summary section at script end picks these up automatically.

## Alternatives Considered

1. **Integrate dashboard checks into `cct-dashboard.sh` as a `dashboard doctor` subcommand** — Pros: co-locates dashboard logic; dashboard script already knows its own paths and port. Cons: breaks the single-entry-point UX of `shipwright doctor`; users would need to know to run a separate command; doesn't contribute to the unified pass/warn/fail summary; inconsistent with every other doctor check.

2. **Use `curl` or `nc` to probe port 8767 instead of `lsof`/`ss`/`netstat`** — Pros: simpler single command; `curl -s http://localhost:8767/health` also validates the dashboard is responding correctly, not just that something is listening. Cons: `curl` to localhost can hang or timeout if a non-HTTP process holds the port; `nc` availability varies; doesn't identify the owning process (less actionable); adds latency to doctor runs. The chosen approach gives process-level detail and is instant.

3. **Make dashboard checks a hard failure (fail count) rather than warnings** — Pros: stricter validation. Cons: the dashboard is an optional enhancement — many users run Shipwright without it. Hard failures would make `shipwright doctor` report a broken setup for users who intentionally skip the dashboard. Warnings with install guidance is the right severity.

## Implementation Plan

- **Files to create**: `scripts/cct-doctor-test.sh` (~238 lines) — dedicated test suite with 14 tests covering all dashboard doctor sub-checks using mock binaries and controlled environments
- **Files to modify**: `scripts/cct-doctor.sh` — add Section 12 (DASHBOARD) at approximately lines 703–802; update the section count in the header
- **Dependencies**: None new. Bun is detected, not required. `lsof`/`ss`/`netstat` are system utilities used opportunistically.
- **Risk areas**:
  - **`pipefail` interaction with `grep -c`**: The port-check grep commands must be guarded with `|| true` to prevent script exit on no-match. This is a known pitfall documented in `CLAUDE.md`.
  - **Path resolution on installed vs. dev environments**: The three-path search for `server.ts` must handle symlinks correctly. Use `readlink -f` where available, fall back to the raw path.
  - **macOS vs. Linux `lsof` flags**: macOS `lsof` supports `-i :PORT -sTCP:LISTEN` but the output format differs from Linux. The implementation should parse only the PID column, which is consistent across platforms.
  - **Stale PID file race condition**: Between reading the PID file and running `kill -0`, the process could exit. The `kill -0` is already in an `if` block so this is safe, but the warn message should note the PID may be stale.

## Validation Criteria

- [ ] `shipwright doctor` on a system with Bun installed shows a green pass with the Bun version string
- [ ] `shipwright doctor` on a system without Bun shows a yellow warning with the `curl -fsSL https://bun.sh/install | bash` install command
- [ ] When `dashboard/server.ts` exists in the repo directory, doctor reports it found with the resolved path
- [ ] When no `server.ts` is found in any of the three search paths, doctor warns with upgrade guidance
- [ ] Missing individual public assets (`index.html`, `app.js`, `styles.css`) each produce a distinct warning message
- [ ] When port 8767 is free, doctor reports it as available (green pass)
- [ ] When port 8767 is occupied by a non-Shipwright process, doctor warns with the process name and PID
- [ ] When a stale `dashboard.pid` file exists (process dead), doctor warns about the stale PID
- [ ] All 14 tests in `scripts/cct-doctor-test.sh` pass via `npm test`
- [ ] Doctor runs cleanly under `set -euo pipefail` — no unguarded commands that could exit on non-zero
- [ ] The total pass/warn/fail summary at the end of doctor output correctly includes dashboard check counts
- [ ] Works on both macOS (lsof primary) and Linux (ss/netstat fallback) — the fallback chain is exercised in tests via mock binaries

Historical context (lessons from previous pipelines):
# Shipwright Memory Context
# Injected at: 2026-02-09T23:47:47Z
# Stage: build

## Failure Patterns to Avoid

## Known Fixes

## Code Conventions

Task tracking (check off items as you complete them):
# Pipeline Tasks — shipwright doctor should validate dashboard dependencies and port availability

## Implementation Checklist
- [x] `shipwright doctor` shows Bun check with install instructions if missing
- [x] Dashboard file existence verified (server.ts + public assets)
- [x] Port availability checked (with lsof/ss/netstat fallbacks)
- [x] Tests exist and are part of `npm test`

## Context
- Pipeline: standard
- Branch: docs/shipwright-doctor-should-validate-dashbo-6
- Issue: #6
- Generated: 2026-02-09T23:46:34Z"
iteration: 8
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-02-10T00:45:50Z
last_iteration_at: 2026-02-10T00:45:50Z
consecutive_failures: 0
total_commits: 8
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-02-09T23:53:13Z)
**Implementation verified — all checks pass:**
- `scripts/cct-doctor.sh` Section 12 (lines 702-802): DASHBOARD validation with Bun detection, server.ts location search
- `scripts/cct-doctor-test.sh`: 14 tests covering all dashboard doctor checks — all passing

### Iteration 2 (2026-02-10T00:03:49Z)
- **Gate 1 (tests)**: All 185 tests passing
- **Gate 2 (uncommitted changes)**: Clean working tree
- **Gate 3 (TODO markers)**: 0 markers in diff

### Iteration 3 (2026-02-10T00:09:52Z)
The implementation is complete and verified:
- `scripts/cct-doctor.sh` Section 12 (DASHBOARD) validates Bun runtime, server.ts location, public assets, and port 8767
- `scripts/cct-doctor-test.sh` has 14 dedicated tests all passing

### Iteration 4 (2026-02-10T00:17:40Z)
The implementation is fully complete and already on main:
- `scripts/cct-doctor.sh` Section 12 (DASHBOARD) validates Bun runtime, server.ts location, public assets, and port 8767
- `scripts/cct-doctor-test.sh` has 14 dedicated tests all passing

### Iteration 5 (2026-02-10T00:23:11Z)
All three quality gates pass:
1. **Tests**: All 185 tests pass (14 doctor-specific + 171 others)
2. **Clean working tree**: No uncommitted changes

### Iteration 6 (2026-02-10T00:29:07Z)
The implementation is fully complete:
- `scripts/cct-doctor.sh` Section 12 (DASHBOARD) validates Bun runtime, server.ts location, public assets, and port 8767
- `scripts/cct-doctor-test.sh` has 14 dedicated tests all passing

### Iteration 7 (2026-02-10T00:38:15Z)
The implementation is fully complete:
- `scripts/cct-doctor.sh` Section 12 (DASHBOARD) validates Bun runtime, server.ts location, public assets, and port 8767
- `scripts/cct-doctor-test.sh` has 14 dedicated tests all passing

### Iteration 8 (2026-02-10T00:45:50Z)
The implementation is fully complete:
- `scripts/cct-doctor.sh` Section 12 (DASHBOARD) validates Bun runtime, server.ts location, public assets, and port 8767
- `scripts/cct-doctor-test.sh` has 14 dedicated tests all passing

