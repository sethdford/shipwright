import type { Tier } from "./features";

/**
 * The routing table: what each difficulty tier gets. Static and versioned; a change to it is a
 * policy change that goes through the paired ratchet (ADR-0009 rule 5, ADR-0012).
 *
 * Shape of routing-v1, from the test-time compute literature:
 * - Easy work gets one attempt and the cheaper model: sequential refinement (the build loop's own
 *   iterations) is the compute-optimal use of budget on easy items (Snell et al. 2024).
 * - Hard work gets parallel attempts with selection: parallel sampling pays on harder items, and
 *   only when a selector can pick the winner (CodeMonkeys 2025). Tournament mode is that selector.
 * - Every route names a model alias (config/models.json) and an explicit effort, because Opus 5.5
 *   defaults to medium (W2-11).
 * - Only templates with plan and review stages are routed to (#241, #8742).
 * Budgets are per-run placeholders until the ledger has enough runs for p90 caps (W2-12).
 */

export const POLICY_VERSION = "routing-v1";

export const EFFORTS = ["low", "medium", "high", "xhigh"] as const;
export type Effort = (typeof EFFORTS)[number];

export interface Route {
  readonly tier: Tier;
  readonly template: string;
  readonly model: string;
  readonly effort: Effort;
  /** Parallel build attempts; 2 or more runs tournament mode. */
  readonly attempts: number;
  /** Cap for the whole run, in USD. */
  readonly budgetUsd: number;
}

export const ROUTING_V1: Readonly<Record<Tier, Route>> = {
  trivial: {
    tier: "trivial",
    template: "cost-aware",
    model: "sonnet",
    effort: "low",
    attempts: 1,
    budgetUsd: 2,
  },
  small: {
    tier: "small",
    template: "cost-aware",
    model: "sonnet",
    effort: "medium",
    attempts: 1,
    budgetUsd: 5,
  },
  medium: {
    tier: "medium",
    template: "standard",
    model: "opus",
    effort: "high",
    attempts: 1,
    budgetUsd: 12,
  },
  large: {
    tier: "large",
    template: "standard",
    model: "opus",
    effort: "high",
    attempts: 3,
    budgetUsd: 30,
  },
  xl: {
    tier: "xl",
    template: "standard",
    model: "opus",
    effort: "xhigh",
    attempts: 3,
    budgetUsd: 40,
  },
};

/** Advice the pipeline shows with a route. xl work usually goes better split up. */
export const TIER_ADVICE: Readonly<Partial<Record<Tier, string>>> = {
  xl: "This issue looks larger than one PR. Consider splitting it (shipwright decompose) before building.",
};

/** The most attempts the tournament supports (TOURNAMENT_LIMITS.maxAttempts in delivery). */
export const MAX_ATTEMPTS = 5;
