import {
  type ArmStats,
  armStats,
  type BenchArm,
  type BenchManifest,
  type BenchRow,
  latestRows,
  type PairStats,
  pairStats,
} from "../../domain/bench";

export interface TaskLine {
  readonly taskId: string;
  /** Per arm: resolved trials / graded trials, or null when not graded yet. */
  readonly cells: readonly (readonly [number, number] | null)[];
}

export interface BenchReport {
  readonly manifest: string;
  readonly suites: readonly string[];
  readonly taskCount: number;
  readonly k: number;
  readonly arms: readonly (ArmStats & {
    readonly label: string;
    readonly model: string;
    readonly kind: string;
  })[];
  readonly baseline: string;
  readonly pairs: readonly PairStats[];
  readonly tasks: readonly TaskLine[];
  readonly generatedAt: string;
}

function cell(
  rows: readonly BenchRow[],
  taskId: string,
  armId: string,
): readonly [number, number] | null {
  const mine = rows.filter(
    (r) => r.taskId === taskId && r.armId === armId && (r.resolved !== null || r.status !== "ok"),
  );
  return mine.length === 0 ? null : [mine.filter((r) => r.resolved === true).length, mine.length];
}

/** Everything a results page shows, computed from the log alone (no model, no network). */
export function buildBenchReport(
  manifest: BenchManifest,
  arms: readonly BenchArm[],
  baseline: string,
  rows: readonly BenchRow[],
  k: number,
  nowMs: number,
): BenchReport {
  const ids = new Set(manifest.tasks.map((t) => t.id));
  const mine = latestRows(rows).filter((r) => ids.has(r.taskId));
  return {
    manifest: manifest.name,
    suites: [...new Set(manifest.tasks.map((t) => t.suite))],
    taskCount: manifest.tasks.length,
    k,
    arms: arms.map((a) => ({
      ...armStats(mine, a.id, k),
      label: a.label,
      model: a.model,
      kind: a.kind,
    })),
    baseline,
    pairs: arms.filter((a) => a.id !== baseline).map((a) => pairStats(mine, a.id, baseline)),
    tasks: manifest.tasks.map((t) => ({
      taskId: t.id,
      cells: arms.map((a) => cell(mine, t.id, a.id)),
    })),
    generatedAt: new Date(nowMs).toISOString(),
  };
}
