import { createHash } from "node:crypto";
import { join } from "node:path";
import type { HistoryCommit, HistorySource } from "../../contexts/intelligence";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const TIMEOUT_MS = 120_000;
const REV = /^[0-9a-f]{7,64}$/;
const REF = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$/;

/** Parses `git log --format=%H%x1f%P%x1f%s%x1f%b%x1e`. */
export function parseLog(out: string): Omit<HistoryCommit, "files">[] {
  const commits: Omit<HistoryCommit, "files">[] = [];
  for (const record of out.split("\x1e")) {
    const [sha, parents, subject, body] = record.replace(/^\n+/, "").split("\x1f");
    const parent = (parents ?? "").split(" ")[0] ?? "";
    if (sha && REV.test(sha) && REV.test(parent))
      commits.push({ sha, parent, subject: subject ?? "", body: (body ?? "").trim() });
  }
  return commits;
}

/**
 * Past changes through git, and a scratch worktree for rebuilding the model at a parent commit. The worktree
 * lives under the state directory, keyed by the repository, and is removed by `release`; the repository's own
 * working tree is never touched.
 */
export class GitHistorySource implements HistorySource {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly scratchDir: string,
  ) {}

  async commits(root: string, ref: string, limit: number) {
    if (!REF.test(ref) || ref.includes("..")) return err(failed(`not a ref: ${ref}`));
    const n = String(Math.max(1, Math.min(5000, Math.floor(limit))));
    const log = await this.git(root, [
      "log",
      "--first-parent",
      "-n",
      n,
      "--format=%H%x1f%P%x1f%s%x1f%b%x1e",
      ref,
      "--",
    ]);
    if (!log.ok) return log;
    const out: HistoryCommit[] = [];
    for (const c of parseLog(log.value)) {
      const diff = await this.git(root, ["diff", "--name-only", c.parent, c.sha, "--"]);
      if (!diff.ok) return diff;
      out.push({ ...c, files: diff.value.split("\n").filter((p) => p.length > 0) });
    }
    return ok(out);
  }

  async checkout(root: string, rev: string): Promise<Result<string, AdapterError>> {
    if (!REV.test(rev)) return err(failed(`not a commit: ${rev}`));
    const wt = this.worktreeOf(root);
    const exists = await this.git(wt, ["rev-parse", "--is-inside-work-tree"]);
    if (!exists.ok) {
      await this.git(root, ["worktree", "prune"]);
      const add = await this.git(root, ["worktree", "add", "--detach", "--force", wt, rev]);
      return add.ok ? ok(wt) : add;
    }
    const co = await this.git(wt, ["checkout", "--quiet", "--detach", "--force", rev]);
    if (!co.ok) return co;
    const clean = await this.git(wt, ["clean", "-qfdx"]);
    return clean.ok ? ok(wt) : clean;
  }

  async release(root: string): Promise<void> {
    await this.git(root, ["worktree", "remove", "--force", this.worktreeOf(root)]);
  }

  private worktreeOf(root: string): string {
    const key = createHash("sha256").update(root).digest("hex").slice(0, 16);
    return join(this.scratchDir, `eval-${key}`);
  }

  private async git(cwd: string, args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, { argv: ["git", ...args], cwd, timeoutMs: TIMEOUT_MS });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout);
    const message = r.stderr.trim() || `git ${args[0]} exited ${r.exitCode}`;
    return err(r.timedOut ? { kind: "transient", message } : failed(message));
  }
}

function failed(message: string): AdapterError {
  return { kind: "failed", message };
}
