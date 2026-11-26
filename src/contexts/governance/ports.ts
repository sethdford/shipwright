import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";

/**
 * Where governance documents are read from. `ref` set: the files committed at that git ref, so an agent's
 * uncommitted or later edits cannot change what it is told (the same rule as review memory, #8673).
 * `ref` unset: the tracked files of the working tree.
 */
export interface DocSource {
  readonly root: string;
  readonly ref?: string;
}

export interface RepoDocs {
  /** Repository-relative paths of tracked files under any of these directory prefixes. */
  list(
    source: DocSource,
    prefixes: readonly string[],
  ): Promise<Result<readonly string[], AdapterError>>;
  read(source: DocSource, path: string): Promise<Result<string, AdapterError>>;
}
