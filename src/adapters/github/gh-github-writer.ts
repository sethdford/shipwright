// The only file allowed to run `gh` write subcommands (rule F10, tools/arch/rules/f10-*.yml).
// Every method is reconcile-then-act on an IdempotencyKey recorded in the GitHub object itself;
// the SideEffects ledger replaces that record when the SQLite durability adapter lands (Wave 1b).
import { z } from "zod";
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../../contexts/integrations";
import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-issue-tracker";
import { runGhJson } from "./gh-json";

export const INCIDENT_LABEL = "shipwright:incident";
export const idempotencyMarker = (key: IdempotencyKey): string =>
  `<!-- shipwright-idempotency-key: ${key} -->`;

const OpenIncident = z.object({
  number: z.number(),
  body: z.string().nullable(),
  comments: z.array(z.object({ body: z.string() })),
});
type OpenIncident = z.infer<typeof OpenIncident>;

const recorded = (incident: OpenIncident, marker: string): boolean =>
  [incident.body ?? "", ...incident.comments.map((c) => c.body)].some((b) => b.includes(marker));

export class GhGithubWriter implements GithubWriter {
  constructor(private readonly runner: ProcessRunner) {}

  async ensureIncident(
    key: IdempotencyKey,
    report: IncidentReport,
  ): Promise<Result<IncidentOutcome, AdapterError>> {
    const list = ["gh", "issue", "list", "--state", "open", "--label", INCIDENT_LABEL];
    const found = await runGhJson(
      this.runner,
      [...list, "--limit", "1", "--json", "number,body,comments"],
      z.array(OpenIncident),
    );
    if (!found.ok) return found;
    const body = `${report.body}\n\n${idempotencyMarker(key)}`;
    const [open] = found.value;
    if (!open) return this.createIncident(report.title, body);
    if (recorded(open, idempotencyMarker(key)))
      return ok({ issue: open.number, action: "unchanged" });
    const commented = await this.gh(["issue", "comment", String(open.number), "--body", body]);
    return commented.ok ? ok({ issue: open.number, action: "commented" }) : commented;
  }

  private async createIncident(
    title: string,
    body: string,
  ): Promise<Result<IncidentOutcome, AdapterError>> {
    const label = await this.gh([
      "label",
      "create",
      INCIDENT_LABEL,
      "--color",
      "B60205",
      "--description",
      "Shipwright circuit-breaker incident",
      "--force",
    ]);
    if (!label.ok) return label;
    const created = await this.gh([
      "issue",
      "create",
      "--title",
      title,
      "--body",
      body,
      "--label",
      INCIDENT_LABEL,
    ]);
    if (!created.ok) return created;
    const issue = created.value.trim().match(/\/issues\/(\d+)$/)?.[1];
    if (!issue)
      return err({ kind: "failed", message: `no issue URL in gh output: ${created.value}` });
    return ok({ issue: Number(issue), action: "created" });
  }

  private async gh(args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, { argv: ["gh", ...args], timeoutMs: 30_000 });
    return r.exitCode === 0 && !r.timedOut ? ok(r.stdout) : err(classifyGhError(r));
  }
}
