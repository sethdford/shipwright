## Cost Data Dashboard Integration

### Problem
Cost data lives in sw-cost.sh (CLI tool writing to ~/.shipwright/costs.json) but operators need visibility in the web dashboard. Safe integration requires:
1. Data freshness guarantees (timestamps, staleness detection)
2. Calculation correctness (cost-per-successful-pipeline must match CLI output)
3. Graceful degradation when cost data is unavailable
4. Schema evolution (if costs.json format changes)

### Approach

**Data Loading**
- Read costs.json and check timestamp; if >1 hour old, mark as stale
- Emit staleness warning in API response (`costDataAge`, `isStale` fields)
- If file missing/unreadable, return 202 (success) with empty data; don't error—let widget render gracefully

**Calculation Verification**
- Replicate cost-per-successful-pipeline calculation in dashboard/server.ts
- Add a comment linking to sw-cost.sh line number where the same calc happens
- Unit-test calculation against fixed sw-cost.sh outputs to catch drift

**API Contract**
```typescript
GET /api/cost-trend?days=30
{
  "costPerPipeline": [{ "date": "2026-09-28", "value": 4.23 }],
  "costDataTimestamp": "2026-09-28T08:00:00Z",
  "costDataAgeSecs": 3600,
  "isStale": false,
  "dailyBudget": 100,
  "budgetRemaining": 23.45,
  "budgetWarning": null
}
```

**Staleness Handling**
- Frontend checks `isStale` and shows muted/grayed widget + timestamp
- If cost data >24h old, show warning: "Cost data not refreshed; pipeline costs may have changed"
- Widget still renders (don't break the dashboard), but clearly signals data is stale

**Testing**
- Mock costs.json with known values; verify endpoint calc matches
- Test staleness detection: create file, wait, check timestamp
- Test schema evolution: if cost.json ever changes, endpoint returns 202 + unchanged frontend behavior
- E2E: trigger a real pipeline run, wait for sw-cost.sh update, verify dashboard reflects new cost
