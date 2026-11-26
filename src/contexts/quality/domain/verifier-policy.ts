import type { FeatureVector } from "./change-features";

/**
 * When the verifier may stop a PR. Pure.
 *
 * Two kinds of stop, kept apart on purpose:
 * - Hard stops are rules, not predictions: no real change, failing tests, run output in the diff.
 *   They need no calibration and block in `enforce` mode from day one.
 * - A low probability blocks only once the model has earned it: enough labelled PRs of both
 *   outcomes, and a leave-one-out score that beats always guessing the base rate. Until then a
 *   low probability is a warning. This keeps a model trained on a dozen PRs from vetoing work.
 */
export type VerifierMode = "off" | "advisory" | "enforce";
export type Verdict = "pass" | "warn" | "block";

export const GATE_RULE = {
  minExamples: 20,
  minEachOutcome: 5,
  minAuc: 0.7,
  /** Below this probability a trusted model blocks (enforce) or warns (advisory). */
  blockBelow: 0.2,
  /** Below this probability the verifier warns. */
  warnBelow: 0.45,
} as const;

export interface Evidence {
  readonly examples: number;
  readonly merged: number;
  readonly unmerged: number;
  /** Leave-one-out AUC and Brier of the trained model; null when not computable. */
  readonly looAuc: number | null;
  readonly looBrier: number | null;
  readonly baseBrier: number | null;
}

export const NO_EVIDENCE: Evidence = {
  examples: 0,
  merged: 0,
  unmerged: 0,
  looAuc: null,
  looBrier: null,
  baseBrier: null,
};

/** Why the model is not yet trusted to block on probability alone (null when it is). */
export function untrustedReason(e: Evidence): string | null {
  const g = GATE_RULE;
  if (e.examples < g.minExamples) return `only ${e.examples} labelled PRs (needs ${g.minExamples})`;
  if (Math.min(e.merged, e.unmerged) < g.minEachOutcome)
    return `needs at least ${g.minEachOutcome} merged and ${g.minEachOutcome} unmerged PRs`;
  if (e.looAuc === null || e.looAuc < g.minAuc)
    return `leave-one-out AUC ${e.looAuc?.toFixed(2) ?? "n/a"} is below ${g.minAuc}`;
  if (e.looBrier === null || e.baseBrier === null || e.looBrier >= e.baseBrier)
    return "it does not beat guessing the base rate (Brier)";
  return null;
}

/** Rule-based stops, independent of the learned weights. */
export function hardStops(x: FeatureVector): string[] {
  const out: string[] = [];
  if (x.noChange > 0) out.push("no change beyond plans or run output");
  if (x.testsFailing > 0) out.push("the repository's tests fail on this change");
  if (x.runArtifacts > 0) out.push("run output (.claude logs, state or caches) is in the diff");
  return out;
}

export interface Decision {
  readonly verdict: Verdict;
  /** What enforce mode would have done; equals `verdict` in enforce mode. */
  readonly wouldBe: Verdict;
  readonly reasons: readonly string[];
}

function raw(p: number, stops: readonly string[], trusted: string | null) {
  if (stops.length > 0) return { v: "block" as Verdict, reasons: [...stops] };
  const pct = `${Math.round(p * 100)}%`;
  if (p < GATE_RULE.blockBelow && trusted === null)
    return { v: "block" as Verdict, reasons: [`predicted merge chance ${pct}`] };
  if (p < GATE_RULE.warnBelow) {
    const why = trusted === null ? "" : ` (not blocking: ${trusted})`;
    return { v: "warn" as Verdict, reasons: [`predicted merge chance ${pct}${why}`] };
  }
  return { v: "pass" as Verdict, reasons: [] };
}

/** The gate decision for one change. `off` always passes; `advisory` never blocks. */
export function decide(mode: VerifierMode, p: number, x: FeatureVector, e: Evidence): Decision {
  const { v, reasons } = raw(p, hardStops(x), untrustedReason(e));
  if (mode === "enforce") return { verdict: v, wouldBe: v, reasons };
  if (mode === "off") return { verdict: "pass", wouldBe: v, reasons };
  return { verdict: v === "block" ? "warn" : v, wouldBe: v, reasons };
}
