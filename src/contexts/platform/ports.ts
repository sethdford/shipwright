import type { AdapterError, AgentRunner, ProcessResult } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";

/** Where a recipe came from. Only `committed` and `detected` recipes run without `--trust-worktree`. */
export type RecipeOrigin = "committed" | "worktree" | "detected";

/** Read-only view of a checkout (ADR-0020). Paths are relative to `root`; the adapter refuses escapes. */
export interface EnvSource {
  /** The file at `ref` (`git show ref:path`), or null when the ref does not have it. */
  fileAt(root: string, ref: string, path: string): Promise<Result<string | null, AdapterError>>;
  /** The working-tree file, or null when it does not exist. */
  readFile(root: string, path: string): Promise<Result<string | null, AdapterError>>;
  /** sha256 of each working-tree file's bytes, null for a missing file. */
  digests(
    root: string,
    paths: readonly string[],
  ): Promise<Result<Record<string, string | null>, AdapterError>>;
  /** Names of the files and directories directly in `root` (for detection). */
  rootEntries(root: string): Promise<Result<readonly string[], AdapterError>>;
  /** A stable id for the repository the checkout belongs to (same for every worktree and clone of it). */
  repoId(root: string): Promise<Result<string, AdapterError>>;
}

export interface CacheEntry {
  readonly repoId: string;
  readonly key: string;
  readonly createdAt: string;
  /** Last restore (or creation) time, for pruning. */
  readonly usedAt: string;
  readonly bytes: number;
  readonly paths: readonly string[];
}

/**
 * Content-addressed store of built environments. Restores are copy-on-write clones where the
 * filesystem supports them (APFS `clonefile`, Linux reflink), plain copies otherwise. Entries
 * are written to a staging directory and renamed into place, so a reader never sees half of one.
 */
export interface EnvCache {
  /** Absolute directory of an entry (for `actions/cache`), whether or not it exists. */
  dirFor(repoId: string, key: string): string;
  get(repoId: string, key: string): Promise<Result<CacheEntry | null, AdapterError>>;
  /** Copies the entry's paths into `dir`, replacing what is there; updates `usedAt`. */
  restore(entry: CacheEntry, dir: string): Promise<Result<void, AdapterError>>;
  /** Copies `paths` (those that exist) out of `dir`. "exists" when another run saved it first. */
  save(
    repoId: string,
    key: string,
    dir: string,
    paths: readonly string[],
  ): Promise<Result<"saved" | "exists", AdapterError>>;
  list(repoId: string): Promise<Result<readonly CacheEntry[], AdapterError>>;
  remove(repoId: string, key: string): Promise<Result<void, AdapterError>>;
}

/**
 * Runs recipe commands. The adapter strips GitHub, git and Claude credentials (test-gate-env.sh).
 * In a test-sandbox-shaped directory (the scratch clones of `env init`) it applies the sandbox's
 * OS write jail. `env` adds to the scrubbed environment; it never replaces PATH or HOME.
 */
export interface EnvExecutor {
  run(
    argv: readonly string[],
    cwd: string,
    env: Readonly<Record<string, string>>,
    timeoutMs: number,
    opts?: ExecOptions,
  ): Promise<ProcessResult>;
}

export interface ExecOptions {
  /** Fail (exit 126) rather than run without the OS write jail: for unreviewed, agent-written recipes. */
  readonly requireJail?: boolean;
}

/** Disposable clones for `env init`: never the operator's checkout. */
export interface Scratch {
  /** A fresh clone of `root` at `ref`, outside it. */
  clone(root: string, ref: string): Promise<Result<string, AdapterError>>;
  /** Writes a file into a checkout (creating parents); used to hand a validated recipe back. */
  write(root: string, path: string, text: string): Promise<Result<void, AdapterError>>;
  /** Idempotent. */
  remove(dir: string): Promise<Result<void, AdapterError>>;
}

export interface EnvPorts {
  readonly source: EnvSource;
  readonly cache: EnvCache;
  readonly exec: EnvExecutor;
  readonly scratch: Scratch;
  readonly agent: () => AgentRunner;
  readonly digest: (text: string) => string;
  readonly platform: { readonly os: string; readonly arch: string };
  readonly sleep: (ms: number) => Promise<void>;
  readonly now: () => number;
}
