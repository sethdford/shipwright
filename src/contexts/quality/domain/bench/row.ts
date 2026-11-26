import { accept, isRecord, type Parsed, reject } from "./parsed";

export type RunStatus = "ok" | "error" | "timeout";

/**
 * One run of one arm on one task. `resolved` is null until graded (SWE-bench rows wait for the
 * official harness). `costUsd` is null when the arm reported no spend: unknown is never $0.
 * The log is append-only; the last row for a (task, arm, trial) wins, so grading appends.
 */
export interface BenchRow {
  readonly taskId: string;
  readonly armId: string;
  readonly trial: number;
  readonly status: RunStatus;
  readonly resolved: boolean | null;
  readonly costUsd: number | null;
  readonly durationMs: number;
  readonly patchBytes: number;
  readonly note: string;
  readonly at: string;
}

export const rowKey = (r: Pick<BenchRow, "taskId" | "armId" | "trial">) =>
  `${r.taskId}\u0000${r.armId}\u0000${r.trial}`;

function validCost(v: unknown): v is number | null {
  return v === null || (typeof v === "number" && Number.isFinite(v) && v >= 0);
}

export function parseRow(value: unknown): Parsed<BenchRow> {
  if (!isRecord(value)) return reject("row is not an object");
  const r = value as Partial<Record<keyof BenchRow, unknown>>;
  const ids = typeof r.taskId === "string" && typeof r.armId === "string";
  const trial = typeof r.trial === "number" && Number.isInteger(r.trial) && r.trial >= 1;
  const status = r.status === "ok" || r.status === "error" || r.status === "timeout";
  const resolved = r.resolved === null || typeof r.resolved === "boolean";
  const nums = typeof r.durationMs === "number" && typeof r.patchBytes === "number";
  if (!(ids && trial && status && resolved && nums && validCost(r.costUsd))) {
    return reject("row is missing fields or has wrong types");
  }
  return accept({
    ...(value as unknown as BenchRow),
    note: typeof r.note === "string" ? r.note : "",
    at: typeof r.at === "string" ? r.at : "",
  });
}

/** The newest row per (task, arm, trial). */
export function latestRows(rows: readonly BenchRow[]): readonly BenchRow[] {
  const byKey = new Map<string, BenchRow>();
  for (const row of rows) byKey.set(rowKey(row), row);
  return [...byKey.values()];
}
