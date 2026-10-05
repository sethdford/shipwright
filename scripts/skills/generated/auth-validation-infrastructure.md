# Auth Validation Infrastructure

## Safe Credential Validation Patterns

### Error Message Design
Never expose secrets or bearer tokens in error output. Instead:
- Reference the *source* of the credential ("GitHub token from GITHUB_TOKEN env var", not the token itself)
- Name the specific scope or permission missing ("Missing 'repo' scope")
- Provide actionable next steps ("Run `gh auth status` to check your token" or "Set CLAUDE_API_KEY environment variable")
- Log full details to a debug file separate from user-facing output

### Lightweight Auth Checks (No Billable Calls)
- **GitHub**: Call `gh auth status` (local CLI check, ~100ms) or inspect token format + cached scope data, not the GitHub API
- **Claude CLI**: Call `claude auth` status check (local, ~50ms)
- Avoid calling GitHub GraphQL or REST API just to validate credentials—those are billable and slow

### Token Scope Validation
For GitHub:
- Parse token's cached scope metadata if available (from `gh auth status --show-token`)
- Cross-reference against required scopes (typically `repo`, `workflow`, `read:org`)
- Clearly communicate which scope(s) are missing, not a generic "insufficient permissions" error

### Sequencing and Fallback
- Run checks sequentially: GitHub first (more likely to fail), Claude CLI second
- If GitHub check fails, stop and report; don't continue to Claude CLI
- If Claude CLI check fails but GitHub passed, warn but allow pipeline start (may fail later in build stage, but provides better diagnostics)
- Cache results locally for <2s subsequent checks (don't re-run auth checks on retries)

### Testing Edge Cases
- **Expired token**: Token format valid, but `gh auth status` returns "token expired"
- **Missing token**: Environment variable not set or empty string
- **Insufficient scope**: Token valid but lacks required permissions (e.g., no `repo` scope)
- **Malformed token**: Invalid format that CLI rejects immediately
- **Network failure during check**: Timeouts or DNS errors—decide: fail hard or warn?
- **Partial failure**: GitHub token valid but Claude CLI not installed or unconfigured

### Performance Optimization
- Measure auth check time; target <1s total (leaves 1s buffer in the <2s overhead constraint)
- Batch checks where possible (both checks can run in parallel if needed)
- Cache results in memory for the duration of pipeline startup
- Log timing: which check took how long, to catch regressions

### Integration into Pipeline Startup
Auth validation should run:
1. Before `intake` stage (fail early, not after several stages)
2. *After* CLI argument parsing (know which credentials are needed)
3. *Before* any GitHub API calls or Claude CLI invocations
4. Output clear status: "✓ GitHub auth valid (scopes: repo, workflow)" or "✗ GitHub token missing"
