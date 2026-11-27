import { createHash } from "node:crypto";
import { readdir, stat } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import type { Snapshot, Workspace, Workspaces } from "../../contexts/delivery";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const GIT_TIMEOUT_MS = 120_000;
const LABEL = /^[a-z0-9][a-z0-9-]{0,31}$/;
const SHA = /^[0-9a-f]{40}([0-9a-f]{24})?$/;

/**
 * Config that turns off everything in the shared `.git` that could run code. Worktrees share the
 * repository's common dir, and agent-written code (the test and setup commands) can write it, so
 * hooks and fsmonitor are never honoured here, and diffs pass `--no-ext-diff --no-textconv` (`--no-verify` alone still
 * runs post-commit, and post-merge on adopt).
 */
const SAFE_CONFIG = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] as const;

/**
 * Tournament worktrees under `root` (outside the repository's working tree, so attempts never
 * show up in its status or diffs). Commits are local, made with a fixed identity, `--no-verify`
 * and hooks disabled. Git runs with `env` (the caller passes a credential-free environment).
 * `adopt` refuses when the repository's hooks or local config changed during the run, so code an
 * attempt planted there is reported instead of left behind silently.
 */
export class GitWorkspaces implements Workspaces {
  private baseline: string | undefined;

  constructor(
    private readonly runner: ProcessRunner,
    private readonly repo: string,
    private readonly root: string,
    private readonly env?: Readonly<Record<string, string>>,
  ) {}

  async baseSha(): Promise<Result<string, AdapterError>> {
    const fp = await this.fingerprint();
    if (!fp.ok) return fp;
    this.baseline ??= fp.value;
    return this.git(this.repo, ["rev-parse", "HEAD"]);
  }

  async create(label: string, baseSha: string): Promise<Result<Workspace, AdapterError>> {
    if (!LABEL.test(label) || !SHA.test(baseSha)) {
      return err({ kind: "failed", message: `bad workspace label or sha: ${label} ${baseSha}` });
    }
    const path = `${this.root}/${label}`;
    const r = await this.git(this.repo, ["worktree", "add", "--detach", "--", path, baseSha]);
    return r.ok ? ok({ label, path }) : r;
  }

  async snapshot(ws: Workspace, baseSha: string): Promise<Result<Snapshot, AdapterError>> {
    const add = await this.git(ws.path, ["add", "-A"]);
    if (!add.ok) return add;
    const staged = await this.git(ws.path, ["diff", "--no-ext-diff", "--cached", "--name-only"]);
    if (!staged.ok) return staged;
    if (staged.value !== "") {
      const commit = await this.git(ws.path, [
        "-c",
        "user.name=shipwright",
        "-c",
        "user.email=shipwright@users.noreply.github.com",
        "commit",
        "-q",
        "--no-verify",
        "-m",
        `tournament attempt ${ws.label}`,
      ]);
      if (!commit.ok) return commit;
    }
    return this.describe(ws, baseSha);
  }

  private async describe(ws: Workspace, baseSha: string): Promise<Result<Snapshot, AdapterError>> {
    const sha = await this.git(ws.path, ["rev-parse", "HEAD"]);
    if (!sha.ok) return sha;
    const patch = await this.git(
      ws.path,
      ["diff", "--no-ext-diff", "--no-textconv", baseSha, sha.value],
      false,
    );
    if (!patch.ok) return patch;
    const names = await this.git(
      ws.path,
      ["diff", "--no-ext-diff", "-z", "--name-only", "--diff-filter=AM", baseSha, sha.value],
      false,
    );
    if (!names.ok) return names;
    const files = names.value.split("\0").filter((f) => f !== "");
    return ok({ sha: sha.value, patch: patch.value, files });
  }

  async overlay(
    ws: Workspace,
    sha: string,
    files: readonly string[],
  ): Promise<Result<void, AdapterError>> {
    if (files.length === 0) return ok(undefined);
    const r = await this.git(ws.path, ["checkout", sha, "--", ...files]);
    return r.ok ? ok(undefined) : r;
  }

  async reset(ws: Workspace, sha: string): Promise<Result<void, AdapterError>> {
    const hard = await this.git(ws.path, ["reset", "-q", "--hard", sha]);
    if (!hard.ok) return hard;
    const clean = await this.git(ws.path, ["clean", "-fdq"]);
    return clean.ok ? ok(undefined) : clean;
  }

  async remove(ws: Workspace): Promise<Result<void, AdapterError>> {
    const r = await this.git(this.repo, ["worktree", "remove", "--force", "--", ws.path]);
    if (!r.ok && !/is not a working tree|No such file/i.test(r.error.message)) return r;
    const prune = await this.git(this.repo, ["worktree", "prune"]);
    return prune.ok ? ok(undefined) : prune;
  }

  async adopt(sha: string): Promise<Result<void, AdapterError>> {
    const fp = await this.fingerprint();
    if (!fp.ok) return fp;
    if (this.baseline === undefined || fp.value !== this.baseline) {
      return err({
        kind: "failed",
        message:
          "refusing to adopt: the repository's git hooks or local config changed during the tournament; inspect .git/hooks and .git/config",
      });
    }
    const r = await this.git(this.repo, ["merge", "--ff-only", "-q", sha]);
    return r.ok ? ok(undefined) : r;
  }

  /** A hash of the common dir's local config and its hooks (names, sizes, mtimes). */
  private async fingerprint(): Promise<Result<string, AdapterError>> {
    const dir = await this.git(this.repo, ["rev-parse", "--git-common-dir"]);
    if (!dir.ok) return dir;
    const common = isAbsolute(dir.value) ? dir.value : join(this.repo, dir.value);
    const config = await this.git(this.repo, ["config", "--local", "--list"], false);
    if (!config.ok) return config;
    const hash = createHash("sha256").update(config.value);
    const hooks = join(common, "hooks");
    const names = await readdir(hooks).catch(() => [] as string[]);
    for (const name of names.sort()) {
      const s = await stat(join(hooks, name)).catch(() => null);
      hash.update(`\0${name}:${s?.size ?? -1}:${s?.mtimeMs ?? -1}`);
    }
    return ok(hash.digest("hex"));
  }

  private async git(
    cwd: string,
    args: readonly string[],
    trim = true,
  ): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: ["git", ...SAFE_CONFIG, ...args],
      cwd,
      ...(this.env ? { env: this.env } : {}),
      timeoutMs: GIT_TIMEOUT_MS,
    });
    if (r.exitCode === 0 && !r.timedOut) return ok(trim ? r.stdout.trim() : r.stdout);
    const message = r.stderr.trim() || `git ${args[0]} exited ${r.exitCode}`;
    return err({ kind: r.timedOut ? "transient" : "failed", message });
  }
}
