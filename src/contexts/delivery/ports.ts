import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError, AgentRunner } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";
import type { CheckRun } from "./domain/steward-ci";
import type { PrComment } from "./domain/steward-reviews";

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

/** What the merge verifier needs to score one tournament candidate. */
export interface VerifierInput {
  readonly goal: string;
  readonly patch: string;
  readonly ownTestsPass: boolean;
  readonly cross: number | null;
  readonly rubric: number | null;
}

/**
 * The merge verifier (quality context, ADR-0012) as the tournament sees it: a probability in
 * [0, 1] that the candidate merges and stays merged, or null when it cannot score. Never throws.
 */
export interface CandidateVerifier {
  score(input: VerifierInput): Promise<number | null>;
}

export interface DeliveryPorts {
  readonly agent: AgentRunner;
  readonly workspaces: Workspaces;
  readonly commands: CommandRunner;
  /** Optional: when wired, its score is one more selection signal. */
  readonly verifier?: CandidateVerifier;
  /** In [0, 1); injected so tests are deterministic. */
  readonly random: () => number;
}

// ── PR steward (ADR-0017) ────────────────────────────────────────────────────

/** An open (or closed) pull request as the steward needs it. */
export interface PullSnapshot {
  readonly number: number;
  readonly state: "open" | "closed" | "merged";
  readonly headSha: string;
  readonly baseSha: string;
  readonly headRef: string;
  /** The head branch lives in another repository (a fork): the steward never acts on it. */
  readonly crossRepository: boolean;
}

/** Read-only GitHub access for the steward. */
export interface StewardReader {
  /** The login the GitHub credentials act as (the steward's replies carry it). */
  self(): Promise<Result<string, AdapterError>>;
  pull(pr: number): Promise<Result<PullSnapshot, AdapterError>>;
  /** Check runs and commit statuses on a commit, newest first. */
  checkRuns(sha: string): Promise<Result<readonly CheckRun[], AdapterError>>;
  /** The login's repository permission: admin, maintain, write, triage, read or none. */
  permission(login: string): Promise<Result<string, AdapterError>>;
  /** An Actions job's log text. */
  jobLog(jobId: number): Promise<Result<string, AdapterError>>;
  /** Inline review comments, review bodies and conversation comments, oldest first. */
  comments(pr: number): Promise<Result<readonly PrComment[], AdapterError>>;
}

export type WriteOutcome = "done" | "unchanged";

/**
 * The steward's GitHub writes (F10: implemented by GhGithubWriter). Each takes an idempotency key
 * and reconciles before it acts, so a retried round never posts or pushes twice.
 */
export interface StewardWriter {
  replyToReviewComment(
    key: IdempotencyKey,
    pr: number,
    threadId: number,
    body: string,
  ): Promise<Result<WriteOutcome, AdapterError>>;
  commentOnPull(
    key: IdempotencyKey,
    pr: number,
    body: string,
  ): Promise<Result<WriteOutcome, AdapterError>>;
  rerunJob(key: IdempotencyKey, jobId: number): Promise<Result<WriteOutcome, AdapterError>>;
  /** Fast-forwards `branch` on origin to `sha` (never a force push). */
  pushCommit(
    key: IdempotencyKey,
    repoDir: string,
    branch: string,
    sha: string,
  ): Promise<Result<WriteOutcome, AdapterError>>;
}

/** The change `base...head` (head defaults to HEAD), for the pre-PR scan and the push scan. */
export interface ChangeDiff {
  diff(
    baseRef: string,
    headRef?: string,
  ): Promise<Result<{ readonly patch: string }, AdapterError>>;
}

export interface StewardPorts {
  readonly reader: StewardReader;
  readonly writer: StewardWriter;
  readonly change: ChangeDiff;
}
