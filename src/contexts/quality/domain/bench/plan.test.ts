import { expect, test } from "bun:test";
import type { BenchArm } from "./arm";
import { estimateUsd, mayStart, pendingRuns, planRuns, spentUsd } from "./plan";
import type { BenchRow } from "./row";
import type { BenchTask } from "./task";

const task = (id: string) => ({ id }) as BenchTask;
const arm = (id: string, estimate: number) => ({ id, estimateUsd: estimate }) as BenchArm;
const row = (taskId: string, armId: string, over: Partial<BenchRow> = {}): BenchRow => ({
  taskId,
  armId,
  trial: 1,
  status: "ok",
  resolved: true,
  costUsd: 1,
  durationMs: 0,
  patchBytes: 1,
  note: "",
  at: "",
  ...over,
});

test("the plan interleaves arms per task so a partial run stays paired", () => {
  const arms = [arm("x", 1), arm("y", 2)];
  const plan = planRuns([task("a"), task("b")], arms, 2);
  const ids = plan.slice(0, 4).map((p) => `${p.taskId}${p.armId}${p.trial}`);
  expect(ids).toEqual(["ax1", "ay1", "bx1", "by1"]);
  expect(plan).toHaveLength(8);
  expect(estimateUsd(plan, arms)).toBe(12);
});

test("done runs are skipped, errored runs are retried", () => {
  const plan = planRuns([task("a")], [arm("x", 1), arm("y", 1)], 1);
  const todo = pendingRuns(plan, [row("a", "x"), row("a", "y", { status: "error" })]);
  expect(todo.map((p) => p.armId)).toEqual(["y"]);
});

test("budget rule: spent < cap and spent + estimate <= cap", () => {
  expect(mayStart(9, 1, 10)).toBe(true);
  expect(mayStart(9.5, 1, 10)).toBe(false);
  expect(mayStart(10, 0, 10)).toBe(false);
});

test("unknown spend counts at the arm's estimate", () => {
  const rows = [row("a", "x", { costUsd: null }), row("b", "x", { costUsd: 2 })];
  expect(spentUsd(rows, [arm("x", 5)])).toBe(7);
});
