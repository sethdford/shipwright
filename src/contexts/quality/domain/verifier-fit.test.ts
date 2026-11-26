import { expect, test } from "bun:test";
import { FEATURES, type FeatureVector } from "./change-features";
import { type Example, fitVerifier, solve } from "./verifier-fit";
import { PRIOR_MODEL, predict } from "./verifier-model";

const NOW = Date.UTC(2026, 10, 26);
const zero = Object.fromEntries(FEATURES.map((f) => [f, 0])) as Record<string, number>;
const x = (over: Partial<FeatureVector> = {}): FeatureVector =>
  ({ ...zero, ...over }) as FeatureVector;
const ex = (id: number, y: 0 | 1, over: Partial<FeatureVector> = {}, weight = 1): Example => ({
  id,
  x: x(over),
  y,
  weight,
});

test("solve handles a system that needs pivoting", () => {
  const r = solve(
    [
      [0, 2],
      [3, 1],
    ],
    [4, 5],
  );
  expect(r[0]).toBeCloseTo(1);
  expect(r[1]).toBeCloseTo(2);
});

test("no data returns the prior", () => {
  expect(fitVerifier([], NOW)).toBe(PRIOR_MODEL);
});

test("the prior already scores the diagnosed failure modes low and a clean change high", () => {
  const clean = predict(PRIOR_MODEL, x({ conventionalTitle: 1, testsAdded: 1, size: 0.5 }));
  const artifacts = predict(PRIOR_MODEL, x({ runArtifacts: 1, size: 1.1, spread: 1 }));
  const chatter = predict(PRIOR_MODEL, x({ chatter: 1, noChange: 1 }));
  expect(clean).toBeGreaterThan(0.7);
  expect(artifacts).toBeLessThan(0.2);
  expect(chatter).toBeLessThan(0.02);
});

test("with little data the fit stays near the prior; with much it follows the data", () => {
  // The data says harness edits always merge, against the prior's -0.7.
  const one = [ex(1, 1, { harness: 1 }), ex(2, 1)];
  const few = fitVerifier(one, NOW);
  expect(few.weights.harness).toBeLessThan(0);
  expect(few.source).toBe("trained");
  expect(few.examples).toBe(2);
  const many = Array.from({ length: 200 }, (_, i) =>
    i % 2 === 0 ? ex(i, 1, { harness: 1 }) : ex(i, i % 4 === 1 ? 1 : 0),
  );
  expect(fitVerifier(many, NOW).weights.harness).toBeGreaterThan(0);
});

test("the bias learns the base rate", () => {
  const mostlyClosed = Array.from({ length: 60 }, (_, i) => ex(i, i < 6 ? 1 : 0));
  const m = fitVerifier(mostlyClosed, NOW);
  expect(predict(m, x())).toBeLessThan(0.2);
});

test("sample weights count", () => {
  const data = [ex(1, 1, { spread: 1 }, 0.01), ex(2, 0, { spread: 1 }, 1), ex(3, 1)];
  const light = fitVerifier(data, NOW);
  const heavy = fitVerifier(
    data.map((e) => (e.id === 1 ? { ...e, weight: 1 } : e)),
    NOW,
  );
  expect(heavy.weights.spread).toBeGreaterThan(light.weights.spread);
});

test("fitting is deterministic", () => {
  const data = [ex(1, 1, { testsAdded: 1 }), ex(2, 0, { chatter: 1 }), ex(3, 1)];
  expect(fitVerifier(data, NOW)).toEqual(fitVerifier(data, NOW));
});
