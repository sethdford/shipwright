import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import type { AuthorStat, RepoSource, SourceFileStat } from "../../contexts/intelligence";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const TIMEOUT_MS = 30_000;
const STAT_BATCH = 64;

function safePath(path: string): boolean {
  return path.length > 0 && !path.startsWith("/") && !path.split("/").includes("..");
}

/** Parses `git log --format=%x1e%an%x1f%as --name-only` into authors per path, most commits first. */
export function parseAuthorship(out: string): Record<string, AuthorStat[]> {
  const tally = new Map<string, Map<string, { commits: number; last: string }>>();
  for (const record of out.split("\x1e")) {
    const [header, ...paths] = record.split("\n");
    const [name, date] = (header ?? "").split("\x1f");
    if (!name || !date) continue;
    for (const p of paths.map((x) => x.trim()).filter((x) => x.length > 0)) {
      let byAuthor = tally.get(p);
      if (!byAuthor) {
        byAuthor = new Map();
        tally.set(p, byAuthor);
      }
      const cur = byAuthor.get(name) ?? { commits: 0, last: date };
      byAuthor.set(name, { commits: cur.commits + 1, last: cur.last > date ? cur.last : date });
    }
  }
  const out2: Record<string, AuthorStat[]> = {};
  for (const [p, byAuthor] of tally) {
    out2[p] = [...byAuthor.entries()]
      .map(([name, s]) => ({ name, ...s }))
      .sort((a, b) => b.commits - a.commits || b.last.localeCompare(a.last))
      .slice(0, 5);
  }
  return out2;
}

/** The working tree through git (which files) and the file system (sizes, mtimes, text). Read-only. */
export class GitRepoSource implements RepoSource {
  constructor(private readonly runner: ProcessRunner) {}

  async list(root: string): Promise<Result<readonly SourceFileStat[], AdapterError>> {
    const r = await this.git(root, [
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
    ]);
    if (!r.ok) return r;
    const paths = [...new Set(r.value.split("\0").filter(safePath))];
    const out: SourceFileStat[] = [];
    for (let i = 0; i < paths.length; i += STAT_BATCH) {
      const batch = await Promise.all(
        paths.slice(i, i + STAT_BATCH).map((p) => this.statOf(root, p)),
      );
      for (const s of batch) if (s) out.push(s);
    }
    return ok(out);
  }

  async read(root: string, path: string): Promise<Result<string, AdapterError>> {
    if (!safePath(path)) return err({ kind: "failed", message: `not a repository path: ${path}` });
    try {
      return ok(await readFile(join(root, path), "utf8"));
    } catch (cause) {
      const missing = (cause as { code?: string }).code === "ENOENT";
      return err({ kind: missing ? "not_found" : "failed", message: String(cause) });
    }
  }

  async head(root: string): Promise<string> {
    const r = await this.git(root, ["rev-parse", "--verify", "--quiet", "HEAD"]);
    return r.ok ? r.value.trim() : "";
  }

  async authorship(
    root: string,
    commits: number,
  ): Promise<Result<Readonly<Record<string, readonly AuthorStat[]>>, AdapterError>> {
    const n = String(Math.max(1, Math.floor(commits)));
    const r = await this.git(root, [
      "log",
      "-n",
      n,
      "--no-merges",
      "--format=%x1e%an%x1f%as",
      "--name-only",
    ]);
    return r.ok ? ok(parseAuthorship(r.value)) : r;
  }

  private async statOf(root: string, path: string): Promise<SourceFileStat | undefined> {
    try {
      const s = await stat(join(root, path));
      return s.isFile() ? { path, size: s.size, mtimeMs: Math.floor(s.mtimeMs) } : undefined;
    } catch {
      return undefined; // deleted in the working tree but still in the index
    }
  }

  private async git(cwd: string, args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, { argv: ["git", ...args], cwd, timeoutMs: TIMEOUT_MS });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout);
    const message = r.stderr.trim() || `git ${args[0]} exited ${r.exitCode}`;
    if (r.timedOut) return err({ kind: "transient", message });
    return err({ kind: /not a git repository/i.test(message) ? "not_found" : "failed", message });
  }
}
