import { randomBytes } from "node:crypto";
import { mkdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import type { BenchTask, BenchWorkspaces } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const GIT_TIMEOUT_MS = 15 * 60_000;
const SETUP_TIMEOUT_MS = 20 * 60_000;
/** Run output that never counts as part of an agent's patch. */
const EXCLUDE = [":(exclude).claude", ":(exclude).shipwright", ":(exclude)node_modules"];

const slug = (repo: string) => repo.replace(/^https:\/\//, "").replace(/[^A-Za-z0-9._-]+/g, "_");
const failed = (message: string): AdapterError => ({ kind: "failed", message });

/**
 * Benchmark checkouts that hold no future history (the SWE-bench Pro leak: agents ran
 * `git log --all` and found the gold fix). Three layers under `root`:
 * - `repos/<repo>.git`: a full mirror, fetched once. Agents never see it.
 * - `snapshots/<repo>-<base>.git`: only `baseCommit` and its ancestors, on one branch, no tags.
 * - one throwaway clone per run under `workRoot` (outside `root`), copied, not linked, from the
 *   snapshot. Its `origin` then points at the workspace itself, so `git fetch origin` works and
 *   finds nothing new, and nothing in the workspace names the snapshot or the mirror.
 * Every workspace is checked before use: a commit that is not an ancestor of the base fails it.
 */
export class GitBenchWorkspaces implements BenchWorkspaces {
  /** Mirror of each workspace, so `bench validate` can bring in the gold commit afterwards. */
  private readonly mirrors = new Map<string, string>();

  constructor(
    private readonly runner: ProcessRunner,
    private readonly root: string,
    private readonly env: Readonly<Record<string, string>>,
    private readonly workRoot: string = `${root}-work`,
  ) {}

  private async git(args: readonly string[], cwd?: string) {
    const r = await this.runner.run({
      argv: ["git", ...args],
      cwd,
      env: this.env,
      timeoutMs: GIT_TIMEOUT_MS,
    });
    if (r.timedOut)
      return err({ kind: "transient", message: `git ${args[0]} timed out` } as AdapterError);
    if (r.exitCode !== 0)
      return err(failed(`git ${args.join(" ").slice(0, 120)}: ${r.stderr.trim().slice(-300)}`));
    return ok(r.stdout);
  }

  /** The whole cache: the mirror, and other tasks' snapshots (a later base can hold this gold). */
  guardedPaths(): readonly string[] {
    return [this.root];
  }

  private async mirror(task: BenchTask, commit: string): Promise<Result<string, AdapterError>> {
    const dir = join(this.root, "repos", `${slug(task.repo)}.git`);
    const has = await this.git(["--git-dir", dir, "cat-file", "-e", `${commit}^{commit}`]);
    if (has.ok) return ok(dir);
    await mkdir(join(this.root, "repos"), { recursive: true });
    const exists = await this.git(["--git-dir", dir, "rev-parse", "--git-dir"]);
    const fetched = exists.ok
      ? await this.git(["--git-dir", dir, "fetch", "--quiet", "origin", commit])
      : await this.git(["clone", "--quiet", "--mirror", task.repo, dir]);
    return fetched.ok ? ok(dir) : fetched;
  }

  /** A bare repo with only `baseCommit` and its ancestors, built once and reused. */
  private async snapshot(task: BenchTask, mirror: string): Promise<Result<string, AdapterError>> {
    const base = task.baseCommit;
    const dir = join(this.root, "snapshots", `${slug(task.repo)}-${base.slice(0, 12)}.git`);
    if ((await this.git(["--git-dir", dir, "cat-file", "-e", `${base}^{commit}`])).ok)
      return ok(dir);
    const tmp = `${dir}.tmp-${randomBytes(4).toString("hex")}`;
    const steps = [
      ["init", "--quiet", "--bare", tmp],
      ["--git-dir", tmp, "fetch", "--quiet", "--no-tags", mirror, `${base}:refs/heads/main`],
      ["--git-dir", tmp, "symbolic-ref", "HEAD", "refs/heads/main"],
      // FETCH_HEAD names the mirror's path; nothing in a snapshot may lead back to it.
      ["--git-dir", tmp, "update-ref", "-d", "FETCH_HEAD"],
    ];
    for (const args of steps) {
      const r = await this.git(args);
      if (!r.ok) {
        await rm(tmp, { recursive: true, force: true });
        return r;
      }
    }
    await rm(dir, { recursive: true, force: true });
    await rename(tmp, dir);
    return ok(dir);
  }

  /** Fails unless every commit in the workspace is the base or one of its ancestors. */
  private async assertNoFuture(dir: string, task: BenchTask): Promise<Result<void, AdapterError>> {
    const extra = await this.git(["rev-list", "--all", "--reflog", "--not", task.baseCommit], dir);
    if (!extra.ok) return extra;
    if (extra.value.trim() !== "")
      return err(failed(`workspace holds commits after the base: ${extra.value.slice(0, 82)}`));
    if (task.goldCommit && (await this.git(["cat-file", "-e", task.goldCommit], dir)).ok)
      return err(failed("workspace holds the gold commit"));
    return ok(undefined);
  }

  private async clone(task: BenchTask, snap: string, dir: string) {
    const steps = [
      ["clone", "--quiet", "--no-hardlinks", "--no-tags", snap, dir],
      ["-C", dir, "checkout", "--quiet", "--detach", task.baseCommit],
      ["-C", dir, "remote", "set-url", "origin", dir],
      ["-C", dir, "config", "user.name", "shipwright-bench"],
      ["-C", dir, "config", "user.email", "bench@shipwright.invalid"],
    ];
    for (const args of steps) {
      const r = await this.git(args);
      if (!r.ok) return r;
    }
    return this.assertNoFuture(dir, task);
  }

  async prepare(task: BenchTask, label: string): Promise<Result<string, AdapterError>> {
    const mirror = await this.mirror(task, task.baseCommit);
    if (!mirror.ok) return mirror;
    const snap = await this.snapshot(task, mirror.value);
    if (!snap.ok) return snap;
    await mkdir(this.workRoot, { recursive: true, mode: 0o700 });
    const dir = join(this.workRoot, `${task.id}-${label}-${randomBytes(4).toString("hex")}`);
    const cloned = await this.clone(task, snap.value, dir);
    if (!cloned.ok) {
      await this.dispose(dir);
      return cloned;
    }
    this.mirrors.set(dir, mirror.value);
    return this.setup(task, dir);
  }

  private async setup(task: BenchTask, dir: string): Promise<Result<string, AdapterError>> {
    for (const argv of task.setup) {
      const r = await this.runner.run({
        argv,
        cwd: dir,
        env: this.env,
        timeoutMs: SETUP_TIMEOUT_MS,
      });
      if (r.timedOut || r.exitCode !== 0) {
        await this.dispose(dir);
        return err(failed(`setup ${argv.join(" ")} failed: ${r.stderr.trim().slice(-300)}`));
      }
    }
    return ok(dir);
  }

  async diff(dir: string, baseCommit: string) {
    const added = await this.git(["add", "-A", "--", ".", ...EXCLUDE], dir);
    if (!added.ok) return added;
    return this.git(["diff", "--cached", "--binary", baseCommit, "--", ".", ...EXCLUDE], dir);
  }

  /** Harness-only (`bench validate`): brings `commit` in from the mirror, then checks it out. */
  async checkout(dir: string, commit: string) {
    const mirror = this.mirrors.get(dir);
    if ((await this.git(["cat-file", "-e", `${commit}^{commit}`], dir)).ok === false) {
      if (!mirror) return err(failed(`commit ${commit.slice(0, 12)} is not in the workspace`));
      const f = await this.git(["fetch", "--quiet", "--no-tags", mirror, commit], dir);
      if (!f.ok) return f;
    }
    const r = await this.git(["checkout", "--quiet", "--force", "--detach", commit], dir);
    return r.ok ? ok(undefined) : r;
  }

  async dispose(dir: string) {
    this.mirrors.delete(dir);
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}
