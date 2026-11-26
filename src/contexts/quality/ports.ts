import type { AdapterError, AgentRunner } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { FileChange } from "./domain/change-features";
import type { PullCommit, PullRecord } from "./domain/scorecard";
import type { VerifierModel } from "./domain/verifier-model";
import type { Evidence } from "./domain/verifier-policy";

/** Closed pull requests of the current repository (read-only). */
export interface ClosedPulls {
  /**
   * PRs closed at or after `sinceMs`, with empty commit lists (commits are read per PR, below).
   * `truncated` is true when the source hit its cap and older PRs in the window may be missing.
   */
  closedSince(
    sinceMs: number,
  ): Promise<
    Result<{ readonly pulls: readonly PullRecord[]; readonly truncated: boolean }, AdapterError>
  >;
  /** The commits of one PR. */
  commits(pr: number): Promise<Result<readonly PullCommit[], AdapterError>>;
}

/** Recorded model spend (read-only). `null` when no real spend was recorded in the window. */
export interface SpendSource {
  between(fromMs: number, toMs: number): Promise<Result<number | null, AdapterError>>;
}

/** Everything the quality commands read, wired in src/main.ts. */
export interface QualityPorts {
  readonly now: () => number;
  readonly pulls: ClosedPulls;
  readonly spend: SpendSource;
}

/** Per-file line counts of one PR (read-only). */
export interface PullFiles {
  files(pr: number): Promise<Result<readonly FileChange[], AdapterError>>;
}

/** The change on the current branch that is not a PR yet: `git diff base...HEAD`. */
export interface LocalChange {
  diff(
    baseRef: string,
  ): Promise<
    Result<{ readonly files: readonly FileChange[]; readonly patch: string }, AdapterError>
  >;
}

/** The verifier as last trained, with the evidence that decides whether it may block. */
export interface StoredVerifier {
  readonly model: VerifierModel;
  readonly evidence: Evidence;
}

/** Where the trained verifier lives (a JSON file in the state directory). */
export interface VerifierStore {
  /** `null` when nothing was trained yet. */
  load(): Promise<Result<StoredVerifier | null, AdapterError>>;
  save(v: StoredVerifier): Promise<Result<void, AdapterError>>;
}

/** Everything the verifier commands use, wired in src/main.ts. */
export interface VerifierPorts {
  readonly now: () => number;
  readonly pulls: ClosedPulls;
  readonly files: PullFiles;
  readonly change: LocalChange;
  readonly store: VerifierStore;
  readonly agent: AgentRunner;
}
