import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { RunRecord } from "./domain/breaker";

/** Recent pipeline runs, shared by every machine (GitHub Actions history in Wave 1a). */
export interface RunHistory {
  /** Up to `limit` of the newest runs, including queued and running ones. */
  recentRuns(limit: number): Promise<Result<readonly RunRecord[], AdapterError>>;
}
