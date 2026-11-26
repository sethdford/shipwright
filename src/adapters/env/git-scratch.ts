import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { relPathProblem, type Scratch } from "../../contexts/platform";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const TIMEOUT_MS = 10 * 60_000;
/** Must match _TEST_SANDBOX_PREFIX in scripts/lib/test-sandbox.sh. */
const SANDBOX_PREFIX = "sw-test-sandbox.";

/**
 * Disposable clones under one base directory (main passes `<stateDir>/env-scratch`). A clone has
 * no remote, so nothing run in it can reach the origin or a credential saved for its URL.
 */
export class GitScratch implements Scratch {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly base: string,
  ) {}

  async clone(root: string, ref: string): Promise<Result<string, AdapterError>> {
    if (ref.length === 0 || ref.startsWith("-") || /[\s\0]/.test(ref))
      return err({ kind: "failed", message: `unsafe ref: ${ref}` });
    const sha = await this.git(["-C", root, "rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
    if (!sha.ok) return err({ kind: "failed", message: `not a commit in ${root}: ${ref}` });
    const made = await this.makeWorkDir();
    if (!made.ok) return made;
    const dir = made.value;
    const steps: string[][] = [
      ["clone", "--quiet", "--local", "--no-hardlinks", "--no-checkout", "--", root, dir],
      ["-C", dir, "remote", "remove", "origin"],
      [
        "-C",
        dir,
        "-c",
        "core.hooksPath=/dev/null",
        "checkout",
        "--quiet",
        "--detach",
        sha.value.trim(),
      ],
    ];
    for (const args of steps) {
      const r = await this.git(args);
      if (!r.ok) {
        await this.remove(dir);
        return r;
      }
    }
    return ok(dir);
  }

  /**
   * `<base>/sw-test-sandbox.XXXXXX/{repo,tmp}`: the test sandbox's layout (ADR-0011), so
   * env-exec.sh can run an unreviewed recipe under its write jail. The path is resolved (macOS
   * /var is /private/var) because the jail compares real paths.
   */
  private async makeWorkDir(): Promise<Result<string, AdapterError>> {
    try {
      await mkdir(this.base, { recursive: true });
      const work = await realpath(await mkdtemp(join(this.base, SANDBOX_PREFIX)));
      await mkdir(join(work, "tmp"));
      return ok(join(work, "repo"));
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
  }

  async write(root: string, path: string, text: string): Promise<Result<void, AdapterError>> {
    const bad = relPathProblem(path);
    if (bad) return err({ kind: "failed", message: `refusing ${path}: ${bad}` });
    const abs = join(root, path);
    try {
      await mkdir(dirname(abs), { recursive: true });
      const [realRoot, realParent] = await Promise.all([realpath(root), realpath(dirname(abs))]);
      if (!within(realRoot, realParent, true))
        return err({ kind: "failed", message: `refusing ${path}: leaves the checkout` });
      await writeFile(abs, text);
      return ok(undefined);
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
  }

  async remove(dir: string): Promise<Result<void, AdapterError>> {
    // A clone is `<work>/repo`: remove the whole work directory with its tmp.
    const abs = resolve(dir);
    const parent = dirname(abs);
    const target =
      basename(abs) === "repo" && basename(parent).startsWith(SANDBOX_PREFIX) ? parent : abs;
    const base = await realpath(this.base).catch(() => resolve(this.base));
    if (!within(base, target, false) && !within(resolve(this.base), target, false))
      return err({ kind: "failed", message: `refusing to remove ${dir}: not inside ${this.base}` });
    try {
      await rm(target, { recursive: true, force: true });
      return ok(undefined);
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
  }

  private async git(args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, { argv: ["git", ...args], timeoutMs: TIMEOUT_MS });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout);
    const message = r.stderr.trim() || `git ${args[0] ?? ""} exited ${r.exitCode}`;
    return err({ kind: r.timedOut ? "transient" : "failed", message });
  }
}

/** True when `child` is strictly inside `parent` (or equal to it, when `orSame`). */
function within(parent: string, child: string, orSame: boolean): boolean {
  const rel = relative(parent, child);
  if (rel === "") return orSame;
  return !rel.startsWith("..") && !isAbsolute(rel);
}
