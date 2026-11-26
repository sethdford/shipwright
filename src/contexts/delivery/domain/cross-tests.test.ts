import { expect, test } from "bun:test";
import {
  crossPassRate,
  isTestPath,
  renderMatrix,
  type TestMatrix,
  validSuites,
} from "./cross-tests";

// a1's tests pass on a1 and a3, fail on a2. a2 wrote no tests. a3's tests fail on a3 itself.
const m: TestMatrix = {
  ids: ["a1", "a2", "a3"],
  cells: [
    ["pass", "skip", "pass"],
    ["fail", "pass", "pass"],
    ["pass", "skip", "fail"],
  ],
};

test("a suite is evidence only when its author's patch passes it", () => {
  // a2's own cell is the gate result (pass), so its column counts, but every other cell skips.
  expect(validSuites(m)).toEqual([0, 1]);
});

test("the cross pass rate counts only other candidates' valid, run suites", () => {
  expect(crossPassRate(m, 0)).toBeNull(); // a2's suite skipped on a1; a3's suite is invalid
  expect(crossPassRate(m, 1)).toBe(0); // fails a1's tests
  expect(crossPassRate(m, 2)).toBe(1); // passes a1's tests
});

test("one candidate has nothing to be cross-checked against", () => {
  expect(crossPassRate({ ids: ["a1"], cells: [["pass"]] }, 0)).toBeNull();
});

test("the matrix renders as a table with a row per patch", () => {
  expect(renderMatrix(m).split("\n")).toEqual([
    "patch \\ tests | a1 | a2 | a3",
    "a1 | ✓ | · | ✓",
    "a2 | ✗ | ✓ | ✓",
    "a3 | ✓ | · | ✗",
  ]);
});

test("test paths are recognised across common layouts", () => {
  for (const p of [
    "src/x.test.ts",
    "lib/a.spec.js",
    "tests/test_parse.py",
    "pkg/parse_test.go",
    "test/unit/foo.rb",
    "scripts/sw-loop-test.sh",
    "src/__tests__/a.tsx",
  ]) {
    expect(isTestPath(p)).toBe(true);
  }
  for (const p of ["src/parse.ts", "testing.md", "src/contest.ts", "latest/x.go"]) {
    expect(isTestPath(p)).toBe(false);
  }
});
