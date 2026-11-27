// Read-only GitHub access for the PR steward (ADR-0017), through `gh api` GET calls. `{owner}` and
// `{repo}` are filled in by gh from GH_REPO or the working directory's remote.
import { z } from "zod";
import type { CheckRun, PrComment, PullSnapshot, StewardReader } from "../../contexts/delivery";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-json";

const REPO = "repos/{owner}/{repo}";
const MAX_LOG_BYTES = 2_000_000;

/** Runs `gh api <path> --jq <filter>` (GET) and returns stdout. */
export async function ghGet(
  runner: ProcessRunner,
  path: string,
  jq: string | null,
  paginate = false,
): Promise<Result<string, AdapterError>> {
  const argv = ["gh", "api", "-X", "GET", path];
  if (paginate) argv.push("--paginate");
  if (jq !== null) argv.push("--jq", jq);
  const r = await runOrFail(runner, { argv, timeoutMs: 60_000 });
  return r.exitCode === 0 && !r.timedOut ? ok(r.stdout) : err(classifyGhError(r));
}

/** One JSON value per line (from `--jq '.[] | {...}'`), each validated. */
export function parseLines<T>(stdout: string, schema: z.ZodType<T>): Result<T[], AdapterError> {
  const out: T[] = [];
  for (const line of stdout.split("\n")) {
    if (!line.trim()) continue;
    let json: unknown;
    try {
      json = JSON.parse(line);
    } catch {
      return err({ kind: "failed", message: `unexpected gh output: ${line.slice(0, 120)}` });
    }
    const p = schema.safeParse(json);
    if (!p.success)
      return err({ kind: "failed", message: `unexpected gh output: ${p.error.message}` });
    out.push(p.data);
  }
  return ok(out);
}

/** True when a comment at `path` (an issue or review-comment list) was written by `login` and holds `marker`. */
export async function markedBy(
  runner: ProcessRunner,
  path: string,
  login: string,
  marker: string,
): Promise<Result<boolean, AdapterError>> {
  const r = await ghGet(
    runner,
    `${path}?per_page=100`,
    '.[] | {login: (.user.login // "ghost"), body}',
    true,
  );
  if (!r.ok) return r;
  const rows = parseLines(r.value, z.object({ login: z.string(), body: z.string().nullable() }));
  if (!rows.ok) return rows;
  return ok(rows.value.some((c) => c.login === login && (c.body ?? "").includes(marker)));
}

const Pull = z.object({
  fork: z.boolean(),
  state: z.string(),
  merged: z.boolean(),
  head: z.string(),
  base: z.string(),
  ref: z.string(),
});
const Run = z.object({
  id: z.number(),
  name: z.string(),
  status: z.string(),
  conclusion: z.string().nullable(),
  app: z.string().nullable(),
});
const Status = z.object({ context: z.string(), state: z.string() });
const Comment = z.object({
  id: z.number(),
  login: z.string(),
  association: z.string(),
  body: z.string().nullable(),
  at: z.string().nullable(),
  path: z.string().nullable().optional(),
  line: z.number().nullable().optional(),
  position: z.number().nullable().optional(),
  replyTo: z.number().nullable().optional(),
  state: z.string().nullable().optional(),
  type: z.string().nullable().optional(),
  subject: z.string().nullable().optional(),
});
type Comment = z.infer<typeof Comment>;

const STATUS_MAP: Record<string, Pick<CheckRun, "status" | "conclusion">> = {
  pending: { status: "in_progress", conclusion: null },
  success: { status: "completed", conclusion: "success" },
  failure: { status: "completed", conclusion: "failure" },
  error: { status: "completed", conclusion: "failure" },
};

export class GhStewardReader implements StewardReader {
  constructor(private readonly runner: ProcessRunner) {}

  async self(): Promise<Result<string, AdapterError>> {
    const r = await ghGet(this.runner, "user", ".login");
    if (!r.ok) return r;
    const login = r.value.trim();
    return login ? ok(login) : err({ kind: "failed", message: "gh api user returned no login" });
  }

  async pull(pr: number): Promise<Result<PullSnapshot, AdapterError>> {
    const jq =
      "{state, merged: (.merged // false), head: .head.sha, base: .base.sha, ref: .head.ref, " +
      'fork: ((.head.repo.full_name // "") != .base.repo.full_name)}';
    const r = await ghGet(this.runner, `${REPO}/pulls/${pr}`, jq);
    if (!r.ok) return r;
    const p = parseLines(r.value, Pull);
    if (!p.ok) return p;
    const [v] = p.value;
    if (!v) return err({ kind: "failed", message: `no data for PR ${pr}` });
    const state = v.merged ? "merged" : v.state === "open" ? "open" : "closed";
    return ok({
      number: pr,
      state,
      headSha: v.head,
      baseSha: v.base,
      headRef: v.ref,
      crossRepository: v.fork,
    });
  }

  async checkRuns(sha: string): Promise<Result<readonly CheckRun[], AdapterError>> {
    if (!/^[0-9a-f]{40}$/.test(sha))
      return err({ kind: "failed", message: `not a full sha: ${sha}` });
    const jq = ".check_runs[] | {id, name, status, conclusion, app: .app.slug}";
    const runs = await ghGet(
      this.runner,
      `${REPO}/commits/${sha}/check-runs?per_page=100&filter=latest`,
      jq,
      true,
    );
    if (!runs.ok) return runs;
    const parsed = parseLines(runs.value, Run);
    if (!parsed.ok) return parsed;
    const statuses = await ghGet(
      this.runner,
      `${REPO}/commits/${sha}/status?per_page=100`,
      ".statuses[] | {context, state}",
      true,
    );
    if (!statuses.ok) return statuses;
    const st = parseLines(statuses.value, Status);
    if (!st.ok) return st;
    return ok([
      ...parsed.value.map((r) => ({
        name: r.name,
        status: r.status,
        conclusion: r.conclusion,
        jobId: r.app === "github-actions" ? r.id : null,
        app: r.app ?? "",
      })),
      ...st.value.map((s) => ({
        name: s.context,
        jobId: null,
        app: "status",
        ...(STATUS_MAP[s.state] ?? STATUS_MAP.pending),
      })),
    ] as CheckRun[]);
  }

  /** The login's permission on the repository (admin, maintain, write, triage, read or none). */
  async permission(login: string): Promise<Result<string, AdapterError>> {
    if (!/^[A-Za-z0-9-]{1,39}$/.test(login)) return ok("none");
    const r = await ghGet(this.runner, `${REPO}/collaborators/${login}/permission`, ".permission");
    if (!r.ok)
      return r.error.kind === "not_found" || /HTTP 404/.test(r.error.message) ? ok("none") : r;
    return ok(r.value.trim() || "none");
  }

  async jobLog(jobId: number): Promise<Result<string, AdapterError>> {
    const r = await ghGet(this.runner, `${REPO}/actions/jobs/${jobId}/logs`, null);
    if (!r.ok) return r;
    return ok(r.value.length > MAX_LOG_BYTES ? r.value.slice(-MAX_LOG_BYTES) : r.value);
  }

  async comments(pr: number): Promise<Result<readonly PrComment[], AdapterError>> {
    const common = `id, login: (.user.login // "ghost"), type: (.user.type // "User"), association: .author_association, body`;
    const parts = [
      {
        kind: "inline",
        path: `${REPO}/pulls/${pr}/comments`,
        jq: `{${common}, at: .created_at, path, line, position, replyTo: .in_reply_to_id, subject: .subject_type}`,
      },
      {
        kind: "review",
        path: `${REPO}/pulls/${pr}/reviews`,
        jq: `{${common}, at: .submitted_at, state}`,
      },
      {
        kind: "conversation",
        path: `${REPO}/issues/${pr}/comments`,
        jq: `{${common}, at: .created_at}`,
      },
    ] as const;
    const out: PrComment[] = [];
    for (const part of parts) {
      const r = await ghGet(this.runner, `${part.path}?per_page=100`, `.[] | ${part.jq}`, true);
      if (!r.ok) return r;
      const rows = parseLines(r.value, Comment);
      if (!rows.ok) return rows;
      out.push(...rows.value.map((c) => toComment(part.kind, c)));
    }
    return ok(out.sort((a, b) => a.createdAt.localeCompare(b.createdAt)));
  }
}

function toComment(kind: PrComment["kind"], c: Comment): PrComment {
  return {
    id: c.id,
    kind,
    author: c.login,
    association: c.association,
    body: c.body ?? "",
    path: c.path ?? null,
    line: c.line ?? null,
    inReplyTo: c.replyTo ?? null,
    // A line comment whose diff position is gone points at code that has changed since. File-level
    // comments (subject_type "file") never have a position.
    outdated: kind === "inline" && c.subject !== "file" && (c.position ?? null) === null,
    reviewState: c.state ?? null,
    createdAt: c.at ?? "",
    isBot: c.type === "Bot",
  };
}
