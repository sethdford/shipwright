# Cost-Aware Feature Downgrade Logic

When a system must gracefully constrain behavior due to budget or resource limits, implement feature downgrade in three layers:

## 1. Precedence is Absolute
Explicit user input (e.g., `--template full`) ALWAYS wins over automatic downgrade. Budget-aware logic is a fallback, not a constraint on explicit requests. Implement as a guard at the entry point:

```
if (explicit_template_flag) {
  use explicit_template
  return
}
// Only then check budget
selected_template = budget_aware_select()
```

Invariant: No code path should override an explicit flag.

## 2. Downgrade Tiers and Thresholds
Define clear tier mappings (e.g., `full` → `standard` → `fast`) and threshold percentages in config:

```json
{
  "cost": {
    "budget_threshold_percent": 20,
    "downgrade_tiers": {
      "full": "standard",
      "standard": "fast",
      "fast": "fast"
    }
  }
}
```

Threshold represents: "if remaining_budget / daily_budget < threshold, downgrade." Test exact boundary (at 20%, just below, just above).

## 3. Event Auditing
Every downgrade decision must emit a structured event with:
- Original template (what was requested or would have been selected)
- Selected template (after budget logic)
- Reason (explicit override, budget downgrade, normal selection)
- Remaining budget and threshold at decision time

Example event:
```json
{
  "type": "template_selected",
  "requested_template": "full",
  "selected_template": "standard",
  "reason": "budget_downgrade",
  "remaining_budget_usd": 4.50,
  "daily_budget_usd": 25.00,
  "threshold_percent": 20,
  "timestamp": "2026-09-27T20:30:00Z"
}
```

## 4. Edge Case Handling
- **Cost tracking unavailable**: Log a warning and proceed with default template (do not hard-fail the pipeline). Document as a known degradation.
- **Negative or zero budget**: Downgrade to cheapest tier (typically `fast` or `hotfix`).
- **Threshold zero or negative**: Disable budget-aware logic (treat as explicit `--no-budget-check`).

## 5. Testing Pattern
Test matrix:
1. Explicit flag always wins: `--template full` with 5% remaining → uses `full` (not downgraded)
2. Low budget triggers downgrade: No flag, 15% remaining (below 20% threshold) → uses downgraded tier
3. High budget is a no-op: No flag, 50% remaining → uses normal/requested tier
4. Boundary at exact threshold: 20% remaining (exactly at threshold) → test both sides
5. Cost tracking failure: Mock cost show returning error → logs warning, proceeds with default
