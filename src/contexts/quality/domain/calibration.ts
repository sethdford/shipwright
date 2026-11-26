import { type Example, fitVerifier } from "./verifier-fit";
import { predict, type VerifierModel } from "./verifier-model";

/**
 * How well the verifier's probabilities match what happened. Brier score and log loss are proper
 * scoring rules (lower is better); AUC says whether it ranks merged changes above unmerged ones;
 * ECE says whether "70%" means 70%. Pure.
 */
export interface Calibration {
  readonly n: number;
  readonly brier: number | null;
  readonly logLoss: number | null;
  readonly auc: number | null;
  /** Expected calibration error over equal-width probability bins. */
  readonly ece: number | null;
  /** Brier score of always predicting the (weighted) base rate: the bar to beat. */
  readonly baseBrier: number | null;
}

export interface Scored {
  readonly p: number;
  readonly y: 0 | 1;
  readonly weight: number;
}

const totalWeight = (s: readonly Scored[]) => s.reduce((a, e) => a + e.weight, 0);
const wmean = (s: readonly Scored[], f: (e: Scored) => number) =>
  s.reduce((a, e) => a + e.weight * f(e), 0) / totalWeight(s);

/** Area under the ROC curve (Mann-Whitney, weighted, ties count half). Null without both classes. */
export function auc(s: readonly Scored[]): number | null {
  const pos = s.filter((e) => e.y === 1);
  const neg = s.filter((e) => e.y === 0);
  if (pos.length === 0 || neg.length === 0) return null;
  let num = 0;
  let den = 0;
  for (const a of pos)
    for (const b of neg) {
      const w = a.weight * b.weight;
      num += w * (a.p > b.p ? 1 : a.p === b.p ? 0.5 : 0);
      den += w;
    }
  return den > 0 ? num / den : null;
}

export function ece(s: readonly Scored[], bins = 5): number | null {
  if (totalWeight(s) <= 0) return null;
  let err = 0;
  for (let b = 0; b < bins; b++) {
    const inBin = s.filter((e) => Math.min(bins - 1, Math.floor(e.p * bins)) === b);
    const w = totalWeight(inBin);
    if (w <= 0) continue;
    err += (w / totalWeight(s)) * Math.abs(wmean(inBin, (e) => e.p) - wmean(inBin, (e) => e.y));
  }
  return err;
}

export function calibrate(s: readonly Scored[]): Calibration {
  if (s.length === 0 || totalWeight(s) <= 0) {
    return { n: 0, brier: null, logLoss: null, auc: null, ece: null, baseBrier: null };
  }
  const base = wmean(s, (e) => e.y);
  const clip = (p: number) => Math.min(1 - 1e-6, Math.max(1e-6, p));
  return {
    n: s.length,
    brier: wmean(s, (e) => (e.p - e.y) ** 2),
    logLoss: wmean(s, (e) => -(e.y * Math.log(clip(e.p)) + (1 - e.y) * Math.log(1 - clip(e.p)))),
    auc: auc(s),
    ece: ece(s),
    baseBrier: wmean(s, (e) => (base - e.y) ** 2),
  };
}

/** Each example scored by a model fitted without it: an honest estimate on small data. */
export function leaveOneOut(data: readonly Example[], nowMs: number): Scored[] {
  return data.map((held) => {
    const model = fitVerifier(
      data.filter((e) => e !== held),
      nowMs,
    );
    return { p: predict(model, held.x), y: held.y, weight: held.weight };
  });
}

/** Every example scored by one fixed model (the prior, or a model trained elsewhere). */
export const scoreWith = (model: VerifierModel, data: readonly Example[]): Scored[] =>
  data.map((e) => ({ p: predict(model, e.x), y: e.y, weight: e.weight }));
