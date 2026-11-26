import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { PullRecord } from "./domain/scorecard";

/** Closed pull requests of the current repository (read-only). */
export interface ClosedPulls {
  /** PRs closed at or after `sinceMs`. `truncated` is true when the source hit its page cap. */
  closedSince(
    sinceMs: number,
  ): Promise<
    Result<{ readonly pulls: readonly PullRecord[]; readonly truncated: boolean }, AdapterError>
  >;
}

/** Recorded model spend (read-only). `null` when nothing was recorded on this machine. */
export interface SpendSource {
  between(fromMs: number, toMs: number): Promise<Result<number | null, AdapterError>>;
}

/** Everything the quality commands read, wired in src/main.ts. */
export interface QualityPorts {
  readonly now: () => number;
  readonly pulls: ClosedPulls;
  readonly spend: SpendSource;
}
