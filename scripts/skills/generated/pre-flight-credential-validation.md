## Pre-Flight Credential Validation

Credential validation that runs at pipeline start must be fast, safe, and actionable. Apply these patterns:

### Design Principles
1. **Fail fast**: Check credentials sequentially and fail on first error; do not attempt to validate all credentials if the first one fails
2. **Zero billable API calls**: Use local CLI checks (Claude CLI auth status) and lightweight GitHub API calls (token scope validation) that fit GitHub's free tier
3. **Timing budget**: Track each check's duration; total should be <2s even on slow networks
4. **Actionable errors**: Every error message must tell the user exactly which credential failed and how to fix it (specific missing scope, token refresh command)

### Implementation Patterns
- **GitHub token scope validation**: Query `GET /user` endpoint and check response headers for scope information; this is a single lightweight API call (counts against GitHub's rate limit but not as a billable operation)
- **Claude CLI auth**: Call `claude --version` and `claude auth status` locally; cache result per session to avoid repeated checks
- **Error message structure**: Format as `Error: <credential_name> validation failed. Problem: <specific issue>. Fix: <actionable step>`
- **Secret redaction**: Never include token values, full token hashes, or partial tokens in any output; use token type descriptors (e.g., "GitHub personal access token" not the token itself)

### Testing Scenarios
- Token missing entirely
- Token expired or revoked
- Token insufficient scope (missing `repo` or `workflow` scope for GitHub)
- Token malformed
- Claude CLI not installed or not authenticated
- Network timeout on validation call (should have sensible fallback)

### Performance Considerations
- Parallelize independent checks (GitHub and Claude CLI can run concurrently)
- Cache validation results in-process to avoid repeated checks if pipeline is restarted
- Set a 5s timeout per check; if check hangs, fail with "credential validation timeout" rather than blocking forever

### Observability
- Log (at debug level) which credential checks ran and their duration
- Surface total validation time in pipeline startup output
- Capture credential validation failures in pipeline state for post-mortem analysis
