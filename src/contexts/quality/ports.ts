import type { AdapterError, AgentRunner } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { BenchArm, BenchRow, BenchTask, MergedPull, RunStatus } from "./domain/bench";
import type { FileChange } from "./domain/change-features";
import type { SurvivalInput } from "./domain/code-survival";
import type { ScoreRecord } from "./domain/score-log";
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

// ── Head-to-head benchmark (ADR-0013) ────────────────────────────────────────

/** A fresh checkout of a task's repo at its base commit, with setup already run. */
export interface BenchWorkspaces {
  prepare(task: BenchTask, label: string): Promise<Result<string, AdapterError>>;
  /** Every change since `baseCommit` (committed or not) as one unified diff. */
  diff(dir: string, baseCommit: string): Promise<Result<string, AdapterError>>;
  /** Checks out `commit` in a prepared workspace (used by `bench validate` for the gold fix). */
  checkout(dir: string, commit: string): Promise<Result<void, AdapterError>>;
  dispose(dir: string): Promise<void>;
}

export interface ArmOutcome {
  readonly status: RunStatus;
  readonly costUsd: number | null;
  readonly durationMs: number;
  readonly note: string;
}

/** Runs one arm on one prepared workspace. Never throws: failures come back as status "error". */
export interface ArmRunner {
  run(arm: BenchArm, task: BenchTask, dir: string): Promise<ArmOutcome>;
}

/** Applies a holdout task's hidden tests over the work in `dir` and runs them. */
export interface BenchGrader {
  grade(
    task: BenchTask,
    dir: string,
  ): Promise<Result<{ resolved: boolean; detail: string }, AdapterError>>;
}

/** The results directory: an append-only JSONL log, saved patches and rendered reports. */
export interface BenchStore {
  rows(): Promise<Result<readonly BenchRow[], AdapterError>>;
  append(row: BenchRow): Promise<Result<void, AdapterError>>;
  savePatch(
    armId: string,
    taskId: string,
    trial: number,
    patch: string,
  ): Promise<Result<void, AdapterError>>;
  readPatch(
    armId: string,
    taskId: string,
    trial: number,
  ): Promise<Result<string | null, AdapterError>>;
  write(name: string, text: string): Promise<Result<string, AdapterError>>;
}

export interface BenchPorts {
  readonly now: () => number;
  readonly workspaces: BenchWorkspaces;
  readonly arms: ArmRunner;
  readonly grader: BenchGrader;
  readonly store: BenchStore;
}

/** Merged PRs and issues of a repository, for mining holdout tasks (read-only). */
export interface HoldoutSource {
  /** Merged PRs since `sinceMs`, newest first, with changed files and the merge commit's parent. */
  mergedSince(sinceMs: number, max: number): Promise<Result<readonly MergedPull[], AdapterError>>;
  issue(
    n: number,
  ): Promise<Result<{ title: string; body: string; createdAt: string }, AdapterError>>;
  /** Unified diff between two commits. */
  diff(base: string, head: string): Promise<Result<string, AdapterError>>;
}

/** Builds benchmark adapters for a results directory, and holdout sources per repo. */
export interface BenchFactory {
  ports(outDir: string): BenchPorts;
  holdout(repo: string): HoldoutSource;
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
  /** The checked-out branch (empty when detached) and its commit. */
  head(): Promise<Result<{ readonly branch: string; readonly sha: string }, AdapterError>>;
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

/**
 * What a merged change added, and the same files `horizonMs` after the merge, from local git
 * history (read-only). `null` when the commits are not in the local clone or the horizon commit
 * does not contain the merge: the PR then keeps its merge label.
 */
export interface SurvivalSource {
  read(
    mergeSha: string,
    mergedAtMs: number,
    horizonMs: number,
  ): Promise<Result<SurvivalInput | null, AdapterError>>;
}

/**
 * The verifier's own score log: one record per `verify score`, keyed by branch, so training can
 * join the critic's and the run's signals to each PR's later outcome (W2-08).
 */
export interface ScoreLog {
  append(r: ScoreRecord): Promise<Result<void, AdapterError>>;
  all(): Promise<Result<readonly ScoreRecord[], AdapterError>>;
}

/** Everything the verifier commands use, wired in src/main.ts. */
export interface VerifierPorts {
  readonly now: () => number;
  readonly pulls: ClosedPulls;
  readonly files: PullFiles;
  readonly change: LocalChange;
  readonly store: VerifierStore;
  readonly agent: AgentRunner;
  readonly survival: SurvivalSource;
  readonly scores: ScoreLog;
}
