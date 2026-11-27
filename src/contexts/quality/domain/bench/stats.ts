import { passHatK } from "../pass-k";
import { median, signTestP } from "../ratchet";
import { type BenchRow, isVoided, latestRows } from "./row";

export interface ArmStats {
  readonly armId: string;
  readonly tasks: number;
  readonly graded: number;
  readonly pending: number;
  readonly resolved: number;
  /** Resolved graded runs ÷ graded runs (pass@1 averaged over trials). */
  readonly resolveRate: number | null;
  /** Wilson 95% interval on the resolve rate. */
  readonly ci95: readonly [number, number] | null;
  /** Mean pass^k over tasks with at least k graded trials; null when none have. */
  readonly passK: number | null;
  readonly totalCostUsd: number;
  readonly costKnownRuns: number;
  readonly costPerResolvedUsd: number | null;
  readonly medianMinutes: number | null;
  readonly errors: number;
  readonly timeouts: number;
  /** Runs with any integrity flag, and those voided by one (counted as unresolved). */
  readonly flagged: number;
  readonly voided: number;
}

/** Wilson score interval for x successes in n trials at z = 1.96. */
export function wilson(x: number, n: number): readonly [number, number] | null {
  if (n <= 0) return null;
  const z = 1.96;
  const p = x / n;
  const denom = 1 + (z * z) / n;
  const centre = (p + (z * z) / (2 * n)) / denom;
  const half = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / denom;
  return [Math.max(0, centre - half), Math.min(1, centre + half)];
}

function meanPassK(graded: readonly BenchRow[], k: number): number | null {
  const byTask = new Map<string, BenchRow[]>();
  for (const r of graded) byTask.set(r.taskId, [...(byTask.get(r.taskId) ?? []), r]);
  const values: number[] = [];
  for (const list of byTask.values()) {
    const v = passHatK(list.length, list.filter((r) => r.resolved).length, k);
    if (v !== null) values.push(v);
  }
  return values.length === 0 ? null : values.reduce((s, v) => s + v, 0) / values.length;
}

/** Headline numbers for one arm. Errored runs count as unresolved: a crash is not a skip. */
export function armStats(all: readonly BenchRow[], armId: string, k: number): ArmStats {
  const rows = latestRows(all).filter((r) => r.armId === armId);
  const graded = rows.filter((r) => r.resolved !== null || r.status !== "ok");
  const asGraded = graded.map((r) => ({ ...r, resolved: r.resolved === true }));
  const resolved = asGraded.filter((r) => r.resolved).length;
  const costed = rows.filter((r) => r.costUsd !== null);
  const totalCostUsd = costed.reduce((s, r) => s + (r.costUsd ?? 0), 0);
  const allCosted = costed.length === rows.length && rows.length > 0;
  const mins = median(rows.map((r) => r.durationMs / 60_000));
  return {
    armId,
    tasks: new Set(rows.map((r) => r.taskId)).size,
    graded: graded.length,
    pending: rows.length - graded.length,
    resolved,
    resolveRate: graded.length === 0 ? null : resolved / graded.length,
    ci95: wilson(resolved, graded.length),
    passK: meanPassK(asGraded, k),
    totalCostUsd,
    costKnownRuns: costed.length,
    costPerResolvedUsd: allCosted && resolved > 0 ? totalCostUsd / resolved : null,
    medianMinutes: mins,
    errors: rows.filter((r) => r.status === "error").length,
    timeouts: rows.filter((r) => r.status === "timeout").length,
    flagged: rows.filter((r) => (r.flags ?? []).length > 0).length,
    voided: rows.filter(isVoided).length,
  };
}

export interface PairStats {
  readonly armId: string;
  readonly baselineId: string;
  readonly tasks: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  /** Exact two-sided sign test on per-task pass@1 differences. */
  readonly p: number;
}

function perTaskRate(rows: readonly BenchRow[], armId: string): Map<string, number> {
  const sums = new Map<string, { n: number; x: number }>();
  for (const r of rows) {
    if (r.armId !== armId || (r.resolved === null && r.status === "ok")) continue;
    const s = sums.get(r.taskId) ?? { n: 0, x: 0 };
    sums.set(r.taskId, { n: s.n + 1, x: s.x + (r.resolved === true ? 1 : 0) });
  }
  return new Map([...sums].map(([id, s]) => [id, s.x / s.n]));
}

/** Paired comparison on tasks both arms have graded runs for. */
export function pairStats(all: readonly BenchRow[], armId: string, baselineId: string): PairStats {
  const rows = latestRows(all);
  const a = perTaskRate(rows, armId);
  const b = perTaskRate(rows, baselineId);
  let wins = 0;
  let losses = 0;
  let ties = 0;
  for (const [task, rate] of a) {
    const base = b.get(task);
    if (base === undefined) continue;
    if (rate > base) wins++;
    else if (rate < base) losses++;
    else ties++;
  }
  const n = wins + losses;
  const p = Math.min(1, 2 * Math.min(signTestP(wins, n), signTestP(losses, n)));
  return { armId, baselineId, tasks: wins + losses + ties, wins, losses, ties, p: n === 0 ? 1 : p };
}
