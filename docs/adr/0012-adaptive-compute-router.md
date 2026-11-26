# 0012. Adaptive compute router: route by difficulty, log every decision, apply only by opt-in

Status: accepted · Date: 2026-11-26

## Context
Every pipeline run gets the same compute: the template's model (mostly Opus), one build attempt, and the
default effort, whether the issue is a README typo or a cross-cutting migration. Easy issues overpay, and hard
ones get no more than easy ones. Tournament mode (#8744) can run 2 to 5 parallel attempts, but only when
someone sets `PIPELINE_ATTEMPTS` by hand.

The bash pieces that tried to adapt are retired or off: Thompson-sampled templates (auto-picking `fast` was
turned off in #8742 because it skipped plan and review), and the UCB1 and A/B model routing behind
`SW_LEGACY_MODEL_ROUTING` (W2-07). The migration spec (§7.5) asks for "a static per-stage model and effort table,
retuned by delivery evals" in the `intelligence` context, and the Wave 2 plan (W2-11) asks for a routing table
whose difficulty comes from history, tightens only, names model aliases and sets effort explicitly.

What the research says, briefly:
- **Allocate test-time compute by difficulty.** Snell et al. (2024) find that choosing the strategy per
  difficulty bin uses about 4x less compute than best-of-N at the same accuracy; easy items do best with
  sequential refinement, hard items with parallel search.
- **Parallel attempts pay only with a good selector.** CodeMonkeys (2025) reaches 69.8% coverage with 10
  parallel attempts on SWE-bench Verified, but selection gets 57.4%; selection is the bottleneck. Tournament
  mode's cross-tests and blind judge are our selector.
- **Prompt-only difficulty prediction is weak.** Scrouting (2026) reports a held-out AUC of about 0.56 from the
  task text; SWE-Router (2026) does better by probing a weak model's first few turns, and finds that an
  escalated run should restart from scratch rather than continue the weak model's trajectory.
- **Report cost per success**, with every component included, not cost per run.

## Decision
Add a `shipwright route` command in a new `intelligence` context, and call it from the pipeline.

1. **Difficulty = a transparent prior, corrected by history.** The prior is a 0 to 100 score from issue text
   and labels (kind, length, files named, acceptance criteria, easy and hard keywords, risky paths, stack
   traces), each weight written in `domain/difficulty.ts`. A size label a person set (`size/M`,
   `difficulty: hard`) wins. The model's own estimate is never an input (ADR-0009 rule 2).
2. **routing-v1 is a static table** (`domain/routes.ts`). Five tiers map to a reviewed template, a model alias,
   an explicit effort, a number of attempts and a run cap: trivial and small get Sonnet and one attempt; medium
   gets Opus at high effort; large and xl get Opus with 3 parallel attempts (tournament mode). xl also carries
   advice to split the issue. The caps are placeholders until the ledger has enough runs for p90 caps (W2-12).
3. **Tighten-only (ADR-0009 rule 3).** History only escalates: a bucket (issue kind and prior tier) that failed
   more than half of at least 3 runs moves up one tier. A success streak never lowers a tier; making routes
   cheaper is a ratchet decision. A retry after a `budget` or `max_turns` failure moves up one tier (the rule 3
   exception); the router finds that failure in its own log by issue number. The daily budget only lowers
   attempts and the cap, and at zero the action is `defer`.
4. **The caller wins.** `--pipeline`, `--model`, `--effort` and `PIPELINE_ATTEMPTS` given by a person are
   passed as overrides and never replaced. Only templates with plan and review are routed to.
5. **Every decision is logged** to `~/.shipwright/routing/decisions.jsonl` with its inputs (features, budget,
   previous failure, overrides), the policy version, the difficulty with its reasons, the route and what was
   applied. The pipeline appends the outcome (result, failure class, cost, PR) when the run ends.
   `shipwright route stats` reports runs, success rate and cost per success per tier, for the scorecard.
6. **Shadow by default.** `SHIPWRIGHT_ROUTER=shadow` (the default) decides and logs but changes nothing, so
   the log collects paired data on the incumbent. `apply` uses the route; `off` skips the router. The router is
   advice, not a gate: if it cannot run, the pipeline goes on with its defaults and an event says why.

## Consequences
- Turning `apply` on by default, or changing a number in routing-v1, is a policy change for the paired ratchet
  (ADR-0009 rule 5); shadow logs give the first evidence for it.
- Outcomes in shadow mode describe the incumbent route, not the routed one. History uses them as a difficulty
  signal only, which is why it can escalate but not cheapen.
- The log is local to each machine, like the cost files. It moves to the run ledger (W2-08) when that lands.
- Known gaps: the feature weights are hand-set and unvalidated (the literature says text alone predicts
  weakly); there is no probe-based escalation yet (a cheap model's first turns as the signal, per
  SWE-Router); and attempts above 1 need tournament mode (#8744) to do anything.
