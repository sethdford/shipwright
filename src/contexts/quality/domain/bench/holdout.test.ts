import { describe, expect, test } from "bun:test";
import {
  classifyPull,
  filterDiff,
  linkedIssue,
  type MergedPull,
  patchPaths,
  testCommandFor,
} from "./holdout";

const pull = (over: Partial<MergedPull> = {}): MergedPull => ({
  number: 7,
  title: "fix",
  body: "Fixes #42",
  author: "sethdford",
  mergedAtMs: 0,
  baseSha: "a".repeat(40),
  mergeSha: "b".repeat(40),
  files: ["src/x.ts", "src/x.test.ts"],
  ...over,
});

describe("classifyPull", () => {
  test("a human PR closing an issue with source and runnable tests is a candidate", () => {
    const c = classifyPull(pull());
    expect("issue" in c && c.issue).toBe(42);
    expect("testCommands" in c && c.testCommands).toEqual([["bun", "test", "./src/x.test.ts"]]);
  });

  test.each([
    [{ author: "dependabot[bot]" }, "bot author"],
    [{ body: "no link" }, "closes no issue"],
    [{ files: ["src/x.test.ts"] }, "no source change"],
    [{ files: ["src/x.ts", "README.md"] }, "no runnable test change"],
    [{ files: ["src/x.ts", "src/x.test.ts", ".claude/loop-state.md"] }, "run output"],
    [{ files: Array.from({ length: 16 }, (_, i) => `src/f${i}.ts`) }, "max 15"],
  ])("rejects %p", (over, reason) => {
    const c = classifyPull(pull(over));
    expect("reason" in c ? c.reason : "").toContain(reason);
  });
});

test("linkedIssue and testCommandFor", () => {
  expect(linkedIssue("This resolves #12 and more")).toBe(12);
  expect(linkedIssue("see #12")).toBeNull();
  expect(testCommandFor("scripts/sw-loop-test.sh")).toEqual(["bash", "scripts/sw-loop-test.sh"]);
  expect(testCommandFor("scripts/lib/x.sh")).toBeNull();
});

const DIFF = [
  "diff --git a/src/x.ts b/src/x.ts\n--- a/src/x.ts\n+++ b/src/x.ts\n@@ -1 +1 @@\n-a\n+b\n",
  "diff --git a/src/x.test.ts b/src/x.test.ts\nnew file mode 100644\n--- /dev/null\n+++ b/src/x.test.ts\n@@ -0,0 +1 @@\n+t\n",
].join("");

test("filterDiff keeps only the named files; patchPaths lists them", () => {
  const tests = filterDiff(DIFF, ["src/x.test.ts"]);
  expect(tests.startsWith("diff --git a/src/x.test.ts")).toBe(true);
  expect(tests).not.toContain("+++ b/src/x.ts\n");
  expect(patchPaths(tests)).toEqual(["src/x.test.ts"]);
  expect(patchPaths(DIFF)).toEqual(["src/x.ts", "src/x.test.ts"]);
});
