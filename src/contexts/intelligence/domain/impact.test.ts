import { describe, expect, test } from "bun:test";
import { modelOf } from "../../../testing/repo-model-fixture";
import { parseUnifiedDiff } from "./diff";
import { buildGraph } from "./graph";
import { changeImpact } from "./impact";
import { renderImpact } from "./render-impact";

const REPO = {
  "src/budget.ts": [
    "export function evaluateBudget(spent: number, cap: number): boolean {",
    "  return spent < cap;",
    "}",
    "function roundCents(n: number) {",
    "  return Math.round(n * 100) / 100;",
    "}",
  ].join("\n"),
  "src/daemon.ts": [
    'import { evaluateBudget } from "./budget";',
    "export function dispatchIssue(n: number) {",
    "  if (!evaluateBudget(n, 3)) return;",
    "}",
  ].join("\n"),
  "src/fleet.ts":
    'import { dispatchIssue } from "./daemon";\nexport const go = () => dispatchIssue(1);\n',
  "src/budget.test.ts": 'import { evaluateBudget } from "./budget";\n',
};
const graph = buildGraph(modelOf(REPO));

const EDIT_BUDGET = [
  "diff --git a/src/budget.ts b/src/budget.ts",
  "index 1..2 100644",
  "--- a/src/budget.ts",
  "+++ b/src/budget.ts",
  "@@ -1,3 +1,3 @@",
  " export function evaluateBudget(spent: number, cap: number): boolean {",
  "-  return spent <= cap;",
  "+  return spent < cap;",
  " }",
  "diff --git a/README.md b/README.md",
  "--- a/README.md",
  "+++ b/README.md",
  "@@ -1 +1 @@",
  "-old",
  "+docs",
].join("\n");

describe("parseUnifiedDiff", () => {
  test("files and new-side changed lines", () => {
    const files = parseUnifiedDiff(EDIT_BUDGET);
    expect(files.map((f) => [f.path, f.lines])).toEqual([
      ["src/budget.ts", [2]],
      ["README.md", [1]],
    ]);
  });

  test("new, deleted and renamed files", () => {
    const patch = [
      "diff --git a/src/new.ts b/src/new.ts",
      "--- /dev/null",
      "+++ b/src/new.ts",
      "@@ -0,0 +1,2 @@",
      "+a",
      "+b",
      "diff --git a/src/old.ts b/src/old.ts",
      "--- a/src/old.ts",
      "+++ /dev/null",
      "@@ -1 +0,0 @@",
      "-x",
      "diff --git a/src/a.ts b/src/b.ts",
      "similarity index 100%",
      "rename from src/a.ts",
      "rename to src/b.ts",
    ].join("\n");
    const files = parseUnifiedDiff(patch);
    expect(files.map((f) => [f.path, f.oldPath, f.deleted, f.lines])).toEqual([
      ["src/new.ts", "", false, [1, 2]],
      ["src/old.ts", "src/old.ts", true, []],
    ]);
  });
});

describe("changeImpact", () => {
  test("edited definition, its importers and callers, and its tests", () => {
    const impact = changeImpact(graph, parseUnifiedDiff(EDIT_BUDGET));
    const f = impact.files[0];
    expect(f?.touched.map((s) => s.name)).toEqual(["evaluateBudget"]);
    expect(f?.dependents.shown).toEqual(["src/budget.test.ts", "src/daemon.ts"]);
    expect(f?.callers).toEqual([
      {
        name: "evaluateBudget",
        files: { shown: ["src/budget.test.ts", "src/daemon.ts"], more: 0 },
      },
    ]);
    expect(f?.tests).toEqual([{ path: "src/budget.test.ts", inChange: false }]);
    expect(impact.untested).toEqual(["src/budget.ts"]);
    expect(impact.unindexed).toEqual(["README.md"]);
  });

  test("a deleted file that is still imported", () => {
    const after = buildGraph(modelOf({ "src/fleet.ts": REPO["src/fleet.ts"] }));
    const patch =
      "diff --git a/src/daemon.ts b/src/daemon.ts\n--- a/src/daemon.ts\n+++ /dev/null\n";
    const impact = changeImpact(after, parseUnifiedDiff(patch));
    expect(impact.orphaned).toEqual([
      { path: "src/daemon.ts", importers: { shown: ["src/fleet.ts"], more: 0 } },
    ]);
    expect(renderImpact(impact)).toContain(
      "DELETED src/daemon.ts is still imported by: src/fleet.ts",
    );
  });

  test("a change with its test edited is not flagged untested; render names everything", () => {
    const patch = `${EDIT_BUDGET}\ndiff --git a/src/budget.test.ts b/src/budget.test.ts\n--- a/src/budget.test.ts\n+++ b/src/budget.test.ts\n@@ -1 +1,2 @@\n+// more\n`;
    const impact = changeImpact(graph, parseUnifiedDiff(patch));
    expect(impact.untested).toEqual([]);
    const text = renderImpact(impact);
    expect(text).toContain("## Change impact (repository model)");
    expect(text).toContain("edits public: evaluateBudget");
    expect(text).toContain("imported by: src/daemon.ts");
    expect(text).toContain("tests: src/budget.test.ts (changed)");
  });

  test("nothing indexed: no section", () => {
    const patch =
      "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n+x\n";
    expect(renderImpact(changeImpact(graph, parseUnifiedDiff(patch)))).toBe("");
  });
});
