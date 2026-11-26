import { expect, test } from "bun:test";
import { auc, calibrate, ece, leaveOneOut, type Scored } from "./calibration";
import { FEATURES, type FeatureVector } from "./change-features";
import type { Example } from "./verifier-fit";

const s = (p: number, y: 0 | 1, weight = 1): Scored => ({ p, y, weight });

test("AUC: perfect ranking is 1, reversed is 0, ties are half, one class is null", () => {
  expect(auc([s(0.9, 1), s(0.1, 0)])).toBe(1);
  expect(auc([s(0.1, 1), s(0.9, 0)])).toBe(0);
  expect(auc([s(0.5, 1), s(0.5, 0)])).toBe(0.5);
  expect(auc([s(0.5, 1)])).toBeNull();
});

test("ECE is 0 when the stated chance matches the outcome rate", () => {
  const data = [
    s(0.7, 1),
    s(0.7, 1),
    s(0.7, 1),
    s(0.7, 0),
    s(0.7, 1),
    s(0.7, 1),
    s(0.7, 1),
    s(0.7, 0),
    s(0.7, 1),
    s(0.7, 0),
  ];
  expect(ece(data)).toBeCloseTo(0);
  expect(ece([s(0.95, 0), s(0.95, 0)])).toBeCloseTo(0.95);
});

test("Brier against the base-rate bar", () => {
  const c = calibrate([s(1, 1), s(0, 0)]);
  expect(c.brier).toBe(0);
  expect(c.baseBrier).toBeCloseTo(0.25);
  expect(c.n).toBe(2);
  expect(calibrate([]).brier).toBeNull();
});

test("leave-one-out scores each example with a model that never saw it", () => {
  const zero = Object.fromEntries(FEATURES.map((f) => [f, 0])) as Record<string, number>;
  const x = (chatter: number) => ({ ...zero, chatter }) as FeatureVector;
  const data: Example[] = Array.from({ length: 12 }, (_, i) => ({
    id: i,
    x: x(i % 2),
    y: i % 2 === 0 ? 1 : 0,
    weight: 1,
  }));
  const loo = leaveOneOut(data, 0);
  expect(loo).toHaveLength(12);
  expect(auc(loo)).toBe(1);
});
