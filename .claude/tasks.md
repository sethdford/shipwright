# Tasks — Surface cost-per-successful-pipeline trend and budget headroom in dashboard

## Status: In Progress
Pipeline: standard | Branch: feat/surface-cost-per-successful-pipeline-tre-7099

## Checklist
- [ ] T1: `readEventsByType()` helper in server.ts
- [ ] T2: `computeCostTrend()` aggregation, including the outcomes-file fallback and budget headroom (blocked by T1)
- [ ] T3: `/api/cost-trend` route with validation, 30 s cache and error handling (blocked by T2)
- [ ] T4: `CostTrendResponse` types and `fetchCostEfficiencyTrend` client (independent; blocks T6)
- [ ] T5: `renderTargetSparkline` chart helper, with gaps and target line (independent; blocks T6)
- [ ] T6: `renderCostEfficiency()` view with loading, empty, error and unlimited-budget states (blocked by T4 and T5)
- [ ] T7: index.html container and styles.css (blocks the visual check of T6)
- [ ] T8: vitest for the sparkline helper (blocked by T5)
- [ ] T9: vitest for the metrics view and API client (blocked by T4 and T6)
- [ ] T10: server API tests: seed events and budget, then check 200, schema, arithmetic, 400s and the empty state (blocked by T3)
- [ ] T11: run the full dashboard vitest, the server API suite, the dashboard e2e suite and tsc
- [ ] `GET /api/cost-trend` returns the schema above; 400 for invalid `days`; 200 with an empty state when there's no data.
- [ ] The Metrics view shows the sparkline with a dashed line at $5, the headline cost per success with its trend, and budget headroom (remaining / daily budget, estimated pipelines left).
- [ ] Loading, empty, error, unlimited-budget and over-budget states all render with readable text; the SVG has an `aria-label`.
- [ ] `sw-server-api-test.sh` includes the new tests (happy path, validation, null-day, event-cap regression) and passes.
- [ ] The dashboard vitest suite passes with the new sparkline, view and API tests; `tsc --noEmit` is clean.
- [ ] `sw-dashboard-e2e-test.sh` still passes.
- [ ] No bash scripts are changed; no existing endpoint's response shape changes.

## Notes
- Generated from pipeline plan at 2026-09-28T08:22:57Z
- Pipeline will update status as tasks complete
