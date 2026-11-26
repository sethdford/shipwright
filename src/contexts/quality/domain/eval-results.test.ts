import { expect, test } from "bun:test";
import { parseEvalResults, scoreRuns } from "./eval-results";

const run = (c: string, pass: boolean, costUsd = 1) => ({ case: c, pass, costUsd });

test("parses a results file and defaults the vetoes", () => {
  const r = parseEvalResults({ policy: "routing-v1", runs: [run("c01", true, 0.5)] });
  expect(r).toEqual({
    ok: true,
    value: {
      policy: "routing-v1",
      runs: [{ caseId: "c01", pass: true, costUsd: 0.5 }],
      vetoes: { fenceViolations: 0, protectedPathTouched: false, oracleTampering: false },
    },
  });
});

test("one malformed run rejects the whole file", () => {
  const bad = [
    { policy: "p", runs: [run("c01", true), { case: "c02", pass: "yes", costUsd: 1 }] },
    { policy: "p", runs: [run("../x", true)] },
    { policy: "p", runs: [run("c01", true, -1)] },
    { policy: "", runs: [] },
    { policy: "p", runs: {} },
    { policy: "p", runs: [], vetoes: { fenceViolations: 1.5 } },
    { policy: "p", runs: [], vetoes: { oracleTampering: "no" } },
    null,
  ];
  for (const value of bad) expect(parseEvalResults(value).ok).toBe(false);
});

test("reads vetoes when present", () => {
  const r = parseEvalResults({ policy: "p", runs: [], vetoes: { fenceViolations: 2 } });
  expect(r.ok && r.value.vetoes.fenceViolations).toBe(2);
});

test("scores pass^3 and mean cost per case", () => {
  const runs = [
    { caseId: "a", pass: true, costUsd: 1 },
    { caseId: "a", pass: true, costUsd: 2 },
    { caseId: "a", pass: true, costUsd: 3 },
    { caseId: "b", pass: true, costUsd: 1 },
    { caseId: "b", pass: false, costUsd: 1 },
    { caseId: "b", pass: true, costUsd: 1 },
  ];
  expect(scoreRuns(runs, 3)).toEqual({
    ok: true,
    value: [
      { caseId: "a", passK: 1, costUsd: 2 },
      { caseId: "b", passK: 0, costUsd: 1 },
    ],
  });
});

test("a case with fewer than k runs is refused", () => {
  const r = scoreRuns([{ caseId: "a", pass: true, costUsd: 1 }], 3);
  expect(r).toEqual({ ok: false, reason: "case a: 1 run(s), need 3" });
});
