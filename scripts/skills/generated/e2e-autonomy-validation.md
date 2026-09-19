## E2E Autonomy Validation

When testing autonomous agent systems (like Shipwright), E2E tests must validate not just that code executes, but that agents made real decisions and performed autonomous actions.

### Core Validation Points

**Proof of Autonomy**
- Assert the agent spawned (check heartbeat, process state, or log markers)
- Verify the agent made a decision (log entry with reasoning, not just execution)
- Confirm the action was self-driven, not scripted (e.g., agent chose to retry vs. always retrying)

**State Consistency Across Boundaries**
- Validate persistent state before, during, and after agent execution
- For multi-agent scenarios, ensure agents don't interfere (use worktree isolation per agent)
- Verify side effects are transactional (all-or-nothing, not partial)

**Real Behavior Under Constraints**
- Test with realistic cost/token budgets (not unlimited)
- Simulate rate limits and API failures the agent must handle
- Validate the agent converges (doesn't loop forever or give up too early)

**Isolation & Cleanup**
- Each test must leave zero artifacts (no temp files, no dangling processes, no state leaks)
- Use git worktrees or sandboxes to isolate agent operations
- Verify cleanup happens even if the agent fails mid-execution

### Anti-Patterns to Avoid
- Asserting the test passed without checking agent logs (false positive)
- Assuming synchronous execution—agents are asynchronous; use polling with timeouts
- Hardcoding expected output instead of validating agent-generated output
- Running tests serially because you assume they conflict; use proper isolation instead

### Checklist
- [ ] Test asserts agent was spawned and ran
- [ ] State before/after is verified, not just final result
- [ ] Test is idempotent (can run twice with same result)
- [ ] Timeout is realistic but prevents hang (not instant, not 10min)
- [ ] Cleanup removes all artifacts, even on failure
