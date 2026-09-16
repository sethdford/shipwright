## Daemon Queue Lane Implementation

The daemon now maintains separate queue lanes (`.queued` for real issues, `.synthetic_queue` for test noise) with priority enforcement: real issues must fully drain before any synthetic issue is dequeued.

### Key Guarantees

1. **No starvation**: Synthetic queue only drains when real queue is empty (enforced at dequeue time)
2. **Atomic state transitions**: Pattern matching → queue lane assignment happens before state write (no orphaned issues)
3. **Safe migration**: Existing daemon-config.json without `triage.synthetic_patterns` works (patterns default to empty list, no quarantine)
4. **Rollback safety**: Toggling `triage.synthetic_patterns` on/off doesn't lose issues or break queue ordering

### Implementation Pattern

```bash
# In daemon_quarantine_if_synthetic():
# 1. Load patterns from daemon-config.json → triage.synthetic_patterns
# 2. Test issue against all patterns (AND within pattern, OR across patterns)
# 3. If matched: enqueue_issue "$key" synthetic  # writes to .synthetic_queue
# 4. If not matched: proceed to normal triage

# In dequeue_next():
# 1. Drain .queued completely
# 2. Only then: if (.queued is empty) && (.synthetic_queue has items): dequeue one synthetic
# 3. Emit event: daemon.synthetic_dequeued
```

### Testing Checklist

- [ ] Pattern matching: current `[automated]` pattern correctly identifies E2E test issues
- [ ] Negative case: real issue with "automated" in body/title is NOT matched
- [ ] Queue isolation: synthetic issue enqueued to `.synthetic_queue`, not `.queued`
- [ ] Priority enforcement: when both queues have items, real issues dequeue first
- [ ] Queue drain: after real queue empties, synthetic issues begin dequeueing
- [ ] Safe no-op: with empty `triage.synthetic_patterns`, all issues flow through normal triage
- [ ] Config validation: malformed regex in pattern list fails with clear error, doesn't crash daemon
- [ ] Events: emit `daemon.issue_quarantined` at match time, `daemon.synthetic_dequeued` at dequeue time

### DORA Reporting Integration

When `DORA_EXCLUDE_SYNTHETIC=1` or `--exclude-synthetic` flag:
- Filter runs where issue was ever in `.synthetic_queue`
- Exclude from: deploy frequency, change failure rate, lead time calculations
- Include in: MTTR only if synthetic issue caused real incident (edge case, default exclude)

### Failure Modes to Guard Against

1. **Pattern regex DoS**: A complex pattern could hang daemon at poll time → bound regex complexity, use timeout
2. **Orphaned issues**: Pattern match succeeds but queue write fails → atomic operation (match + write in transaction)
3. **False quarantine**: Real issue incorrectly matched → test negative cases thoroughly, use multi-signal patterns (title AND label, not title alone)
4. **Queue reordering**: Synthetic issue somehow jumps ahead of real issue → verify dequeue order in queue state snapshots
