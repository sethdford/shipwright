import { expect, test } from "bun:test";
import {
  type ChangeSummary,
  extractFeatures,
  type FileChange,
  isRunArtifact,
  isTestFile,
  NO_SIGNALS,
} from "./change-features";

const file = (path: string, additions = 10, deletions = 0): FileChange => ({
  path,
  additions,
  deletions,
});

const change = (over: Partial<ChangeSummary> = {}): ChangeSummary => ({
  title: "fix(loop): stop the cold start (#12)",
  body: "## Summary\nReuses the session.",
  files: [file("scripts/sw-loop.sh"), file("scripts/sw-loop-test.sh")],
  signals: NO_SIGNALS,
  factory: true,
  ...over,
});

test("a small conventional change with tests has no penalties", () => {
  const x = extractFeatures(change());
  expect(x.factory).toBe(1);
  expect(x.conventionalTitle).toBe(1);
  expect(x.testsAdded).toBe(1);
  for (const f of ["runArtifacts", "noChange", "chatter", "harness", "testsWeakened"] as const)
    expect(x[f]).toBe(0);
  expect(x.cross).toBe(0);
  expect(x.critic).toBe(0);
});

test("run output in the diff is flagged; a diff of only run output is no change", () => {
  const files = [file(".claude/loop-logs/iter-1.log", 9000), file(".claude/loop-state.md", 40)];
  const x = extractFeatures(change({ files }));
  expect(x.runArtifacts).toBe(1);
  expect(x.noChange).toBe(1);
});

test("a plan-only change is no change", () => {
  const x = extractFeatures(change({ files: [file("docs/plans/2026-11-01-plan.md", 200)] }));
  expect(x.noChange).toBe(1);
  expect(extractFeatures(change({ files: [] })).noChange).toBe(1);
});

test("model chatter in the title or summary is flagged (the diagnosed titles)", () => {
  for (const title of [
    "Invalid API key · Fix external API key",
    "The implementation is **already complete**. Here's my analysis",
  ]) {
    const x = extractFeatures(change({ title }));
    expect(x.chatter).toBe(1);
    expect(x.conventionalTitle).toBe(0);
  }
  const body = "## Summary\nThe flag is **already fully implemented** on main.";
  expect(extractFeatures(change({ body })).chatter).toBe(1);
});

test("weakened tests and harness edits are flagged", () => {
  const files = [file("src/a.test.ts", 2, 40), file(".github/workflows/ci.yml", 3, 1)];
  const x = extractFeatures(change({ files }));
  expect(x.testsWeakened).toBe(1);
  expect(x.harness).toBe(1);
});

test("size grows with log lines and is capped", () => {
  const small = extractFeatures(change({ files: [file("a.ts", 9)] })).size;
  const big = extractFeatures(change({ files: [file("a.ts", 99_999)] })).size;
  expect(small).toBeCloseTo(0.25);
  expect(big).toBeCloseTo(1.25);
  expect(extractFeatures(change({ files: [file("a.ts", 1e12)] })).size).toBe(1.5);
});

test("run signals are centred on 0.5 and the critic enters as a clipped logit", () => {
  const signals = {
    ownTestsPass: false,
    crossPassRate: 1,
    rubricScore: 0.25,
    criticProbability: 0.5,
  };
  const x = extractFeatures(change({ signals }));
  expect(x.testsFailing).toBe(1);
  expect(x.cross).toBe(0.5);
  expect(x.rubric).toBe(-0.25);
  expect(x.critic).toBe(0);
  const sure = extractFeatures(change({ signals: { ...signals, criticProbability: 1 } })).critic;
  expect(sure).toBeCloseTo(Math.log(0.98 / 0.02) / 3);
});

test("path classifiers", () => {
  expect(isRunArtifact(".claude/pipeline-artifacts/plan.md")).toBe(true);
  expect(isRunArtifact(".claude/CLAUDE.md")).toBe(false);
  expect(isRunArtifact(".claude/agents/porter.md")).toBe(false);
  const plan = { path: ".claude/IMPLEMENTATION_PLAN.md", additions: 959, deletions: 0 };
  expect(extractFeatures(change({ files: [plan] })).noChange).toBe(1);
  expect(isTestFile("scripts/sw-loop-test.sh")).toBe(true);
  expect(isTestFile("src/a/b.test.ts")).toBe(true);
  expect(isTestFile("tests/x.py")).toBe(true);
  expect(isTestFile("src/contest.ts")).toBe(false);
});
