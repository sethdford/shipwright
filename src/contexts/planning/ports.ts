import type { AdapterError, ProcessResult } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";

/**
 * The repository the acceptance tests live in. Paths are repository-relative; the adapter
 * refuses anything outside the root.
 */
export interface AcceptanceWorkspace {
  readText(path: string): Promise<Result<string, AdapterError>>;
  /** Creates parent directories. */
  writeText(path: string, text: string): Promise<Result<void, AdapterError>>;
  /** True when the path exists in the working tree (tracked or not). */
  exists(path: string): Promise<boolean>;
  headCommit(): Promise<Result<string, AdapterError>>;
  /** The blob id of `path` at `commit`, or null when the commit does not have it. */
  blobAt(commit: string, path: string): Promise<Result<string | null, AdapterError>>;
  /** The blob id the working-tree file would have (`git hash-object`). */
  worktreeBlob(path: string): Promise<Result<string, AdapterError>>;
  /** `git diff -M <commit>` of the working tree, as unified diff text. */
  diffSince(commit: string): Promise<Result<string, AdapterError>>;
  /** Puts the file back exactly as `commit` has it. */
  restore(commit: string, path: string): Promise<Result<void, AdapterError>>;
}

/** Runs one test argv with no credentials in the environment (scripts/lib/test-gate-env.sh). */
export interface TestExecutor {
  run(argv: readonly string[], timeoutMs: number): Promise<ProcessResult>;
}

/** Reads and writes the pipeline's artifacts (absolute paths outside the agent's view of the repo). */
export interface ArtifactStore {
  read(path: string): Promise<Result<string, AdapterError>>;
  write(path: string, text: string): Promise<Result<void, AdapterError>>;
}
