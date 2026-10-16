# 0009. Closed-loop learning: measured, gated, and outside the agent's reach

Status: proposed (draft PR #8588; epic #8587; tranche plan in `docs/superpowers/plans/2026-10-15-wave-2-closed-loop.md`) · Date: 2026-10-15

## Context
Shipwright's retries and self-tuning change behaviour without being measured. The incident record from
2026-10-13 to 2026-10-15 shows three gaps:

- **Silent stalls.** Run 38744601038 (`Shipwright Pipeline #8547`, a one-line docs change) was still
  `in_progress` at 16:39Z, about three hours after it started at 13:39Z. The stall was environmental (E11):
  the loop's test gate inherited real credentials. The gap is that nothing detected it. The CI heartbeat is a
  background timer that posts every 10 minutes whatever the run does, and the watchdog treated it as liveness.
- **Deterministic failures re-run.** 288 runs failed at the pre-flight auth check on 2026-10-14, and they
  were re-run by dispatch and sweep. The CI auto-retry categoriser has no auth category, so an auth failure
  falls through to `BUILD_FAILURE`, the "safest retry strategy". Dispatch's guard recognises the comment text
  "Pipeline Auth Failure", which the pre-flight writes with `|| true`.
- **Contaminated test gate (E11).** The loop's test gate inherited the GitHub and Claude credentials, so
  `scripts/sw-e2e-integration-test.sh` ran a nested real pipeline on each iteration. It filed real issues, switched
  branches in the agent's checkout and deleted `.claude/pipeline-state.md`. The mechanism is [V] from PR #8610, which
  is **open, not merged**; the counts (about 1000 leaked issues, 37 open ones since closed) are [U] and tracked in #8608.
  The fix lives in #8610 (`sw_test_gate_env`, `SHIPWRIGHT_E2E_REAL=1` opt-in). This ADR does not change its code.
- **Unmeasured learners.** `loop-tuning.json` is read by the loop but nothing writes it. `iteration-model.json`,
  `template-weights.json`, UCB1 model selection, the 20% `$RANDOM` A/B and the recruit override all change
  behaviour from data, yet their tests check source text or bookkeeping, not outcomes. UCB1, the A/B and recruit
  set the build model, so the template's model is not what runs.

The approved spec (2026-10-13) already covers most of the response: error fingerprinting and budgets (§6.2),
the don't-port list (§7.5), and delivery evals and a scorecard (§8). The one new item is that spec §7.4 places
a "gated optimizer" in Wave 4; this ADR keeps that timing and defers the fitter (W2-19).

**Evidence, with status as checked on 2026-10-15:**
- **Cost variance.** Bai et al., [arXiv 2604.22750](https://arxiv.org/pdf/2604.22750): cost for one task varies up
  to 30x across runs; models predict their own token use poorly (correlation up to 0.39) and underestimate it.
  [Verified.] The "accuracy peaks at intermediate cost" claim is **not** verified and is not used.
- **Lights-off review.** "(When) Should a Software Factory be Lights-off? Benchmarking Code Review Agents on Bug
  Detection", [arXiv 2610.13668](https://arxiv.org/abs/2610.13668): claude-opus-5 with copilot-cli catches 71.9% of
  bugs in its top-5 comments; opus-4.6 47.7%. [Verified by fetch, with two corrections.] The bugs are
  "human-verified bugs mined from repository history", not injected bugs. The page does not say the two results
  share a harness. The paper reports weaker results on complex or non-local changes and on proprietary
  repositories, which supports keeping merge human by default.
- **Holdout scenarios.** StrongDM's software factory keeps end-to-end scenarios outside the codebase and scores
  "satisfaction" across them, with digital twins of third-party services. [Verified through
  [Willison, 2026-02-07](https://simonwillison.net/2026/feb/7/software-factory/) and secondary coverage.] Transfer
  to Shipwright is a judgement.
- **Harness evaluation.** Weng, "Harness Engineering for Self-Improvement" (2026-07-04). [Read only through
  secondary coverage; the read-only claims are not used as evidence.]
- **Gated self-improvement.** ModularRSI, [arXiv 2609.14857](https://arxiv.org/pdf/2609.14857): a five-module harness
  evolved with restricted scope and contrastive trajectory analysis. [Verified; the paper reports no ablation of
  the contrastive step.] The proposer and gate design in Phase J is a judgement drawn from this line of work.

## Decision
Shipwright adopts closed-loop **measurement and gating**, not open-ended learning. The rules:

1. **Every adaptive decision is written to the run ledger** with its inputs, its policy version and its output.
   The ledger records tool calls, handoffs and fence violations, so an incident can be replayed. It lands in
   Tranche 2 (W2-08 to W2-10); Tranche 1 decisions are logged as they are made in bash and CI.
2. **Difficulty comes from ledger history, never from the model's own estimate.** Budgets are enforced at runtime
   by the orchestrator, and the model is not asked to forecast its cost. A stall stops the run (W2-05, W2-06).
3. **Adaptation can only tighten.** Nothing adaptive raises a retry cap, a budget, a breaker threshold or an
   iteration limit above the incumbent (ADR-0007). **Explicit exception:** difficulty may move a run up one tier
   after a `budget` or `max_turns` failure, because those failures show the run was under-provisioned. The
   exception is bounded to one tier, is recorded in the ledger, and does not change the caps the tier sets.
4. **The evaluator is outside the loop.** Tests, verifiers, the holdout, the ledger, the eval set, the ratchet and
   the routing and model configuration are read-only to the build agent. Enforcement for **eval replays and the
   verifier** is a fence in the runner: the replay worktree is made with `git archive` and without the protected
   paths, and the holdout is mounted only into the verifier. A diff that touches a protected path routes to a human
   tier and is never auto-merged. The full fence for the local build (H2) is deferred to its own plan, because
   macOS and CI behaviour are not yet tested. A static rule checks configured task specs; the fence, not the
   denylist, is the enforcement.
5. **Policy changes ship only through a paired ratchet.** The incumbent and the candidate run on the same cases,
   in the same window, with the same CLI and SDK version, three runs per case, reporting pass^3. Non-inferiority is
   the default (losses minus wins at most 0, and at most one loss). Superiority requires an exact one-sided sign
   test at p ≤ 0.05. A cost-motivated change requires a median paired cost ratio of at most 0.9. Hard vetoes reject
   any fence violation, forbidden-path touch or oracle tampering. With about 24 cases this is a **regression
   tripwire**, not a measurement of superiority; the corpus grows to at least 50 cases before any fitter exists.
   One PR may not change both the evals and the policy.
6. **Satisfaction is a fraction.** An issue's score is the fraction of its holdout scenarios satisfied, averaged over
   the runs. The gate remains pass^3. The holdout lives in a private store fetched only by eval and verifier jobs,
   and it is not in this repository. Scenarios are human-written (Q13, default: the maintainer).
7. **The GitHub twin is deferred.** Its scope is the `gh` surface Shipwright actually uses. It makes replays
   deterministic and offline once it exists, and it does not replace the real service.
8. **Merge is lights-on by default.** The factory opens PRs and a human merges. Auto-merge, if ever allowed, is for a
   named low-risk tier with evidence attached, and only after 30 days of quality metrics. The tiers are deferred.
9. **Specifiability is checked before building.** Intake asks for clarification or refuses when acceptance
   criteria or scope are missing. This is deferred with the merge tiers.
10. **Setup and hermeticity failures are their own classes.** `environment` (setup) is retried at most once and
    then escalates. `contamination` (a run that reached a real service through the test gate, or changed the
    agent's checkout) is never retried, because a retry repeats the real side effects. W2-02 implements both. The
    claim that environment setup is the largest factor in agent success is not verified, and the class is kept
    because the incident record shows setup failures.
11. **Self-improvement is optional and last.** Any proposer may edit only an explicit surface (prompts, skills, tool
    descriptions, routing values within caps). Each edit states a hypothesis and a predicted effect. Edits to tier
    structure, models or caps need maintainer approval. The whole phase is deferred (W2-19).

**Model alias conversion (D-M, needs approval).** Templates move from `claude-opus-5`, `claude-sonnet-5` and
`claude-haiku-4-5` to the aliases in `config/models.json`, which resolve to `claude-opus-5-5`, `claude-sonnet-5-5`
and `claude-haiku-5-5`. Two workflow pins also move: the triage `claude-haiku-4-5-20251001` (to the `haiku` alias)
and the remediation `claude-sonnet-4-20250514` (to the `sonnet` alias). This is a model change for every run that
uses those templates or workflows. It is recorded here so it is not mistaken for a hygiene edit. Default: convert.

What is **not** adopted: reinforcement learning, bandits in production, online adaptation during a run, model
fine-tuning, and any claim from an unverified source.

**Spec amendments.** Most of this is already in the spec. The only item that needs a change is the timing of the
gated optimizer (§7.4), which this ADR keeps in Wave 4 and defers. No change to §2 is needed for Tranches 1 to 3.

### Maintainer decisions (2026-10-16)
- **Sandbox (Q3):** live end-to-end and eval runs move to a private sandbox repo (`sethdford/shipwright-sandbox`);
  deterministic replays run offline against the GitHub digital twin, pulled forward from the deferred list.
- **Holdout (Q13):** cases are mined from merged PRs with linked issues and tests, an LLM drafts acceptance
  scenarios, and the maintainer approves them by PR into a separate private repo (`sethdford/shipwright-holdout`)
  that only the eval and verifier jobs can read. Agents have no GitHub credentials, and this repository's
  `GITHUB_TOKEN` cannot read another private repository.
- **Eval spend (Q4):** paired, change-triggered replays on a stratified subset for policy-changing PRs, a weekly full
  replay, hard runtime caps of $25 per run and $100 per week, sequential early stopping once the sign test is
  decided, prompt caching, and `claude-haiku-5-5` for grading. No fixed nightly schedule.
- **Models (D-M):** every pinned model is in the Claude 5.5 family (#8634); routing becomes deterministic in W2-07.

## Consequences
- Each routing, policy and model change has a measurable answer, once the corpus and the replay exist. Until then
  the ratchet is advisory and cannot block a merge.
- The ledger becomes the single source for cost, outcome and audit. The bash learners it replaces are retired
  behind aliases, not deleted without a trace.
- The replay fence and the GitHub twin are real engineering costs, and the twin's fidelity needs a nightly contract
  run against the real service.
- Adaptive behaviour changes more slowly: every routing edit goes through the ratchet. That is intended.
- Known gaps, stated plainly: the replay fence is untested on macOS and CI; the satisfaction judge is unvalidated
  until calibrated against human labels; the sign test has low power at 24 cases; the Weng claims are unverified;
  and the "accuracy peaks at intermediate cost" claim is not used.
- The decision is reviewed when the first paired ratchet result exists, and at each model release (spec §7.4).
