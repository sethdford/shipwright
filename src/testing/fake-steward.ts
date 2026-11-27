import type {
  CheckRun,
  PrComment,
  PullSnapshot,
  StewardPorts,
  WriteOutcome,
} from "../contexts/delivery";
import type { IdempotencyKey } from "../shared/kernel/durability";
import type { AdapterError } from "../shared/kernel/ports";
import { err, ok, type Result } from "../shared/kernel/result";

export const HEAD_SHA = "a".repeat(40);
export const BASE_SHA = "b".repeat(40);

export interface FakeStewardScript {
  readonly self?: string;
  readonly pull?: Partial<PullSnapshot>;
  /** Check runs per commit sha (missing sha: none). */
  readonly checkRuns?: Readonly<Record<string, readonly CheckRun[]>>;
  /** Job logs per job id (missing: a not_found error). */
  readonly logs?: Readonly<Record<number, string>>;
  readonly comments?: readonly PrComment[];
  /** Repository permission per lowercase login (missing: "write"). */
  readonly permissions?: Readonly<Record<string, string>>;
  readonly patch?: string;
  /** Names of reader or writer methods that fail with this error. */
  readonly failing?: Readonly<Record<string, AdapterError>>;
}

export interface RecordedWrite {
  readonly method: string;
  readonly key: IdempotencyKey;
  readonly args: readonly unknown[];
}

/** Scripted StewardPorts: reads answer from the script; writes are recorded and reconcile by key. */
export class FakeSteward {
  readonly writes: RecordedWrite[] = [];
  readonly logsRead: number[] = [];
  readonly diffs: { base: string; head: string | undefined }[] = [];
  readonly permissionsAsked: string[] = [];
  private readonly seenKeys = new Set<string>();

  constructor(private readonly s: FakeStewardScript = {}) {}

  ports(): StewardPorts {
    return { reader: this.reader(), writer: this.writer(), change: this.change() };
  }

  private fail(method: string): Result<never, AdapterError> | null {
    const e = this.s.failing?.[method];
    return e ? err(e) : null;
  }

  private reader(): StewardPorts["reader"] {
    return {
      self: async () => this.fail("self") ?? ok(this.s.self ?? "shipwright-bot"),
      pull: async (pr) =>
        this.fail("pull") ??
        ok({
          number: pr,
          state: "open",
          headSha: HEAD_SHA,
          baseSha: BASE_SHA,
          headRef: "feat/x",
          crossRepository: false,
          ...this.s.pull,
        }),
      checkRuns: async (sha) =>
        this.fail(`checkRuns:${sha}`) ??
        this.fail("checkRuns") ??
        ok(this.s.checkRuns?.[sha] ?? []),
      jobLog: async (jobId) => {
        this.logsRead.push(jobId);
        const log = this.s.logs?.[jobId];
        return log === undefined ? err({ kind: "not_found", message: `no log ${jobId}` }) : ok(log);
      },
      comments: async () => this.fail("comments") ?? ok(this.s.comments ?? []),
      permission: async (login) => {
        this.permissionsAsked.push(login);
        return this.fail("permission") ?? ok(this.s.permissions?.[login] ?? "write");
      },
    };
  }

  private write(method: string, key: IdempotencyKey, args: unknown[]) {
    const failed = this.fail(method);
    if (failed) return failed;
    this.writes.push({ method, key, args });
    if (this.seenKeys.has(key)) return ok<WriteOutcome>("unchanged");
    this.seenKeys.add(key);
    return ok<WriteOutcome>("done");
  }

  private writer(): StewardPorts["writer"] {
    return {
      replyToReviewComment: async (key, pr, threadId, body) =>
        this.write("replyToReviewComment", key, [pr, threadId, body]),
      commentOnPull: async (key, pr, body) => this.write("commentOnPull", key, [pr, body]),
      rerunJob: async (key, jobId) => this.write("rerunJob", key, [jobId]),
      pushCommit: async (key, repoDir, branch, sha) =>
        this.write("pushCommit", key, [repoDir, branch, sha]),
    };
  }

  private change(): StewardPorts["change"] {
    return {
      diff: async (base, head) => {
        this.diffs.push({ base, head });
        return this.fail("diff") ?? ok({ patch: this.s.patch ?? "" });
      },
    };
  }
}
