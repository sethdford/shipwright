import { expect, test } from "bun:test";
import {
  type CaseScore,
  decideRatchet,
  median,
  minWinsForSuperiority,
  pairCases,
  signTestP,
} from "./ratchet";

// The table in the Wave 2 plan (W2-13), computed there with math.comb and shown to 4 places.
const TABLE: readonly [number, number | null, number | null][] = [
  [1, null, null],
  [4, null, null],
  [5, 5, 0.0312],
  [8, 7, 0.0352],
  [10, 9, 0.0107],
  [13, 10, 0.0461],
  [16, 12, 0.0384],
  [18, 13, 0.0481],
  [20, 15, 0.0207],
];

test("minimum wins and p-values match the plan's sign-test table", () => {
  for (const [n, wins, p] of TABLE) {
    expect(minWinsForSuperiority(n)).toBe(wins);
    if (wins !== null && p !== null) expect(signTestP(wins, n)).toBeCloseTo(p, 3);
  }
});

test("median handles odd, even and empty lists", () => {
  expect(median([3, 1, 2])).toBe(2);
  expect(median([4, 1, 3, 2])).toBe(2.5);
  expect(median([])).toBeNull();
});

const score = (caseId: string, passK: number, costUsd = 1): CaseScore => ({
  caseId,
  passK,
  costUsd,
});
const many = (n: number, passK: number, costUsd = 1) =>
  Array.from({ length: n }, (_, i) => score(`c${i}`, passK, costUsd));

test("identical results are non-inferior but not accepted", () => {
  const r = decideRatchet(many(16, 1), many(16, 1));
  expect(r.ok && r.verdict).toMatchObject({ accept: false, nonInferior: true, ties: 16 });
});

test("five wins and no losses are superior and accepted", () => {
  const inc = many(16, 0);
  const cand = [...many(5, 1), ...inc.slice(5)];
  const r = decideRatchet(inc, cand);
  expect(r.ok && r.verdict).toMatchObject({ accept: true, superior: true, wins: 5, losses: 0 });
});

test("two losses break non-inferiority even with more wins", () => {
  const inc = many(16, 0.5);
  const cand = inc.map((c, i) => score(c.caseId, i < 2 ? 0 : i < 10 ? 1 : 0.5));
  const r = decideRatchet(inc, cand);
  expect(r.ok && r.verdict).toMatchObject({ accept: false, nonInferior: false, losses: 2 });
});

test("non-inferior and 10% cheaper is accepted", () => {
  const r = decideRatchet(many(16, 1, 1), many(16, 1, 0.9));
  expect(r.ok && r.verdict).toMatchObject({ accept: true, cheaper: true, medianCostRatio: 0.9 });
});

test("a veto rejects a candidate that would otherwise win", () => {
  const vetoes = { fenceViolations: 1, protectedPathTouched: false, oracleTampering: true };
  const r = decideRatchet(many(16, 0), many(16, 1), vetoes);
  expect(r.ok && r.verdict.accept).toBe(false);
  expect(r.ok && r.verdict.vetoes).toEqual(["1 fence violation(s)", "oracle tampering"]);
});

test("unpaired or empty case sets are refused", () => {
  expect(decideRatchet(many(3, 1), many(2, 1)).ok).toBe(false);
  expect(decideRatchet(many(2, 1), many(3, 1)).ok).toBe(false);
  expect(decideRatchet([], []).ok).toBe(false);
  expect("error" in pairCases([score("a", 1), score("a", 1)], [score("a", 1)])).toBe(true);
});
