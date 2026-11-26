import { describe, expect, test } from "bun:test";
import type { BenchRow } from "./row";
import { armStats, pairStats, wilson } from "./stats";

const row = (
  taskId: string,
  armId: string,
  resolved: boolean | null,
  over: Partial<BenchRow> = {},
): BenchRow => ({
  taskId,
  armId,
  trial: 1,
  status: "ok",
  resolved,
  costUsd: 1,
  durationMs: 120_000,
  patchBytes: 1,
  note: "",
  at: "",
  ...over,
});

describe("armStats", () => {
  test("rates, cost per resolved, errors count as unresolved, pending is separate", () => {
    const rows = [
      row("a", "x", true),
      row("b", "x", false),
      row("c", "x", null, { status: "error", costUsd: 2 }),
      row("d", "x", null),
    ];
    const s = armStats(rows, "x", 1);
    expect(s).toMatchObject({
      graded: 3,
      pending: 1,
      resolved: 1,
      errors: 1,
      totalCostUsd: 5,
      costPerResolvedUsd: 5,
    });
    expect(s.resolveRate).toBeCloseTo(1 / 3);
    expect(s.medianMinutes).toBe(2);
  });

  test("cost per resolved is unknown when any run's cost is unknown", () => {
    const s = armStats([row("a", "x", true), row("b", "x", true, { costUsd: null })], "x", 1);
    expect(s.costPerResolvedUsd).toBeNull();
    expect(s.costKnownRuns).toBe(1);
  });

  test("the last row for a run wins (grading appends)", () => {
    const s = armStats([row("a", "x", null), row("a", "x", true)], "x", 1);
    expect(s).toMatchObject({ graded: 1, resolved: 1, pending: 0 });
  });

  test("pass^k over tasks with k trials", () => {
    const rows = [
      row("a", "x", true),
      row("a", "x", true, { trial: 2 }),
      row("b", "x", true),
      row("b", "x", false, { trial: 2 }),
    ];
    expect(armStats(rows, "x", 2).passK).toBe(0.5);
    expect(armStats(rows, "x", 3).passK).toBeNull();
  });
});

test("pairStats: wins, losses and an exact two-sided sign test", () => {
  const rows: BenchRow[] = [];
  for (let i = 0; i < 10; i++) rows.push(row(`t${i}`, "sw", true), row(`t${i}`, "cc", i < 2));
  const p = pairStats(rows, "sw", "cc");
  expect(p).toMatchObject({ wins: 8, losses: 0, ties: 2, tasks: 10 });
  expect(p.p).toBeCloseTo(2 / 256, 6);
  const alone = rows.filter((r) => r.armId === "sw");
  expect(pairStats(alone, "sw", "cc")).toMatchObject({ tasks: 0, p: 1 });
});

test("wilson interval", () => {
  expect(wilson(0, 0)).toBeNull();
  const [lo, hi] = wilson(5, 10) ?? [0, 0];
  expect(lo).toBeCloseTo(0.2366, 3);
  expect(hi).toBeCloseTo(0.7634, 3);
});
