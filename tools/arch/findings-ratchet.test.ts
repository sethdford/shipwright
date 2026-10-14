import { expect, test } from "bun:test";
import {
  checkFindings,
  countFindings,
  type Finding,
  nextFindingsBaseline,
  parseScan,
  summaryMarkdown,
} from "./findings-ratchet";

const f = (ruleId: string, file: string, line = 1): Finding => ({
  ruleId,
  file,
  line,
  message: `${ruleId} message`,
});
const RATCHETED = ["R1", "R2"];
const current = countFindings([f("R1", "a.sh"), f("R1", "a.sh", 9), f("R2", "b.sh")], RATCHETED);

test("counts findings per rule and file, keeping every ratcheted rule as a key", () => {
  expect(current).toEqual({ R1: { "a.sh": 2 }, R2: { "b.sh": 1 } });
  expect(countFindings([f("R1", "a.sh")], RATCHETED)).toEqual({ R1: { "a.sh": 1 }, R2: {} });
});

test("parses ast-grep --json=stream output (lines are 0-based there)", () => {
  const line = JSON.stringify({
    ruleId: "R1",
    file: "a.sh",
    range: { start: { line: 4, column: 0 } },
    message: "m",
  });
  expect(parseScan(`${line}\n\n`)).toEqual([{ ruleId: "R1", file: "a.sh", line: 5, message: "m" }]);
});

test("matching counts pass; new files and growth fail", () => {
  expect(checkFindings(current, { R1: { "a.sh": 2 }, R2: { "b.sh": 1 } })).toEqual([]);
  expect(checkFindings(current, { R1: { "a.sh": 2 }, R2: {} })).toEqual([
    "R2 b.sh: 1 new finding(s). Fix them: baselined findings may only go down.",
  ]);
  expect(checkFindings(current, { R1: { "a.sh": 1 }, R2: { "b.sh": 1 } })).toEqual([
    "R1 a.sh: 2 findings (baseline 1). Fix the new one: baselined findings may only go down.",
  ]);
});

test("loose and stale entries fail so the baseline tracks reality", () => {
  expect(checkFindings(current, { R1: { "a.sh": 3 }, R2: { "b.sh": 1, "gone.sh": 4 } })).toEqual([
    "tighten baseline R1 a.sh to 2",
    "remove baseline entry R2 gone.sh (no findings left)",
  ]);
});

test("a ratcheted rule without a baseline key, or a key for another rule, fails", () => {
  expect(checkFindings(current, { R1: { "a.sh": 2 } })).toEqual([
    "R2 b.sh: 1 new finding(s). Fix them: baselined findings may only go down.",
    "R2 has no baseline entry. Seed it: bun tools/arch/ast-scan.ts --write-baseline",
  ]);
  expect(checkFindings(current, { R1: { "a.sh": 2 }, R2: { "b.sh": 1 }, R9: {} })).toEqual([
    "remove baseline entry R9 (not a ratcheted rule)",
  ]);
});

test("write mode seeds a rule the baseline does not know yet, and keeps zeroed rules as keys", () => {
  expect(nextFindingsBaseline(current, undefined, RATCHETED)).toEqual({ baseline: current });
  expect(nextFindingsBaseline(current, { R1: { "a.sh": 2 } }, RATCHETED)).toEqual({
    baseline: current,
  });
  const zeroed = countFindings([f("R1", "a.sh")], RATCHETED);
  expect(nextFindingsBaseline(zeroed, { R1: { "a.sh": 2 }, R2: { "b.sh": 1 } }, RATCHETED)).toEqual(
    { baseline: { R1: { "a.sh": 1 }, R2: {} } },
  );
});

test("write mode refuses new files and raised counts, and drops rules no longer ratcheted", () => {
  expect(
    nextFindingsBaseline(current, { R1: { "z.sh": 1 }, R2: { "b.sh": 1 } }, RATCHETED),
  ).toEqual({
    errors: ["refusing to baseline new finding R1 a.sh (2)"],
  });
  expect(
    nextFindingsBaseline(current, { R1: { "a.sh": 1 }, R2: { "b.sh": 1 } }, RATCHETED),
  ).toEqual({
    errors: ["refusing to raise baseline R1 a.sh from 1 to 2"],
  });
  expect(nextFindingsBaseline(current, { ...current, R9: { "x.sh": 1 } }, RATCHETED)).toEqual({
    baseline: current,
  });
});

test("summary lists files and findings per rule", () => {
  expect(summaryMarkdown(current)).toBe(
    "| Ratcheted rule | Files | Findings |\n|---|---|---|\n| R1 | 1 | 2 |\n| R2 | 1 | 1 |\n",
  );
});
