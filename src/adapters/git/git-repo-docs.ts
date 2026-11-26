import { join } from "node:path";
import type { DocSource, RepoDocs } from "../../contexts/governance";
import type { AdapterError, FileReader, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const TIMEOUT_MS = 30_000;

function safePath(path: string): boolean {
  return path.length > 0 && !path.startsWith("/") && !path.split("/").includes("..");
}

/**
 * Governance documents from git: tracked files only, so an untracked file an agent drops in is never read.
 * With a ref, the ref is resolved to a commit once and every read comes from that commit.
 */
export class GitRepoDocs implements RepoDocs {
  private readonly commits = new Map<string, string>();

  constructor(
    private readonly runner: ProcessRunner,
    private readonly files: FileReader,
  ) {}

  async list(
    source: DocSource,
    prefixes: readonly string[],
  ): Promise<Result<readonly string[], AdapterError>> {
    let argv: string[];
    if (source.ref === undefined) {
      argv = ["ls-files", "-z", "--", ...prefixes];
    } else {
      const sha = await this.commit(source);
      if (!sha.ok) return sha;
      argv = ["ls-tree", "-r", "-z", "--name-only", sha.value, "--", ...prefixes];
    }
    const out = await this.git(source.root, argv);
    if (!out.ok) return out;
    return ok(out.value.split("\0").filter((p) => p.length > 0));
  }

  async read(source: DocSource, path: string): Promise<Result<string, AdapterError>> {
    if (!safePath(path)) return err({ kind: "failed", message: `not a repository path: ${path}` });
    if (source.ref === undefined) return this.files.readText(join(source.root, path));
    const sha = await this.commit(source);
    if (!sha.ok) return sha;
    return this.git(source.root, ["show", `${sha.value}:${path}`]);
  }

  private async commit(source: DocSource): Promise<Result<string, AdapterError>> {
    const ref = source.ref ?? "HEAD";
    const key = `${source.root}\0${ref}`;
    const known = this.commits.get(key);
    if (known !== undefined) return ok(known);
    if (ref.startsWith("-")) return err({ kind: "failed", message: `not a ref: ${ref}` });
    const r = await this.git(source.root, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
    if (!r.ok) return err({ kind: "not_found", message: `no commit for ref ${ref}` });
    const sha = r.value.trim();
    this.commits.set(key, sha);
    return ok(sha);
  }

  private async git(cwd: string, args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, { argv: ["git", ...args], cwd, timeoutMs: TIMEOUT_MS });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout);
    const message = r.stderr.trim() || `git ${args[0] ?? ""} exited ${r.exitCode}`;
    return err({ kind: r.timedOut ? "transient" : "failed", message });
  }
}
