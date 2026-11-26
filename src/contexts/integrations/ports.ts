import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError } from "../../shared/kernel/ports";
import type { Result } from "../../shared/kernel/result";

export interface IncidentReport {
  readonly title: string;
  readonly body: string;
}
export type IncidentAction = "created" | "commented" | "unchanged";
export interface IncidentOutcome {
  readonly issue: number;
  readonly action: IncidentAction;
}

/**
 * GitHub side effects (rule F10). Every method takes an `IdempotencyKey` and reconciles before it
 * acts, so a retried or concurrent call never writes twice for the same key. Implemented only in
 * `src/adapters/github/gh-github-writer.ts`; an ast-grep rule keeps `gh` writes out of other files.
 */
export interface GithubWriter {
  /**
   * Keeps one open incident issue: creates it, or comments on the open one, once per `key`.
   * A key already recorded on the open incident is `unchanged`.
   */
  ensureIncident(
    key: IdempotencyKey,
    report: IncidentReport,
  ): Promise<Result<IncidentOutcome, AdapterError>>;
}

/** One proof run's artifacts (ADR-0019): files under `dir`, published under `prefix`. */
export interface ProofUpload {
  readonly repoRoot: string;
  readonly dir: string;
  /** Paths relative to `dir`, already checked to be inside it. */
  readonly files: readonly string[];
  /** Folder on the proof branch, e.g. "feat-login/2026-11-26T21-30-00Z". */
  readonly prefix: string;
}

export interface ProofPublished {
  readonly commit: string;
  /** Where the files are served, ending in "/". */
  readonly baseUrl: string;
  readonly action: "created" | "unchanged";
}

/**
 * Pushes proof artifacts to the repository's `shipwright-proof` branch (rule F10: a GitHub side
 * effect, keyed and reconciled). Each run adds one commit whose tree holds only that run's files,
 * on top of the branch tip, so URLs by commit stay valid and the tip stays small. The same key
 * finds the earlier commit instead of pushing twice.
 */
export interface ProofBranchWriter {
  publishProof(
    key: IdempotencyKey,
    upload: ProofUpload,
  ): Promise<Result<ProofPublished, AdapterError>>;
}
