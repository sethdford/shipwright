# 0018. Outcome-trained critic and adaptive attempts: label by code survival, stop early only when trusted

Status: accepted · Date: 2026-11-26

## Context
The merge verifier (ADR-0012) learns from "merged and not reverted within 14 days". That is a weak label
for an agent's work: a PR can merge and be rewritten line by line the next week without a revert. OpenHands
(2026) reports that a critic trained on benchmark passes ranks real PRs worse than chance, while one trained
on whether the code survives in the codebase reaches an AUC of about 0.69, and that using it to stop adding
attempts once one is clearly good cuts attempts from 8 to about 1.35 at a similar resolve rate.

Two gaps kept our verifier from learning that: history had no execution signals (every historical PR had a
critic feature of 0, so the critic's weight could never move off its prior), and tournament mode always
ran every attempt, with the verifier not wired into it at all.

## Decision
1. **Survival label.** `verify train --outcome survival` (the default) relabels each merged, unreverted PR by
   what survives of it 21 days after the merge (`--survival-days`): the share of its significant added lines
   (not blank, punctuation or bare keywords) still present in the same files at the last base-branch commit
   before the horizon, matched as a multiset. Below 50% is label 0. It is read from local git history
   (`GitSurvivalSource`, read-only). PRs too recent, with fewer than 3 significant lines, or whose commits are
   not in the clone keep the merge label, and the report counts each group. Renamed files count as not
   surviving, which errs toward the stricter label. `--outcome merge` keeps the old label.
2. **Score log.** Every `verify score` appends its signals (own tests, cross-tests, rubric, the critic's chance)
   to `$SHIPWRIGHT_STATE_DIR/verifier/scores.jsonl` under the current branch. Training joins the latest score
   taken on a PR's head branch between 6 hours before it opened and when it closed. A logging failure is a
   note, never an error.
3. **Adaptive attempts.** `shipwright tournament --adaptive off|shadow|enforce` (default `shadow`) and `--stop-at`
   (default 0.8). Each attempt that builds and passes its own tests is probed with the verifier alone (no
   cross-tests or rubric, which depend on other attempts). Shadow runs everything as before and reports where
   it would have stopped, what that would have saved and whether the winner would have been the same.
   Enforce runs attempts one at a time and stops once a probe clears the threshold, but only when the trained
   verifier meets the same evidence bar as blocking a PR (ADR-0012: 20 or more factory PRs, 5 of each outcome,
   leave-one-out AUC 0.7 or more, Brier better than the base rate); otherwise it falls back to shadow and says why.
4. **Wiring.** The tournament gets the verifier (`candidateVerifier`: trained model, no critic, every candidate
   scored under the same conventional title so only diffs and signals differ). `SHIPWRIGHT_VERIFIER=off` unwires it.

## Consequences
- On this repository's history (88 labelled PRs, 2026-11-26) survival changed one label (#8634, 38% of its lines
  left at 21 days); most human PRs survive. Leave-one-out AUC was 0.86 with survival labels and 0.88 with merge
  labels over all PRs, and 0.60 on the 13 factory PRs either way: not trusted, so nothing blocks or stops early.
  The label matters more as the factory's own merged PRs accumulate, which is the population it is for.
- Turning `--adaptive enforce` on by default is a policy change for the ratchet (ADR-0009 rule 5); shadow reports
  are its evidence. Trajectory features (turns, test-fix loops, cost) are not in the model yet: history has
  none, and the score log is the place to add them.
