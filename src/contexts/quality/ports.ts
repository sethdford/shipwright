import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { PullCommit, PullRecord } from "./domain/scorecard";

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
