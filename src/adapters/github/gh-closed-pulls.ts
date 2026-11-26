import { z } from "zod";
import type { ClosedPulls, PullCommit, PullRecord } from "../../contexts/quality";
import type { ProcessRunner } from "../../shared/kernel/ports";
import { ok } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

const Author = z.object({
  login: z.string().nullish(),
  name: z.string().nullish(),
  email: z.string().nullish(),
});
const Commit = z.object({ committedDate: z.string(), authors: z.array(Author) });
const GhClosedPull = z.object({
  number: z.number(),
  title: z.string(),
  body: z.string(),
  headRefName: z.string(),
  labels: z.array(z.object({ name: z.string() })),
  createdAt: z.string(),
  mergedAt: z.string().nullable(),
  closedAt: z.string().nullable(),
  mergeCommit: z.object({ oid: z.string() }).nullish(),
});
const GhCommits = z.object({ commits: z.array(Commit) });

/**
 * Closed PRs read per call. More than this is reported as truncated, never silently dropped.
 * Commits are not in this query: with them, GitHub's 500,000-node GraphQL cap fails at about 50
 * PRs. They are read per PR, and only for the PRs the scorecard inspects.
 */
export const MAX_CLOSED_PULLS = 1000;

const FIELDS = "number,title,body,headRefName,labels,createdAt,mergedAt,closedAt,mergeCommit";

function epoch(iso: string | null): number | null {
  if (iso === null || iso === "") return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : ms;
}

function toRecord(p: z.infer<typeof GhClosedPull>): PullRecord {
  return {
    number: p.number,
    title: p.title,
    body: p.body,
    headRef: p.headRefName,
    labels: p.labels.map((l) => l.name),
    createdAtMs: epoch(p.createdAt) ?? 0,
    mergedAtMs: epoch(p.mergedAt),
    closedAtMs: epoch(p.closedAt),
    commits: [],
    mergeSha: p.mergeCommit?.oid ?? null,
  };
}

function toCommit(c: z.infer<typeof Commit>): PullCommit {
  return {
    identities: c.authors.flatMap((a) => [a.login ?? "", a.name ?? "", a.email ?? ""]),
    atMs: epoch(c.committedDate) ?? 0,
  };
}

/** Closed PRs of the current repository through `gh pr list` (read-only, argv only). */
export class GhClosedPulls implements ClosedPulls {
  constructor(private readonly runner: ProcessRunner) {}

  /**
   * No `--search`: GitHub's search index drops some closed PRs (bulk-closed ones among them), so
   * every closed PR is listed and the window is applied here, by close time.
   */
  async closedSince(sinceMs: number) {
    const argv = ["gh", "pr", "list", "--state", "closed"];
    const limit = ["--limit", String(MAX_CLOSED_PULLS + 1), "--json", FIELDS];
    const r = await runGhJson(this.runner, [...argv, ...limit], z.array(GhClosedPull));
    if (!r.ok) return r;
    const truncated = r.value.length > MAX_CLOSED_PULLS;
    const pulls = r.value
      .slice(0, MAX_CLOSED_PULLS)
      .map(toRecord)
      .filter((p) => p.closedAtMs !== null && p.closedAtMs >= sinceMs);
    return ok({ pulls, truncated });
  }

  async commits(pr: number) {
    const argv = ["gh", "pr", "view", String(pr), "--json", "commits"];
    const r = await runGhJson(this.runner, argv, GhCommits);
    if (!r.ok) return r;
    return ok(r.value.commits.map(toCommit));
  }
}
