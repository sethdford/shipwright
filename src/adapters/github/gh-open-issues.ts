import { z } from "zod";
import type { IssueSummary, OpenIssues } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

const GhIssue = z.object({
  number: z.number(),
  title: z.string(),
  labels: z.array(z.object({ name: z.string() })),
});

/**
 * All open issues (the repo had ~850 open in October 2026; listing takes ~7 s, inside the 30 s
 * timeout). A listing that fills `limit` may be truncated, so it is an error: the gate fails closed.
 */
export class GhOpenIssues implements OpenIssues {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly limit = 2000,
  ) {}

  async open(): Promise<Result<readonly IssueSummary[], AdapterError>> {
    const argv = ["gh", "issue", "list", "--state", "open", "--limit", String(this.limit)];
    const r = await runGhJson(
      this.runner,
      [...argv, "--json", "number,title,labels"],
      z.array(GhIssue),
    );
    if (!r.ok) return r;
    if (r.value.length >= this.limit) {
      return err({
        kind: "failed",
        message: `issue list may be truncated at ${this.limit}; cannot verify intake caps`,
      });
    }
    return ok(r.value.map((i) => ({ ...i, labels: i.labels.map((l) => l.name) })));
  }
}
