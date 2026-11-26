import { z } from "zod";
import type { HoldoutSource, MergedPull } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-json";

const REPO = /^[\w.-]+\/[\w.-]+$/;
const SHA = /^[0-9a-f]{40}$/;
const Pull = z.object({
  number: z.number(),
  title: z.string(),
  body: z.string().nullable(),
  user: z.object({ login: z.string() }).nullable(),
  merged_at: z.string().nullable(),
  merge_commit_sha: z.string().nullable(),
});
const Issue = z.object({ title: z.string(), body: z.string().nullable(), created_at: z.string() });
const Commit = z.object({ parents: z.array(z.object({ sha: z.string() })) });

/** Merged PRs, issues and diffs over GitHub's REST API (`gh api`, read-only, argv only). */
export class GhHoldoutSource implements HoldoutSource {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly repo: string,
  ) {
    if (!REPO.test(repo)) throw new Error(`repo must be owner/name: ${repo}`);
  }

  private async api(path: string, accept?: string): Promise<Result<string, AdapterError>> {
    const argv = ["gh", "api", ...(accept ? ["-H", `Accept: ${accept}`] : []), path];
    const r = await runOrFail(this.runner, { argv, timeoutMs: 60_000 });
    return r.exitCode !== 0 || r.timedOut ? err(classifyGhError(r)) : ok(r.stdout);
  }

  private async json<T>(path: string, schema: z.ZodType<T>): Promise<Result<T, AdapterError>> {
    const r = await this.api(path);
    if (!r.ok) return r;
    try {
      const parsed = schema.safeParse(JSON.parse(r.value));
      return parsed.success
        ? ok(parsed.data)
        : err({ kind: "failed", message: `unexpected ${path} shape` });
    } catch {
      return err({ kind: "failed", message: `${path} is not JSON` });
    }
  }

  private async complete(p: z.infer<typeof Pull>): Promise<Result<MergedPull, AdapterError>> {
    const merge = p.merge_commit_sha ?? "";
    if (!SHA.test(merge))
      return err({ kind: "failed", message: `#${p.number} has no merge commit` });
    const commit = await this.json(`repos/${this.repo}/commits/${merge}`, Commit);
    if (!commit.ok) return commit;
    const files = await this.json(
      `repos/${this.repo}/pulls/${p.number}/files?per_page=100`,
      z.array(z.object({ filename: z.string() })),
    );
    if (!files.ok) return files;
    const base = commit.value.parents[0]?.sha ?? "";
    if (!SHA.test(base)) return err({ kind: "failed", message: `#${p.number}: no parent commit` });
    return ok({
      number: p.number,
      title: p.title,
      body: p.body ?? "",
      author: p.user?.login ?? "",
      mergedAtMs: Date.parse(p.merged_at ?? "") || 0,
      baseSha: base,
      mergeSha: merge,
      files: files.value.map((f) => f.filename),
    });
  }

  async mergedSince(sinceMs: number, max: number) {
    const out: MergedPull[] = [];
    for (let page = 1; page <= 20 && out.length < max; page++) {
      const list = await this.json(
        `repos/${this.repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=${page}`,
        z.array(Pull),
      );
      if (!list.ok) return list;
      if (list.value.length === 0) break;
      for (const p of list.value) {
        const merged = Date.parse(p.merged_at ?? "");
        if (Number.isNaN(merged) || merged < sinceMs || out.length >= max) continue;
        const full = await this.complete(p);
        if (full.ok) out.push(full.value);
      }
    }
    return ok(out.sort((a, b) => b.mergedAtMs - a.mergedAtMs));
  }

  async issue(n: number) {
    const r = await this.json(`repos/${this.repo}/issues/${n}`, Issue);
    if (!r.ok) return r;
    return ok({ title: r.value.title, body: r.value.body ?? "", createdAt: r.value.created_at });
  }

  async diff(base: string, head: string) {
    if (!SHA.test(base) || !SHA.test(head))
      return err({ kind: "failed", message: "diff needs two shas" } as AdapterError);
    return this.api(`repos/${this.repo}/compare/${base}...${head}`, "application/vnd.github.diff");
  }
}
