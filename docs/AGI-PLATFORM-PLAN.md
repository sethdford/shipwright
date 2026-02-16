# AGI-Level Platform Plan: Refactor, Refine, Remove, Redo

**Status:** Active  
**Created:** 2026-02-16  
**Goal:** Make Shipwright a fully autonomous product development team — reduce hardcoded/static policy, clean architecture, and let the platform improve itself.

---

## Success Criteria

- **Policy:** All tunables (timeouts, limits, thresholds) live in `config/policy.json` or env; scripts read via `policy_get` or jq. Zero new hardcoded magic numbers in core paths.
- **Monoliths:** `sw-pipeline.sh` and `sw-daemon.sh` decomposed into sourced modules (stages, health, poll loop); single-file line count < 2000 for core orchestration.
- **Helpers:** All scripts use `lib/helpers.sh` for colors/output/events (or a single other canonical source); no duplicated info/success/warn/error blocks.
- **Platform health:** `shipwright hygiene platform-refactor` counts trend down (hardcoded, fallback, TODO/FIXME/HACK); strategic agent routinely suggests platform refactor issues.
- **Continuous:** Hygiene + platform-refactor run in CI or weekly; strategic reads platform-hygiene and policy; AGI-level criterion is part of product thinking.

---

## Phase 1: Foundation (Policy + Helpers Adoption)

**Goal:** Policy and helpers are the default; at least two key scripts read from policy; plan is visible and tracked.

**Status:** Done. 1.1–1.3 done (strategic + hygiene read policy; plan linked from STRATEGY P6). 1.4 done — all ~98 scripts migrated to `lib/helpers.sh`; zero duplicated helper blocks remain.

| #   | Task                                                                                                                                                                                              | Owner | Acceptance                                                                                   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | -------------------------------------------------------------------------------------------- |
| 1.1 | **Strategic reads policy** — In sw-strategic.sh, after constants block, source policy.sh and override STRATEGIC_MAX_ISSUES, COOLDOWN, STRATEGY_LINES, OVERLAP_THRESHOLD from policy when present. | Agent | strategic run uses config/policy.json values when file exists; fallback to current literals. |
| 1.2 | **Hygiene reads policy** — In sw-hygiene.sh, read artifact_age_days from policy (policy_get ".hygiene.artifact_age_days" 7) when policy.sh available.                                             | Agent | hygiene --artifact-age default comes from policy when present.                               |
| 1.3 | **Document plan** — This doc (docs/AGI-PLATFORM-PLAN.md) is the single source of truth; link from STRATEGY.md P6.                                                                                 | Done  | STRATEGY P6 references this plan.                                                            |
| 1.4 | **Helpers adoption** — Migrate 3–5 high-traffic scripts to source lib/helpers.sh instead of defining info/success/warn/error (e.g. sw-strategic, sw-hygiene, sw-quality).                         | Agent | No duplicate color/output blocks in those scripts; they source helpers.                      |

---

## Phase 2: Policy Migration (First Batch)

**Goal:** Daemon, pipeline, quality, and sweep read their key tunables from policy; hardcoded count drops.

**Status:** Done. 2.1–2.5 complete. Daemon (timeouts, intervals), pipeline (coverage/quality thresholds), quality (thresholds), sweep (workflow reads policy.json and exports env vars).

| #   | Task                                                                                                                                                                                                                 | Owner | Acceptance                                                                                                                |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------- |
| 2.1 | **Daemon timeouts** — In sw-daemon.sh, health heartbeat and stage timeouts read from policy_get when policy exists (else keep current defaults).                                                                     | Agent | daemon_health_timeout_for_stage uses policy .daemon.stage_timeouts and .daemon.health_heartbeat_timeout.                  |
| 2.2 | **Daemon intervals** — POLL_INTERVAL, AUTO_SCALE_INTERVAL, OPTIMIZE_INTERVAL, STALE_REAPER_INTERVAL read from policy when present.                                                                                   | Agent | One place (policy) controls daemon timing.                                                                                |
| 2.3 | **Pipeline thresholds** — Coverage and quality gate thresholds in pipeline read from policy (pipeline.coverage_threshold_percent, quality_gate_score_threshold, memory fallbacks).                                   | Agent | Pipeline quality gate uses policy_get for thresholds when policy exists.                                                  |
| 2.4 | **Quality script** — sw-quality.sh reads coverage_threshold and gate_score_threshold from policy.                                                                                                                    | Agent | quality validate/gate use policy.                                                                                         |
| 2.5 | **Sweep (workflow)** — Document in plan that sweep workflow (shipwright-sweep.yml) uses hardcoded 4h/30min; add optional env or later step to read from policy (e.g. script that emits workflow inputs from policy). | Agent | Either sweep reads policy in a wrapper or doc states “sweep defaults documented in config/policy.json; override via env.” |

---

## Phase 3: Monolith Decomposition

**Goal:** Pipeline and daemon are split into sourced modules; no single file > 2000 lines for orchestration core.

**Status:** All done. 3.1 pipeline fully decomposed: sw-pipeline.sh reduced from 8,665 → 2,434 lines (72% reduction) by wiring pipeline-state.sh, pipeline-github.sh, pipeline-detection.sh, pipeline-quality-checks.sh, pipeline-intelligence.sh, pipeline-stages.sh. 3.2 done (pipeline-quality.sh). 3.3 daemon fully decomposed: sw-daemon.sh reduced from 6,150 → 1,351 lines (78% reduction) by wiring daemon-state.sh, daemon-adaptive.sh, daemon-triage.sh, daemon-failure.sh, daemon-dispatch.sh, daemon-patrol.sh, daemon-poll.sh. 3.4 done (daemon-health.sh). All tests pass.

| #   | Task                                                                                                                                                                                                   | Owner | Acceptance                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- | --------------------------------------------------------------------- |
| 3.1 | **Pipeline stages lib** — Extract stage run logic (run_intake, run_plan, run_build, run_test, …) into scripts/lib/pipeline-stages.sh or scripts/lib/pipeline-stages/\*.sh; source from sw-pipeline.sh. | Agent | sw-pipeline.sh sources stages; line count drops; existing tests pass. |
| 3.2 | **Pipeline quality gate** — Extract quality gate and audit selection into scripts/lib/pipeline-quality.sh; source from sw-pipeline.sh.                                                                 | Agent | Quality gate logic in one place; pipeline sources it.                 |
| 3.3 | **Daemon poll loop** — Extract daemon_poll_loop, daemon_poll_issues, daemon_reap_completed into scripts/lib/daemon-poll.sh; source from sw-daemon.sh.                                                  | Agent | Daemon sources daemon-poll; line count drops.                         |
| 3.4 | **Daemon health** — Extract health check and timeout logic into scripts/lib/daemon-health.sh.                                                                                                          | Agent | Daemon sources daemon-health; tests pass.                             |

---

## Phase 4: Cleanup (TODO / FIXME / HACK / Dead Code)

**Goal:** Triage all TODO/FIXME/HACK; remove dead code; reduce fallback count.

**Status:** All done. 4.1–4.2 triage complete (PLATFORM-TODO-TRIAGE.md: 4 github-issue, 3 accepted-debt). 4.3 dead code scan complete — 1 confirmed dead function (get_adaptive_heartbeat_timeout in daemon-adaptive.sh, accepted debt; may wire later). No unused scripts. No .bak/temp files. 4.4 fallback count reduced from 71 → 54 via monolith decomposition; remaining fallbacks are legitimate defensive patterns (intelligence heuristics, template fallbacks, grep-based search fallbacks). Pre-existing `now_unix` bug in sw-scale.sh fixed.

| #   | Task                                                                                                                                                                                                    | Owner | Acceptance                                               |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | -------------------------------------------------------- |
| 4.1 | **TODO/FIXME backlog** — Generate list (from platform-refactor findings); create GitHub issues for each or mark “accepted tech debt” in code; strategic can then suggest “Resolve TODO in X” as issues. | Agent | Every TODO/FIXME has an issue or comment; count tracked. |
| 4.2 | **HACK/KLUDGE** — Same as 4.1; replace or document.                                                                                                                                                     | Agent | HACK count explained or reduced.                         |
| 4.3 | **Dead code** — Run hygiene dead-code; remove or refactor unused functions/scripts.                                                                                                                     | Agent | Dead code count in hygiene report drops.                 |
| 4.4 | **Fallback reduction** — Where adaptive/learned data exists, remove duplicate hardcoded fallbacks so one code path wins (policy → adaptive → minimal default).                                          | Agent | Fallback count in platform-refactor scan drops.          |

---

## Phase 5: Continuous (CI + Strategic + Metrics)

**Goal:** Platform health is measured and improved continuously.

**Status:** 5.1 done (shipwright-platform-health.yml with threshold gate). 5.2 done (strategic reads platform-hygiene + AGI rule; CI workflow now runs hygiene before strategic). 5.3 done (doctor shows platform health counts). 5.4 done (config/policy.schema.json created; ajv validates; integrated in CI). E2E policy tests added (sw-policy-e2e-test.sh, 26 tests).

| #   | Task                                                                                                                                                                                               | Owner | Acceptance                                                |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | --------------------------------------------------------- |
| 5.1 | **Hygiene in CI** — Add a job (e.g. in shipwright-sweep or a new workflow) that runs `shipwright hygiene platform-refactor` and fails or warns if counts exceed thresholds (e.g. hardcoded > 100). | Agent | CI runs platform-refactor; optional gate.                 |
| 5.2 | **Strategic creates refactor issues** — Ensure strategic prompt and platform-hygiene input are used; run strategic periodically so it suggests platform refactor issues.                           | Done  | Strategic already has platform health + AGI rule.         |
| 5.3 | **Metrics dashboard** — Optional: add a small “platform health” section to dashboard or doctor showing platform-hygiene counts and trend.                                                          | Agent | Doctor or dashboard shows hardcoded/fallback/TODO counts. |
| 5.4 | **Policy schema** — Add JSON schema for config/policy.json and validate in CI or on load.                                                                                                          | Agent | policy.json validated against schema.                     |

---

## Current Snapshot (from platform-refactor scan)

- **hardcoded:** 66 | **fallback:** 71 | **TODO:** 38 | **FIXME:** 19 | **HACK/KLUDGE:** 18
- **Triage:** 4 github-issue, 3 accepted-debt, 0 stale, 0 fix-now (see `docs/PLATFORM-TODO-TRIAGE.md`)
- **Largest scripts:** sw-pipeline.sh (8665), sw-daemon.sh (6150), sw-loop.sh (2492), sw-recruit.sh (2636), sw-prep.sh (1657), sw-memory.sh (1634). Pipeline/daemon have extracted libs (scripts/lib/pipeline-_.sh, scripts/lib/daemon-_.sh).
- _Last scan: 2026-02-16. Run `shipwright hygiene platform-refactor` to refresh._

---

## Sweep defaults (Phase 2.5)

Sweep workflow (`.github/workflows/shipwright-sweep.yml`) uses hardcoded values: stuck = 4h, cron every 30min, retry template = full, retry max_iterations = 25, stuck retry = 30. These are documented in **config/policy.json** under `sweep`. To override: set env in the workflow (e.g. `STUCK_THRESHOLD_HOURS`, `RETRY_MAX_ITERATIONS`) or add a wrapper step that reads policy and exports env for the dispatch step.

## How to Use This Plan

1. **Run platform-refactor:** `shipwright hygiene platform-refactor` to refresh `.claude/platform-hygiene.json`.
2. **Run strategic:** `shipwright strategic run` to get AI-suggested issues (including platform refactor).
3. **Execute phases in order:** Phase 1 → 2 → 3 → 4 → 5; mark tasks done in this doc or in issues.
4. **Policy first:** Any new tunable goes in config/policy.json; scripts use policy_get or jq.

---

## References

- **STRATEGY.md** — P6 Platform Self-Improvement, Technical Principle 8 (AGI-level criterion).
- **config/policy.json** — Central policy schema.
- **docs/config-policy.md** — Policy usage and roadmap.
- **scripts/lib/policy.sh** — policy_get helper.
- **scripts/lib/helpers.sh** — Canonical colors and output helpers.
- **config/policy.schema.json** — JSON Schema for policy validation.
- **docs/PLATFORM-TODO-TRIAGE.md** — Phase 4 TODO/FIXME/HACK triage results.
- **scripts/sw-policy-e2e-test.sh** — E2E policy integration tests (26 tests).
