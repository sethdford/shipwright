/**
 * Adaptive attempts with early stopping (OpenHands' trained critic: stop adding attempts once one
 * is clearly good enough, ~1.35 attempts instead of 8 at a similar resolve rate). After each
 * attempt the merge verifier probes it on its own (no cross-tests or rubric, which depend on other
 * attempts); once an eligible attempt reaches the threshold, no further attempt is needed.
 */

/** off: no early stop. shadow: decide and report, change nothing. enforce: actually stop. */
export type AdaptiveMode = "off" | "shadow" | "enforce";

export interface EarlyStopRule {
  /** The verifier probability an eligible attempt must reach to stop launching more. */
  readonly threshold: number;
  /** Never stop before this many attempts have run. */
  readonly minAttempts: number;
}

export const EARLY_STOP_RULE: EarlyStopRule = {
  /** High enough that a stop is rare unless the verifier is confident (the OpenHands setting). */
  threshold: 0.8,
  /** One attempt can be enough: the point is to skip the rest. */
  minAttempts: 1,
};

/** One attempt as the early-stop rule sees it, in attempt order. */
export interface StopProbe {
  readonly id: string;
  /** 0-based attempt position. */
  readonly index: number;
  /** Built a non-empty patch and passed the repository's own tests. */
  readonly eligible: boolean;
  /** The verifier's probability for this attempt alone, or null when not probed or unscored. */
  readonly p: number | null;
}

const qualifies = (probe: StopProbe, rule: EarlyStopRule): boolean =>
  probe.eligible && probe.p !== null && probe.p >= rule.threshold;

/** The earliest probe that meets the threshold, whatever minAttempts says. */
function firstQualifying(probes: readonly StopProbe[], rule: EarlyStopRule): StopProbe | null {
  let best: StopProbe | null = null;
  for (const probe of probes) {
    if (qualifies(probe, rule) && (best === null || probe.index < best.index)) best = probe;
  }
  return best;
}

/**
 * The smallest attempt count k (1-based, k >= minAttempts) such that some probe among the first k
 * attempts is eligible with p >= threshold; null when it never would within the probes given.
 */
export function wouldStopAt(probes: readonly StopProbe[], rule: EarlyStopRule): number | null {
  const first = firstQualifying(probes, rule);
  if (first === null) return null;
  const k = Math.max(rule.minAttempts, first.index + 1);
  return k <= probes.length ? k : null;
}

/** The probe that triggers the stop, or null when the rule would not stop. */
export function stopTrigger(probes: readonly StopProbe[], rule: EarlyStopRule): StopProbe | null {
  return wouldStopAt(probes, rule) === null ? null : firstQualifying(probes, rule);
}

/** What the attempts after the stop point cost: the shadow "would have saved" figure, in cents. */
export function spendAfterStop(
  attempts: readonly { readonly index: number; readonly costUsd: number }[],
  stopAt: number | null,
): number {
  if (stopAt === null) return 0;
  const after = attempts.filter((a) => a.index >= stopAt).reduce((s, a) => s + a.costUsd, 0);
  return Math.round(after * 100) / 100;
}
