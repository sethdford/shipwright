// The only file allowed to run `gh` write subcommands (rule F10, tools/arch/rules/f10-*.yml).
// Every method is reconcile-then-act on an IdempotencyKey recorded in the GitHub object itself;
// the SideEffects ledger replaces that record when the SQLite durability adapter lands (Wave 1b),
// which also removes the marker scan below. Note that `gh issue list --json comments` may return at
// most the first 100 comments of an issue, so a marker beyond that is not seen until Wave 1b.
import { z } from "zod";
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../../contexts/integrations";
import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError, runGhJson } from "./gh-json";

export const INCIDENT_LABEL = "shipwright:incident";
export const MAX_BODY_CHARS = 60_000;
export const MAX_TITLE_CHARS = 256;
const OPEN_INCIDENT_LIMIT = 20;

export const idempotencyMarker = (key: IdempotencyKey): string =>
  `<!-- shipwright-idempotency-key: ${key} -->`;

const Author = z.object({ login: z.string() }).nullable().optional();
const OpenIncident = z.object({
  number: z.number(),
  body: z.string().nullable(),
  author: Author,
  comments: z.array(z.object({ body: z.string(), author: Author })),
});
type OpenIncident = z.infer<typeof OpenIncident>;

/** A marker counts only when written by the token's own login: anyone can paste a forged one. */
const recorded = (incident: OpenIncident, marker: string, login: string): boolean =>
  (incident.author?.login === login && (incident.body ?? "").includes(marker)) ||
  incident.comments.some((c) => c.author?.login === login && c.body.includes(marker));

/** Trims the report body first so the marker, which is appended last, always survives. */
const withMarker = (body: string, key: IdempotencyKey): string =>
  `${body.slice(0, MAX_BODY_CHARS)}\n\n${idempotencyMarker(key)}`;

const labelMissing = (stderr: string): boolean =>
  /label.*not found|not found.*label|could not add label/i.test(stderr);

export class GhGithubWriter implements GithubWriter {
  private login: string | undefined;

  constructor(private readonly runner: ProcessRunner) {}

  async ensureIncident(
    key: IdempotencyKey,
    report: IncidentReport,
  ): Promise<Result<IncidentOutcome, AdapterError>> {
    const me = await this.authenticatedLogin();
    if (!me.ok) return me;
    const found = await this.openIncidents();
    if (!found.ok) return found;
    const marker = idempotencyMarker(key);
    const already = found.value.find((i) => recorded(i, marker, me.value));
    if (already) return ok({ issue: already.number, action: "unchanged" });
    const body = withMarker(report.body, key);
    const [canonical] = found.value;
    if (!canonical) return this.createIncident(me.value, key, report.title, body);
    return this.comment(canonical.number, body);
  }

  private async authenticatedLogin(): Promise<Result<string, AdapterError>> {
    if (this.login) return ok(this.login);
    const r = await runOrFail(this.runner, {
      argv: ["gh", "api", "user", "--jq", ".login"],
      timeoutMs: 30_000,
    });
    if (r.exitCode !== 0 || r.timedOut) return err(classifyGhError(r));
    const login = r.stdout.trim();
    if (!login) return err({ kind: "failed", message: "gh api user returned no login" });
    this.login = login;
    return ok(login);
  }

  /** Open incidents, lowest number first; the first one is the canonical incident. */
  private async openIncidents(): Promise<Result<OpenIncident[], AdapterError>> {
    const found = await runGhJson(
      this.runner,
      [
        "gh",
        "issue",
        "list",
        "--state",
        "open",
        "--label",
        INCIDENT_LABEL,
        "--limit",
        String(OPEN_INCIDENT_LIMIT),
        "--json",
        "number,body,author,comments",
      ],
      z.array(OpenIncident),
    );
    return found.ok ? ok([...found.value].sort((a, b) => a.number - b.number)) : found;
  }

  private async createIncident(
    login: string,
    key: IdempotencyKey,
    title: string,
    body: string,
  ): Promise<Result<IncidentOutcome, AdapterError>> {
    const mine = await this.createIssue(title, body);
    if (!mine.ok) return mine;
    // Concurrent trippers each saw no open incident. The lowest-numbered one wins.
    const after = await this.openIncidents();
    const winner = after.ok ? after.value.find((i) => i.number < mine.value) : undefined;
    if (!winner) return ok({ issue: mine.value, action: "created" });
    const closed = await this.gh([
      "issue",
      "close",
      String(mine.value),
      "--comment",
      `Duplicate of #${winner.number}, opened by a concurrent trip.`,
    ]);
    if (!closed.ok) return closed;
    if (recorded(winner, idempotencyMarker(key), login)) {
      return ok({ issue: winner.number, action: "unchanged" });
    }
    return this.comment(winner.number, body);
  }

  /** Creates the issue; only if gh reports the label missing, creates it and retries once. */
  private async createIssue(title: string, body: string): Promise<Result<number, AdapterError>> {
    const create = () =>
      this.gh(
        [
          "issue",
          "create",
          `--title=${title.slice(0, MAX_TITLE_CHARS)}`,
          "--body-file",
          "-",
          "--label",
          INCIDENT_LABEL,
        ],
        body,
      );
    let created = await create();
    if (!created.ok && labelMissing(created.error.message)) {
      const label = await this.gh([
        "label",
        "create",
        INCIDENT_LABEL,
        "--color",
        "B60205",
        "--description",
        "Shipwright circuit-breaker incident",
      ]);
      // Another tripper may have created the label first; the retry below decides.
      if (!label.ok && !/already exists/i.test(label.error.message)) return label;
      created = await create();
    }
    if (!created.ok) return created;
    const match = created.value.trim().match(/\/issues\/(\d+)$/)?.[1];
    if (!match)
      return err({ kind: "failed", message: `no issue URL in gh output: ${created.value}` });
    return ok(Number(match));
  }

  private async comment(
    issue: number,
    body: string,
  ): Promise<Result<IncidentOutcome, AdapterError>> {
    const commented = await this.gh(["issue", "comment", String(issue), "--body-file", "-"], body);
    return commented.ok ? ok({ issue, action: "commented" }) : commented;
  }

  private async gh(args: readonly string[], stdin?: string): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: ["gh", ...args],
      timeoutMs: 30_000,
      ...(stdin === undefined ? {} : { stdin }),
    });
    return r.exitCode === 0 && !r.timedOut ? ok(r.stdout) : err(classifyGhError(r));
  }
}
