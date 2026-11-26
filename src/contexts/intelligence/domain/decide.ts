import { difficultyPrior, tierUp } from "./difficulty";
import type { Tier } from "./features";
import {
  bucketOf,
  countsAsSignal,
  type DecisionInputs,
  type RoutedRun,
  type RouterMode,
  type RoutingDecision,
} from "./records";
import { MAX_ATTEMPTS, POLICY_VERSION, ROUTING_V1, type Route, TIER_ADVICE } from "./routes";

/**
 * The routing decision. Pure: the caller passes history, time and id. ADR-0009 rule 3 holds: the
 * history can only escalate a route (never cheapen it), a budget or max_turns failure moves the
 * retry up exactly one tier, and the budget only ever lowers attempts and caps.
 */

export interface DecideRequest {
  readonly id: string;
  readonly at: string;
  readonly mode: RouterMode;
  readonly issue?: number;
  readonly repo?: string;
  readonly inputs: DecisionInputs;
}

/** History escalates a bucket that failed more than half of at least this many runs. */
export const HISTORY_RULE = { minRuns: 3, maxSuccessRate: 0.5 } as const;
/** Failures that show the run was under-provisioned (ADR-0009 rule 3 exception). */
export const UNDER_PROVISIONED: readonly string[] = ["budget", "max_turns"];

interface Step {
  readonly tier: Tier;
  readonly notes: readonly string[];
}

export function historyStep(tier: Tier, bucket: string, history: readonly RoutedRun[]): Step {
  const runs = history.filter(
    (r) =>
      bucketOf(r.decision.inputs.features.kind, r.decision.difficulty.prior) === bucket &&
      countsAsSignal(r),
  );
  const wins = runs.filter((r) => r.outcome.result === "success").length;
  if (runs.length < HISTORY_RULE.minRuns || wins / runs.length >= HISTORY_RULE.maxSuccessRate) {
    return { tier, notes: [] };
  }
  const up = tierUp(tier);
  return {
    tier: up,
    notes: [`history: ${bucket} succeeded ${wins}/${runs.length}; ${tier} -> ${up}`],
  };
}

function failureStep(tier: Tier, previous: string | undefined): Step {
  if (previous === undefined || !UNDER_PROVISIONED.includes(previous)) return { tier, notes: [] };
  const up = tierUp(tier);
  return { tier: up, notes: [`retry after ${previous} failure; ${tier} -> ${up}`] };
}

const money = (usd: number): string => `$${usd.toFixed(2)}`;

/** Tighten-only fit to the money left today: fewer attempts first, then a lower cap. */
export function fitBudget(
  route: Route,
  remainingUsd: number | undefined,
): { route: Route; notes: readonly string[] } {
  if (remainingUsd === undefined || remainingUsd >= route.budgetUsd) return { route, notes: [] };
  const perAttempt = route.budgetUsd / route.attempts;
  const attempts = Math.max(1, Math.min(route.attempts, Math.floor(remainingUsd / perAttempt)));
  const budgetUsd = Math.max(0, Math.floor(remainingUsd * 100) / 100);
  const notes = [
    `budget: ${money(remainingUsd)} left today; cap ${money(route.budgetUsd)} -> ${money(budgetUsd)}`,
  ];
  if (attempts < route.attempts) notes.push(`budget: attempts ${route.attempts} -> ${attempts}`);
  return { route: { ...route, attempts, budgetUsd }, notes };
}

function applyOverrides(route: Route, inputs: DecisionInputs): RoutingDecision["applied"] {
  const o = inputs.overrides;
  const attempts = o.attempts ?? route.attempts;
  return {
    template: o.template ?? route.template,
    model: o.model ?? route.model,
    effort: o.effort ?? route.effort,
    attempts: Math.max(1, Math.min(MAX_ATTEMPTS, Math.trunc(attempts))),
    budgetUsd: route.budgetUsd,
  };
}

export function decideRoute(req: DecideRequest, history: readonly RoutedRun[]): RoutingDecision {
  const f = req.inputs.features;
  const prior = difficultyPrior(f);
  const byHistory = historyStep(prior.tier, bucketOf(f.kind, prior.tier), history);
  const byFailure = failureStep(byHistory.tier, req.inputs.previousFailure);
  const fitted = fitBudget(ROUTING_V1[byFailure.tier], req.inputs.remainingUsd);
  const spent = req.inputs.remainingUsd !== undefined && req.inputs.remainingUsd <= 0;
  const advice = TIER_ADVICE[byFailure.tier];
  return {
    kind: "decision",
    schema: 1,
    id: req.id,
    at: req.at,
    policy: POLICY_VERSION,
    mode: req.mode,
    ...(req.issue === undefined ? {} : { issue: req.issue }),
    ...(req.repo === undefined ? {} : { repo: req.repo }),
    inputs: req.inputs,
    difficulty: {
      score: prior.score,
      prior: prior.tier,
      tier: byFailure.tier,
      reasons: prior.reasons,
    },
    route: fitted.route,
    applied: applyOverrides(fitted.route, req.inputs),
    adjustments: [...byHistory.notes, ...byFailure.notes, ...fitted.notes],
    action: spent ? "defer" : "build",
    ...(advice === undefined ? {} : { advice }),
  };
}
