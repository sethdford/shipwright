# 0012. A learned merge verifier, gated by its own calibration

Status: accepted
Date: 2026-11-26

## Context

Of the pipeline's closed PRs, 10 of 12 never merged (diagnosed 2026-11-26): run logs in the diff,
model chatter as titles, "already implemented" runs, plan-only changes. Each was visible before the
PR opened. The tournament (#8744) picks the best of N attempts but has no notion of "none of these
should ship", and nothing predicts whether a change will merge.

Research points one way. Outcome verifiers that rank candidate patches beat single attempts on
SWE-bench, and hybrids win: execution-based signals (tests, cross-tests) and execution-free ones
(a learned or prompted judge) fail differently (R2E-Gym 2025, SWE-Gym 2024). LLM-as-judge gives
useful rankings but overconfident probabilities, so its stated confidence must be calibrated
before it is trusted. And with about a dozen labelled factory PRs, a purely learned model is noise.

## Decision

`shipwright verify` (quality context) is a logistic model over features of the change: diff size
and spread, run output, plan-only changes, CI or test-config edits, tests added or weakened,
chatter in the title or summary, a conventional title, and, when a run measured them, its own tests,
the cross-test pass rate, the rubric score and a prompted critic's chance. The weights start as a
hand-set prior (a rubric written as weights). `verify train` fits them to the repository's closed
PRs by MAP logistic regression with a Gaussian prior centred on that rubric, so a dozen PRs barely
move it and hundreds dominate it. Human PRs help the fit at half weight; a `factory` offset learns
the factory's own base rate.

Blocking is split. Hard stops are rules (no real change, failing tests, run output in the diff) and
block in `enforce` mode at once. A low predicted chance (below 20%) blocks only once the model is
trusted on the factory's own PRs, measured leave-one-out: 20 or more labelled, 5 of each outcome,
AUC 0.7 or more, and a Brier score below the base rate's. Until then it warns. The pipeline calls
the verifier before `gh pr create` in `advisory` mode by default (`SHIPWRIGHT_VERIFIER`), and the
tournament can call `scoreCandidate` per finalist.

## Consequences

- The gate earns its authority from data: `verify train` prints when it becomes trusted.
- On today's history (68 PRs, 12 from the factory) the trained model beats the prior on all PRs
  (leave-one-out Brier 0.110 vs 0.189, base rate 0.215) but is not trusted for factory PRs (2 merges).
  The hard stops alone flag 10 of the 12 factory PRs, including 9 of the 10 that never merged.
- Critic scores are not yet recorded for history, so the critic's weight stays at the prior until
  runs log them. Recording verifier scores with each run's outcome is the next step (W2-08 ledger).
- A verifier that cannot run never blocks: it is a quality signal, not a safety gate (ADR-0007).
