import type { BenchArm } from "./arm";
import { type BenchRow, rowKey } from "./row";
import type { BenchTask } from "./task";

export interface PlannedRun {
  readonly taskId: string;
  readonly armId: string;
  readonly trial: number;
}

/**
 * Every run, interleaved trial → task → arm, so a run stopped early (budget, Ctrl-C) still has
 * every arm on the same tasks and the comparison stays paired.
 */
export function planRuns(
  tasks: readonly BenchTask[],
  arms: readonly BenchArm[],
  trials: number,
): readonly PlannedRun[] {
  const plan: PlannedRun[] = [];
  for (let trial = 1; trial <= trials; trial++) {
    for (const task of tasks) {
      for (const arm of arms) plan.push({ taskId: task.id, armId: arm.id, trial });
    }
  }
  return plan;
}

/** Runs not yet in the log. A row that errored is retried; a timeout or a result is kept. */
export function pendingRuns(plan: readonly PlannedRun[], done: readonly BenchRow[]) {
  const finished = new Set(done.filter((r) => r.status !== "error").map(rowKey));
  return plan.filter((p) => !finished.has(rowKey(p)));
}

export function estimateUsd(plan: readonly PlannedRun[], arms: readonly BenchArm[]): number {
  const per = new Map(arms.map((a) => [a.id, a.estimateUsd]));
  return plan.reduce((sum, p) => sum + (per.get(p.armId) ?? 0), 0);
}

/**
 * The project budget rule (ADR-0007, PR #8734): a run may start when spent < cap and
 * spent + estimate <= cap. Unknown spend counts at the arm's estimate.
 */
export function mayStart(spentUsd: number, estimate: number, capUsd: number): boolean {
  return spentUsd < capUsd && spentUsd + estimate <= capUsd;
}

/** Spend so far in a log: reported cost, or the arm's estimate where cost is unknown. */
export function spentUsd(rows: readonly BenchRow[], arms: readonly BenchArm[]): number {
  const per = new Map(arms.map((a) => [a.id, a.estimateUsd]));
  return rows.reduce((sum, r) => sum + (r.costUsd ?? per.get(r.armId) ?? 0), 0);
}
