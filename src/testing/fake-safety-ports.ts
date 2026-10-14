import type { GithubWriter, IncidentOutcome, IncidentReport } from "../contexts/integrations";
import type {
  CostEntry,
  CostLedger,
  DailyBudget,
  LocalPause,
  PauseFlag,
  PauseLabel,
  PullRequests,
  PullSummary,
  RunHistory,
  RunRecord,
  SafetyPorts,
} from "../contexts/orchestration";
import type { IdempotencyKey } from "../shared/kernel/durability";
import type { AdapterError } from "../shared/kernel/ports";
import { ok, type Result } from "../shared/kernel/result";

export const NOW = Date.parse("2026-10-14T12:00:00Z");

export class MemoryPauseFlag implements PauseFlag {
  constructor(public flag: LocalPause | null = null) {}
  async read(): Promise<Result<LocalPause | null, AdapterError>> {
    return ok(this.flag);
  }
  async write(reason: string, at: string): Promise<Result<void, AdapterError>> {
    this.flag = { reason, since: at, resumeAfter: null };
    return ok(undefined);
  }
  async clear(): Promise<Result<void, AdapterError>> {
    this.flag = null;
    return ok(undefined);
  }
}

export class RecordingGithubWriter implements GithubWriter {
  readonly calls: { key: IdempotencyKey; report: IncidentReport }[] = [];
  constructor(
    private readonly result: Result<IncidentOutcome, AdapterError> = ok({
      issue: 900,
      action: "created",
    }),
  ) {}
  async ensureIncident(key: IdempotencyKey, report: IncidentReport) {
    this.calls.push({ key, report });
    return this.result;
  }
}

export const fixedRuns = (r: Result<readonly RunRecord[], AdapterError>): RunHistory => ({
  recentRuns: async () => r,
});
export const fixedLabel = (r: Result<readonly number[], AdapterError>): PauseLabel => ({
  labelled: async () => r,
});

export const fixedCosts = (
  budget: DailyBudget | null,
  entries: readonly CostEntry[] = [],
): CostLedger => ({ read: async () => ok({ budget, entries, present: true }) });

export const fixedPulls = (r: Result<readonly PullSummary[], AdapterError>): PullRequests => ({
  open: async () => r,
});

/** Safety ports with harmless defaults: no runs, no pause flag, label or cap, a recording incident writer. */
export function fakeSafetyPorts(over: Partial<SafetyPorts> = {}): SafetyPorts {
  return {
    now: () => NOW,
    runs: fixedRuns(ok([])),
    pauseFlag: new MemoryPauseFlag(),
    pauseLabel: fixedLabel(ok([])),
    github: new RecordingGithubWriter(),
    costs: fixedCosts(null),
    pulls: fixedPulls(ok([])),
    ...over,
  };
}
