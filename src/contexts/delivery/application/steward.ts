/**
 * PR steward use cases (ADR-0017). `inspectPull` reads a PR and decides the next action; the
 * caller (the bash pipeline stage) runs a fix round through the patch handoff, then calls
 * `pushFix` (steward-push.ts), `postReplies` and `rerunJobs`, each an idempotent GitHub write.
 */
import { idempotencyKey } from "../../../shared/kernel/durability";
import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import {
  type FixBrief,
  type FixerReply,
  fixBrief,
  parseReplies,
  replyBody,
  summaryBody,
} from "../domain/steward-brief";
import {
  type CheckFailure,
  type CheckRun,
  type ChecksSummary,
  checkState,
  latestRuns,
  summarizeChecks,
  triageFailures,
} from "../domain/steward-ci";
import {
  decideNext,
  type StewardDecision,
  type StewardHistory,
  type StewardLimits,
} from "../domain/steward-policy";
import {
  type ActionableComment,
  actionableComments,
  candidateWriters,
} from "../domain/steward-reviews";
import type { StewardPorts, StewardReader } from "../ports";

export interface InspectRequest {
  readonly pr: number;
  readonly history: StewardHistory;
  readonly limits: StewardLimits;
  readonly bots: ReadonlySet<string>;
  /** The caller waited long enough that a commit with no checks has no CI. */
  readonly noChecksOk?: boolean;
}

export interface StewardReport {
  readonly pr: number;
  readonly state: "open" | "closed" | "merged";
  readonly headSha: string;
  readonly baseSha: string;
  readonly headRef: string;
  readonly checks: ChecksSummary;
  readonly failures: readonly CheckFailure[];
  readonly comments: readonly ActionableComment[];
  readonly decision: StewardDecision;
  /** Present when the decision is fix. */
  readonly brief: FixBrief | null;
}

/** At most this many failed jobs' logs are read per round. */
const MAX_LOGS = 8;

export async function inspectPull(
  ports: StewardPorts,
  req: InspectRequest,
): Promise<Result<StewardReport, AdapterError>> {
  const self = await ports.reader.self();
  if (!self.ok) return self;
  const pull = await ports.reader.pull(req.pr);
  if (!pull.ok) return pull;
  const runs = await ports.reader.checkRuns(pull.value.headSha);
  if (!runs.ok) return runs;
  const failures = await classify(ports.reader, latestRuns(runs.value), pull.value.baseSha);
  const comments = await trustedComments(ports.reader, req, self.value);
  if (!comments.ok) return comments;
  const checks = summarizeChecks(runs.value);
  const decision = decideNext(
    {
      prState: pull.value.state,
      fork: pull.value.crossRepository,
      noChecksOk: req.noChecksOk === true,
      checks,
      failures,
      comments: comments.value,
    },
    req.history,
    req.limits,
  );
  return ok({
    pr: req.pr,
    state: pull.value.state,
    headSha: pull.value.headSha,
    baseSha: pull.value.baseSha,
    headRef: pull.value.headRef,
    checks,
    failures,
    comments: comments.value,
    decision,
    brief: decision.action === "fix" ? fixBrief(decision) : null,
  });
}

const WRITE = new Set(["admin", "maintain", "write"]);

/** Actionable comments, with each human author's repository permission looked up (write or more). */
async function trustedComments(
  reader: StewardReader,
  req: InspectRequest,
  self: string,
): Promise<Result<ActionableComment[], AdapterError>> {
  const raw = await reader.comments(req.pr);
  if (!raw.ok) return raw;
  const writers = new Set<string>();
  for (const login of candidateWriters(raw.value)) {
    const p = await reader.permission(login);
    if (!p.ok) return p;
    if (WRITE.has(p.value)) writers.add(login);
  }
  return ok(actionableComments(raw.value, { self, bots: req.bots, handled: new Set(), writers }));
}

/** Failed checks with their logs, and which of them also fail on the base commit. */
async function classify(
  reader: StewardReader,
  runs: readonly CheckRun[],
  baseSha: string,
): Promise<CheckFailure[]> {
  const failed = runs.filter((r) => checkState(r) === "failed");
  if (failed.length === 0) return [];
  const withLogs = await Promise.all(
    failed.map(async (run, i) => {
      if (run.jobId === null || i >= MAX_LOGS) return { run, log: "" };
      const log = await reader.jobLog(run.jobId);
      return { run, log: log.ok ? log.value : "" };
    }),
  );
  return triageFailures(withLogs, await failingOn(reader, baseSha));
}

/** Check names that fail on `sha`. Unknown (unreadable) means none, so nothing is excused. */
async function failingOn(reader: StewardReader, sha: string): Promise<Set<string>> {
  if (!/^[0-9a-f]{40}$/.test(sha)) return new Set();
  const runs = await reader.checkRuns(sha);
  if (!runs.ok) return new Set();
  return new Set(
    latestRuns(runs.value)
      .filter((r) => checkState(r) === "failed")
      .map((r) => r.name),
  );
}

export interface ReplyRequest {
  readonly pr: number;
  readonly sha: string;
  /** The comments the fix round was given (from its report). */
  readonly offered: readonly ActionableComment[];
  /** The fixer's report file contents ("" when it wrote none). */
  readonly repliesText: string;
  /** False when the round committed nothing: a "fixed" report is then posted as no change. */
  readonly changed: boolean;
}

export interface ReplyOutcome {
  readonly replied: readonly number[];
  /** Offered comments the fixer did not report on: offered again next round, up to the limit. */
  readonly unhandled: readonly number[];
}

export async function postReplies(
  ports: StewardPorts,
  req: ReplyRequest,
): Promise<Result<ReplyOutcome, AdapterError>> {
  const replies = parseReplies(req.repliesText, new Set(req.offered.map((c) => c.id))).map((r) =>
    !req.changed && r.status === "fixed" ? { ...r, status: "declined" as const } : r,
  );
  const byId = new Map(req.offered.map((c) => [c.id, c]));
  const inline = replies.filter((r) => byId.get(r.id)?.kind === "inline");
  const rest = replies.filter((r) => byId.get(r.id)?.kind !== "inline");
  for (const r of inline) {
    const c = byId.get(r.id) as ActionableComment;
    const key = idempotencyKey("steward", `pr${req.pr}`, "reply", String(r.id), req.sha);
    const posted = await ports.writer.replyToReviewComment(
      key,
      req.pr,
      c.threadId,
      replyBody([r.id], r.status, r.note, req.sha),
    );
    if (!posted.ok) return posted;
  }
  const summary = await postSummary(ports, req, rest);
  if (!summary.ok) return summary;
  const replied = new Set(replies.map((r) => r.id));
  return ok({
    replied: [...replied],
    unhandled: req.offered.map((c) => c.id).filter((id) => !replied.has(id)),
  });
}

async function postSummary(
  ports: StewardPorts,
  req: ReplyRequest,
  replies: readonly FixerReply[],
): Promise<Result<void, AdapterError>> {
  if (replies.length === 0) return ok(undefined);
  const ids = replies.map((r) => String(r.id)).join("-");
  const key = idempotencyKey("steward", `pr${req.pr}`, "summary", ids, req.sha);
  const posted = await ports.writer.commentOnPull(key, req.pr, summaryBody(replies, req.sha));
  return posted.ok ? ok(undefined) : posted;
}

export async function rerunJobs(
  ports: StewardPorts,
  pr: number,
  jobIds: readonly number[],
): Promise<Result<readonly number[], AdapterError>> {
  const done: number[] = [];
  for (const id of jobIds) {
    const r = await ports.writer.rerunJob(
      idempotencyKey("steward", `pr${pr}`, "rerun", String(id)),
      id,
    );
    if (!r.ok) return r;
    done.push(id);
  }
  return ok(done);
}
