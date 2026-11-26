import { FEATURES, type Feature, type FeatureVector } from "./change-features";
import { PRIOR_MODEL, sigmoid, type VerifierModel } from "./verifier-model";

/** A labelled historical change: 1 merged and stayed merged, 0 closed unmerged or reverted. */
export interface Example {
  readonly id: number;
  readonly x: FeatureVector;
  readonly y: 0 | 1;
  /** Sample weight: 1 for the factory's own PRs, less for human PRs (a different population). */
  readonly weight: number;
}

export const FIT_RULE = {
  /** Prior precision on each feature weight (sd about 0.7 logits around the prior). */
  weightPrecision: 2,
  /** A weak prior on the bias and the factory offset, so both base rates are learned from data. */
  biasPrecision: 0.1,
  iterations: 25,
} as const;

/** Solves A x = b by Gaussian elimination with partial pivoting (A is small and positive definite). */
export function solve(a: number[][], b: number[]): number[] {
  const n = b.length;
  const m = a.map((row, i) => [...row, b[i] as number]);
  for (let c = 0; c < n; c++) {
    let p = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(m[r]?.[c] ?? 0) > Math.abs(m[p]?.[c] ?? 0)) p = r;
    [m[c], m[p]] = [m[p] as number[], m[c] as number[]];
    const pivot = m[c] as number[];
    for (let r = c + 1; r < n; r++) {
      const row = m[r] as number[];
      const f = (row[c] as number) / (pivot[c] as number);
      for (let k = c; k <= n; k++) row[k] = (row[k] as number) - f * (pivot[k] as number);
    }
  }
  const x = new Array<number>(n).fill(0);
  for (let r = n - 1; r >= 0; r--) {
    const row = m[r] as number[];
    let s = row[n] as number;
    for (let k = r + 1; k < n; k++) s -= (row[k] as number) * (x[k] as number);
    x[r] = s / (row[r] as number);
  }
  return x;
}

const row = (x: FeatureVector): number[] => [1, ...FEATURES.map((f) => x[f])];

/** One Newton step on the penalized log-likelihood. θ = [bias, ...weights]. */
function newtonStep(
  theta: number[],
  prior: number[],
  precision: number[],
  data: readonly Example[],
) {
  const d = theta.length;
  const grad = theta.map((t, i) => -(precision[i] as number) * (t - (prior[i] as number)));
  const hess = theta.map((_, i) => theta.map((__, j) => (i === j ? (precision[i] as number) : 0)));
  for (const e of data) {
    const v = row(e.x);
    const p = sigmoid(v.reduce((s, vi, i) => s + vi * (theta[i] as number), 0));
    const w = e.weight * p * (1 - p);
    for (let i = 0; i < d; i++) {
      grad[i] = (grad[i] as number) + e.weight * (e.y - p) * (v[i] as number);
      const hi = hess[i] as number[];
      for (let j = 0; j < d; j++)
        hi[j] = (hi[j] as number) + w * (v[i] as number) * (v[j] as number);
    }
  }
  const step = solve(hess, grad);
  return theta.map((t, i) => t + (step[i] as number));
}

/**
 * MAP logistic regression with a Gaussian prior centred on `prior`'s weights (Newton's method).
 * Deterministic. With no data it returns the prior unchanged.
 */
export function fitVerifier(
  data: readonly Example[],
  nowMs: number,
  prior: VerifierModel = PRIOR_MODEL,
): VerifierModel {
  if (data.length === 0) return prior;
  const mean = [prior.bias, ...FEATURES.map((f) => prior.weights[f])];
  const precision = [
    FIT_RULE.biasPrecision,
    ...FEATURES.map((f) => (f === "factory" ? FIT_RULE.biasPrecision : FIT_RULE.weightPrecision)),
  ];
  let theta = [...mean];
  for (let i = 0; i < FIT_RULE.iterations; i++) {
    const next = newtonStep(theta, mean, precision, data);
    if (next.some((t) => !Number.isFinite(t))) break;
    const moved = Math.max(...next.map((t, k) => Math.abs(t - (theta[k] as number))));
    theta = next;
    if (moved < 1e-8) break;
  }
  const weights = Object.fromEntries(FEATURES.map((f, i) => [f, theta[i + 1] as number]));
  return {
    version: 1,
    bias: theta[0] as number,
    weights: weights as Record<Feature, number>,
    source: "trained",
    examples: data.length,
    trainedAtMs: nowMs,
  };
}
