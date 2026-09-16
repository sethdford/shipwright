## Synthetic Test Quarantine & Safe Lifecycle

Automated E2E tests file issues indistinguishable from real work, creating three problems: (1) resource waste—synthetic tests consume MAX_PARALLEL daemon slots, delaying real issues; (2) metrics noise—test runs inflate DORA metrics (deploy frequency, CFR, MTTR), obscuring signal; (3) false signals—incorrect pattern matching could quarantine real bugs.

### Pattern Matching (High Confidence)

Identify synthetic issues using AND logic (require 3+ signals to reduce false positives):
- **Title**: `^[Ee]2[Ee] [Tt]est`, `test:`, `automated test`, or similar keywords
- **Body**: `\[automated\]`, `synthetic`, or explicit "E2E test" markers
- **Labels**: `e2e-test`, `automated`, `synthetic`
- **Author**: bot accounts (`shipwright[bot]`, GitHub Actions runner accounts)

### Queue Lane Isolation

Maintain two-tier processing:
- **Primary lane** (`.queued`): Real issues—processed first, always have capacity
- **Synthetic lane** (`.synthetic_queue`): Test noise—drained only after primary is empty

Enforce: synthetic jobs NEVER starve real work. If budget exhausted, skip synthetic entirely.

### Metrics-Safe Execution

- Run with `--local-mode` or `--no-github` to prevent real PR/deployment creation
- Tag all artifacts (logs, state, events) with `synthetic: true` for post-hoc filtering
- Exclude from DORA dashboards: `shipwright dora --exclude-synthetic` removes all runs where issue was ever quarantined
- Track synthetic test harness reliability separately (test infrastructure health, not product health)

### Safe Auto-Close Protocol

Only auto-close if ALL conditions met:
1. Test execution exited cleanly (exit 0)
2. No unintended side effects: no stale branches, no orphaned PRs, no uncommitted state
3. Pattern matched with high confidence (3+ signals)
4. Grace period elapsed (allow manual override window)
5. Log close reason: `"closed: synthetic test completed, no side effects detected"`

### Monitoring & Observability

Emit events: `daemon.issue_quarantined`, `daemon.synthetic_dequeued`, `daemon.synthetic_completed`. Track metrics: synthetic test execution rate, success rate, average runtime. Alerts on anomalies (test suddenly timing out = real issue).
