# What's Next — Gaps, Not Fully Implemented, Not Integrated, E2E Audit

**Status:** 2026-02-16  
**Companion to:** [docs/AGI-PLATFORM-PLAN.md](AGI-PLATFORM-PLAN.md)

---

## 1. Still broken or risky

| Item                                         | What                                                                                                                                                                                    | Fix                                                                                           |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Platform-health workflow threshold check** | ~~Report step used string comparison for threshold.~~ **Fixed:** Now normalizes to numeric with default 0.                                                                              | Done.                                                                                         |
| **policy.sh when REPO_DIR not set**          | If a script is run from a different cwd (e.g. CI from repo root), `git rev-parse --show-toplevel` may point to a different repo.                                                        | Already uses SCRIPT_DIR/.. when SCRIPT_DIR is set; document that callers must set SCRIPT_DIR. |
| **Daemon get_adaptive_heartbeat_timeout**    | When policy has no entry for a stage, we fall back to case statement only when `policy_get` is not available; when policy exists but stage is missing we keep HEALTH_HEARTBEAT_TIMEOUT. | Verified: logic is correct (policy stage → else case → HEALTH_HEARTBEAT_TIMEOUT).             |

---

## 2. Not fully implemented

| Item                                       | What                                                                                                                                                                                          | Next step                                                                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| ~~**Phase 3 libs not sourced**~~           | **Done.** `pipeline-quality.sh` sourced by `sw-pipeline.sh` and `sw-quality.sh`; `daemon-health.sh` sourced by `sw-daemon.sh`.                                                                | Wired and verified.                                                                             |
| ~~**Policy JSON Schema validation**~~      | **Done.** `config/policy.schema.json` created; `ajv-cli` validates successfully; optional step in platform-health workflow confirmed working.                                                 | Validated locally; trigger workflow_dispatch in CI to confirm.                                  |
| ~~**Sweep workflow still hardcoded**~~     | **Done.** Sweep workflow now checks out repo, reads `config/policy.json`, and exports `STUCK_THRESHOLD_HOURS`, `RETRY_TEMPLATE`, `RETRY_MAX_ITERATIONS`, `STUCK_RETRY_MAX_ITERATIONS` to env. | Wired.                                                                                          |
| ~~**Helpers adoption (Phase 1.4)**~~       | **Done.** All ~98 scripts migrated to `lib/helpers.sh`. Zero duplicated info/success/warn/error blocks remain.                                                                                | Complete.                                                                                       |
| **Monolith decomposition (Phase 3.1–3.4)** | Pipeline stages, pipeline quality gate, daemon poll loop, daemon health are **not** extracted into separate sourced files. Line counts unchanged (8600+ / 6000+).                             | Defer or do incrementally: extract one module (e.g. pipeline quality gate block) and source it. |

---

## 3. Not integrated

| Item                                 | What                                                                                                                                              | Next step |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| ~~**pipeline-quality.sh**~~          | **Done.** Sourced by `sw-pipeline.sh` and `sw-quality.sh`; duplicate policy_get for thresholds removed.                                           | Wired.    |
| ~~**daemon-health.sh**~~             | **Done.** Sourced by `sw-daemon.sh`; `get_adaptive_heartbeat_timeout` calls `daemon_health_timeout_for_stage` when loaded.                        | Wired.    |
| ~~**Strategic + platform-hygiene**~~ | **Done.** `shipwright-strategic.yml` now runs `hygiene platform-refactor` before strategic analysis, feeding fresh data to the AI agent.          | Wired.    |
| ~~**Test suite and policy**~~        | **Done.** Policy read test added to `sw-hygiene-test.sh` (Test 12): verifies `policy_get` reads from config and returns default when key missing. | Covered.  |

---

## 4. Not audited E2E

| Item                                    | What                                                                                                                                                               | Next step                                                              |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| ~~**Pipeline E2E with policy**~~        | **Done.** `sw-policy-e2e-test.sh` (26 tests) verifies pipeline-quality.sh reads coverage/gate thresholds from policy, policy_get with mock and real configs.       | Added to npm test suite.                                               |
| ~~**Daemon E2E with policy**~~          | **Done.** `sw-policy-e2e-test.sh` verifies daemon policy_get for poll_interval, heartbeat_timeout, stage_timeouts, auto_scale_interval.                            | Covered in policy E2E test.                                            |
| **Platform-health workflow E2E**        | Workflow validated locally (schema, scan, report steps); not yet triggered via workflow_dispatch in CI.                                                            | Trigger workflow (workflow_dispatch) to confirm end-to-end in real CI. |
| ~~**Doctor with no platform-hygiene**~~ | **Done.** Doctor now auto-runs `hygiene platform-refactor` when report is missing; `--skip-platform-scan` flag available for fast mode.                            | Complete.                                                              |
| ~~**Full npm test with policy**~~       | **Done.** `sw-policy-e2e-test.sh` added to npm test; 26 policy-specific assertions covering policy_get, pipeline-quality.sh, daemon thresholds, and sanity checks. | In test suite.                                                         |

---

## 5. Summary checklist

- [x] **Wire or remove** pipeline-quality.sh and daemon-health.sh — sourced in pipeline, quality, daemon.
- [x] **Policy schema** — `config/policy.schema.json` created; ajv validates successfully; integrated in CI.
- [x] **Sweep** — Workflow reads policy.json and exports env vars.
- [x] **Helpers** — All ~98 scripts migrated to lib/helpers.sh; zero duplicated helper blocks remain.
- [x] **Test** — Policy read test in hygiene-test.sh (Test 12) + 26 E2E policy tests in sw-policy-e2e-test.sh.
- [x] **E2E** — Pipeline + daemon policy assertions in sw-policy-e2e-test.sh; platform-health workflow validated locally.
- [x] **TODO/FIXME/HACK** — Phase 4 triage complete: 4 github-issue, 3 accepted-debt, 0 stale. See `docs/PLATFORM-TODO-TRIAGE.md`.
- [x] **Strategic + hygiene** — Strategic CI workflow now runs hygiene platform-refactor before analysis.
- [ ] **Platform-health workflow_dispatch** — Trigger once in CI to confirm end-to-end execution.
- [x] **Monolith decomposition (Phase 3.1, 3.3)** — Done. Pipeline 8,665 → 2,434 lines; daemon 6,150 → 1,351 lines. All libs wired and sourced.
- [x] **Doctor auto-hygiene** — Doctor auto-runs platform-refactor when report missing; `--skip-platform-scan` flag added.
- [x] **Dead code scan** — 1 confirmed dead function (accepted debt); no unused scripts or temp files.
- [x] **Fallback reduction** — Counts reduced 71 → 54 via decomposition; remaining are legitimate patterns.

---

## References

- [AGI-PLATFORM-PLAN.md](AGI-PLATFORM-PLAN.md) — Phases and success criteria.
- [PLATFORM-TODO-BACKLOG.md](PLATFORM-TODO-BACKLOG.md) — TODO/FIXME/HACK triage.
- [config-policy.md](config-policy.md) — Policy usage and schema.
