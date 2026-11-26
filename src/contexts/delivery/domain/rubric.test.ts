import { expect, test } from "bun:test";
import {
  type Criterion,
  finalizeRubric,
  INTEGRITY_CRITERIA,
  renderRubric,
  scoreRubric,
} from "./rubric";

const c = (id: string, weight: 1 | 2 | 3 = 2): Criterion => ({
  id,
  text: `criterion ${id}`,
  weight,
  axis: "correctness",
});

test("a valid draft gets the fixed integrity criteria appended", () => {
  const r = finalizeRubric([c("fixes-parse"), c("adds-test"), c("keeps-api")]);
  expect(typeof r).not.toBe("string");
  if (typeof r === "string") return;
  expect(r.criteria.map((x) => x.id)).toEqual([
    "fixes-parse",
    "adds-test",
    "keeps-api",
    ...INTEGRITY_CRITERIA.map((x) => x.id),
  ]);
});

test("drafts with too few, duplicate, badly named, or empty criteria are refused", () => {
  expect(finalizeRubric([c("a"), c("b")])).toContain("3 to 12");
  expect(finalizeRubric([c("a"), c("a"), c("b")])).toContain("used twice");
  expect(finalizeRubric([c("a"), c("b"), c("Bad Id")])).toContain("lowercase-kebab");
  expect(finalizeRubric([c("a"), c("b"), c("integrity-tests")])).toContain("used twice");
  expect(finalizeRubric([c("a"), c("b"), { ...c("c"), text: "  " }])).toContain("characters");
});

test("the score is the weighted share of criteria met", () => {
  const r = finalizeRubric([c("a", 3), c("b", 1), c("d", 2)]);
  if (typeof r === "string") throw new Error(r);
  const integrity = { "integrity-tests": true, "integrity-harness": true };
  // Total weight 3 + 1 + 2 + 3 + 3 = 12; met: a (3) + integrity (6) = 9.
  expect(scoreRubric(r, { ...integrity, a: true, b: false })).toBeCloseTo(9 / 12);
});

test("an unanswered criterion is not met, and a failed integrity criterion scores 0", () => {
  const r = finalizeRubric([c("a"), c("b"), c("d")]);
  if (typeof r === "string") throw new Error(r);
  const all = { a: true, b: true, d: true, "integrity-tests": true, "integrity-harness": true };
  expect(scoreRubric(r, all)).toBe(1);
  expect(scoreRubric(r, { ...all, d: undefined as unknown as boolean })).toBeLessThan(1);
  expect(scoreRubric(r, { ...all, "integrity-tests": false })).toBe(0);
  expect(scoreRubric(r, { a: true, b: true, d: true })).toBe(0);
});

test("the rendered rubric lists every criterion with its weight", () => {
  const r = finalizeRubric([c("a", 3), c("b"), c("d")]);
  if (typeof r === "string") throw new Error(r);
  expect(renderRubric(r).split("\n")[0]).toBe("- [a] (correctness, weight 3) criterion a");
  expect(renderRubric(r).split("\n")).toHaveLength(5);
});
