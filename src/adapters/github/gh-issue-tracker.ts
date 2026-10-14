import { z } from "zod";
import type { AdapterError, Issue, IssueTracker, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-json";

export { classifyGhError };

const GhIssue = z.object({
  number: z.number(),
  title: z.string(),
  body: z.string().nullable(),
  state: z.enum(["OPEN", "CLOSED"]),
  author: z.object({ login: z.string() }),
  labels: z.array(z.object({ name: z.string() })),
});

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
