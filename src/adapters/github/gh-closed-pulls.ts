import { z } from "zod";
import type { ClosedPulls, PullRecord } from "../../contexts/quality";
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
  createdAt: z.string(),
  mergedAt: z.string().nullable(),
  closedAt: z.string().nullable(),
  commits: z.array(Commit),
});

/** One page; more than this in the window is reported as truncated, never silently dropped. */
export const MAX_CLOSED_PULLS = 300;

const FIELDS = "number,title,body,headRefName,createdAt,mergedAt,closedAt,commits";

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
    createdAtMs: epoch(p.createdAt) ?? 0,
    mergedAtMs: epoch(p.mergedAt),
    closedAtMs: epoch(p.closedAt),
    commits: p.commits.map((c) => ({
      identities: c.authors.flatMap((a) => [a.login ?? "", a.name ?? "", a.email ?? ""]),
      atMs: epoch(c.committedDate) ?? 0,
    })),
  };
}

/** Closed PRs of the current repository through `gh pr list` (read-only, argv only). */
export class GhClosedPulls implements ClosedPulls {
  constructor(private readonly runner: ProcessRunner) {}

  async closedSince(sinceMs: number) {
    const day = new Date(sinceMs).toISOString().slice(0, 10);
    const argv = [
      "gh",
      "pr",
      "list",
      "--state",
      "closed",
      "--search",
      `closed:>=${day}`,
      "--limit",
      String(MAX_CLOSED_PULLS + 1),
      "--json",
      FIELDS,
    ];
    const r = await runGhJson(this.runner, argv, z.array(GhClosedPull));
    if (!r.ok) return r;
    const truncated = r.value.length > MAX_CLOSED_PULLS;
    const pulls = r.value.slice(0, MAX_CLOSED_PULLS).map(toRecord);
    return ok({ pulls, truncated });
  }
}
