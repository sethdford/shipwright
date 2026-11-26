import { randomBytes } from "node:crypto";
import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import type { BenchTask, BenchWorkspaces } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const GIT_TIMEOUT_MS = 15 * 60_000;
const SETUP_TIMEOUT_MS = 20 * 60_000;
/** Run output that never counts as part of an agent's patch. */
const EXCLUDE = [":(exclude).claude", ":(exclude).shipwright", ":(exclude)node_modules"];

const slug = (repo: string) => repo.replace(/^https:\/\//, "").replace(/[^A-Za-z0-9._-]+/g, "_");

/**
 * Checkouts from a bare mirror per repo (`<root>/repos`), one detached worktree per run
 * (`<root>/work`). The mirror is fetched once; each run starts from the exact base commit.
 */
export class GitBenchWorkspaces implements BenchWorkspaces {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly root: string,
    private readonly env: Readonly<Record<string, string>>,
  ) {}

  private async git(args: readonly string[], cwd?: string, stdin?: string) {
    const r = await this.runner.run({
      argv: ["git", ...args],
      cwd,
      stdin,
      env: this.env,
      timeoutMs: GIT_TIMEOUT_MS,
    });
    if (r.timedOut)
      return err({ kind: "transient", message: `git ${args[0]} timed out` } as AdapterError);
    if (r.exitCode !== 0)
      return err({
        kind: "failed",
        message: `git ${args.join(" ").slice(0, 120)}: ${r.stderr.trim().slice(-300)}`,
      } as AdapterError);
    return ok(r.stdout);
  }

  private async mirror(task: BenchTask): Promise<Result<string, AdapterError>> {
    const dir = join(this.root, "repos", `${slug(task.repo)}.git`);
    const has = await this.git(["--git-dir", dir, "cat-file", "-e", `${task.baseCommit}^{commit}`]);
    if (has.ok) return ok(dir);
    await mkdir(join(this.root, "repos"), { recursive: true });
    const exists = await this.git(["--git-dir", dir, "rev-parse", "--git-dir"]);
    const fetched = exists.ok
      ? await this.git(["--git-dir", dir, "fetch", "--quiet", "origin", task.baseCommit])
      : await this.git(["clone", "--quiet", "--mirror", task.repo, dir]);
    return fetched.ok ? ok(dir) : fetched;
  }

  async prepare(task: BenchTask, label: string): Promise<Result<string, AdapterError>> {
    const mirror = await this.mirror(task);
    if (!mirror.ok) return mirror;
    const dir = join(this.root, "work", `${task.id}-${label}-${randomBytes(4).toString("hex")}`);
    const added = await this.git([
      "--git-dir",
      mirror.value,
      "worktree",
      "add",
      "--detach",
      "--force",
      dir,
      task.baseCommit,
    ]);
    if (!added.ok) return added;
    for (const [k, v] of [
      ["user.name", "shipwright-bench"],
      ["user.email", "bench@shipwright.invalid"],
    ]) {
      await this.git(["config", k ?? "", v ?? ""], dir);
    }
    for (const argv of task.setup) {
      const r = await this.runner.run({
        argv,
        cwd: dir,
        env: this.env,
        timeoutMs: SETUP_TIMEOUT_MS,
      });
      if (r.timedOut || r.exitCode !== 0) {
        await this.dispose(dir);
        return err({
          kind: "failed",
          message: `setup ${argv.join(" ")} failed: ${r.stderr.trim().slice(-300)}`,
        });
      }
    }
    return ok(dir);
  }

  async diff(dir: string, baseCommit: string) {
    const added = await this.git(["add", "-A", "--", ".", ...EXCLUDE], dir);
    if (!added.ok) return added;
    return this.git(["diff", "--cached", "--binary", baseCommit, "--", ".", ...EXCLUDE], dir);
  }

  async checkout(dir: string, commit: string) {
    const r = await this.git(["checkout", "--quiet", "--force", "--detach", commit], dir);
    return r.ok ? ok(undefined) : r;
  }

  async dispose(dir: string) {
    await this.git(["worktree", "remove", "--force", dir], dir);
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}
