import { existsSync } from "node:fs";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import type { AcceptanceWorkspace } from "../../contexts/planning";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const TIMEOUT_MS = 60_000;
/** Untracked files larger than this are listed as added without their content. */
const UNTRACKED_BYTES = 200_000;

/** The acceptance tests' repository, through git and the filesystem. Every path stays under `root`. */
export class GitAcceptanceWorkspace implements AcceptanceWorkspace {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly root: string,
  ) {}

  async readText(path: string): Promise<Result<string, AdapterError>> {
    const abs = this.inside(path);
    if (!abs.ok) return abs;
    try {
      return ok(await readFile(abs.value, "utf8"));
    } catch (cause) {
      const missing = (cause as { code?: string }).code === "ENOENT";
      return err({ kind: missing ? "not_found" : "failed", message: String(cause) });
    }
  }

  async writeText(path: string, text: string): Promise<Result<void, AdapterError>> {
    const abs = this.inside(path);
    if (!abs.ok) return abs;
    try {
      await mkdir(dirname(abs.value), { recursive: true });
      await writeFile(abs.value, text, { flag: "wx" });
      return ok(undefined);
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
  }

  async exists(path: string): Promise<boolean> {
    const abs = this.inside(path);
    return abs.ok && existsSync(abs.value);
  }

  async headCommit(): Promise<Result<string, AdapterError>> {
    const r = await this.git(["rev-parse", "--verify", "HEAD^{commit}"]);
    return r.ok ? ok(r.value.trim()) : r;
  }

  async blobAt(commit: string, path: string): Promise<Result<string | null, AdapterError>> {
    if (!this.inside(path).ok || !isSha(commit))
      return err({ kind: "failed", message: `bad blob request: ${commit}:${path}` });
    const r = await this.git(["rev-parse", "--verify", "--quiet", `${commit}:${path}`]);
    return ok(r.ok ? r.value.trim() : null);
  }

  async worktreeBlob(path: string): Promise<Result<string, AdapterError>> {
    if (!this.inside(path).ok)
      return err({ kind: "failed", message: `outside the repository: ${path}` });
    const r = await this.git(["hash-object", "--", path]);
    return r.ok ? ok(r.value.trim()) : r;
  }

  async diffSince(commit: string): Promise<Result<string, AdapterError>> {
    if (!isSha(commit)) return err({ kind: "failed", message: `not a commit id: ${commit}` });
    const tracked = await this.git([
      "diff",
      "-M",
      "--no-color",
      "--no-ext-diff",
      "--no-textconv",
      commit,
      "--",
    ]);
    if (!tracked.ok) return tracked;
    const others = await this.git(["ls-files", "-z", "--others", "--exclude-standard"]);
    if (!others.ok) return others;
    const parts = [tracked.value];
    for (const p of others.value.split("\0").filter((x) => x.length > 0))
      parts.push(await this.untrackedDiff(p));
    return ok(parts.join("\n"));
  }

  async restore(commit: string, path: string): Promise<Result<void, AdapterError>> {
    if (!isSha(commit) || !this.inside(path).ok)
      return err({ kind: "failed", message: `bad restore: ${commit}:${path}` });
    const r = await this.git(["checkout", commit, "--", path]);
    return r.ok ? ok(undefined) : r;
  }

  /** An untracked file as a "new file" diff, so a test config the agent added is still checked. */
  private async untrackedDiff(path: string): Promise<string> {
    const head = `diff --git a/${path} b/${path}\nnew file mode 100644\n`;
    const abs = resolve(this.root, path);
    try {
      if ((await stat(abs)).size > UNTRACKED_BYTES) return head;
      const text = await readFile(abs, "utf8");
      return (
        head +
        text
          .split("\n")
          .map((l) => `+${l}`)
          .join("\n")
      );
    } catch {
      return head;
    }
  }

  private inside(path: string): Result<string, AdapterError> {
    const abs = resolve(this.root, path);
    const rel = relative(this.root, abs);
    if (
      path.length === 0 ||
      rel.startsWith("..") ||
      rel === "" ||
      resolve(this.root, rel) !== abs
    ) {
      return err({ kind: "failed", message: `outside the repository: ${path}` });
    }
    return ok(abs);
  }

  private async git(args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: ["git", ...args],
      cwd: this.root,
      timeoutMs: TIMEOUT_MS,
    });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout);
    const message = r.stderr.trim() || `git ${args[0] ?? ""} exited ${r.exitCode}`;
    return err({ kind: r.timedOut ? "transient" : "failed", message });
  }
}

function isSha(value: string): boolean {
  return /^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value);
}
