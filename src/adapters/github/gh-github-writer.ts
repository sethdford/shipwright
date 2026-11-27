// The only file allowed to run `gh` write subcommands (rule F10, tools/arch/rules/f10-*.yml).
// Every method is reconcile-then-act on an IdempotencyKey recorded in the GitHub object itself;
// the SideEffects ledger replaces that record when the SQLite durability adapter lands (Wave 1b),
// which also removes the marker scan below. Note that `gh issue list --json comments` may return at
// most the first 100 comments of an issue, so a marker beyond that is not seen until Wave 1b.
import { z } from "zod";
import type { StewardWriter, WriteOutcome } from "../../contexts/delivery";
import type { GithubWriter, IncidentOutcome, IncidentReport } from "../../contexts/integrations";
import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError, runGhJson } from "./gh-json";
import { ghGet, markedBy } from "./gh-steward-reader";

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

const STEWARD_REPO = "repos/{owner}/{repo}";
const FULL_SHA = /^[0-9a-f]{40}$/;
const BRANCH_NAME = /^(?!-)(?!.*\.\.)[A-Za-z0-9._/-]{1,200}$/;

export class GhGithubWriter implements GithubWriter, StewardWriter {
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

  /** PR steward (ADR-0017): a reply in an inline review thread, once per key. */
  async replyToReviewComment(
    key: IdempotencyKey,
    pr: number,
    threadId: number,
    body: string,
  ): Promise<Result<WriteOutcome, AdapterError>> {
    return this.postOnce(
      key,
      `${STEWARD_REPO}/pulls/${pr}/comments`,
      `${STEWARD_REPO}/pulls/${pr}/comments/${threadId}/replies`,
      body,
    );
  }

  /** PR steward: a conversation comment on the PR, once per key. */
  async commentOnPull(
    key: IdempotencyKey,
    pr: number,
    body: string,
  ): Promise<Result<WriteOutcome, AdapterError>> {
    return this.postOnce(
      key,
      `${STEWARD_REPO}/issues/${pr}/comments`,
      `${STEWARD_REPO}/issues/${pr}/comments`,
      body,
    );
  }

  /** PR steward: re-runs one Actions job, unless it is already running again. */
  async rerunJob(_key: IdempotencyKey, jobId: number): Promise<Result<WriteOutcome, AdapterError>> {
    const status = await ghGet(this.runner, `${STEWARD_REPO}/actions/jobs/${jobId}`, ".status");
    if (!status.ok) return status;
    if (status.value.trim() !== "completed") return ok("unchanged");
    const r = await this.gh(["api", "-X", "POST", `${STEWARD_REPO}/actions/jobs/${jobId}/rerun`]);
    return r.ok ? ok("done") : r;
  }

  /** PR steward: fast-forwards origin's `branch` to `sha` (no force, no hooks); unchanged if already there. */
  async pushCommit(
    _key: IdempotencyKey,
    repoDir: string,
    branch: string,
    sha: string,
  ): Promise<Result<WriteOutcome, AdapterError>> {
    if (!FULL_SHA.test(sha) || !BRANCH_NAME.test(branch)) {
      return err({ kind: "failed", message: `refusing push of ${sha} to ${branch}` });
    }
    const git = [
      "git",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.fsmonitor=false",
      "-C",
      repoDir,
    ];
    const ref = `refs/heads/${branch}`;
    const remote = await runOrFail(this.runner, {
      argv: [...git, "ls-remote", "origin", ref],
      timeoutMs: 60_000,
    });
    if (remote.exitCode === 0 && remote.stdout.startsWith(sha)) return ok("unchanged");
    const push = await runOrFail(this.runner, {
      argv: [...git, "push", "--no-verify", "origin", `${sha}:${ref}`],
      timeoutMs: 180_000,
    });
    return push.exitCode === 0 && !push.timedOut ? ok("done") : err(classifyGhError(push));
  }

  /** Posts `body` (with the key's marker) to `postPath` unless `listPath` already holds it from us. */
  private async postOnce(
    key: IdempotencyKey,
    listPath: string,
    postPath: string,
    body: string,
  ): Promise<Result<WriteOutcome, AdapterError>> {
    const me = await this.authenticatedLogin();
    if (!me.ok) return me;
    const marker = idempotencyMarker(key);
    const seen = await markedBy(this.runner, listPath, me.value, marker);
    if (!seen.ok) return seen;
    if (seen.value) return ok("unchanged");
    const payload = JSON.stringify({ body: withMarker(body, key) });
    const r = await this.gh(["api", "-X", "POST", postPath, "--input", "-"], payload);
    return r.ok ? ok("done") : r;
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
