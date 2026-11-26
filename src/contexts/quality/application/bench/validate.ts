import type { BenchTask } from "../../domain/bench";
import type { BenchPorts } from "../../ports";

export interface OracleCheck {
  readonly taskId: string;
  /** The hidden tests fail on the base commit (they test something not yet there). */
  readonly failsOnBase: boolean | null;
  /** The hidden tests pass on the gold fix. */
  readonly passesOnGold: boolean | null;
  readonly note: string;
}

async function gradeAt(
  task: BenchTask,
  commit: string | null,
  ports: Pick<BenchPorts, "workspaces" | "grader">,
) {
  const dir = await ports.workspaces.prepare(task, "validate");
  if (!dir.ok) return { value: null, note: dir.error.message };
  try {
    if (commit !== null) {
      const c = await ports.workspaces.checkout(dir.value, commit);
      if (!c.ok) return { value: null, note: c.error.message };
    }
    const g = await ports.grader.grade(task, dir.value);
    return g.ok
      ? { value: g.value.resolved, note: g.value.detail }
      : { value: null, note: g.error.message };
  } finally {
    await ports.workspaces.dispose(dir.value);
  }
}

/**
 * The oracle check for a holdout task (the SWE-bench FAIL_TO_PASS rule): its hidden tests must
 * fail on the base commit and pass on the gold fix. A task failing either is not a fair task.
 */
export async function validateTask(
  task: BenchTask,
  ports: Pick<BenchPorts, "workspaces" | "grader">,
): Promise<OracleCheck> {
  if (task.suite !== "holdout" || task.goldCommit === null) {
    return {
      taskId: task.id,
      failsOnBase: null,
      passesOnGold: null,
      note: "not a holdout task with a gold commit",
    };
  }
  const base = await gradeAt(task, null, ports);
  const gold = await gradeAt(task, task.goldCommit, ports);
  const failsOnBase = base.value === null ? null : !base.value;
  return {
    taskId: task.id,
    failsOnBase,
    passesOnGold: gold.value,
    note: `base: ${base.note}; gold: ${gold.note}`,
  };
}

export const oracleOk = (c: OracleCheck) => c.failsOnBase === true && c.passesOnGold === true;
