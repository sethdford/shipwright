# 0009. Closed-loop learning: measured, gated, and outside the agent's reach

Status: proposed (awaiting maintainer approval of spec amendments D1 to D3 in the Wave 2 plan) · Date: 2026-10-15

## Context
The 2026-10 incidents show that Shipwright's retries and self-tuning change behaviour without ever being
measured. Three recorded examples: a one-line docs change ran more than 2.5 hours in the build stage and
reported healthy (the watchdog treats timer heartbeats as liveness); 288 runs failed at the pre-flight auth
check and were retried, because CI's auto-retry has no auth category and falls back to "build failure";
and `loop-tuning.json` is read by the loop but nothing in the repository writes it. The bash intelligence
layer (`classify_failure`, self-optimize, template weights, UCB1 model selection, memory injection) changes
behaviour from data, yet its tests check source text or bookkeeping, not outcomes (survey in the Wave 2 plan).

The approved spec (2026-10-13, §7.5) puts self-optimize, adaptive and bandit learning on the don't-port list
and defers one gated optimizer to Wave 4. This ADR proposes moving a restricted version forward.

External work informs the design. Status of each claim, as checked on 2026-10-15:
- **Holdout scenarios the coding agent cannot read, scored as a satisfaction probability.** StrongDM's
  "software factory" uses end-to-end scenarios kept outside the codebase, and digital twins of third-party
  services. Source: [Willison, "software factory", 2026-02-07](https://simonwillison.net/2026/feb/7/software-factory/),
  read through secondary coverage. Verified as described; transfer to Shipwright is a judgement.
- **Evaluator outside the loop.** Weng, "Harness Engineering for Self-Improvement" (Lil'Log, 2026-07-04).
  Read through secondary coverage only; the specific read-only requirements were **not verified** against
  the original. The principle is kept because it matches ADR-0007 and F9.
- **Runtime budget, not pre-task estimates.** Bai et al., [arXiv 2604.22750](https://arxiv.org/pdf/2604.22750):
  cost for one task varies up to 30x across runs; models predict their own token use poorly (correlation up to
  0.39) and underestimate it. Verified. The claim that accuracy peaks at intermediate cost was not verified and
  is not relied on.
- **Gated self-improving harness.** ModularRSI, [arXiv 2609.14857](https://arxiv.org/pdf/2609.14857): a harness
  split into five modules, evolved with restricted scope and contrastive trajectory analysis. Verified. The
  paper reports no ablation of the contrastive step. The proposer and held-in/held-out gate are a judgement
  drawn from this line of work.
- **Risk-tiered merge and review quality.** A review benchmark figure (CRBugBench, arXiv 2610.13668, "71.9%
  of injected bugs") was **not found** and is **not cited**. [CR-Bench, arXiv 2603.11078](https://arxiv.org/pdf/2603.11078)
  reports low signal-to-noise for review agents that aim to find every issue; it is related context only.

## Decision
Shipwright adopts closed-loop *measurement and gating*, not open-ended learning. Its rules:

1. **Every adaptive decision is written to the run ledger** with its inputs, the policy version and the output.
   The ledger records tool calls, handoffs and fence violations, so an incident can be replayed.
2. **Difficulty comes from ledger history, never from the model's own estimate.** Budgets are enforced at
   runtime by the orchestrator; the model is not asked to forecast its cost. Plateau detection stops runs.
3. **Adaptation can only tighten.** Nothing adaptive raises a retry cap, a budget, a breaker threshold or an
   iteration limit above the incumbent (ADR-0007).
4. **The evaluator is outside the loop.** Tests, verifiers, holdout scenarios, the ledger, the eval set, the
   ratchet and the routing and model configuration are read-only to the build agent. Enforcement is a
   fence in the runner: the build worktree is made without those paths, and the holdout store is mounted
   only into the verifier. A static rule checks configured task specs. The fence is the enforcement; the
   denylist is advisory (judgement, to be tested on macOS and CI).
5. **Policy changes ship only through a ratchet.** A candidate routing table or policy must beat the incumbent
   on the holdout split by more than the noise threshold (3 points), or tie it and cut cost per success by at
   least 10%. The ratchet is a required check, and one PR may not change both the evals and the policy.
6. **Satisfaction is a fraction, not a single pass.** An issue's score is the fraction of its holdout scenarios
   satisfied, averaged over k runs. The gate remains pass^k.
7. **Holdout and twin.** Holdout scenarios are human-written and live outside every worktree. A GitHub twin
   implements the existing ports, is checked by a contract suite that also runs nightly against real GitHub,
   and makes replays deterministic and offline. It does not replace the real service.
8. **Merge policy is lights-on by default.** The factory opens PRs; a human merges. Auto-merge, if ever allowed,
   is limited to a low-risk tier with evidence attached, and only after the quality metrics (merged without
   rework, escaped defects, reverts, cost per merged PR, time to merge) have run for 30 days.
9. **Specifiability is checked before building.** Intake refuses or asks for clarification when acceptance
   criteria or scope are missing.
10. **Environment failures are their own class**, retried at most once.
11. **A self-improving harness is optional and last.** It proposes edits only to an explicit surface (prompts,
    skills, tool descriptions, routing values within caps), records a hypothesis and a predicted effect for
    each, keeps an archive of candidates, and requires human approval for changes to tier structure, models or
    caps.

What is **not** adopted: reinforcement learning, bandits in production, online adaptation during a run, model
fine-tuning, and any claim taken from the unverified sources above.

Supersedes nothing yet. It amends spec §2 (a fourth exception to the no-new-features rule) and §7.5 (the
restricted routing-table fitter replaces the Wave 4 optimizer, and the listed learners stay retired). Both
amendments need maintainer approval.

## Consequences
- Shipwright gains a measurable answer to "did this change help" for each routing, policy and model change.
  Until the eval set and holdout exist, the ratchet cannot run, and the plan says so.
- The ledger becomes the single source for cost, outcome and audit, and the bash intelligence it replaces is
  retired behind aliases, not deleted without a trace.
- The fence and the twin are real engineering costs. The twin's fidelity is a continuing maintenance task.
- Adaptive behaviour becomes slower to change: every routing edit goes through an eval. This is intended.
- Known gaps: the fence is untested on macOS and CI; the satisfaction judge is unvalidated until calibrated
  against human labels; the Weng and CRBugBench claims are unverified; the "accuracy peaks at intermediate
  cost" claim is not used.
- The decision is reviewed when the first ratchet result exists, and at each model release (spec §7.4).
