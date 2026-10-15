import { z } from "zod";
import type { RunHistory, RunOutcome, RunRecord } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

const GhRun = z.object({
  databaseId: z.number().int().nonnegative(),
  status: z.string(),
  conclusion: z.string().nullable(),
  createdAt: z.iso.datetime(),
  startedAt: z.iso.datetime(),
  updatedAt: z.iso.datetime(),
});
type GhRun = z.infer<typeof GhRun>;

/** Conclusions that count as a failed run. Skipped, neutral, stale and action_required runs are dropped. */
const FAILED = new Set(["failure", "timed_out", "startup_failure"]);

function outcomeOf(conclusion: string | null): RunOutcome | null {
  if (conclusion === "success") return "success";
  if (conclusion === "cancelled") return "cancelled";
  return FAILED.has(conclusion ?? "") ? "failure" : null;
}

/**
 * `null` for a completed run whose conclusion is not counted. `updatedAt` is the completion time of
 * the latest attempt. `startedAt` is the latest attempt's start (a re-run restarts it); GitHub
 * reports a zero time for a run that has not started, so that falls back to `createdAt`.
 */
export function toRunRecord(run: GhRun): RunRecord | null {
  const id = String(run.databaseId);
  const attemptStart = Date.parse(run.startedAt);
  const startedAt = attemptStart > 0 ? attemptStart : Date.parse(run.createdAt);
  if (run.status !== "completed") return { id, startedAt, finished: null };
  const outcome = outcomeOf(run.conclusion);
  if (outcome === null) return null;
  return { id, startedAt, finished: { at: Date.parse(run.updatedAt), outcome } };
}

/** Pipeline run history from GitHub Actions. The repo comes from the cwd or `GH_REPO`. */
export class GhRunHistory implements RunHistory {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly workflow = "shipwright-pipeline.yml",
  ) {}

  async recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>> {
    if (!Number.isSafeInteger(limit) || limit < 1) {
      return err({ kind: "failed", message: `invalid limit: ${limit}` });
    }
    const fields = "databaseId,status,conclusion,createdAt,startedAt,updatedAt";
    const argv = ["gh", "run", "list", "--workflow", this.workflow, "--limit", String(limit)];
    const runs = await runGhJson(this.runner, [...argv, "--json", fields], z.array(GhRun));
    if (!runs.ok) return runs;
    return ok(runs.value.map(toRunRecord).filter((r): r is RunRecord => r !== null));
  }
}
