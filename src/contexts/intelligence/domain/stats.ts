import { TIERS, type Tier } from "./features";
import type { RoutedRun, RouterMode } from "./records";

/**
 * Per-tier results of routed runs, for `shipwright route stats` and the delivery scorecard.
 * Cost per success is the headline number (total spend over solved runs, as the routing papers
 * report it), so a cheap route that fails often does not look cheap.
 */

export interface TierStats {
  readonly tier: Tier;
  readonly runs: number;
  readonly successes: number;
  readonly successRate: number | null;
  readonly costUsd: number;
  /** Runs with a recorded cost; cost figures cover only these. */
  readonly costed: number;
  readonly costPerSuccessUsd: number | null;
}

export interface RoutingStats {
  readonly runs: number;
  readonly byMode: Readonly<Record<RouterMode, number>>;
  readonly tiers: readonly TierStats[];
  /** Decisions with no outcome yet (still running, or the run died before reporting). */
  readonly open: number;
}

const round2 = (n: number): number => Math.round(n * 100) / 100;

function tierStats(tier: Tier, runs: readonly RoutedRun[]): TierStats {
  const mine = runs.filter((r) => r.decision.difficulty.tier === tier);
  const successes = mine.filter((r) => r.outcome.result === "success").length;
  const costedRuns = mine.filter((r) => r.outcome.costUsd !== undefined);
  const costUsd = round2(costedRuns.reduce((s, r) => s + (r.outcome.costUsd ?? 0), 0));
  return {
    tier,
    runs: mine.length,
    successes,
    successRate: mine.length === 0 ? null : round2(successes / mine.length),
    costUsd,
    costed: costedRuns.length,
    costPerSuccessUsd:
      successes === 0 || costedRuns.length === 0 ? null : round2(costUsd / successes),
  };
}

export function routingStats(runs: readonly RoutedRun[], decisions: number): RoutingStats {
  return {
    runs: runs.length,
    byMode: {
      shadow: runs.filter((r) => r.decision.mode === "shadow").length,
      apply: runs.filter((r) => r.decision.mode === "apply").length,
    },
    tiers: TIERS.map((t) => tierStats(t, runs)),
    open: Math.max(0, decisions - runs.length),
  };
}
