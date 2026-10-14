import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";

export interface IncidentReport {
  readonly title: string;
  readonly body: string;
}
export type IncidentAction = "created" | "commented" | "unchanged";
export interface IncidentOutcome {
  readonly issue: number;
  readonly action: IncidentAction;
}

/**
 * GitHub side effects (rule F10). Every method takes an `IdempotencyKey` and reconciles before it
 * acts, so a retried or concurrent call never writes twice for the same key. Implemented only in
 * `src/adapters/github/gh-github-writer.ts`; an ast-grep rule keeps `gh` writes out of other files.
 */
export interface GithubWriter {
  /**
   * Keeps one open incident issue: creates it, or comments on the open one, once per `key`.
   * A key already recorded on the open incident is `unchanged`.
   */
  ensureIncident(
    key: IdempotencyKey,
    report: IncidentReport,
  ): Promise<Result<IncidentOutcome, AdapterError>>;
}
