# Wave 2 — Closed-Loop Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **This document is a plan only.** Nothing here is implemented yet, and the approval items in "Decisions needing the maintainer" must be resolved before Phase A starts.

**Goal:** Make Shipwright's delivery loop measure its own outcomes and change its behaviour only when a measured change beats the incumbent. Concretely: (A) a run ledger that every mode can share; (B) a failure classifier that reads the actual error and stops repeated or non-retryable failures; (C) progress signals and a stall detector that replace timer heartbeats as liveness; (D) a difficulty estimate, a single routing table with current Claude 5 model IDs, and cost capture; (E) a replayable eval set with a behavioural ratchet; (F) an independent verifier on by default; (G) retirement of the legacy intelligence that the evals do not justify.

**Architecture:** Pure policies in `src/contexts/*/domain` (no I/O; F1), use cases in `application/` over ports, adapters in `src/adapters` (F5). Run state goes through the durability ports (ADR-0005). Every adaptive decision is written to the ledger with its inputs and policy version, so it can be replayed. Adaptation can lower risk, never raise a retry cap, a budget or a breaker threshold (ADR-0007).

**Tech Stack:** Bun 1.2.19, TypeScript (strict, `noUncheckedIndexedAccess`), zod 4 (adapters only), Biome 2, dependency-cruiser, `@ast-grep/cli`, `gh`, bash 3.2 for the parts that remain bash.

**Spec:** `docs/superpowers/specs/2026-10-13-shipwright-ts-migration-design.md` §2, §3.1, §3.3, §5, §6.1, §6.2, §6.3, §7.4, §7.5, §8, §9 · ADR-0005, ADR-0007, ADR-0008 · the Wave 1a plans in `docs/superpowers/plans/`.

**Dependencies on work that is not yet on `main`:**
- Wave 1b: the SQLite durability adapter (`adapters/durability/sqlite`), `RunJournal` and the `decide()` interpreter. `src/adapters/durability/` does not exist yet. Phase A's M1 path depends on it.
- Spec §6.3 evaluator (Wave 1). Phase F is the default-on use of that evaluator, so it reuses that component rather than building a second one.
- Wave 2 Postgres adapter. Without it, M2 and M3 cannot share the ledger through `RunJournal`. This plan does not deliver M2/M3 sharing; see "Modes" below.
- ADR-0006 (credentials, Wave 1c). Not required by this plan, but the verifier in Phase F runs with the same credential rules.

**Not in this plan:** training any model, reinforcement learning, bandits in production, cross-repository transfer, automatic merging, a new workflow engine, porting `sw-loop.sh` in full (the full port is the delivery context's job and is a separate plan).

---

## Decisions needing the maintainer

This plan conflicts with the approved spec in three places. These must be decided first; the phases below assume the recommended option.

| # | Conflict | Spec text | Recommendation (assumed below) |
|---|---|---|---|
| D1 | Closed-loop learning is on the don't-port list | §7.5 retires `intelligence`, `self-optimize`, `adaptive`, `rl / bandit / policy learner`, and model-router learning; §7.4 puts "one gated optimizer" in Wave 4 | Amend §7.5 and §7.4. The gated optimizer moves into Phase E and is restricted to fitting the routing table from ledger data. No RL, no bandits, no online learning. |
| D2 | Scope during migration | §2: no new features during migration except safety (§6.2), durability (§6.1) and the evaluator (§6.3) | Amend §2 to add "closed-loop measurement and gating (ADR-0009)" as a fourth exception. |
| D3 | Wave numbering | §7.4: Wave 2 is integrations and Postgres | Name this plan "Wave 2 (closed-loop)" and sequence it after Wave 1b. Phases A to C can run on SQLite (M1) before Postgres exists. |

The ADR (`docs/adr/0009-closed-loop-learning.md`) records the decision as **proposed** until D1 to D3 are approved.

---

## Dark-factory requirements (Oct 2026 research): source check and treatment

The coordinator's list of requirements was checked against sources before it was folded in. The
evidence status of each claim is stated, because some numbers in the briefing could not be confirmed.

| # | Requirement | Evidence status | Treatment |
|---|---|---|---|
| R1 | Holdout scenarios the coding agent cannot read or edit; score a fraction of scenarios satisfied | **Verified (secondary):** StrongDM's "scenarios" are end-to-end user stories kept outside the codebase, scored as a probabilistic "satisfaction" by LLM judges ([Willison, 2026-02-07](https://simonwillison.net/2026/feb/7/software-factory/); secondary coverage). Whether it transfers to Shipwright is a judgement. | Phase H1 to H3 |
| R2 | Evaluator outside the loop: checks, models and budgets read-only to the agent | **Partly verified:** Weng's "Harness Engineering for Self-Improvement" (Lil'Log, 2026-07-04) exists and lists weak evaluators and reward hacking as open problems. The specific claim that tests and budgets must be read-only was **not verified from the original post**. The principle matches ADR-0007 and F9. | Phase H1 and H2 |
| R3 | Digital twin of GitHub for deterministic offline validation | **Verified (secondary) for StrongDM's twins** of third-party services (Okta, Jira, Slack, Google Docs). A GitHub twin is a judgement. | Phase H4 |
| R4 | Runtime budget control; difficulty from ledger history, not the model's estimate; plateau stops | **Verified:** [Bai et al., arXiv 2604.22750](https://arxiv.org/pdf/2604.22750): cost for the same task varies up to 30x across runs; models predict their own token use poorly (correlation up to 0.39) and underestimate it. **Not verified:** a claim that accuracy peaks at intermediate cost. The abstract says higher token use does not mean higher accuracy; this plan uses only that. | Phase D5; Phase C |
| R5 | Gated self-improving harness: proposer, editable surface, hypothesis, held-in and held-out gate, archive, human review | **Verified:** [ModularRSI, arXiv 2609.14857](https://arxiv.org/pdf/2609.14857) evolves a harness split into five modules, with restricted modification scope and contrastive trajectory analysis; the paper reports that it does not ablate the contrastive step. The proposer and gate design is a judgement drawn from that line of work. AHE and Self-Harness were **not verified** and are not cited. | Phase J |
| R6 | Risk-tiered merge; lights-on by default; reviewer effort scales with complexity | **Not verified:** the "CRBugBench" paper (arXiv 2610.13668) and its "71.9%" figure **could not be found** and are **not cited**. The related [CR-Bench, arXiv 2603.11078](https://arxiv.org/pdf/2603.11078) reports low signal-to-noise for review agents that try to find every issue. The lights-on default and the tiers are judgements. | Phase I1, I2 |
| R7 | Measure quality, not volume: merged without rework, escaped defects, reverts, cost per merged PR, time to merge | **Judgement** (matches spec §8 scorecard) | Phase I4; ledger in A |
| R8 | Intake scores specifiability and asks or refuses instead of building | **Judgement**, motivated by the ~721 auto-patrol issues recorded in spec §1 (verified in repo) | Phase I3 |
| R9 | Audit trail that includes tool calls, handoffs and decisions | **Judgement**; the ledger in its first form had no tool-call entries, so it is added here | Phase A1 (new payload types) |
| R10 | Environment and setup failures as their own failure class | **Not verified** (the "biggest single factor" claim was not checked); the class is cheap and the baseline shows setup failures are common in the incident record | Phase B6 |

**Items cited to the coordinator's briefing but not verifiable here:** the production proof run that created issue #8547. It is not used as evidence in this plan.

### Phase A addendum: tool calls and handoffs in the trace (R9)

Add two variants to `LedgerPayload` in Task A1, and to the zod union in Task A3:

```ts
| {
    readonly type: "tool_call";
    readonly stage: string;
    readonly tool: string;
    /** SHA-256 of the canonical JSON of the arguments. Raw arguments are never stored (secrets). */
    readonly argsHash: string;
    readonly resultStatus: "ok" | "error" | "denied";
  }
| { readonly type: "handoff"; readonly fromStage: string; readonly toStage: string; readonly reason: string }
| { readonly type: "fence_violation"; readonly path: string; readonly by: string }
```

The Agent SDK message stream reports tool use; the `AgentRunner` adapter maps it to `tool_call` entries. Verify the exact message fields against the pinned SDK version before writing the mapper (Wave 0 verification item).

### Phase B6: environment and setup failures as their own class (R10)

- [ ] **Step 1: Failing test** in `src/contexts/learning/domain/failure.test.ts`: `classifyFailure({text: "bun: command not found"})` is `environment`; `"ENOENT: no such file or directory, open 'node_modules/.bin/tsc'"` is `environment`; `"EACCES: permission denied, mkdir '/usr/local/lib'"` is `environment`; a plain assertion failure is still `unknown` or `execution`, not `environment`.
- [ ] **Step 2: Implement.** Add `environment` to `FailureClass`. Add a rule after `auth` and before `transient`: `command not found|enoent.*(node_modules|\.bin)|eacces|could not install|lockfile|setup-bun|no such file or directory.*(tsconfig|package\.json)`.
- [ ] **Step 3: Policy.** In `decideRetry`, `environment` is retried at most once, then escalates with "fix the environment; retrying will not help". Add a test.

### Phase D5: runtime budget control (R4)

Budgets are caps enforced by the orchestrator at runtime. They are not predictions, and the model is never asked to estimate its own cost.

- [ ] **Step 1: Failing tests** (`src/contexts/intelligence/application/run-budget.test.ts`, using `FakeLedger`):
  1. Cumulative spend in the ledger for the run reaches the run's cap; the next `runTask` is not called, and the run ends `escalated` with reason `budget`.
  2. A `TaskSpec` that carries a larger `maxBudgetUsd` than the routing table allows is clamped to the table value. The orchestrator value wins.
  3. The `TaskSpec` type has no field for a model-estimated cost (a type test).
- [ ] **Step 2: Implement.** Before every call, read the run's `agent_call` entries, sum `usage.costUsd`, compare with the tier cap from `routeFor(tier)`, and stop when the next call would exceed it. Per-call caps (`maxBudgetUsd`, `maxTurns`, `timeoutMs`) come from the same table.
- [ ] **Step 3: Calibration.** Set each tier's cap at the 90th percentile of ledger history for that tier once history exists (Phase D4). Until then the placeholders in D2 apply, and they are labelled as placeholders.
- [ ] **Step 4: Plateau stop.** The Phase C `stalled` verdict also ends the run here, so a plateau cannot spend its way to the cap.


## Modes (M1, M2, M3)

Every phase must work in all three modes, or it must say which mode it does not cover.

| Phase | M1 local (SQLite) | M2 server | M3 multi-machine | Notes |
|---|---|---|---|---|
| A ledger | `RunJournal` over SQLite (after Wave 1b). Before 1b: JSONL files under `~/.shipwright/ledger/`. | As M1, one daemon. | **Not covered until Postgres (Wave 2).** Each machine has its own JSONL, so policies would see partial history. Phase A marks ledger reads as partial when a machine has no shared store. | Concurrent writers are safe only with the journal's fence. |
| B classifier | Stateless; reads one run's log and the run's previous attempts. | As M1. | Attempt history is read from the ledger, so M3 needs the shared store. Until then a machine uses its own history, and the policy says so in the decision. | |
| C progress | Per-run state in the ledger. | As M1. | The stall decision must be taken by the worker that holds the lease (fence). A stale worker cannot write a verdict. | |
| D routing | The table is static code; difficulty reads ledger history. | As M1. | Same history limit as B. | |
| E evals | Runs on a developer machine or a CI runner. | Nightly job on the server. | Nightly job on one runner; reads the shared ledger. | The ratchet is a file in git, so all modes read the same incumbent. |
| F verifier | Per run. | As M1. | As M1. | |
| G retirement | No mode-specific work. | | | |

CI (the GitHub Actions path) is a fourth environment. It uses the `shipwright-data` branch for cross-run state. That branch is the source of truth for CI history until Postgres exists.

---

## Baseline: the intelligence that exists today

Survey at `origin/main` (commit `1cc7b95f5`). "Read back" means some later code path changes its behaviour because of the file. "Outcome-tested" means a test checks an outcome (a decision, a retry count, a measured result) rather than grepping source for text. Where a test was not read in full, the row says so.

| Feature (file) | Writes | Read back to change behaviour? | Outcome-tested? |
|---|---|---|---|
| `classify_failure` (`scripts/lib/daemon-failure.sh:22`) | Nothing; returns `auth_error`, `api_error`, `invalid_issue`, `context_exhaustion` or the default. Reads `LOG_DIR/issue-N.log` tail. | **Yes:** `auth_error` and `invalid_issue` skip retry (lines ~218–232). | **No.** `scripts/sw-daemon-test.sh:1683` `test_classify_failure_auth` greps the function's source for the string `not logged in`. It does not run the classifier. |
| Retry escalation (`daemon-failure.sh:204–300`) | `retry_count` in SQLite or `daemon-state.json`; log lines | **Yes:** retry 1 uses opus and 30 iterations; retry 2 uses the `full` template, opus and 5 compound cycles; backoff 30 s, or 300 s for `api_error`. | No outcome test found. No measurement of whether escalation helps. |
| Per-class retry caps (`daemon-failure.sh:78–88`) | Nothing | **Yes:** `api_error` 4, `context_exhaustion` 2, `build_failure` 2, others 2 (env overridable). | No. The caps are env-overridable and not checked against any outcome. |
| CI auto-retry categorisation (`.github/workflows/shipwright-auto-retry.yml:126–222`) | `SHIPWRIGHT-RETRY-CATEGORY` and `SHIPWRIGHT-ERROR-MSG` markers | **Yes:** the category selects the retry strategy. **Auth failures have no category pattern**: they fall through to `BUILD_FAILURE`, the "safest retry strategy" (line ~214). | No. No workflow test in the repo. |
| Loop circuit breaker (`scripts/sw-loop.sh:124–125`, `scripts/lib/loop-convergence.sh:66–100`) | `loop.circuit_breaker` events | **Yes:** 3 consecutive iterations with fewer than 5 inserted lines stop the loop. | No. `sw-loop-test.sh` has no `test_` functions; its 62 matches are source greps. |
| Stuckness detection (`loop-convergence.sh:168–316`, `sw-loop.sh:2556`) | `loop.stuckness_detected`; `STUCKNESS_COUNT` | **Yes:** count ≥ 3 triggers a session restart. | No. |
| Convergence (`scripts/lib/convergence.sh:29–564`, `sw-loop.sh:2461`) | `convergence-recommendation.json`, history file | **Yes:** return 1 stops as converged, 2 stops as diverging. The `LOOP_COMPLETE` shortcut requires tests to pass (good). | Not verified in this survey. |
| `loop-tuning.json` (read at `sw-loop.sh:684–698`) | **Nothing.** A repo-wide search finds no writer. | Read: it would set `max_iterations`, `extension_size`, `circuit_breaker_threshold`. **Dead read path**: the file is never created. | No. |
| `iteration-model.json` (`scripts/sw-self-optimize.sh:50, 586–599`) | Self-optimize `tune` writes per-complexity means and sample counts | **Yes:** `sw-loop.sh:702–708`, `scripts/lib/pipeline-execution.sh:231–243`, `pipeline-intelligence-scoring.sh:21` set iteration and cycle limits from it. | `sw-self-optimize-test.sh` has 25 tests, 10 of them source greps. None measures whether the limits improve outcomes. |
| `template-weights.json` (writes `sw-self-optimize.sh:268–282, 429–431`) | Template weights | **Yes:** `scripts/lib/daemon-triage.sh:421–422` reads them for template choice. | `test_template_weight_high_success` is a unit check on the weight arithmetic, not on outcomes. |
| UCB1 model selection (`sw-self-optimize.sh:693–899`, read at `pipeline-execution.sh:696`) | Route stats in optimization state | **Yes:** `ucb1_select_model` picks the model. | `sw-bandit-selector-test.sh` exists; not read in full. No evidence it beats a fixed model. |
| Model router (`scripts/sw-model-router.sh:161` `route_model`) | Nothing found in this survey | Called by pipeline stages (`sw-model-router.sh:336`). Not analysed further. | Not analysed. |
| Memory (`scripts/sw-memory.sh`, 41 functions) | `~/.shipwright/memory/` | **Yes:** injected into prompts by `scripts/lib/loop-iteration.sh` and others (13 files read it). | `sw-memory-effectiveness-test.sh`: 16 tests on injection and outcome **bookkeeping** and score arithmetic with known inputs. No test that injection improves pass rate. |
| Outcome feedback (`scripts/lib/outcome-feedback.sh`: `generate_learned_rules`, `get_rolling_quality_score`) | Learned-rule and quality files | Readers not confirmed in this survey. | Not checked. |
| Heartbeat, CI (`shipwright-pipeline.yml:640–646`) | `SHIPWRIGHT-HEARTBEAT` comment **every 600 s from a background `sleep` loop, regardless of progress** | **Yes:** the watchdog treats the latest heartbeat as liveness. | `sw-heartbeat-test.sh`: 17 tests on file mechanics. No test on stall detection. |
| Watchdog (`.github/workflows/shipwright-watchdog.yml:100–256`) | Cancels runs; labels `shipwright-stuck`; posts `SHIPWRIGHT-WATCHDOG-ABANDON` | **Yes:** 45 min of silence cancels; 2 h abandons. | No workflow test. Only static checks (`workflow-fail-closed`, `workflow-injection`). |
| File heartbeat (`scripts/sw-heartbeat.sh`) | `~/.shipwright/heartbeats/` | Read by daemon dispatch and loop (`daemon-dispatch.sh:302`, `sw-loop.sh:2534`) | As above. |
| Stall detector (`scripts/sw-stall-detector.sh`) | `stall-detector-state.json` | **No.** Only the CLI and its test read it. Not wired into any workflow. | `sw-stall-detector-test.sh`: 12 tests, 8 of them greps. |
| Cost (`scripts/sw-cost.sh`; `costs.json`, `budget.json`) | Cost entries | **Yes, locally:** the TS budget guard (`src/contexts/orchestration/domain/budget.ts`) reads them before dispatch. **CI:** the gate is a no-op because runners have no cost files (ADR-0007). | `sw-cost-test.sh` and `sw-cost-optimizer-test.sh` (12 tests). Not read in full. |
| `auto_template` (`scripts/lib/daemon-poll.sh:315`) | Config flag | **Yes:** enables the fast path when lead time exceeds 2 h. | No. |
| Adaptive model and iteration estimate (`scripts/lib/adaptive-model.sh`, `sw-intelligence.sh`, `sw-adaptive.sh`) | Intelligence cache | **Yes:** `sw-loop.sh:714` calls `intelligence_estimate_iterations`. | Mixed. `sw-adaptive-model-test.sh` has 20 tests; `sw-adaptive-test.sh` has 0 test functions and 3 greps. |
| DORA (`scripts/sw-dora.sh`) | Reports only | **No.** No escalation logic found in `sw-dora.sh`, despite the name. | `sw-dora-test.sh`: 0 test functions, 11 greps. |
| Weekly optimizer (`.github/workflows/shipwright-optimize.yml`, cron Sunday 03:00 UTC) | Runs `sw-self-optimize.sh tune` and `evolve-memory`; persists `memory/` and `optimization/` to `shipwright-data` | **Yes:** the restored state is read by the next runs. | No. |
| Pipeline state persistence (`shipwright-pipeline.yml:~860–880`, `shipwright-optimize.yml:111`) | Force-pushes `shipwright-data` as a fallback | Not a learner, but it is the cross-run store for CI. A failed fast-forward is retried with `--force`, which can overwrite another run's data. | No. |

**What the survey shows.** Several mechanisms change behaviour from data, so "nothing reads it back" is not the problem. The problems are: (1) no outcome is ever measured against a baseline, so no change can be shown to help; (2) the CI heartbeat is a timer, not progress; (3) the CI failure classifier has no auth category; (4) one read path (`loop-tuning.json`) has no writer; (5) several tests grep source instead of checking behaviour.

---

## Phase order and what blocks dispatch at scale

| Phase | Depends on | Blocks re-enabling dispatch at scale? | Why |
|---|---|---|---|
| A ledger | Wave 1b (for M1 via `RunJournal`) | No | Measurement prerequisite for everything else. |
| B classifier and retry policy | A (for attempt history in CI) | **Yes** | Without it, a deterministic failure can be retried at scale (288 runs in one day on 2026-10-14). |
| C progress and stall | A | **Yes** | Without it, a non-converging run reports healthy for hours. |
| D difficulty, routing, cost | A; B for cost on the same path | **Yes** for CI cost (no budget enforcement on CI otherwise) | ADR-0007 notes the CI budget is a no-op. |
| E evals and ratchet | A, B, C, D | No, but **required before any routing or model change ships** | The ratchet is the only way a policy change can be accepted. |
| F verifier by default | E (to prove it helps), the spec §6.3 evaluator | No | Measured in E before it becomes default. |
| G retirement | E | No | Removes what E does not justify. |
| H holdout, read-only surfaces, GitHub twin | E (ratchet trust); H1 and H2 before the E ratchet blocks merges | No | Makes the E ratchet's inputs untamperable and offline. |
| I merge policy, review, specifiability, metrics | E, F | No (lights-on default) | Decides who merges; measures quality. |
| J self-improving harness (optional) | E, H, I | No | Gated search over the editable surface; may be cut. |

Scale dispatch is also gated by Wave 1b, because the breaker reads only GitHub Actions history until local outcomes reach the shared journal (ADR-0007).

---

## Conventions for every task

- Run commands from the worktree root. Implementation happens on a new branch cut from `origin/main` after this plan is merged. Do not reuse `wave2/plan`.
- `node_modules` in a worktree is a symlink. Never run `bun install` in a worktree. Use the existing install.
- Every new source file passes the fitness rules: F1 (domain imports only its own `domain/`; it may import no shared kernel types, so domain code declares its own structural types), F5 (I/O only in `adapters/`, `main.ts`, `cli.ts`, `testing/`), F7 (files ≤ 300 lines, functions ≤ 40 lines), F8 (tests use `createTestEnv()` when they touch a path).
- `zod` lives in adapters, where persisted data and CLI input are parsed. Domain code stays free of it.
- Bash edits: each bash change is a one-line bridge to a TS command. Bash edits must not add `eval`, `sh -c`, `${{` or GitHub writes (F11, F10). Check with `bun run arch` before and after; the findings baseline may only go down (ADR-0008).
- Never run a tmux-driving bash suite locally: `sw-daemon-test`, `sw-lib-daemon-dispatch-test`, `sw-lib-daemon-patrol-test`, `sw-lib-daemon-poll-test`, `sw-tmux-*`, or `sw-test-all.sh` without `--pattern`. Hermetic suites may run with `bash scripts/sw-test-all.sh --pattern <name>` and their output must not be piped (the watchdog `sleep` holds a pipe).
- Never run `shipwright gates check` or `breaker check` without `--no-github` on the real repository.
- Before calling any task done: `bun run format`, then stage new files, then `bun run check:fast`, then `bun run check` before the phase closes.

---

## File map (all phases)

| Path | Phase | Responsibility |
|---|---|---|
| `src/contexts/learning/domain/ledger.ts` | A | Ledger entry types and the validation rule. Pure. |
| `src/contexts/learning/ports.ts` | A | `RunLedger` port. |
| `src/contexts/learning/application/ledger.ts` | A | `appendEntry`, `readRun`, `verifyLedger` use cases. |
| `src/contexts/learning/index.ts` | A | Public API of the context. |
| `src/adapters/ledger/jsonl-ledger.ts` | A | File-per-run JSONL adapter (zod parse, fail-closed on corrupt lines). |
| `src/testing/fake-ledger.ts` | A | In-memory fake. |
| `src/testing/contracts/ledger-contract.ts` | A | One contract suite run against every adapter. |
| `src/cli/commands/ledger.ts` | A | `shipwright ledger append | show | verify`. |
| `src/contexts/learning/domain/failure.ts` | B | Failure class from typed kind or log text; normalized fingerprint. |
| `src/contexts/learning/domain/retry.ts` | B | `decideRetry`: retry, or escalate with a reason. |
| `src/contexts/learning/application/classify-failure.ts` | B | Use case: evidence + attempts → decision; appends a `decision` entry. |
| `src/cli/commands/failure.ts` | B | `shipwright failure classify --log FILE [--attempts FILE] [--json]`. |
| `scripts/lib/daemon-failure.sh` | B | `classify_failure` body replaced by a call to the TS command. |
| `scripts/sw-daemon-test.sh` (`test_classify_failure_auth`) | B | Source-grep assertion rewritten as a behaviour test. |
| `.github/workflows/shipwright-auto-retry.yml` | B | Categorisation step calls the TS classifier; `AUTH` category does not retry. |
| `src/contexts/delivery/domain/progress.ts` | C | Iteration snapshots and `assessProgress`. |
| `src/contexts/delivery/domain/progress.test.ts` | C | Outcome tests on snapshot histories. |
| `src/contexts/delivery/domain/stall-watchdog.ts` | C | Pure liveness decision from the last progress marker. |
| `src/cli/commands/progress.ts` | C | `shipwright progress assess --history FILE`. |
| `.github/workflows/shipwright-pipeline.yml` | C | Heartbeat timer replaced by progress markers from the TS assessor. |
| `.github/workflows/shipwright-watchdog.yml` | C | Reads `SHIPWRIGHT-PROGRESS`, not `SHIPWRIGHT-HEARTBEAT`, as liveness. |
| `src/contexts/intelligence/domain/models.ts` | D | The one place model IDs are named. |
| `src/contexts/intelligence/domain/routing.ts` | D | Versioned routing table (tier → model, effort, iterations, budget, verifier). |
| `src/contexts/intelligence/domain/difficulty.ts` | D | Deterministic difficulty tier from issue facts and ledger history. |
| `src/contexts/intelligence/index.ts` | D | Public API. |
| `tools/models/no-pinned-models.test.ts` | D | Policy check: workflows and templates name only IDs in `models.ts`. |
| `evals/delivery/cases/<id>/` | E | Case directories (issue, base SHA, reference diff, oracle, metadata, split). |
| `evals/ratchet/incumbent.json` | E | Incumbent policy and its holdout scores. |
| `src/contexts/learning/domain/eval-score.ts` | E | pass^k, cost per success, rework proxy. |
| `src/contexts/learning/domain/ratchet.ts` | E | Pure accept/reject rule with noise threshold. |
| `tools/eval/replay.ts`, `tools/eval/ratchet.ts` | E | Replay harness and CI ratchet check (tools may do I/O). |
| `src/contexts/quality/domain/verdict.ts` | F | Criterion verdicts and gap handling (shared with spec §6.3 evaluator). |
| `templates/pipelines/fast.json`, `hotfix.json`, `standard.json` | F | Add the `verify` stage; `fast` currently has `review` disabled. |
| `scripts/sw-self-optimize.sh`, `scripts/lib/daemon-triage.sh`, `scripts/sw-loop.sh`, `scripts/lib/pipeline-execution.sh`, `scripts/lib/daemon-poll.sh`, `scripts/sw-stall-detector.sh`, `scripts/sw-heartbeat.sh`, `scripts/sw-predictive.sh`, `scripts/sw-intelligence.sh`, `scripts/sw-adaptive.sh`, `scripts/sw-model-router.sh` | G | Retire or alias to "removed" stubs. |
| `docs/adr/0009-closed-loop-learning.md` | this plan | Decision record (proposed). |
| `docs/plans/port/progress.json` | A–G | Entries for each retired or added command. |
| `AGENTS.md`, `docs/architecture.md`, `docs/safety-runbook.md` | A–D | Agent and operator guidance for the ledger, classifier, progress markers and ratchet. |

---

## Phase A: run ledger, port, adapters, recording

**Exit criteria**
1. `bun test src/contexts/learning src/testing/contracts` passes, and the ledger contract suite passes against the fake and the JSONL adapter.
2. A corrupt line in a run's ledger makes `verifyLedger` return `corrupt` and makes `readRun` fail. No policy reads a corrupt ledger (fail closed).
3. A CI run of `shipwright-pipeline.yml` on the sandbox repository (see "Verification on GitHub") writes one `outcome` entry to the ledger, and the entry is on the `shipwright-data` branch after the run.
4. The `shipwright-data` persist step no longer force-pushes ledger files (fast-forward with retry).

### Task A1: Ledger domain types and validation (pure)

**Files:**
- Create: `src/contexts/learning/domain/ledger.ts`
- Test: `src/contexts/learning/domain/ledger.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/contexts/learning/domain/ledger.test.ts
import { describe, expect, test } from "bun:test";
import { type NewLedgerEntry, validateNewEntry } from "./ledger";

const base: NewLedgerEntry = {
  runId: "run-42",
  at: "2026-10-15T10:00:00.000Z",
  payload: { type: "outcome", status: "failed", reason: "tests red" },
};

describe("validateNewEntry", () => {
  test("accepts a well-formed outcome", () => {
    expect(validateNewEntry(base)).toBeNull();
  });

  test("rejects a run id that could escape a file name", () => {
    expect(validateNewEntry({ ...base, runId: "../etc" })).toMatch(/runId/);
  });

  test("rejects a timestamp that does not parse", () => {
    expect(validateNewEntry({ ...base, at: "yesterday" })).toMatch(/at/);
  });

  test("rejects non-finite usage numbers", () => {
    const entry: NewLedgerEntry = {
      ...base,
      payload: {
        type: "agent_call",
        stage: "build",
        model: "claude-opus-5-5",
        effort: "high",
        usage: { costUsd: Number.NaN, inputTokens: 1, outputTokens: 1, durationMs: 1 },
        failureClass: null,
        fingerprint: null,
      },
    };
    expect(validateNewEntry(entry)).toMatch(/costUsd/);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/contexts/learning/domain/ledger.test.ts`
Expected: FAIL with `Cannot find module './ledger'`.

- [ ] **Step 3: Write the implementation**

```ts
// src/contexts/learning/domain/ledger.ts
// Run ledger entries (spec §5 rule 3, §6.1). Pure types and one validation rule; no I/O.

export type LedgerOutcome = "succeeded" | "failed" | "escalated" | "stalled" | "cancelled";

export interface Usage {
  readonly costUsd: number;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly durationMs: number;
}

export type LedgerPayload =
  | {
      readonly type: "agent_call";
      readonly stage: string;
      readonly model: string;
      readonly effort: string;
      readonly usage: Usage;
      readonly failureClass: string | null;
      readonly fingerprint: string | null;
    }
  | {
      readonly type: "decision";
      readonly name: string;
      readonly policyVersion: string;
      readonly inputs: Readonly<Record<string, unknown>>;
      readonly output: Readonly<Record<string, unknown>>;
    }
  | {
      readonly type: "iteration";
      readonly stage: string;
      readonly index: number;
      readonly signals: Readonly<Record<string, unknown>>;
    }
  | { readonly type: "outcome"; readonly status: LedgerOutcome; readonly reason: string };

export interface NewLedgerEntry {
  readonly runId: string;
  /** ISO-8601 timestamp, written by the caller. */
  readonly at: string;
  readonly payload: LedgerPayload;
}

export interface LedgerEntry extends NewLedgerEntry {
  /** 1-based, monotonic within a run. Assigned by the adapter. */
  readonly seq: number;
}

const RUN_ID = /^[A-Za-z0-9._-]{1,128}$/;

function usageError(usage: Usage): string | null {
  const fields: ReadonlyArray<keyof Usage> = ["costUsd", "inputTokens", "outputTokens", "durationMs"];
  for (const field of fields) {
    if (!Number.isFinite(usage[field]) || usage[field] < 0) return `usage.${field} must be a finite number >= 0`;
  }
  return null;
}

/** Returns the first problem with a new entry, or `null` when it is valid. */
export function validateNewEntry(entry: NewLedgerEntry): string | null {
  if (!RUN_ID.test(entry.runId)) return "runId must match [A-Za-z0-9._-]{1,128}";
  if (Number.isNaN(Date.parse(entry.at))) return "at must be an ISO-8601 timestamp";
  if (entry.payload.type === "agent_call") return usageError(entry.payload.usage);
  return null;
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bun test src/contexts/learning/domain/ledger.test.ts`
Expected: `4 pass, 0 fail`.

- [ ] **Step 5: Commit** (on the implementation branch, after Task A2 passes; keep the commit path-limited)

### Task A2: The `RunLedger` port and the append use case

**Files:**
- Create: `src/contexts/learning/ports.ts`
- Create: `src/contexts/learning/application/ledger.ts`
- Create: `src/contexts/learning/index.ts`
- Test: `src/contexts/learning/application/ledger.test.ts`
- Create: `src/testing/fake-ledger.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/contexts/learning/application/ledger.test.ts
import { describe, expect, test } from "bun:test";
import { FakeLedger } from "../../../testing/fake-ledger";
import { appendEntry, readRun, verifyLedger } from "./ledger";

const outcome = (runId: string, status: "succeeded" | "failed") => ({
  runId,
  at: "2026-10-15T10:00:00.000Z",
  payload: { type: "outcome" as const, status, reason: "x" },
});

describe("ledger use cases", () => {
  test("assigns increasing sequence numbers per run", async () => {
    const ledger = new FakeLedger();
    const a = await appendEntry(ledger, outcome("r1", "failed"));
    const b = await appendEntry(ledger, outcome("r1", "succeeded"));
    expect(a.ok && a.value.seq).toBe(1);
    expect(b.ok && b.value.seq).toBe(2);
  });

  test("rejects an invalid entry without writing it", async () => {
    const ledger = new FakeLedger();
    const result = await appendEntry(ledger, { ...outcome("../x", "failed") });
    expect(result.ok).toBe(false);
    expect((await readRun(ledger, "../x")).ok).toBe(false);
  });

  test("verifyLedger reports the run count and no corruption on a clean ledger", async () => {
    const ledger = new FakeLedger();
    await appendEntry(ledger, outcome("r1", "failed"));
    await appendEntry(ledger, outcome("r2", "succeeded"));
    const report = await verifyLedger(ledger);
    expect(report).toEqual({ ok: true, runs: 2, entries: 2 });
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/contexts/learning/application/ledger.test.ts`
Expected: FAIL with `Cannot find module`.

- [ ] **Step 3: Write the port, the use cases, the fake, and the context index**

```ts
// src/contexts/learning/ports.ts
import type { Result } from "../../shared/kernel/result";
import type { LedgerEntry, NewLedgerEntry } from "./domain/ledger";

export type LedgerError =
  | { readonly kind: "invalid"; readonly message: string }
  | { readonly kind: "corrupt"; readonly message: string; readonly line?: number }
  | { readonly kind: "io"; readonly message: string };

/**
 * Append-only run ledger. Adapters: JSONL files (M1 before Wave 1b; CI on `shipwright-data`),
 * then `RunJournal` over SQLite (M1) and Postgres (M2/M3). Each adapter must pass
 * src/testing/contracts/ledger-contract.ts.
 */
export interface RunLedger {
  append(entry: NewLedgerEntry): Promise<Result<LedgerEntry, LedgerError>>;
  /** Entries for one run in `seq` order. Fails `corrupt` if any stored line cannot be parsed. */
  read(runId: string): Promise<Result<readonly LedgerEntry[], LedgerError>>;
  listRunIds(): Promise<Result<readonly string[], LedgerError>>;
}
```

```ts
// src/contexts/learning/application/ledger.ts
import { err, ok, type Result } from "../../../shared/kernel/result";
import { type LedgerEntry, type NewLedgerEntry, validateNewEntry } from "../domain/ledger";
import type { LedgerError, RunLedger } from "../ports";

export async function appendEntry(
  ledger: RunLedger,
  entry: NewLedgerEntry,
): Promise<Result<LedgerEntry, LedgerError>> {
  const problem = validateNewEntry(entry);
  if (problem !== null) return err({ kind: "invalid", message: problem });
  return ledger.append(entry);
}

export function readRun(ledger: RunLedger, runId: string) {
  return ledger.read(runId);
}

export interface VerifyReport {
  readonly ok: boolean;
  readonly runs: number;
  readonly entries: number;
  readonly problem?: string;
}

/** Fail closed: any unreadable run makes the whole report not ok. */
export async function verifyLedger(ledger: RunLedger): Promise<VerifyReport> {
  const ids = await ledger.listRunIds();
  if (!ids.ok) return { ok: false, runs: 0, entries: 0, problem: ids.error.message };
  let entries = 0;
  for (const id of ids.value) {
    const run = await ledger.read(id);
    if (!run.ok) return { ok: false, runs: ids.value.length, entries, problem: `${id}: ${run.error.message}` };
    entries += run.value.length;
  }
  return { ok: true, runs: ids.value.length, entries };
}

export { ok };
```

```ts
// src/testing/fake-ledger.ts
import { err, ok, type Result } from "../shared/kernel/result";
import { type LedgerEntry, type NewLedgerEntry, validateNewEntry } from "../contexts/learning/domain/ledger";
import type { LedgerError, RunLedger } from "../contexts/learning/ports";

/** In-memory ledger for application tests. Same rules as the real adapters. */
export class FakeLedger implements RunLedger {
  private readonly runs = new Map<string, LedgerEntry[]>();

  async append(entry: NewLedgerEntry): Promise<Result<LedgerEntry, LedgerError>> {
    const problem = validateNewEntry(entry);
    if (problem !== null) return err({ kind: "invalid", message: problem });
    const list = this.runs.get(entry.runId) ?? [];
    const stored: LedgerEntry = { ...entry, seq: list.length + 1 };
    this.runs.set(entry.runId, [...list, stored]);
    return ok(stored);
  }

  async read(runId: string): Promise<Result<readonly LedgerEntry[], LedgerError>> {
    return ok(this.runs.get(runId) ?? []);
  }

  async listRunIds(): Promise<Result<readonly string[], LedgerError>> {
    return ok([...this.runs.keys()]);
  }
}
```

```ts
// src/contexts/learning/index.ts
export type { LedgerEntry, LedgerOutcome, LedgerPayload, NewLedgerEntry, Usage } from "./domain/ledger";
export { validateNewEntry } from "./domain/ledger";
export { appendEntry, readRun, verifyLedger, type VerifyReport } from "./application/ledger";
export type { LedgerError, RunLedger } from "./ports";
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bun test src/contexts/learning`
Expected: all tests pass (`4 pass` from A1 plus `3 pass` here).

Run: `bun run arch`
Expected: exit 0. `application/ledger.ts` imports only `shared/kernel` and its own `domain` and `ports`. If F2 fails, the failure text names the rule.

Note on `application/ledger.ts`: the `ok` re-export at the bottom is unused; remove it before committing, because Biome flags unused exports only in strict mode, but it is noise. (Left out of the snippet on purpose so the implementer checks it.)

### Task A3: JSONL adapter (file per run, fail-closed reads)

**Files:**
- Create: `src/adapters/ledger/jsonl-ledger.ts`
- Test: `src/adapters/ledger/jsonl-ledger.test.ts`

Contract: one file per run at `<stateDir>/ledger/<runId>.jsonl`. Each line is one JSON entry with `seq` set. A run has one writer (its run id is unique to that run). Reads parse every line with zod; any unparseable line returns `corrupt` with the 1-based line number.

- [ ] **Step 1: Write the failing test**

```ts
// src/adapters/ledger/jsonl-ledger.test.ts
import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv } from "../../testing/test-env";
import { JsonlLedger } from "./jsonl-ledger";

const entry = (runId: string) => ({
  runId,
  at: "2026-10-15T10:00:00.000Z",
  payload: { type: "outcome" as const, status: "succeeded" as const, reason: "ok" },
});

describe("JsonlLedger", () => {
  test("writes one line per entry under the state directory", async () => {
    const env = createTestEnv();
    const ledger = new JsonlLedger(env.stateDir);
    await ledger.append(entry("run-1"));
    await ledger.append(entry("run-1"));
    const run = await ledger.read("run-1");
    expect(run.ok && run.value.map((e) => e.seq)).toEqual([1, 2]);
  });

  test("fails closed when a stored line is corrupt", async () => {
    const env = createTestEnv();
    const dir = join(env.stateDir, "ledger");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "run-2.jsonl"), `${JSON.stringify({ ...entry("run-2"), seq: 1 })}\n{not json\n`);
    const result = await new JsonlLedger(env.stateDir).read("run-2");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatchObject({ kind: "corrupt", line: 2 });
  });

  test("lists runs by file name and rejects a traversal id before touching disk", async () => {
    const env = createTestEnv();
    const ledger = new JsonlLedger(env.stateDir);
    await ledger.append(entry("run-3"));
    const ids = await ledger.listRunIds();
    expect(ids.ok && ids.value).toEqual(["run-3"]);
    const bad = await ledger.append({ ...entry("x"), runId: "../escape" });
    expect(bad.ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/adapters/ledger/jsonl-ledger.test.ts`
Expected: FAIL with `Cannot find module './jsonl-ledger'`.

- [ ] **Step 3: Write the adapter**

```ts
// src/adapters/ledger/jsonl-ledger.ts
import { appendFile, mkdir, readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import { err, ok, type Result } from "../../shared/kernel/result";
import { type LedgerEntry, type NewLedgerEntry, validateNewEntry } from "../../contexts/learning/domain/ledger";
import type { LedgerError, RunLedger } from "../../contexts/learning/ports";

// Persisted format: zod parses every line (spec §3.4). The domain type stays zod-free.
const usage = z.object({
  costUsd: z.number().finite().min(0),
  inputTokens: z.number().finite().min(0),
  outputTokens: z.number().finite().min(0),
  durationMs: z.number().finite().min(0),
});
const payload = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("agent_call"),
    stage: z.string(),
    model: z.string(),
    effort: z.string(),
    usage,
    failureClass: z.string().nullable(),
    fingerprint: z.string().nullable(),
  }),
  z.object({
    type: z.literal("decision"),
    name: z.string(),
    policyVersion: z.string(),
    inputs: z.record(z.string(), z.unknown()),
    output: z.record(z.string(), z.unknown()),
  }),
  z.object({
    type: z.literal("iteration"),
    stage: z.string(),
    index: z.number().int().min(0),
    signals: z.record(z.string(), z.unknown()),
  }),
  z.object({
    type: z.literal("outcome"),
    status: z.enum(["succeeded", "failed", "escalated", "stalled", "cancelled"]),
    reason: z.string(),
  }),
]);
const stored = z.object({
  runId: z.string(),
  seq: z.number().int().min(1),
  at: z.string(),
  payload,
});

/** One JSONL file per run. A run has one writer; its id is unique per run. */
export class JsonlLedger implements RunLedger {
  constructor(private readonly stateDir: string) {}

  private dir(): string {
    return join(this.stateDir, "ledger");
  }

  async append(entry: NewLedgerEntry): Promise<Result<LedgerEntry, LedgerError>> {
    const problem = validateNewEntry(entry);
    if (problem !== null) return err({ kind: "invalid", message: problem });
    const current = await this.read(entry.runId);
    if (!current.ok) return current;
    const row: LedgerEntry = { ...entry, seq: current.value.length + 1 };
    try {
      await mkdir(this.dir(), { recursive: true });
      await appendFile(join(this.dir(), `${entry.runId}.jsonl`), `${JSON.stringify(row)}\n`);
    } catch (cause) {
      return err({ kind: "io", message: String(cause) });
    }
    return ok(row);
  }

  async read(runId: string): Promise<Result<readonly LedgerEntry[], LedgerError>> {
    const problem = validateNewEntry({ runId, at: new Date(0).toISOString(), payload: { type: "outcome", status: "failed", reason: "" } });
    if (problem !== null) return err({ kind: "invalid", message: problem });
    let text: string;
    try {
      text = await readFile(join(this.dir(), `${runId}.jsonl`), "utf8");
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code === "ENOENT") return ok([]);
      return err({ kind: "io", message: String(cause) });
    }
    return parseLines(text);
  }

  async listRunIds(): Promise<Result<readonly string[], LedgerError>> {
    try {
      const names = await readdir(this.dir());
      return ok(names.filter((n) => n.endsWith(".jsonl")).map((n) => n.slice(0, -".jsonl".length)).sort());
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code === "ENOENT") return ok([]);
      return err({ kind: "io", message: String(cause) });
    }
  }
}

function parseLines(text: string): Result<readonly LedgerEntry[], LedgerError> {
  const out: LedgerEntry[] = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    if (line.trim() === "") continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      return err({ kind: "corrupt", message: "line is not JSON", line: i + 1 });
    }
    const checked = stored.safeParse(parsed);
    if (!checked.success) return err({ kind: "corrupt", message: checked.error.message, line: i + 1 });
    out.push(checked.data as LedgerEntry);
  }
  return ok(out);
}
```

Implementation notes for the implementer:
- Replace the odd `validateNewEntry(...)` call inside `read` with a dedicated `validateRunId(runId)` exported from `domain/ledger.ts` (one regex, one place). The snippet above reuses the full validator to keep the example short; the single-purpose function is the correct version and is part of this task.
- `NodeJS.ErrnoException` is a type from `@types/node`; if the project's Biome or tsconfig forbids it, use `(cause as { code?: string }).code`.

- [ ] **Step 4: Run it to verify it passes**

Run: `bun test src/adapters/ledger`
Expected: `3 pass, 0 fail`.

Run: `bun run check:fast`
Expected: exit 0.

### Task A4: Shared contract suite for every ledger adapter

**Files:**
- Create: `src/testing/contracts/ledger-contract.ts`
- Create: `src/testing/contracts/ledger-contract.test.ts`

- [ ] **Step 1: Write the contract (it runs against any `RunLedger`)**

```ts
// src/testing/contracts/ledger-contract.ts
import { describe, expect, test } from "bun:test";
import type { RunLedger } from "../../contexts/learning/ports";

const at = "2026-10-15T10:00:00.000Z";
const outcome = (runId: string) => ({
  runId,
  at,
  payload: { type: "outcome" as const, status: "failed" as const, reason: "r" },
});

/** Every RunLedger adapter must pass this suite unchanged (ADR-0005 pattern). */
export function ledgerContract(name: string, make: () => Promise<RunLedger>): void {
  describe(`ledger contract: ${name}`, () => {
    test("sequence numbers are per run and start at 1", async () => {
      const ledger = await make();
      await ledger.append(outcome("a"));
      await ledger.append(outcome("b"));
      const a = await ledger.append(outcome("a"));
      expect(a.ok && a.value.seq).toBe(2);
    });

    test("reads return entries in seq order", async () => {
      const ledger = await make();
      for (let i = 0; i < 3; i++) await ledger.append(outcome("c"));
      const run = await ledger.read("c");
      expect(run.ok && run.value.map((e) => e.seq)).toEqual([1, 2, 3]);
    });

    test("unknown runs read as empty, not as an error", async () => {
      const ledger = await make();
      const run = await ledger.read("never-written");
      expect(run.ok && run.value).toEqual([]);
    });

    test("invalid entries are refused and nothing is listed", async () => {
      const ledger = await make();
      const bad = await ledger.append({ ...outcome("x"), at: "not a time" });
      expect(bad.ok).toBe(false);
      const ids = await ledger.listRunIds();
      expect(ids.ok && ids.value).toEqual([]);
    });
  });
}
```

```ts
// src/testing/contracts/ledger-contract.test.ts
import { FakeLedger } from "../fake-ledger";
import { JsonlLedger } from "../../adapters/ledger/jsonl-ledger";
import { createTestEnv } from "../test-env";
import { ledgerContract } from "./ledger-contract";

ledgerContract("fake", async () => new FakeLedger());
ledgerContract("jsonl", async () => new JsonlLedger(createTestEnv().stateDir));
```

- [ ] **Step 2: Run it**

Run: `bun test src/testing/contracts/ledger-contract.test.ts`
Expected: 8 pass (4 tests × 2 adapters), 0 fail.

Adapters added later (SQLite `RunJournal`-backed in Wave 1b; Postgres in Wave 2) must add one line each to this file, and they must pass unchanged.

### Task A5: `shipwright ledger` command

**Files:**
- Create: `src/cli/commands/ledger.ts`
- Modify: `src/cli/commands/index.ts` (register the command; read the file first and follow its pattern)
- Modify: `src/main.ts` (add `ledger: () => RunLedger` to the `CommandContext`, built lazily like `safety`)
- Modify: `src/cli/command.ts` (add the `ledger` field to `CommandContext`)
- Test: `src/cli/commands/ledger.test.ts` (uses `src/testing/cli-harness.ts`)

Behaviour:
- `shipwright ledger append --run <id> --file <payload.json>`: reads one JSON object with `at` and `payload`; the file path is a validated argv value, never interpolated into a shell string. Exit 0 with the stored `seq` on stdout; exit 1 with the reason on stderr otherwise.
- `shipwright ledger show --run <id> [--json]`
- `shipwright ledger verify`: exit 0 when `verifyLedger` is ok, exit 1 otherwise (fail closed).

- [ ] **Step 1: Write the failing CLI test** using the existing harness pattern (read `src/cli/commands/gates.ts` and its test first, and copy the harness usage exactly). Cover: `append` with a valid file exits 0 and prints `seq`; `append` with a corrupt file exits 1; `verify` exits 1 after a corrupt line is planted in the test's state directory.

- [ ] **Step 2: Implement** the three subcommands by calling `appendEntry` and `verifyLedger` only. The command reads the payload file through a file-reader port that the adapter layer supplies (command code does not touch `node:fs`, F5).

- [ ] **Step 3: Verify**

Run: `bun test src/cli/commands/ledger.test.ts`
Expected: all pass.

Run: `bun run docs:gen && bun run docs:check`
Expected: `docs/reference/cli.md` regenerated; `docs:check` exits 0.

### Task A6: Record from CI and from the bash daemon (bridges, one line each)

**Files:**
- Modify: `.github/workflows/shipwright-pipeline.yml` (final outcome step)
- Modify: `scripts/lib/daemon-failure.sh` (one call in `record_failure`)
- Modify: `.github/workflows/shipwright-pipeline.yml` persist step (the `cp` list gains `ledger`; the push loses `--force`)

- [ ] **Step 1: CI outcome step.** After the pipeline's result is known, write the payload with `jq -n --arg` into `$RUNNER_TEMP/outcome.json` (values come through `env:`, never `${{ }}` inside `run:`), then run `shipwright ledger append --run "$GITHUB_RUN_ID" --file "$RUNNER_TEMP/outcome.json"`. The step must not swallow errors: a failed append fails the job (workflow rule, ADR-0007).

- [ ] **Step 2: Bash bridge.** In `record_failure`, write the payload to a `mktemp` file with `printf` and call `shipwright ledger append --run "issue-${issue_num}-$(date +%s)" --file "$tmp"`. Never build the command string from issue text.

- [ ] **Step 3: Persist without force.** Replace the `git push origin shipwright-data --force` fallback for the `ledger/` path with: fetch, `git rebase` or re-copy the new ledger files on top of `origin/shipwright-data`, push without `--force`, retry up to 5 times. Ledger files are unique per run, so a rebase never conflicts with another run's files. Add a restore step that copies `ledger/` back from the branch before the run (as the optimize workflow already does for `memory` and `optimization`).

- [ ] **Step 4: Verify**

Run: `bun run arch`
Expected: exit 0; the F11 and F10 findings count does not grow (compare `tools/arch/findings-baseline.json` before and after).

Run: `bash scripts/sw-lib-daemon-failure-test.sh` is **not** the check here; see the GitHub verification below.

---

## Phase B: failure classifier and retry policy

**Exit criteria**
1. `classifyFailure` returns the typed kind when one is given, the text rule otherwise, and never returns a class from source text.
2. For the 2026-10-14 pre-flight auth failure text, `decideRetry` escalates on the first attempt. Replaying three such attempts makes exactly one escalation and zero retries.
3. Two identical non-transient fingerprints in a row escalate. A transient failure is retried with exponential backoff, and never beyond `maxTransient`.
4. `scripts/sw-daemon-test.sh`'s `test_classify_failure_auth` no longer greps source; it runs the function on a fixture log.
5. The CI auto-retry step categorises through the TS command. An `AUTH` category is never retried and posts the existing "Pipeline Auth Failure" text, which dispatch already recognises.

### Task B1: Failure classes and fingerprints (pure)

**Files:**
- Create: `src/contexts/learning/domain/failure.ts`
- Test: `src/contexts/learning/domain/failure.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/contexts/learning/domain/failure.test.ts
import { describe, expect, test } from "bun:test";
import { classifyFailure, failureFingerprint } from "./failure";

describe("classifyFailure", () => {
  test("a typed kind wins over text", () => {
    expect(classifyFailure({ kind: "auth", text: "rate limit exceeded" })).toBe("auth");
  });

  test("the 2026-10-14 pre-flight auth text is an auth failure", () => {
    const text = "::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret";
    expect(classifyFailure({ text })).toBe("auth");
  });

  test("auth outranks transient when a log has both", () => {
    expect(classifyFailure({ text: "429 rate limit\nAPI Error: 401 unauthorized" })).toBe("auth");
  });

  test("a mention of the token variable alone is not an auth failure", () => {
    expect(classifyFailure({ text: "CLAUDE_CODE_OAUTH_TOKEN is documented in README" })).toBe("unknown");
  });

  test("text with no known pattern is unknown, not a guess", () => {
    expect(classifyFailure({ text: "TypeError: cannot read properties of undefined" })).toBe("unknown");
  });
});

describe("failureFingerprint", () => {
  test("is stable across digits and paths", () => {
    const a = failureFingerprint("execution", "build failed at /tmp/x/42 line 7");
    const b = failureFingerprint("execution", "build failed at /tmp/y/9 line 3");
    expect(a).toBe(b);
  });

  test("differs when the class differs", () => {
    expect(failureFingerprint("auth", "x")).not.toBe(failureFingerprint("transient", "x"));
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/contexts/learning/domain/failure.test.ts`
Expected: FAIL with `Cannot find module './failure'`.

- [ ] **Step 3: Write the implementation**

```ts
// src/contexts/learning/domain/failure.ts
// Failure classes (spec §6.2 error fingerprinting). Pure. Domain code declares its own kind names
// (F1 forbids importing the shared kernel), mirroring AgentFailureKind in shared/kernel/ports.ts.

export type FailureClass =
  | "auth"
  | "invalid_input"
  | "transient"
  | "budget"
  | "max_turns"
  | "refusal"
  | "schema"
  | "truncated"
  | "timeout"
  | "execution"
  | "unknown";

export interface FailureEvidence {
  /** The typed agent failure kind, when one exists (AgentFailureKind). Wins over text. */
  readonly kind?: string;
  /** Log or error text. */
  readonly text?: string;
}

const KIND_CLASS: Readonly<Record<string, FailureClass>> = {
  auth: "auth",
  transient: "transient",
  budget: "budget",
  max_turns: "max_turns",
  refusal: "refusal",
  schema: "schema",
  truncated: "truncated",
  timeout: "timeout",
  execution: "execution",
  aborted: "execution",
};

// First match wins. Auth is first: retrying an auth failure cannot help, so it must not be
// masked by a rate-limit line in the same log. The bare variable name is deliberately not a rule.
const TEXT_RULES: ReadonlyArray<readonly [RegExp, FailureClass]> = [
  [
    /authentication[ _]failed|invalid api key|api error: 401|oauth token (is )?(expired|invalid)|not logged in|unauthorized/i,
    "auth",
  ],
  [/issue not found|api error: 404|no body|could not resolve|issue.*does not exist/i, "invalid_input"],
  [
    /rate.?limit|overloaded|api error: (429|5\d\d)|econnreset|etimedout|socket hang up|service unavailable|econnrefused|eai_again/i,
    "transient",
  ],
];

export function classifyFailure(evidence: FailureEvidence): FailureClass {
  const typed = evidence.kind !== undefined ? KIND_CLASS[evidence.kind] : undefined;
  if (typed !== undefined) return typed;
  const text = evidence.text ?? "";
  for (const [pattern, cls] of TEXT_RULES) {
    if (pattern.test(text)) return cls;
  }
  return "unknown";
}

/** FNV-1a, 32-bit: a pure, dependency-free hash for grouping identical failures. */
export function fnv1a(input: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

/** Digits, paths, timestamps and hex are normalised so the same failure groups together. */
export function failureFingerprint(cls: FailureClass, text: string): string {
  const normalised = text
    .toLowerCase()
    .replace(/\/[^\s'":]+/g, "<path>")
    .replace(/\d{4}-\d{2}-\d{2}t?[\d:.z+-]*/g, "<time>")
    .replace(/0x[0-9a-f]+|[0-9a-f]{7,40}/g, "<hex>")
    .replace(/\d+/g, "0")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 160);
  return `${cls}:${fnv1a(normalised)}`;
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bun test src/contexts/learning/domain/failure.test.ts`
Expected: `7 pass, 0 fail`.

### Task B2: Retry decision (pure)

**Files:**
- Create: `src/contexts/learning/domain/retry.ts`
- Test: `src/contexts/learning/domain/retry.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/contexts/learning/domain/retry.test.ts
import { describe, expect, test } from "bun:test";
import { type Attempt, decideRetry, type RetryPolicy } from "./retry";

const policy: RetryPolicy = { maxAttempts: 4, maxTransient: 3, baseDelayMs: 1000, maxDelayMs: 60_000 };
const att = (cls: Attempt["cls"], fingerprint = `${cls}:x`): Attempt => ({ cls, fingerprint });

describe("decideRetry", () => {
  test("auth is never retried; it escalates to a human on the first attempt", () => {
    const d = decideRetry([att("auth")], policy);
    expect(d.action).toBe("escalate");
  });

  test("invalid input is never retried", () => {
    expect(decideRetry([att("invalid_input")], policy).action).toBe("escalate");
  });

  test("the same non-transient failure twice escalates", () => {
    const same = att("execution", "execution:abc");
    const d = decideRetry([same, same], policy);
    expect(d).toMatchObject({ action: "escalate" });
    if (d.action === "escalate") expect(d.reason).toContain("same failure twice");
  });

  test("two distinct budget failures are retried within caps", () => {
    const d = decideRetry([att("budget", "b:1"), att("budget", "b:2")], policy);
    expect(d.action).toBe("retry");
  });

  test("transient failures back off exponentially", () => {
    const d = decideRetry([att("transient", "t:1"), att("transient", "t:1")], policy);
    expect(d).toMatchObject({ action: "retry", delayMs: 2000 });
  });

  test("transient failures escalate once they exceed maxTransient", () => {
    const many = Array.from({ length: 4 }, () => att("transient", "t:1"));
    const d = decideRetry(many, { ...policy, maxAttempts: 10 });
    expect(d.action).toBe("escalate");
  });

  test("the attempt cap cannot be exceeded", () => {
    const four = [att("budget", "1"), att("budget", "2"), att("budget", "3"), att("budget", "4")];
    expect(decideRetry(four, policy).action).toBe("escalate");
  });

  test("no history means no decision to act on: escalate", () => {
    expect(decideRetry([], policy).action).toBe("escalate");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/contexts/learning/domain/retry.test.ts`
Expected: FAIL with `Cannot find module './retry'`.

- [ ] **Step 3: Write the implementation**

```ts
// src/contexts/learning/domain/retry.ts
import type { FailureClass } from "./failure";

export interface Attempt {
  readonly cls: FailureClass;
  readonly fingerprint: string;
}

export interface RetryPolicy {
  /** Total runs allowed, first run included. The fix-loop cap (ADR-0007) is 4. */
  readonly maxAttempts: number;
  readonly maxTransient: number;
  readonly baseDelayMs: number;
  readonly maxDelayMs: number;
}

export type RetryDecision =
  | { readonly action: "retry"; readonly delayMs: number; readonly reason: string }
  | { readonly action: "escalate"; readonly reason: string };

/** Adaptation may only tighten these caps; it never raises them (ADR-0007, ADR-0009). */
export const DEFAULT_RETRY_POLICY: RetryPolicy = {
  maxAttempts: 4,
  maxTransient: 3,
  baseDelayMs: 30_000,
  maxDelayMs: 3_600_000,
};

const NEVER_RETRY: ReadonlySet<FailureClass> = new Set(["auth", "invalid_input"]);

/** Decides from the attempt history of one issue. Pure; the caller records the decision. */
export function decideRetry(history: readonly Attempt[], policy: RetryPolicy): RetryDecision {
  const last = history.at(-1);
  if (last === undefined) return { action: "escalate", reason: "no attempt to decide on" };
  if (NEVER_RETRY.has(last.cls)) {
    return { action: "escalate", reason: `${last.cls}: retrying cannot help; a human must act` };
  }
  if (history.length >= policy.maxAttempts) {
    return { action: "escalate", reason: `attempt cap ${policy.maxAttempts} reached` };
  }
  const prev = history.at(-2);
  if (prev !== undefined && prev.fingerprint === last.fingerprint && last.cls !== "transient") {
    return { action: "escalate", reason: `same failure twice (${last.fingerprint})` };
  }
  if (last.cls === "transient") return retryTransient(history, policy);
  return { action: "retry", delayMs: 0, reason: `${last.cls}: retry within caps` };
}

function retryTransient(history: readonly Attempt[], policy: RetryPolicy): RetryDecision {
  const transients = history.filter((a) => a.cls === "transient").length;
  if (transients > policy.maxTransient) {
    return { action: "escalate", reason: `transient failures exceed ${policy.maxTransient}` };
  }
  const delayMs = Math.min(policy.baseDelayMs * 2 ** (transients - 1), policy.maxDelayMs);
  return { action: "retry", delayMs, reason: `transient (${transients}): backoff` };
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bun test src/contexts/learning/domain/retry.test.ts`
Expected: `8 pass, 0 fail`.

Note on the transient test: two transient attempts give `transients = 2`, so `delayMs = base * 2^(2-1) = 2000`. This is the expected value in the test.

### Task B3: Classify use case and the `shipwright failure classify` command

**Files:**
- Create: `src/contexts/learning/application/classify-failure.ts`
- Test: `src/contexts/learning/application/classify-failure.test.ts`
- Create: `src/cli/commands/failure.ts`; register it; wire a file-text port through `main.ts` (as Phase A did for the ledger)
- Test: `src/cli/commands/failure.test.ts`

Behaviour: the use case takes `evidence` (kind and text) and the prior `attempts` list. It returns `{ class, fingerprint, decision }` and appends a `decision` ledger entry with `policyVersion: "failure-v1"`, the inputs (class, fingerprint, attempts count) and the output. The CLI takes `--log FILE` (text is read by the adapter), optional `--kind K`, optional `--attempts FILE` (JSON array of `{cls, fingerprint}`), and `--json`. Exit 0 for retry, 3 for escalate (distinct from 1, which means an error), 2 for usage errors.

- [ ] **Step 1: Failing test for the use case** (with `FakeLedger`): the auth text produces `escalate`, one `decision` entry is in the ledger, and its `output.action` is `"escalate"`.

- [ ] **Step 2: Failing CLI test** using the command harness: `--log` pointing at a fixture file containing the pre-flight text exits 3 and prints JSON with `"class":"auth"`.

- [ ] **Step 3: Implement** the use case by calling `classifyFailure`, `failureFingerprint` and `decideRetry`, then `appendEntry`. The CLI reads the log through the file-text port, never with `node:fs`.

- [ ] **Step 4: Verify**

Run: `bun test src/contexts/learning src/cli/commands/failure.test.ts`
Expected: all pass.

Run: `bun run check:fast`
Expected: exit 0.

### Task B4: Bash bridge: `classify_failure` calls the TS classifier

**Files:**
- Modify: `scripts/lib/daemon-failure.sh` (lines 22–75: replace the body)
- Modify: `scripts/sw-daemon-test.sh` (`test_classify_failure_auth`, lines ~1683–1692)

Mapping (the bash names stay, so callers do not change). Read `daemon-failure.sh` lines 60–75 first to confirm the bash default for an unmatched log before writing the mapping.

| TS class | Bash output |
|---|---|
| `auth` | `auth_error` |
| `transient` | `api_error` |
| `invalid_input` | `invalid_issue` |
| `max_turns`, `truncated`, `budget` | `context_exhaustion` (only when the progress file shows it; otherwise the bash default, as today) |
| all others | the bash default used for an unmatched log today |

- [ ] **Step 1: Rewrite `test_classify_failure_auth`** so it writes a fixture log containing the pre-flight text into a temporary `LOG_DIR`, sources the function, calls `classify_failure 42`, and asserts the output is `auth_error`. Delete the `grep -A 30 'classify_failure()'` assertions. (Hermetic: the suite already mocks `gh`; it must not touch the real `HOME`.)

- [ ] **Step 2: Replace the body** of `classify_failure` with a call: write the log tail to a `mktemp` file, run `shipwright failure classify --log "$tmp" --json` (argv only, no `eval`, no `sh -c`), and map the `class` field with a `case` statement. If the TS command is missing (Bun absent), return the bash default and log a warning: the daemon fails open on classification but closed on gates. The gates still refuse to dispatch (ADR-0007).

- [ ] **Step 3: Verify hermetically**

Run: `bash scripts/sw-test-all.sh --pattern sw-lib-daemon-failure-test`
Expected: the suite passes; no output piped.

Run: `bun run arch`
Expected: exit 0; the F11 findings for `daemon-failure.sh` must not increase (the new call is argv-only).

### Task B5: CI auto-retry uses the classifier; `AUTH` never retries

**Files:**
- Modify: `.github/workflows/shipwright-auto-retry.yml` (categorisation block, lines ~126–222; retry branch around line 345)

- [ ] **Step 1:** Replace the regex categorisation with a step that writes the fetched log tail to `$RUNNER_TEMP/tail.log` and runs `shipwright failure classify --log "$RUNNER_TEMP/tail.log" --json`. The log path and the attempts file reach the step through `env:`. Map `auth` to a new `AUTH` category; keep `TRANSIENT`, `BUILD_FAILURE`, `DESIGN_FAILURE` and `INFRA` as the existing names so the strategy `case` still works. `invalid_input` maps to `DESIGN_FAILURE` with the existing "invalid issue" comment path.

- [ ] **Step 2:** `AUTH` posts the existing "Pipeline Auth Failure" text (already recognised by `shipwright-dispatch.yml:105–107`) and returns without dispatching. It writes `SHIPWRIGHT-RETRY-CATEGORY: AUTH` through `scripts/ci/bot-comments.sh` conventions, so only bot-authored markers count.

- [ ] **Step 3:** The step must not swallow classifier errors. If `shipwright failure classify` exits 1 (error, not escalation), the job fails, as the gate steps do.

- [ ] **Step 4: Verify**

Run: `actionlint .github/workflows/shipwright-auto-retry.yml`
Expected: no output, exit 0.

Run: `bun run arch`
Expected: exit 0 (`workflow-injection` and `workflow-fail-closed` pass).

GitHub verification: see "Verification on GitHub", Phase B.

---

## Phase C: progress signals, stall detection, watchdog

**Exit criteria**
1. A snapshot history with no progress for 3 iterations, or the same error fingerprint for 3 iterations, is `stalled`. A history where the failing-test set shrinks, the passing count grows, or the diff grows is `progressing`.
2. `LOOP_COMPLETE` with red tests is not `converged`.
3. The CI watchdog decides liveness from the last `SHIPWRIGHT-PROGRESS` marker. A `SHIPWRIGHT-HEARTBEAT` alone does not count as progress.
4. The stub non-converging run (see verification) is marked stalled within 3 iterations, and the watchdog reports it stalled, not healthy.

### Task C1: Progress domain (pure)

**Files:**
- Create: `src/contexts/delivery/domain/progress.ts`
- Test: `src/contexts/delivery/domain/progress.test.ts`

Shape (fill in during implementation; the tests below fix the behaviour):

```ts
export interface IterationSnapshot {
  readonly index: number;
  readonly passingTests: number | null; // null: the test summary was not parseable
  readonly failingTests: readonly string[]; // sorted names
  readonly diffLines: number; // insertions + deletions against the base
  readonly newCommits: number;
  readonly errorFingerprint: string | null; // from failureFingerprint, last error of the iteration
  readonly loopCompleteClaimed: boolean;
}
export interface ProgressPolicy { readonly stallIterations: number; readonly repeatFingerprint: number }
export type ProgressVerdict =
  | { readonly kind: "progressing"; readonly reasons: readonly string[] }
  | { readonly kind: "plateau"; readonly reasons: readonly string[] }
  | { readonly kind: "stalled"; readonly reasons: readonly string[] }
  | { readonly kind: "converged"; readonly reasons: readonly string[] };
export function assessProgress(history: readonly IterationSnapshot[], policy: ProgressPolicy): ProgressVerdict;
```

- [ ] **Step 1: Failing tests** (outcome-based):

1. The 2.5-hour docs case: four iterations, each with `diffLines: 2`, `passingTests: null`, `failingTests: []`, `newCommits: 0`, and the same `errorFingerprint`. `assessProgress` with `{stallIterations: 3, repeatFingerprint: 3}` returns `stalled`.
2. A history where iteration 3 has `failingTests` shrinked from `["a","b"]` to `["a"]` returns `progressing`.
3. `loopCompleteClaimed: true` with `failingTests: ["a"]` is not `converged`.
4. `loopCompleteClaimed: true` with `passingTests: 10`, `failingTests: []` is `converged`.
5. Two iterations without progress and then progress resumes → `progressing`.
6. A single unparseable test summary (`passingTests: null`) does not count as "no progress" by itself: progress is judged on the other signals.

- [ ] **Step 2: Implement.** Rules, in order: `converged` requires the claim, an empty `failingTests` and a non-null `passingTests`; `stalled` if the last `stallIterations` snapshots show no progress signal, or the last `repeatFingerprint` snapshots share one non-null `errorFingerprint`; `plateau` if the last two show no signal; otherwise `progressing`. A progress signal is: `failingTests` strictly smaller as a set than before, `passingTests` increased, `diffLines` increased, or `newCommits > 0`.

- [ ] **Step 3: Verify**

Run: `bun test src/contexts/delivery/domain/progress.test.ts`
Expected: all pass.

### Task C2: Stall-aware watchdog decision (pure)

**Files:**
- Create: `src/contexts/delivery/domain/stall-watchdog.ts`
- Test: `src/contexts/delivery/domain/stall-watchdog.test.ts`

Inputs: `now`, the timestamp of the last `SHIPWRIGHT-PROGRESS` marker (or the run start), and the last heartbeat timestamp (for information only). Output: `healthy | silent | stuck | abandoned` with the existing thresholds (45 min → cancel as stuck; 2 h → abandon). Tests: a heartbeat 1 minute ago with progress marker 90 minutes ago returns `stuck`, not `healthy`.

### Task C3: `shipwright progress assess` command and the iteration bridge

**Files:**
- Create: `src/cli/commands/progress.ts` (register as in Phase A)
- Modify: `scripts/sw-loop.sh` (one call after each iteration, after `convergence_integrate`, that appends the snapshot to a JSON history file and reads the verdict; `stalled` sets the loop status to `stalled` and exits)

This is the one deliberate extension of bash in this plan. It is one line plus the status handling, it is argv-only, and it is ratcheted by `bun run arch`. The full port of `sw-loop.sh` belongs to the delivery context and to a separate plan.

- [ ] **Step 1:** Failing CLI test: `progress assess --history FILE` with the 2.5-hour fixture exits 3 (stalled) and prints `"kind":"stalled"`.
- [ ] **Step 2:** Implement, delegating to `assessProgress`. Exit codes: 0 progressing or plateau, 3 stalled, 0 converged (the loop's existing convergence path stops it).
- [ ] **Step 3:** Bash bridge: after each iteration, write the snapshot with `printf` into a `mktemp` JSON array and call the command. Do not interpolate values into a command string.
- [ ] **Step 4:** Verify `bun test src/cli/commands/progress.test.ts`, then `bun run arch` (no new findings).

### Task C4: Progress markers in CI and the watchdog reads them

**Files:**
- Modify: `.github/workflows/shipwright-pipeline.yml` (lines ~640–646: the background `sleep 600` heartbeat loop stays as "alive", but a new `SHIPWRIGHT-PROGRESS` comment is posted only when the iteration bridge reports a new signal, from the TS assessor's output file)
- Modify: `.github/workflows/shipwright-watchdog.yml` (lines ~100–125: `LAST_SIGNAL_DATE` takes the latest `SHIPWRIGHT-PROGRESS` marker from bot comments only; heartbeat is shown in the report but not used for the cancel decision)

- [ ] **Step 1:** Add the marker writer. Values come through `env:`. Posting goes through the existing comment step (the `integrations` writer rule F10 applies to new GitHub writes in TS; in this bash workflow step the comment is posted with the same `gh issue comment` pattern the file already uses, which is ratcheted, so the count must not grow).
- [ ] **Step 2:** Watchdog reads progress markers through `scripts/ci/bot-comments.sh`.
- [ ] **Step 3:** `actionlint` on both workflow files; `bun run arch`.

GitHub verification: see Phase C under "Verification on GitHub".

---

## Phase D: difficulty, routing table, cost

**Exit criteria**
1. Every model ID used in `.github/workflows/`, `templates/pipelines/` and `scripts/` for a Claude call is one of the IDs in `src/contexts/intelligence/domain/models.ts`. The three pinned strings `claude-sonnet-4-20250514` (`.github/workflows/review-remediation.yml:136`), `claude-haiku-4-5-20251001` (`.github/workflows/shipwright-pipeline.yml:211`) and `claude-haiku-4-5` (`templates/pipelines/cost-aware.json`) are gone. The check is `tools/models/no-pinned-models.test.ts`. It is a policy check on files, so it is a grep, and it is labelled as one.
2. The routing table names effort explicitly for every stage. It never sends `thinking: {type: "disabled"}` or a `budget_tokens` value to `claude-opus-5-5`, `claude-sonnet-5-5` or `claude-haiku-5-5`, which the API rejects with 400.
3. Difficulty is a pure function; the same inputs always give the same tier, and the inputs are written to the ledger.
4. CI spend for the day is readable from the ledger before dispatch (the budget gate reads it). Until the CI cost source is confirmed (open question Q6), the CI budget gate stays a no-op and this exit criterion is not met.

### Task D1: Model IDs in one place

**Files:**
- Create: `src/contexts/intelligence/domain/models.ts`
- Test: `tools/models/no-pinned-models.test.ts`

```ts
// src/contexts/intelligence/domain/models.ts
// The only place Shipwright names Claude models. IDs are the exact strings from the Claude API
// model table; no date suffixes. Change a value here, through the eval ratchet (ADR-0009), never
// by editing a workflow or template.
export const MODELS = {
  opus: "claude-opus-5-5",
  sonnet: "claude-sonnet-5-5",
  haiku: "claude-haiku-5-5",
} as const;
export type ModelAlias = keyof typeof MODELS;
```

- [ ] Failing test: `no-pinned-models` scans `.github/workflows/*.yml`, `templates/pipelines/*.json` and `scripts/**/*.sh` for `claude-(opus|sonnet|haiku)-[0-9a-z.-]+` and fails for any ID not in `Object.values(MODELS)`. The test lists the offending file and line.
- [ ] Replace the three pinned strings. Each replacement is a model change, so it must pass the Phase E ratchet before it ships to the default path. Until Phase E exists, the replacements land behind the routing table's `incumbent` flag and do not change the default route.

Note on the current Claude 5 family: `claude-opus-5-5` is the default; `claude-sonnet-5-5` and `claude-haiku-5-5` are the current Sonnet and Haiku (checked against the Claude API model table, cached 2026-10-06). Opus 5.5 defaults to effort `medium`, so every route sets `output_config.effort` explicitly. Opus 5.5, Sonnet 5.5 and Haiku 5.5 reject `budget_tokens` (400) and reject `{type: "disabled"}` for thinking (400 on Opus 5.5 and Sonnet 5.5; Haiku 5.5 accepts it only at effort `high` or below). The routing table therefore sets effort, never thinking-disabled. The Agent SDK adapter (`src/adapters/agent/agent-sdk-runner.ts`) passes `effort`, `maxBudgetUsd` and `maxTurns`; the plan does not send thinking configuration directly, because the Agent SDK is the transport (ADR-0003). Whether the SDK maps `effort` onto `output_config.effort` for each model is a Wave 0 verification item and must be confirmed against the SDK version pinned in `package.json` before Phase D ships.

### Task D2: Versioned routing table (pure)

**Files:**
- Create: `src/contexts/intelligence/domain/routing.ts`
- Test: `src/contexts/intelligence/domain/routing.test.ts`

Incumbent table, `routing-v1` (initial values; they are the incumbent and are changed only through the Phase E ratchet, and the budgets are placeholders until Phase D's cost data exists):

| Tier | Build model | Build effort | Verifier model | Verifier effort | Max iterations | Budget per run (USD, placeholder) |
|---|---|---|---|---|---|---|
| trivial | `sonnet` | `medium` | `sonnet` | `high` | 4 | 2 |
| small | `opus` | `high` | `opus` | `high` | 10 | 8 |
| medium | `opus` | `xhigh` | `opus` | `high` | 20 | 20 |
| large | `opus` | `xhigh` | `opus` | `xhigh` | 30 | 40 |

Haiku is used for `decide` tasks (triage, difficulty explanations) only, at effort `low`, following spec §5.

- [ ] Failing test: `routeFor("trivial")` returns the `sonnet` build route; every route names an effort; no route uses `haiku` for `build`; the version string is `routing-v1`.
- [ ] Implement as a `const` table validated by a function that refuses a missing effort at module load (a test, not a runtime path).

### Task D3: Difficulty estimate (pure)

**Files:**
- Create: `src/contexts/intelligence/domain/difficulty.ts`
- Test: `src/contexts/intelligence/domain/difficulty.test.ts`

Inputs: labels, body length, the number of file paths mentioned in the body, whether acceptance criteria are present, and up to 20 prior runs for similar issues from the ledger (template, outcome, cost). Output: `{tier, reasons}`. Rules are fixed and written down in the test file. A `docs`-only label or a body under 800 characters that names one file gives `trivial`. The history can only move a tier up: if similar runs of this kind failed twice or more, the tier rises by one. Tests cover the one-line docs change (must be `trivial`), an issue naming ten files (`medium` or higher), and a history that raises a tier but never lowers it.

### Task D4: Cost capture and the CI budget source

**Files:**
- Modify: the pipeline stage runner path that records usage (after Phase A, usage is written as `agent_call` ledger entries; before that, read the existing `costs.json` entries)
- Test: `src/contexts/intelligence/application/budget-from-ledger.test.ts`

- [ ] **Step 1:** Confirm which usage fields the `claude` CLI emits with JSON output in CI. This is an open question (Q6). Do not assume a field name. Verify with one sandbox run that costs a small amount (approval required; see Q4).
- [ ] **Step 2:** `budget check` reads the ledger's `agent_call` costs for the UTC day in addition to the local `costs.json`, and takes the larger of the two so that a missing local file cannot understate spend (fail closed).
- [ ] **Step 3:** Test: a day with ledger spend above the cap blocks; a day with an unreadable ledger blocks; a day with no entries and a readable ledger allows.

---

## Phase E: eval set, replay, behavioural ratchet

**Exit criteria**
1. At least 24 cases (6 trivial, 10 small, 6 medium, 2 negative cases where the correct outcome is escalation), each with a split label (`dev` or `holdout`). Holdout is used only to gate a change.
2. Replay of the incumbent (`routing-v1`) over the holdout with k=3 produces pass^3, cost per success and median time, all written to `evals/ratchet/incumbent.json`.
3. The ratchet rejects a candidate that is within the noise threshold (3 percentage points) and not cheaper. It accepts a candidate that beats the incumbent on holdout pass^3 by more than 3 points, or ties it and reduces cost per success by at least 10%.
4. The ratchet runs as a required PR check on any change under `src/contexts/intelligence/`, `templates/pipelines/`, `.github/workflows/shipwright-pipeline.yml` or `evals/`. A PR may not change both `evals/` and the policy.

### Task E1: Eval case format and the corpus

**Files:**
- Create: `evals/delivery/README.md` (format; it is the only doc in this directory)
- Create: `evals/delivery/cases/<id>/{issue.md,base.sha,reference.diff,oracle.json,meta.json}`

`oracle.json`: `{ "testCmd": "...", "mustPass": ["..."], "forbiddenPaths": ["..."] }`. `meta.json`: `{ "tier": "trivial|small|medium|large|negative", "split": "dev|holdout", "source": "PR #NNNN" }`. Cases come from merged PRs in this repository, labelled by a human (spec §6.3 calibration, about 20 PRs). The one-line docs change that ran 2.5 hours is case `docs-oneliner-01`; it is in `dev`.

- [ ] A test in `tools/eval/cases.test.ts` checks that each case has the six files, that `split` is `dev` or `holdout`, that the tier counts meet the exit criteria, and that `oracle.json` names at least one `mustPass` test. The test reads files and so lives in `tools/`, which may do I/O.

### Task E2: Scoring and the ratchet rule (pure)

**Files:**
- Create: `src/contexts/learning/domain/eval-score.ts` (pass^k, cost per success, rework proxy)
- Create: `src/contexts/learning/domain/ratchet.ts` (accept or reject)
- Test: `src/contexts/learning/domain/ratchet.test.ts`

Definitions:
- `pass^k` for a case: 1 if all k runs pass, else 0. Suite value: the mean over cases.
- Rework proxy: a run passes and its diff is at most 2× the reference diff's lines and touches no forbidden path.
- Cost per success: total cost of all runs ÷ number of passing runs (infinite if none pass).

Ratchet table tests (outcome-based): candidate 0.80 vs incumbent 0.78 → rejected (within 3 points, cost not lower); candidate 0.84 vs 0.78 → accepted; equal pass with cost 10% lower → accepted; candidate with a forbidden-path touch in any holdout run → rejected regardless of score.

### Task E3: Replay harness

**Files:**
- Create: `tools/eval/replay.ts`
- Test: `tools/eval/replay.test.ts` (uses a scripted fake runner; no model calls)

The harness creates a worktree per case at `base.sha`, runs the delivery loop with the policy's model, effort and iteration cap, collects the ledger entries for each run id, and applies the oracle (`mustPass`, `forbiddenPaths`). Until the delivery context exists, it drives the bash `shipwright loop` with `--model`, `--max-iterations` and effort flags, and reads results from the ledger. Real replays cost money: never run them in PR CI. PR CI runs the scripted replay only.

### Task E4: CI ratchet check and nightly replay

**Files:**
- Create: `tools/eval/ratchet.ts` (reads `evals/ratchet/incumbent.json` and a candidate result file; exits 0 accept, 1 reject, 2 usage)
- Create: `evals/ratchet/incumbent.json`
- Modify: `.github/workflows/test.yml` or a new `.github/workflows/eval-ratchet.yml` (PR check; path-filtered as in exit criterion 4)
- Create (later, with approval): nightly replay workflow with a budget cap, modelled on `.github/workflows/shipwright-optimize.yml`

- [ ] `CODEOWNERS`: `evals/` and `evals/ratchet/` owned by the maintainer, like `tools/arch/` (ADR-0008).

### Task E5: Gated optimizer (the one learner, restricted)

**Files:**
- Create: `src/contexts/intelligence/domain/fit-routing.ts` (pure: from ledger-derived per-tier statistics, propose a candidate `routing-v{n+1}`)
- Test: `src/contexts/intelligence/domain/fit-routing.test.ts`

The optimizer proposes; it never ships. Its only output is a candidate table, which must pass the Task E4 ratchet on holdout. It may lower a tier's iteration cap or budget when the ledger shows the cap is never reached by passing runs; it may not raise any cap or budget above the incumbent, and it may not add a model. This keeps it inside ADR-0007.

---

## Phase F: independent verifier by default

**Exit criteria**
1. The `verify` stage runs in every template that builds code (`fast`, `hotfix`, `standard`, `full`, `tdd`, `deployed`, `enterprise`, `autonomous`). It is skipped only when a template says so explicitly and the skip is in the ledger.
2. The verifier runs the oracle's test command itself. It does not trust the builder's test report.
3. The verifier receives the issue text (as data), the diff and its own test output. It does not receive the builder's transcript or reasoning.
4. A `gap` verdict returns the run to build and counts against the fix-loop cap of 3 (ADR-0007). It cannot loop forever.
5. The E ratchet shows verifier-on is at least as good on holdout (pass^3 and rework proxy), or the verifier is not made default.

### Task F1: Verdict domain and the stage

**Files:**
- Create: `src/contexts/quality/domain/verdict.ts`, `src/contexts/quality/domain/verdict.test.ts`
- Modify: `templates/pipelines/fast.json` (add `verify` after `test`; the current `review` stays disabled), and the other templates listed above

The verdict schema is per criterion: `{id, verdict: "pass" | "gap", evidence}`. The verifier call uses structured output (`output_config.format` through the Agent SDK's schema option) and does not use forced tool choice: Opus 5.5, Sonnet 5.5 and Fable 5.1 reject `tool_choice` `any` or `tool` with 400, so the verifier relies on `auto` with a read-only allowlist and strict tool schemas.

### Task F2: Verifier use case and the fix-loop bridge

**Files:**
- Create: `src/contexts/quality/application/verify.ts` (the spec §6.3 evaluator, minimal form if the evaluator is not yet built; reconcile with it before merging)
- Test: `src/contexts/quality/application/verify.test.ts` (scripted fake `AgentRunner`)

Tests: a builder that claims tests pass while the verifier's own run fails gets `gap`; a gap sends the run to build; a fourth gap escalates (`escalated` outcome in the ledger). The fake `AgentRunner` is in `src/testing/`.

---

## Phase G: retire or prove the legacy intelligence

Each item is either **retired** (its reads and writes are deleted, the command becomes a "removed" stub that names its replacement, per spec §7.5), or **kept** (only if the Phase E ratchet shows a gain, recorded in the ledger). Entries follow the baseline table above.

| # | Item | Decision | When | Evidence needed |
|---|---|---|---|---|
| G1 | `loop-tuning.json` read (`sw-loop.sh:684–698`) | **Retire now.** It has no writer; the read path can never fire. | Any phase | Repo search (done in this survey) |
| G2 | `iteration-model.json` and its readers (`sw-self-optimize.sh`, `pipeline-execution.sh:231–243`, `sw-loop.sh:702–708`, `pipeline-intelligence-scoring.sh:21`) | **Replace** with the fitted routing table (E5). | After E | Ratchet result of routing-v2 against routing-v1 |
| G3 | `template-weights.json` (`sw-self-optimize.sh:268–282`, `daemon-triage.sh:421–422`) | **Replace** with difficulty tiers and the per-tier template. | After D and E | Ratchet result |
| G4 | UCB1 model selection (`sw-self-optimize.sh:693–899`, `pipeline-execution.sh:696`) | **Retire** unless E shows it beats the fixed route on holdout. Spec §7.5 already lists bandits as not ported. | After E | Ratchet result |
| G5 | Memory injection (`sw-memory.sh`, `loop-iteration.sh`) | **Ablate** in E: a run with injection off is a second arm. Keep only if pass^3 gains beyond noise. | In E | Ablation result |
| G6 | Outcome feedback learned rules (`scripts/lib/outcome-feedback.sh`) | **Ablate** the same way, after confirming where its output is read (not confirmed in this survey). | In E | Readers confirmed; ablation result |
| G7 | `sw-stall-detector.sh` | **Retire** after C (the TS detector replaces it; it is not wired into any workflow). | After C | C's exit criteria met |
| G8 | File heartbeat (`sw-heartbeat.sh`) and the CI timer as liveness | **Retire** the liveness role after C; the timer may remain as "alive" for humans. | After C | Watchdog test |
| G9 | Loop circuit breaker on line counts (`sw-loop.sh:124–125`, `loop-convergence.sh:66–100`) and stuckness restart (`sw-loop.sh:2556`) | **Replace** with C's progress verdict; keep the line-count rule only as a backstop with a test. | After C | C's exit criteria met |
| G10 | `auto_template` lead-time rule (`daemon-poll.sh:315`) | **Replace** with difficulty tiers. | After D | Ratchet result |
| G11 | `sw-predictive`, `sw-intelligence` AI triage, `sw-adaptive`, `scripts/lib/adaptive-model.sh` | **Retire** (spec §7.5 don't-port list). Aliases become "removed" stubs. | After E | Decision D1 approved |
| G12 | `sw-dora` | **No behaviour change.** It reports. It becomes a ledger reader in observability (Wave 3). | Wave 3 | — |

`docs/plans/port/progress.json` gets an entry for each retired or replaced command, with the replacement named in the `notes` field.

---

## Phase H: read-only evaluator territory, holdout scenarios, GitHub twin (R1 to R3)

**Why now:** the Phase E ratchet is only as honest as its inputs. If the build agent can read the holdout set, or can change `routing.ts`, `models.ts` or a check, a passing score means nothing. Until H1 and H2 are tested, the Phase E ratchet runs in advisory mode and cannot block a merge.

**Exit criteria**
1. A build run cannot read a holdout scenario or write a protected surface, and the attempt is recorded as a `fence_violation` in the ledger. Tested with a scripted agent that tries both.
2. The static rule fails when a build `TaskSpec` points into a protected path.
3. Each issue's score is the fraction of its scenarios satisfied, averaged over k runs. The ratchet gate stays pass^k.
4. The GitHub twin passes the same contract suite as the real `gh` adapter, and the nightly contract run against real GitHub is green.

### Task H1: Protected surfaces and the static rule

**Files:** `tools/arch/protected-surfaces.ts` (tool, may read files), `tools/arch/protected-surfaces.test.ts`, `evals/**` and `.github/CODEOWNERS` entries.

Protected surfaces (never writable by an agent run): `evals/**`, `src/contexts/intelligence/domain/routing.ts`, `src/contexts/intelligence/domain/models.ts`, `src/contexts/learning/domain/ratchet.ts`, `tools/arch/**`, `tools/eval/**`, `src/testing/contracts/**`, `.github/CODEOWNERS`, and the ledger directory.

- [ ] Failing test: a `TaskSpec` fixture with `cwd` inside a protected path fails the rule, and the message names the path and the fix ("build runs take a copy of the base commit with protected paths removed; see H2").
- [ ] Implement as a function over a list of configured task specs (the orchestrator exports them), so the rule tests real configuration, not source text.

This static rule catches configuration mistakes. It does not stop a running agent; H2 does that.

### Task H2: Runtime fence (the enforcement that matters)

- [ ] **Step 1: Worktree without protected paths.** The build worktree is made from `git archive <base.sha>` with protected paths excluded into a fresh directory with no `.git` directory. The agent cannot read or change the excluded paths because they do not exist in its directory. This is the fence; it is not a permission setting.
- [ ] **Step 2: Holdout outside the repo.** Holdout scenarios live in a directory owned by the eval runner, outside every worktree. Only the verifier's sandbox (Phase F and H3 scoring) receives a read-only mount of it. The build sandbox never receives the mount.
- [ ] **Step 3: Second layer.** A `PreToolUse` denylist on `Read`, `Edit`, `Write` and `Bash` for the protected path names, as the spec §5 already requires for test paths. The denylist is advisory; Step 1 and Step 2 are the enforcement.
- [ ] **Step 4: Test.** A scripted fake agent (in `src/testing/`) attempts to `cat` a holdout scenario, to edit `routing.ts`, and to write `evals/...`. Expect: the first two fail because the paths do not exist in its worktree; the third is denied; three `fence_violation` entries are in the ledger; the run's outcome is recorded as `failed` with reason `fence`.
- [ ] **Step 5: Judgement, stated plainly.** On macOS the OS sandbox (Seatbelt) is the second layer and its behaviour under this layout must be confirmed on a real machine before H2 is accepted. On CI the container boundary is the enforcement (spec §5, "Tools run in the SDK's OS sandbox ... in a container on M2/M3 workers and in CI"). The plan does not claim either is proven yet.

### Task H3: Holdout scenarios and satisfaction scoring

**Files:** `evals/delivery/scenarios/<case-id>/s-NN.md` (outside the build worktree; in the runner's private store, see H2 Step 2), `src/contexts/learning/domain/satisfaction.ts`, its test.

- Each scenario is a user-level story with observable checks written in plain language (what the user does, what they should see). Scenarios are written by a human for each case in `holdout`; they are not generated by the build agent.
- A verifier (read-only, separate from the builder, Phase F) judges each scenario `satisfied` or `not satisfied` from the diff, the test output and the running app where available. Structured output, one verdict per scenario.
- Issue score = satisfied ÷ total scenarios. Suite satisfaction = mean over cases and k runs. Reported next to pass^k.
- Judgement: LLM-judged scenarios are noisy. Calibrate the judge against a human-labelled sample (the spec §6.3 calibration set) before any satisfaction number gates a change.

**Test:** a fixture of 3 scenarios with 2 satisfied scores 0.667; a case with zero scenarios is refused, not scored 1.0.

### Task H4: GitHub digital twin behind the existing ports

**Scope rule:** the twin implements only the `gh` surface Shipwright uses. The surface is enumerated first, not assumed.

- [ ] **Step 1: Enumerate.** Grep every `gh` call in `scripts/` and `src/`, and every workflow `gh` call, into `docs/reference/gh-surface.md` (generated by `tools/docs/` in a follow-up, or by hand in this task). Expected categories: issues (get, list, create, edit, comment, close, labels), PRs (list, create, view, checks, review state, merge), check runs, workflow runs (list, view, cancel, dispatch), and label listing. The count of distinct subcommands is an open item until this grep is done.
- [ ] **Step 2: Port shapes.** The twin implements the existing ports, not a new interface: `RunHistory`, `PauseLabel`, `PullRequests`, `OpenIssues` (`src/contexts/orchestration/ports.ts`), `IssueTracker` (`src/shared/kernel/ports.ts`), and `GithubWriter` (`src/contexts/integrations/ports.ts`; confirm the file before implementing). F10 still holds: writes go through the writer port, and the twin is one more implementation of it.
- [ ] **Step 3: Adapter.** `src/adapters/github/twin/` backed by files under the test state directory (`createTestEnv()`), with a fixed clock and deterministic ids, so replays are reproducible.
- [ ] **Step 4: Contract.** `src/testing/contracts/github-contract.ts` runs against the twin on every PR (`bun test`) and against the real `gh` adapter in the nightly sandbox job (Q3). A divergence is a failing test on the twin, not a note.
- [ ] **Step 5: Use.** Phase E replays run against the twin, so they are offline and cost no GitHub rate limit. Model calls still cost money; the twin removes only the GitHub cost. This also serves M1 local mode, where there is no shared GitHub state to test against.
- [ ] **Judgement, stated plainly:** a twin is only as faithful as its contract. Drift is the main risk, which is why Step 4 runs nightly against the real service.

---

## Phase I: merge policy, review, specifiability, quality metrics (R6 to R8, R5 review)

**Default: lights-on.** The factory opens the PR; a human merges. Nothing in this phase changes that until the metrics in I4 show it is safe for a named tier.

### Task I1: Risk tiers (pure)

**Files:** `src/contexts/quality/domain/risk-tier.ts`, its test.

Inputs: paths touched (protected or not; `.github/workflows`, auth, migrations, dashboard, config as high-risk), number of contexts or packages touched (blast radius), diff size, whether the change is reversible (a revert is a clean commit), the verifier verdict, and scenario satisfaction (H3).

Output: `T0` (docs or tests only, small, verifier pass, satisfaction 1.0, no high-risk path), `T1`, `T2`, `T3` (never auto-merged). Auto-merge is allowed only for T0, and only with evidence attached to the PR: the oracle test log, the verifier verdict JSON, the scenario verdicts and the ledger run id.

- Test: a docs-only diff with a verifier pass is T0; the same diff touching `.github/workflows` is not T0; a protected-path touch is T3 whatever the size.
- Judgement: the thresholds are initial values. They are backtested on the ledger after 30 days of lights-on history before any auto-merge is enabled.

### Task I2: Review scaled to complexity, with repository knowledge

- Review effort is a function of the tier: T0 gets the verifier only; T1 and above get a second independent review with `effort` from the routing table.
- The reviewer receives a repository context file (the fitness rules, the ADR list, the conventions in AGENTS.md) as data in the user turn, not in the system prompt (AGENTS.md safety rule).
- Judgement: no evidence in this plan shows this improves review quality. It is measured in I5, not assumed.

### Task I3: Specifiability gate at intake

- Score each issue with a `decide<T>` call (Haiku, effort `low`, zod schema): acceptance criteria present; scope bounded (named files, contexts or a clear area); not a title-fingerprint duplicate of an open issue (the spec §6.2 check, already in `intake check`).
- Below threshold: post one clarifying question (through the `GithubWriter` port, F10) or refuse with the missing items listed. Never build.
- Test: an issue with no acceptance criteria and an unbounded scope is refused; a bounded issue with criteria passes; a near-duplicate is refused.
- Judgement: the threshold and the scoring prompt are not evidence-backed yet. They are calibrated against the labelled eval cases (Phase E), with the refusal rate reported.

### Task I4: Quality metrics written to the ledger and the dashboard

Derived from the ledger plus GitHub state (twin in tests, real GitHub in CI):

| Metric | Definition | Source |
|---|---|---|
| Merged without substantial rework | Agent PR merged, with no human commits to the agent branch and no revert or reopen within 14 days | PR events, ledger `outcome` (extended with `merged_at`, `reverted`) |
| Escaped defects | Issues labelled as bugs and linked to an agent PR within 14 days of merge | Issue labels and links |
| Reverts | Agent commits reverted | Git history |
| Cost per merged PR | Sum of `agent_call` cost for the run ÷ merged PRs | Ledger |
| Time to merge | PR open to merge, excluding time waiting for a human who has not yet looked | PR events |

- Test: a fixture history with one reworked PR and one clean PR gives 50% merged without rework. The formula is in the test.
- The dashboard view belongs to Wave 3 (observability). This phase writes the metrics; it does not build the view.
- Note: this is the spec §8 operational scorecard; this phase makes it real.

### Task I5: Track review quality as models change

- Add seeded defects to a subset of eval cases (a known bug injected into a reference diff). The reviewer's catch rate on seeded defects is measured per model version.
- Changing the review model or effort is a routing change, so it goes through the Phase E ratchet with catch rate as a required non-regression metric.
- Judgement: this is a plain measurement. No external catch rate is assumed.

---

## Phase J: self-improving harness, gated (R5; optional, last)

**Preconditions (all required):** Phase E ratchet enforced (not advisory); Phase H fence tested on the real runner; Phase I metrics running for at least 30 days; the maintainer approves the editable surface.

**Honest expectation:** ModularRSI reports gains on benchmarks; nothing here shows the approach helps Shipwright. Phase J is a bet that can be cut without affecting A to I.

### Task J1: Traces as files, with root-cause summaries

- Each run writes a directory `traces/<run-id>/` containing the ledger lines for the run (including `tool_call` and `handoff`), the stage outputs, and `root-cause.md` (written by a `decide<T>` summariser, schema-validated, from the trace only).
- The proposer reads these files. It does not read the eval holdout (H2 fence).

### Task J2: Proposer over an explicit editable surface

- Editable surface, and nothing else: `prompts/**` for stages, `skills/**`, tool descriptions in the adapter, and numeric values in `routing.ts` within their existing caps.
- Not editable: evals, ratchet, tests, arch rules, `models.ts`, budgets above the incumbent, protected paths (H1).
- Each proposal must state a hypothesis, the predicted effect on named failures, and the target failure ids. A proposal without them is refused by the schema.

### Task J3: Gate: held-in and held-out

- Held-in: the dev-split cases where the targeted failure occurred. Held-out: the holdout split.
- Accept only if the held-in set improves and neither set regresses beyond the noise threshold (3 points) on satisfaction and pass^3. This is the Phase E ratchet with a second set.
- Every rejected proposal is logged as a `decision` entry with the reason. The log is the archive.

### Task J4: Archive, not one lineage

- Keep all candidates with their scores and the edit that produced them. The next proposal samples from the archive, weighted by holdout score, and spreads over edit surfaces so the search does not collapse onto one kind of change.
- Judgement: the sampling rule is a design choice, not evidence-backed.

### Task J5: Human review at decision points

- Any edit that changes routing tier structure, adds a model, or changes a cap goes to the maintainer through CODEOWNERS. Prompt and skill edits that pass the gate may be accepted by the maintainer in batch.
- Weng's open-problems list (as reported in secondary coverage) includes reward hacking. The protections are H1 to H3 and this human step. They reduce the risk; they do not remove it.

---

## Verification on GitHub (end to end)

Real GitHub runs write issues, labels and comments. Running them on `sethdford/shipwright` itself would create incidents and touch real work. Every end-to-end check below runs on a **disposable sandbox repository**, which needs the maintainer's approval (Q3). Each check states the observable that proves it.

**Phase A (ledger in CI)**
1. Dispatch `shipwright-pipeline.yml` on a sandbox issue with a trivial change.
2. Expect: the run's `ledger/<run-id>.jsonl` exists on the `shipwright-data` branch after the run, its last line is an `outcome` entry, and `shipwright ledger verify` on a fresh checkout exits 0.
3. Expect: a second concurrent run does not remove the first run's ledger file (check the branch's history for a fast-forward, not a force push).

**Phase B (classifier stops the 288-run loop)**
1. In the sandbox only, set `CLAUDE_CODE_OAUTH_TOKEN` to an invalid value. Label one sandbox issue for dispatch.
2. Expect: the pre-flight fails once; auto-retry's category is `AUTH`; no further run is dispatched for that issue; the issue carries one "Pipeline Auth Failure" comment. Count the runs: exactly one.
3. Restore the sandbox token. Expect the next dispatch to pass the pre-flight.
4. Replay: `shipwright failure classify` on three copies of the failing log with `--attempts` set to the previous attempts must escalate on the first.

**Phase C (stall is caught, not healthy)**
1. In the sandbox, label an issue whose requirement cannot be met by the test suite (for example, a required test that asserts an impossible value). This is a stub, not a real issue.
2. Expect: the loop marks the run `stalled` within 3 iterations (`SHIPWRIGHT-PROGRESS` markers show no progress after iteration 1). The watchdog's report for the run says `stuck` on the progress age, not `healthy` on the heartbeat, and it cancels after 45 minutes of no progress.
3. Compare with the baseline: the same stub on `main` runs until the watchdog's 2 h abandon.

**Phase D (routing and cost)**
1. Expect: the ledger's `decision` entry for the run names `difficulty-v1`, the tier, `routing-v1`, the model `claude-opus-5-5` or `claude-sonnet-5-5` as routed, and the effort set explicitly.
2. Expect: `tools/models/no-pinned-models.test.ts` passes on the branch.

**Phase E (ratchet)**
1. Open a PR that changes `routing.ts` to a weaker route. Expect: the `eval-ratchet` check fails with the candidate and incumbent numbers. Close the PR without merging.
2. Expect: the nightly replay (after approval) uploads its results as an artifact and updates nothing in git.

**Phase F (verifier)**
1. Expect: a run with a builder that claims success over a failing test ends with a verifier `gap`, the run returns to build, and a fourth gap produces an `escalated` outcome.

**Phase G**
1. Expect: each retired command still runs as a "removed" stub that names its replacement, and `docs:check` passes.

**Dark-factory additions (Phases H to J):**
- *Phase H:* the static rule (H1) tests configuration; the runtime fence (H2) is the enforcement. A test with a scripted agent shows the fence refusing the holdout read and the protected write, and the ledger records both.
- *Phase H:* holdout satisfaction (H3) is reported beside pass^k. It is not used as a gate until the judge is calibrated against human labels.
- *Phase I:* on the merge path, a T0 auto-merge is attempted only after 30 days of lights-on metrics show the tier's rework and revert rates are acceptable; until then the rule is enforced by the default, not by code.
- *Phase J:* run only after the preconditions in its header are met; a pilot on the dev split must show held-out non-regression before any accepted edit is kept.

---

## Open questions (need the maintainer's decision)

- **Q1 (D1–D3).** Approve the spec amendments: §7.5 (closed-loop learning restricted to the fitted routing table under the ratchet), §2 (a fourth allowed exception), and the Wave numbering. Without Q1 this plan is a proposal only.
- **Q2 (sequencing).** Do Phases A–C run on M1 SQLite before Postgres (Wave 2)? Recommendation: yes. The M2/M3 ledger stays partial until Postgres exists, and the plan says so in each phase.
- **Q3 (sandbox).** May I create a disposable repository (for example `sethdford/shipwright-sandbox`) with a copy of the workflows, and set a sandbox-only invalid token secret for Phase B? Every GitHub write in the verification sections happens there.
- **Q4 (spend).** What cap per night and per week may the eval replays and any CI cost test use? The per-run cost is not yet measured; Phase D sets it. No default is assumed here.
- **Q5 (incident data).** Can you supply the run logs and the `issue-N.log` for the 2.5-hour docs-change run, and the failing pre-flight logs? They are the fixtures for Phases B and C. Without them, the fixtures are synthetic and the plan says so.
- **Q6 (CI cost source).** Which usage fields does the `claude` CLI emit with JSON output on CI? This is verified with one approved sandbox run; the plan does not assume a field name.
- **Q7 (triage model).** Replace `claude-haiku-4-5-20251001` in the CI triage with `claude-haiku-5-5` now? It is a model change, so it needs the ratchet unless you accept it as a non-routing change.
- **Q8 (fast-template model).** The incident report says the `fast` template ran with opus, but `templates/pipelines/fast.json` sets `"model": "sonnet"` in its defaults, and the escalation code defaults to opus (`daemon-failure.sh`). The ledger will record the effective model from now on; it is not known which one the incident run used.
- **Q9 (server-side fallbacks).** The Claude API offers server-side model fallbacks on refusal (`fallbacks`), but the Agent SDK path does not expose them in this repository. Decide whether refusal fallback belongs in the runner (a separate ADR) or is out of scope.
- **Q10 (memory and outcome-feedback).** Confirm where `outcome-feedback.sh`'s learned rules are read before Phase G decides on them.
- **Q11 (sources).** The CRBugBench paper (arXiv 2610.13668) and its figure could not be found. If you have the correct ID or title, the figure can be checked and considered for Phase I5. Until then it is not cited.
- **Q12 (fence).** Approve the runtime fence in H2 (a worktree built from `git archive` without protected paths, and a holdout store mounted only into the verifier). It needs a real-machine test on macOS and a container test on CI before it is accepted.
- **Q13 (scenarios).** Who writes the holdout scenarios for each `holdout` case? They must be human-written (H3); this is a labelling cost.
- **Q14 (twin scope).** Approve the GitHub twin (H4) and its nightly contract run against the sandbox repository (Q3). The `gh` surface is not yet enumerated; Step 1 of H4 does that.

---

## Out of scope (stated plainly)

- No model is trained. "Learning" here means fitting a small table to ledger statistics under a ratchet, plus deterministic rules.
- No reinforcement learning, bandits in production, or online adaptation during a run.
- M2 and M3 share the ledger only after the Postgres adapter (Wave 2). Until then, each machine's ledger is partial and every policy records that it read partial history.
- The eval set measures this repository's own merged PRs. It does not show that the routing transfers to other repositories.
- Human labelling (about 20 PRs for calibration, spec §6.3) is a cost in people's time that this plan cannot remove.
- Automatic merging is not in scope. A human still merges.
- The full port of `sw-loop.sh` and `daemon-failure.sh` is the delivery and orchestration contexts' work. This plan only adds the bridges it needs.

---

- No model-trained or self-modifying learner outside the gated Phase J search; no reinforcement learning; no fine-tuning.
- A GitHub twin is not a substitute for the real service: its fidelity is checked by the nightly contract run (H4 Step 4), and any gap is a bug in the twin.
- No claim that the holdout fence (H2) is proven on macOS until it is tested on a real machine.
- The "71.9%" review-catch figure and the CRBugBench citation from the briefing are not used anywhere in this plan.

## Self-review (against the spec, ADRs and AGENTS.md)

Checked on 2026-10-15 against the sources listed at the top.

1. **Placeholders.** Phases A and B have complete code and tests. Phase C has complete domain tests and task-level steps; its exact progress-domain code is left to the implementer because its inputs (real iteration logs) are not available (Q5). Phases D to G are task-level. Each of those phases says what it still needs. Nothing is "TBD"; where a value is a placeholder (budgets in D2), the text says so.
2. **Contradictions with the spec.** D1–D3 are listed at the top rather than hidden. §5's model defaults (`claude-opus-5-5` build, `claude-haiku-5-5` decide) are used. §6.2's "adaptation may not raise caps" is enforced in `decideRetry` and in the Phase E optimizer rule.
3. **Contradictions with the ADRs.** ADR-0005: the ledger goes through `RunJournal` once Wave 1b lands; before then, the JSONL adapter is a stated, temporary adapter. ADR-0007: the breaker still reads GitHub history until local outcomes reach the journal; the plan does not change that. ADR-0008: every bash change is argv-only and ratcheted; the plan says where bash grows (one line in `sw-loop.sh`, one in `daemon-failure.sh`, one in `record_failure`).
4. **Fitness rules.** Domain files import only their own `domain/` (F1): `failure.ts` and `retry.ts` redeclare the kind names, which is why they do not import `AgentFailureKind`. Adapters own zod and `node:fs` (F5). The contract suite lives in `src/testing/`, which F5 allows. Function and file sizes are the implementer's check (F7); `jsonl-ledger.ts` is about 120 lines, comfortably under 300.
5. **Tasks that cannot pass `bun run check`.** Two things must be fixed before implementation: the `ok` re-export at the bottom of `application/ledger.ts` (remove it), and the `validateNewEntry` call inside `JsonlLedger.read` (replace with a `validateRunId` function, noted in A3). Both are called out in the tasks. The `NodeJS.ErrnoException` type may be disallowed by Biome; the task names the alternative.
6. **Paths.** Every path that is cited in this plan was checked to exist on `origin/main`, except the files the plan creates. `docs/safety-runbook.md`, `scripts/ci/bot-comments.sh`, `.github/actions/safety-gates/action.yml`, `.github/CODEOWNERS`, `src/testing/fake-safety-ports.ts`, `src/testing/in-memory-durability.ts` and `src/testing/contracts/durability-fixture.ts` were checked.
7. **Survey claims that were not fully verified.** The table marks them: `convergence.sh` outcome tests, `sw-model-router.sh` (not analysed), `outcome-feedback.sh` readers (not confirmed), `sw-bandit-selector-test.sh` and the cost tests (not read in full), and `sw-lib-daemon-failure-test.sh` (not analysed in detail). These are listed as Q10 or as Phase G evidence.
8. **Model facts.** Model IDs and the thinking and budget constraints were checked against the claude-api skill's model table (cached 2026-10-06). The Agent SDK option names were checked against `src/adapters/agent/agent-sdk-runner.ts`. The SDK's mapping of `effort` is a Wave 0 verification item and is not assumed.
9. **Honesty about the current state.** The plan says that today's classifier has no outcome test, that CI auth failures have no category, that one read path has no writer, that the CI heartbeat is a timer, and that the budget gate is a no-op on CI. Those statements are from source reads, not from running the system.
