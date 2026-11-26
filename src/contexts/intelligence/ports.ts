import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { AuthorStat, RepoModel } from "./domain/model";
import type { RoutingRecord } from "./domain/records";

export interface SourceFileStat {
  readonly path: string;
  readonly size: number;
  readonly mtimeMs: number;
}

/** The working tree of one repository: what the model is built from (ADR-0016). */
export interface RepoSource {
  /** Tracked files and untracked files git does not ignore, repository-relative. */
  list(root: string): Promise<Result<readonly SourceFileStat[], AdapterError>>;
  read(root: string, path: string): Promise<Result<string, AdapterError>>;
  /** The checked-out commit, or "" outside git history. */
  head(root: string): Promise<string>;
  /** Authors per path over the last `commits` commits, most active first. */
  authorship(
    root: string,
    commits: number,
  ): Promise<Result<Readonly<Record<string, readonly AuthorStat[]>>, AdapterError>>;
}

/** Where a built model is kept between runs; a cache, so a failed save never fails a query. */
export interface ModelStore {
  load(root: string): Promise<RepoModel | undefined>;
  save(model: RepoModel): Promise<Result<void, AdapterError>>;
}

export interface RepoModelPorts {
  readonly source: RepoSource;
  readonly store: ModelStore;
  readonly now: () => string;
}

/** A line-oriented stdio channel (the MCP stdio transport): one JSON message per line each way. */
export interface LineChannel {
  lines(): AsyncIterable<string>;
  write(line: string): void;
}

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
