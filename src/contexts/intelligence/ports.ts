import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { RoutingRecord } from "./domain/records";

/** The routing log: append-only decisions and outcomes, one JSON object per line. */
export interface RoutingLog {
  /** Every record, oldest first. A missing log is empty; a malformed one is an error. */
  read(): Promise<Result<readonly RoutingRecord[], AdapterError>>;
  append(record: RoutingRecord): Promise<Result<void, AdapterError>>;
}

export interface RoutingPorts {
  readonly log: RoutingLog;
  /** Epoch milliseconds. */
  readonly now: () => number;
}
