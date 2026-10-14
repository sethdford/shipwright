import { z } from "zod";
import type { PullRequests, PullSummary } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

const GhPull = z.object({
  number: z.number(),
  author: z.object({ login: z.string() }),
  labels: z.array(z.object({ name: z.string() })),
  isDraft: z.boolean(),
  reviewDecision: z.string().nullable(),
});

export class GhPullRequests implements PullRequests {
  constructor(private readonly runner: ProcessRunner) {}

  async open(): Promise<Result<readonly PullSummary[], AdapterError>> {
    const argv = ["gh", "pr", "list", "--state", "open", "--limit", "200"];
    const fields = "number,author,labels,isDraft,reviewDecision";
    const r = await runGhJson(this.runner, [...argv, "--json", fields], z.array(GhPull));
    if (!r.ok) return r;
    return ok(
      r.value.map((p) => ({
        number: p.number,
        author: p.author.login,
        labels: p.labels.map((l) => l.name),
        draft: p.isDraft,
        approved: p.reviewDecision === "APPROVED",
      })),
    );
  }
}
