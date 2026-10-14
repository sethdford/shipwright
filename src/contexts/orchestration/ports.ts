import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { GithubWriter } from "../integrations";
import type { RunRecord } from "./domain/breaker";
import type { CostEntry, DailyBudget } from "./domain/budget";
import type { PullSummary } from "./domain/flow";
import type { IssueSummary } from "./domain/intake";
import type { LocalPause } from "./domain/pause";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}

/** The local pause flag file the bash daemon also reads (`~/.shipwright/daemon-pause.flag`). */
export interface PauseFlag {
  /** `null` when no flag is set. */
  read(): Promise<Result<LocalPause | null, AdapterError>>;
  write(reason: string, at: string): Promise<Result<void, AdapterError>>;
  /** Idempotent: clearing an absent flag is ok. */
  clear(): Promise<Result<void, AdapterError>>;
}

/** Open issues carrying the `shipwright:pause` label. */
export interface PauseLabel {
  labelled(): Promise<Result<readonly number[], AdapterError>>;
}

/** Spend and the daily cap, as recorded by `shipwright cost` (read-only). */
export interface CostLedger {
  read(): Promise<
    Result<
      {
        /** `null` when no cap is enabled. */
        readonly budget: DailyBudget | null;
        readonly entries: readonly CostEntry[];
        /** False when no cost file exists at all (a CI runner): nothing was recorded to check. */
        readonly present: boolean;
      },
      AdapterError
    >
  >;
}

/** Open pull requests, for the review-WIP limit. */
export interface PullRequests {
  open(): Promise<Result<readonly PullSummary[], AdapterError>>;
}

/** Open issues, for intake caps and dedupe. */
export interface OpenIssues {
  open(): Promise<Result<readonly IssueSummary[], AdapterError>>;
}

/** Everything the safety gates read or write, wired in src/main.ts. */
export interface SafetyPorts {
  readonly now: () => number;
  readonly runs: RunHistory;
  readonly pauseFlag: PauseFlag;
  readonly pauseLabel: PauseLabel;
  readonly github: GithubWriter;
  readonly costs: CostLedger;
  readonly pulls: PullRequests;
  readonly issues: OpenIssues;
}
