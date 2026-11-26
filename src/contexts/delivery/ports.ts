import type { AdapterError, AgentRunner } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";

/** An isolated checkout (a git worktree) where one attempt works. */
export interface Workspace {
  readonly label: string;
  readonly path: string;
}

/** A finished attempt, committed locally (never pushed). */
export interface Snapshot {
  readonly sha: string;
  /** `git diff base..sha`; empty when the attempt changed nothing. */
  readonly patch: string;
  /** Paths the attempt added or modified (not deleted). */
  readonly files: readonly string[];
}

/** Git worktrees for tournament attempts. Nothing here pushes or touches a remote. */
export interface Workspaces {
  /** The commit the repository's current branch points at. */
  baseSha(): Promise<Result<string, AdapterError>>;
  /** A new detached worktree at `baseSha`, outside the repository's working tree. */
  create(label: string, baseSha: string): Promise<Result<Workspace, AdapterError>>;
  /** Commits every change in the workspace (if any) and returns it relative to `baseSha`. */
  snapshot(ws: Workspace, baseSha: string): Promise<Result<Snapshot, AdapterError>>;
  /** Checks `files` out of commit `sha` into the workspace (to run another attempt's tests). */
  overlay(
    ws: Workspace,
    sha: string,
    files: readonly string[],
  ): Promise<Result<void, AdapterError>>;
  /** Puts the workspace back exactly at `sha`, removing untracked files. */
  reset(ws: Workspace, sha: string): Promise<Result<void, AdapterError>>;
  /** Idempotent. */
  remove(ws: Workspace): Promise<Result<void, AdapterError>>;
  /** Fast-forwards the repository's current branch to `sha`; fails if the branch has moved. */
  adopt(sha: string): Promise<Result<void, AdapterError>>;
}

export interface CommandOutcome {
  readonly passed: boolean;
  readonly timedOut: boolean;
  /** The last lines of output, for the report. */
  readonly tail: string;
}

/** Runs an operator-configured command (test or setup) in a workspace. Never model or issue text. */
export interface CommandRunner {
  run(
    command: string,
    cwd: string,
    timeoutMs: number,
  ): Promise<Result<CommandOutcome, AdapterError>>;
}

export interface DeliveryPorts {
  readonly agent: AgentRunner;
  readonly workspaces: Workspaces;
  readonly commands: CommandRunner;
  /** In [0, 1); injected so tests are deterministic. */
  readonly random: () => number;
}
