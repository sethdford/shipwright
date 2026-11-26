import { expect, test } from "bun:test";
import { compareEval, summarizeEval } from "./eval";

const runs = (cases: number, passes: (c: number) => boolean, costUsd = 1) =>
  Array.from({ length: cases }, (_, c) =>
    Array.from({ length: 3 }, () => ({ case: `c${c}`, pass: passes(c), costUsd })),
  ).flat();

test("summarizes pass^3, spend and run count", () => {
  const r = summarizeEval({ policy: "routing-v1", runs: runs(4, (c) => c < 3, 0.5) }, 3);
  expect(r.ok && r.value).toMatchObject({ policy: "routing-v1", meanPassK: 0.75, runs: 12 });
  expect(r.ok && r.value.totalCostUsd).toBeCloseTo(6);
});

test("a results file with no runs or bad runs is refused with its label", () => {
  expect(summarizeEval({ policy: "p", runs: [] }, 3)).toEqual({
    ok: false,
    reason: "results: no runs",
  });
  const bad = summarizeEval({ policy: "p", runs: [{ case: "c0" }] }, 3);
  expect(!bad.ok && bad.reason.startsWith("results:")).toBe(true);
});

test("accepts a superior candidate and names both policies", () => {
  const inc = { policy: "routing-v1", runs: runs(16, () => false) };
  const cand = { policy: "routing-v2", runs: runs(16, (c) => c < 5) };
  const r = compareEval(inc, cand, 3);
  expect(r.ok && r.value).toMatchObject({
    incumbent: "routing-v1",
    candidate: "routing-v2",
    verdict: { accept: true, wins: 5, losses: 0 },
  });
});

test("applies the candidate's vetoes", () => {
  const inc = { policy: "a", runs: runs(16, () => false) };
  const cand = { policy: "b", runs: runs(16, () => true), vetoes: { oracleTampering: true } };
  const r = compareEval(inc, cand, 3);
  expect(r.ok && r.value.verdict.accept).toBe(false);
});

test("names the side whose file or scores are wrong", () => {
  const good = { policy: "a", runs: runs(2, () => true) };
  const short = { policy: "b", runs: [{ case: "c0", pass: true, costUsd: 1 }] };
  const r1 = compareEval(null, good, 3);
  expect(!r1.ok && r1.reason.startsWith("incumbent:")).toBe(true);
  const r2 = compareEval(good, short, 3);
  expect(!r2.ok && r2.reason.startsWith("candidate:")).toBe(true);
  const r3 = compareEval(good, { policy: "b", runs: runs(3, () => true) }, 3);
  expect(r3.ok).toBe(false);
});
