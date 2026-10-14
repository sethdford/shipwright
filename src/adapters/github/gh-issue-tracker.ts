import { z } from "zod";
import type {
  AdapterError,
  Issue,
  IssueTracker,
  ProcessResult,
  ProcessRunner,
} from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const GhIssue = z.object({
  number: z.number(),
  title: z.string(),
  body: z.string().nullable(),
  state: z.enum(["OPEN", "CLOSED"]),
  author: z.object({ login: z.string() }),
  labels: z.array(z.object({ name: z.string() })),
});

export function classifyGhError(r: ProcessResult): AdapterError {
  const message = r.stderr.trim() || `gh exited ${r.exitCode}`;
  if (r.timedOut) return { kind: "transient", message };
  // Deliberately no bare "not found" or HTTP 404: "gh: command not found" is a broken environment,
  // and a 404 from a GraphQL call means a missing or invisible repo, not a missing issue.
  if (/could not resolve to an? (issue|pull request)/i.test(message)) {
    return { kind: "not_found", message };
  }
  if (
    /rate limit|HTTP (429|5\d\d)|timed? ?out|connection (reset|refused)|no such host|could not resolve host|dial tcp|EOF/i.test(
      message,
    )
  ) {
    return { kind: "transient", message };
  }
  if (/HTTP 401|HTTP 403|bad credentials|gh auth login|authentication/i.test(message)) {
    return { kind: "auth", message };
  }
  return { kind: "failed", message };
}

export class GhIssueTracker implements IssueTracker {
  constructor(private readonly runner: ProcessRunner) {}

  async getIssue(number: number): Promise<Result<Issue, AdapterError>> {
    if (!Number.isSafeInteger(number) || number <= 0) {
      return err({ kind: "failed", message: `invalid issue number: ${number}` });
    }
    const r = await runOrFail(this.runner, {
      argv: [
        "gh",
        "issue",
        "view",
        String(number),
        "--json",
        "number,title,body,state,author,labels",
      ],
      timeoutMs: 30_000,
    });
    if (r.exitCode !== 0 || r.timedOut) return err(classifyGhError(r));
    let json: unknown;
    try {
      json = JSON.parse(r.stdout);
    } catch (e) {
      return err({
        kind: "failed",
        message: `unexpected gh output: ${e instanceof Error ? e.message : String(e)}`,
      });
    }
    const parsed = GhIssue.safeParse(json);
    if (!parsed.success) {
      return err({ kind: "failed", message: `unexpected gh output: ${parsed.error.message}` });
    }
    const i = parsed.data;
    return ok({
      number: i.number,
      title: i.title,
      body: i.body ?? "",
      state: i.state === "OPEN" ? "open" : "closed",
      author: i.author.login,
      labels: i.labels.map((l) => l.name),
    });
  }
}
