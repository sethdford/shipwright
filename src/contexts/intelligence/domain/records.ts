import type { IssueFeatures, IssueKind, Tier } from "./features";
import type { Effort, Route } from "./routes";

/** One line of the routing log: a decision when a run starts, an outcome when it ends. */

export type RouterMode = "shadow" | "apply";
export type RouteAction = "build" | "defer";

/** What the caller set explicitly; the router never overrides these. */
export interface RouteOverrides {
  readonly template?: string;
  readonly model?: string;
  readonly effort?: Effort;
  readonly attempts?: number;
}

export interface DecisionInputs {
  readonly features: IssueFeatures;
  /** USD left under the daily cap; absent when there is no cap. */
  readonly remainingUsd?: number;
  /** Failure class of the run this one retries, if any. */
  readonly previousFailure?: string;
  readonly overrides: RouteOverrides;
}

export interface RoutingDecision {
  readonly kind: "decision";
  readonly schema: 1;
  readonly id: string;
  readonly at: string;
  readonly policy: string;
  readonly mode: RouterMode;
  readonly issue?: number;
  readonly repo?: string;
  readonly inputs: DecisionInputs;
  readonly difficulty: {
    readonly score: number;
    /** Tier from the issue features alone; the history bucket key. */
    readonly prior: Tier;
    readonly tier: Tier;
    readonly reasons: readonly string[];
  };
  /** The table's route for the final tier, after budget limits; before caller overrides. */
  readonly route: Route;
  /** What the run should use: route values, except where the caller set one. */
  readonly applied: Omit<Route, "tier" | "budgetUsd"> & { readonly budgetUsd: number };
  readonly adjustments: readonly string[];
  readonly action: RouteAction;
  readonly advice?: string;
}

export const OUTCOME_RESULTS = ["success", "failure"] as const;
export type OutcomeResult = (typeof OUTCOME_RESULTS)[number];

export interface RoutingOutcome {
  readonly kind: "outcome";
  readonly schema: 1;
  readonly decisionId: string;
  readonly at: string;
  readonly result: OutcomeResult;
  readonly failureClass?: string;
  readonly costUsd?: number;
  readonly pr?: number;
}

export type RoutingRecord = RoutingDecision | RoutingOutcome;

/** A finished run: its decision joined to its outcome. */
export interface RoutedRun {
  readonly decision: RoutingDecision;
  readonly outcome: RoutingOutcome;
}

/** Joins outcomes to decisions by id; the last outcome for a decision wins. */
export function joinRuns(records: readonly RoutingRecord[]): readonly RoutedRun[] {
  const decisions = new Map<string, RoutingDecision>();
  const outcomes = new Map<string, RoutingOutcome>();
  for (const r of records) {
    if (r.kind === "decision") decisions.set(r.id, r);
    else outcomes.set(r.decisionId, r);
  }
  const runs: RoutedRun[] = [];
  for (const [id, outcome] of outcomes) {
    const decision = decisions.get(id);
    if (decision !== undefined) runs.push({ decision, outcome });
  }
  return runs;
}

/** History bucket: the issue kind and its feature-only tier. */
export const bucketOf = (kind: IssueKind, prior: Tier): string => `${kind}/${prior}`;

/** Runs whose outcome says nothing about difficulty (ADR-0009 rule 10, E11). */
export const NON_SIGNAL_FAILURES: readonly string[] = [
  "contamination",
  "auth",
  "environment",
  "transient",
];

export const countsAsSignal = (run: RoutedRun): boolean =>
  run.outcome.result === "success" || !NON_SIGNAL_FAILURES.includes(run.outcome.failureClass ?? "");
