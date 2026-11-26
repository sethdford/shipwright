import { createHash } from "node:crypto";
import { readdir, readFile, realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative } from "node:path";
import { type EnvSource, relPathProblem } from "../../contexts/platform";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const TIMEOUT_MS = 30_000;
/** A local-path origin is followed this many times, so a clone of a local clone keeps its id. */
const MAX_LOCAL_HOPS = 3;

/** A checkout seen through git (`git show`, remotes) and the filesystem (ADR-0020). */
export class GitEnvSource implements EnvSource {
  constructor(private readonly runner: ProcessRunner) {}

  async fileAt(
    root: string,
    ref: string,
    path: string,
  ): Promise<Result<string | null, AdapterError>> {
    const bad = refProblem(ref) ?? relPathProblem(path);
    if (bad) return err({ kind: "failed", message: `refusing ${ref}:${path}: ${bad}` });
    const shown = await this.git(root, ["show", `${ref}:${path}`]);
    if (shown.ok) return shown;
    const commit = await this.git(root, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
    if (!commit.ok) return err({ kind: "failed", message: `not a commit: ${ref}` });
    return ok(null);
  }

  async readFile(root: string, path: string): Promise<Result<string | null, AdapterError>> {
    const abs = await inside(root, path);
    if (!abs.ok) return abs;
    if (abs.value === null) return ok(null);
    try {
      return ok(await readFile(abs.value, "utf8"));
    } catch (cause) {
      return isMissing(cause) ? ok(null) : err({ kind: "failed", message: String(cause) });
    }
  }

  async digests(
    root: string,
    paths: readonly string[],
  ): Promise<Result<Record<string, string | null>, AdapterError>> {
    const out: Record<string, string | null> = {};
    for (const p of paths) {
      const abs = await inside(root, p);
      if (!abs.ok) return abs;
      if (abs.value === null) {
        out[p] = null;
        continue;
      }
      try {
        out[p] = createHash("sha256")
          .update(await readFile(abs.value))
          .digest("hex");
      } catch (cause) {
        if (!isMissing(cause)) return err({ kind: "failed", message: String(cause) });
        out[p] = null;
      }
    }
    return ok(out);
  }

  async rootEntries(root: string): Promise<Result<readonly string[], AdapterError>> {
    try {
      return ok((await readdir(root)).sort());
    } catch (cause) {
      return err({ kind: isMissing(cause) ? "not_found" : "failed", message: String(cause) });
    }
  }

  async repoId(root: string): Promise<Result<string, AdapterError>> {
    return this.repoIdAt(root, 0);
  }

  private async repoIdAt(root: string, hops: number): Promise<Result<string, AdapterError>> {
    const url = await this.git(root, ["remote", "get-url", "origin"]);
    const remote = url.ok ? url.value.trim() : "";
    const local = localRemotePath(remote, root);
    if (local !== null && hops < MAX_LOCAL_HOPS) {
      const viaOrigin = await this.repoIdAt(local, hops + 1);
      if (viaOrigin.ok) return viaOrigin;
    } else if (remote !== "" && local === null) {
      const norm = normalizeRemote(remote);
      return ok(makeId(basename(norm), `url:${norm}`));
    }
    const common = await this.git(root, [
      "rev-parse",
      "--path-format=absolute",
      "--git-common-dir",
    ]);
    if (!common.ok) return common;
    let dir = common.value.trim();
    dir = await realpath(dir).catch(() => dir);
    const name = basename(dir) === ".git" ? basename(dirname(dir)) : basename(dir);
    return ok(makeId(name, `dir:${dir}`));
  }

  private async git(root: string, args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: ["git", "-C", root, ...args],
      timeoutMs: TIMEOUT_MS,
    });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout);
    const message = r.stderr.trim() || `git ${args[0] ?? ""} exited ${r.exitCode}`;
    return err({ kind: r.timedOut ? "transient" : "failed", message });
  }
}

/**
 * A remote URL with credentials, scheme, port, `.git` and case removed, so the https, ssh and
 * scp-style forms of one repository compare equal: `github.com/owner/repo`.
 */
export function normalizeRemote(url: string): string {
  let s = url.trim();
  const scp = /^(?:[^@/]+@)?([^:/]+):(?!\/)(.+)$/.exec(s);
  if (scp && !/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) s = `${scp[1]}/${scp[2]}`;
  s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "");
  const slash = s.indexOf("/");
  let host = slash === -1 ? s : s.slice(0, slash);
  const path = slash === -1 ? "" : s.slice(slash);
  host = host.slice(host.lastIndexOf("@") + 1).replace(/:\d*$/, "");
  return `${host}${path}`
    .toLowerCase()
    .replace(/\/+$/, "")
    .replace(/\.git$/, "")
    .replace(/\/+$/, "");
}

function makeId(name: string, identity: string): string {
  const slug =
    name
      .toLowerCase()
      .replace(/\.git$/, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40)
      .replace(/-+$/, "") || "repo";
  return `${slug}-${createHash("sha256").update(identity).digest("hex").slice(0, 16)}`;
}

/** The directory a local-path or file:// origin points at, or null for a network remote. */
function localRemotePath(remote: string, root: string): string | null {
  if (remote.startsWith("file://")) return remote.slice("file://".length);
  if (isAbsolute(remote)) return remote;
  if (remote.startsWith("./") || remote.startsWith("../")) return join(root, remote);
  return null;
}

/** A ref git will not read as an option or a path, e.g. `HEAD`, `main`, `origin/main`, a sha. */
function refProblem(ref: string): string | null {
  if (ref.length === 0 || ref.length > 255) return "empty or too long ref";
  if (ref.startsWith("-") || ref.includes(":") || /[\s\0]/.test(ref)) return "unsafe ref";
  return null;
}

/** Absolute path of `path` under `root`; null when a symlink on the way leaves `root` or is missing. */
async function inside(root: string, path: string): Promise<Result<string | null, AdapterError>> {
  const bad = relPathProblem(path);
  if (bad) return err({ kind: "failed", message: `refusing ${path}: ${bad}` });
  const abs = join(root, path);
  try {
    const [realRoot, real] = await Promise.all([realpath(root), realpath(abs)]);
    const rel = relative(realRoot, real);
    if (rel === "" || rel.startsWith("..") || isAbsolute(rel))
      return err({ kind: "failed", message: `refusing ${path}: leaves the checkout` });
    return ok(real);
  } catch (cause) {
    if (isMissing(cause)) return ok(null);
    return err({ kind: "failed", message: String(cause) });
  }
}

function isMissing(cause: unknown): boolean {
  const code = (cause as { code?: string }).code;
  return code === "ENOENT" || code === "ENOTDIR";
}
