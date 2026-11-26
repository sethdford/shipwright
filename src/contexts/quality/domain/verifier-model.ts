import { FEATURES, type Feature, type FeatureVector } from "./change-features";

/**
 * The merge verifier: a logistic model over the change features. It predicts the probability that
 * a change merges and is not reverted within the revert window. Pure.
 *
 * It starts as a hand-set prior (a rubric written as weights) and becomes a learned model as the
 * repository's history grows: training is a MAP fit whose Gaussian prior is centred on these
 * weights, so with a dozen PRs the model stays close to the rubric and with hundreds it follows
 * the data.
 */
export interface VerifierModel {
  readonly version: 1;
  readonly bias: number;
  readonly weights: Readonly<Record<Feature, number>>;
  /** Where the weights came from: the hand-set prior, or a fit on `examples` labelled PRs. */
  readonly source: "prior" | "trained";
  readonly examples: number;
  readonly trainedAtMs: number | null;
}

/**
 * Prior weights, in logit units per unit of feature. Signs come from the 2026-11-26 diagnosis of
 * the pipeline's closed PRs; magnitudes are deliberately moderate so data can overrule them.
 */
export const PRIOR_WEIGHTS: Readonly<Record<Feature, number>> = {
  factory: 0, // the factory's own base rate, learned: its PRs merge far less often than humans'
  size: -0.6, // 10k changed lines costs about -0.6
  spread: -0.5,
  runArtifacts: -2.0, // loop logs and caches were 90-99% of most closed pipeline diffs
  noChange: -3.0, // "already implemented" and plan-only runs
  harness: -0.7, // CI, lint and test-runner config changes need a human's eye
  testsAdded: 0.6,
  testsWeakened: -1.5, // the reward hack the rubric's integrity criteria also guard against
  chatter: -2.0, // "Invalid API key", "The implementation is already complete"
  conventionalTitle: 0.8,
  testsFailing: -2.5,
  cross: 1.5, // cross-test pass rate, centred on 0.5
  rubric: 2.0, // rubric score, centred on 0.5
  critic: 1.0, // the critic's logit / 3: weight 1 trusts it at a third of its stated confidence
};

export const PRIOR_MODEL: VerifierModel = {
  version: 1,
  bias: 0.4,
  weights: PRIOR_WEIGHTS,
  source: "prior",
  examples: 0,
  trainedAtMs: null,
};

export const sigmoid = (z: number): number => 1 / (1 + Math.exp(-z));

export function logit(model: VerifierModel, x: FeatureVector): number {
  return FEATURES.reduce((z, f) => z + model.weights[f] * x[f], model.bias);
}

export const predict = (model: VerifierModel, x: FeatureVector): number => sigmoid(logit(model, x));

export interface Contribution {
  readonly feature: Feature;
  /** Weight times value, in logit units: negative pulls the prediction toward "won't merge". */
  readonly effect: number;
}

/** The features that moved this prediction most, largest effect first. */
export function explain(model: VerifierModel, x: FeatureVector, top = 4): Contribution[] {
  return FEATURES.map((feature) => ({ feature, effect: model.weights[feature] * x[feature] }))
    .filter((c) => Math.abs(c.effect) >= 0.05)
    .sort((a, b) => Math.abs(b.effect) - Math.abs(a.effect))
    .slice(0, top);
}
