import type { BenchArm, BenchRow, BenchTask, PlannedRun } from "../../domain/bench";
import { mayStart, pendingRuns, planRuns, spentUsd } from "../../domain/bench";
import type { ArmOutcome, BenchPorts } from "../../ports";

export interface RunRequest {
  readonly tasks: readonly BenchTask[];
  readonly arms: readonly BenchArm[];
  readonly trials: number;
  readonly budgetUsd: number;
}

export interface RunSummary {
  readonly ran: number;
  readonly skipped: number;
  readonly stoppedForBudget: boolean;
  readonly spentUsd: number;
}

type Progress = (row: BenchRow, index: number, total: number) => void;

async function grade(task: BenchTask, dir: string, out: ArmOutcome, ports: BenchPorts) {
  if (out.status !== "ok") return { resolved: false, note: out.note };
  if (task.suite === "swe-bench-verified")
    return { resolved: null, note: "awaiting swebench harness" };
  const g = await ports.grader.grade(task, dir);
  if (!g.ok) return { resolved: false, note: `grading failed: ${g.error.message}` };
  return { resolved: g.value.resolved, note: g.value.detail };
}

type RowBase = Pick<BenchRow, "taskId" | "armId" | "trial" | "at">;

/** Runs the arm in a prepared workspace, saves its patch and grades it. */
async function workOn(
  dir: string,
  base: RowBase,
  task: BenchTask,
  arm: BenchArm,
  ports: BenchPorts,
) {
  const out = await ports.arms.run(arm, task, dir);
  const diff = await ports.workspaces.diff(dir, task.baseCommit);
  const patch = diff.ok ? diff.value : "";
  await ports.store.savePatch(arm.id, task.id, base.trial, patch);
  const g =
    patch.trim() === "" && out.status === "ok"
      ? { resolved: false, note: "empty patch" }
      : await grade(task, dir, out, ports);
  const row: BenchRow = {
    ...base,
    status: diff.ok ? out.status : "error",
    resolved: g.resolved,
    costUsd: out.costUsd,
    durationMs: out.durationMs,
    patchBytes: patch.length,
    note: g.note,
  };
  return row;
}

/** Prepares a workspace, runs and grades the arm, and always disposes of the workspace. */
async function runOne(p: PlannedRun, task: BenchTask, arm: BenchArm, ports: BenchPorts) {
  const base = { taskId: p.taskId, armId: p.armId, trial: p.trial, at: "" };
  const dir = await ports.workspaces.prepare(task, `${arm.id}-${p.trial}`);
  const stamp = (row: BenchRow): BenchRow => ({ ...row, at: new Date(ports.now()).toISOString() });
  if (!dir.ok) {
    const note = `workspace: ${dir.error.message}`;
    const failed: BenchRow = {
      ...base,
      status: "error",
      resolved: null,
      costUsd: null,
      durationMs: 0,
      patchBytes: 0,
      note,
    };
    return stamp(failed);
  }
  try {
    return stamp(await workOn(dir.value, base, task, arm, ports));
  } finally {
    await ports.workspaces.dispose(dir.value);
  }
}

/**
 * Runs every pending (task, arm, trial) in a paired order, appending one row per run, and stops
 * before any run the budget cannot cover. Resumable: rows already in the store are skipped.
 */
export async function runBenchmark(req: RunRequest, ports: BenchPorts, onRow: Progress = () => {}) {
  const existing = await ports.store.rows();
  if (!existing.ok) return existing;
  const rows = [...existing.value];
  const plan = planRuns(req.tasks, req.arms, req.trials);
  const todo = pendingRuns(plan, rows);
  const tasks = new Map(req.tasks.map((t) => [t.id, t]));
  const arms = new Map(req.arms.map((a) => [a.id, a]));
  let ran = 0;
  for (const p of todo) {
    const task = tasks.get(p.taskId);
    const arm = arms.get(p.armId);
    if (!task || !arm) continue;
    if (!mayStart(spentUsd(rows, req.arms), arm.estimateUsd, req.budgetUsd)) {
      return {
        ok: true,
        value: summary(ran, plan.length - todo.length, true, rows, req.arms),
      } as const;
    }
    const row = await runOne(p, task, arm, ports);
    const saved = await ports.store.append(row);
    if (!saved.ok) return saved;
    rows.push(row);
    onRow(row, ++ran, todo.length);
  }
  return {
    ok: true,
    value: summary(ran, plan.length - todo.length, false, rows, req.arms),
  } as const;
}

function summary(
  ran: number,
  skipped: number,
  stopped: boolean,
  rows: BenchRow[],
  arms: readonly BenchArm[],
): RunSummary {
  return { ran, skipped, stoppedForBudget: stopped, spentUsd: spentUsd(rows, arms) };
}
