import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { MARKER_FILES, type ProofRepo, type RepoFacts } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const MAX_FILE = 512_000;
const GIT_TIMEOUT_MS = 30_000;
const PATH_LINE = /^[^\0\n]{1,400}$/;

function readSmall(path: string): string | null {
  try {
    if (!existsSync(path) || statSync(path).size > MAX_FILE) return null;
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

function goMains(root: string): string[] {
  const out = existsSync(join(root, "main.go")) ? ["."] : [];
  const cmd = join(root, "cmd");
  try {
    for (const d of readdirSync(cmd, { withFileTypes: true }))
      if (d.isDirectory() && existsSync(join(cmd, d.name, "main.go"))) out.push(d.name);
  } catch {
    // no cmd/ directory
  }
  return out;
}

/** Root files of the repository under test, its proof.json, and the change's files from git. */
export class FsProofRepo implements ProofRepo {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly root: string,
  ) {}

  async facts(): Promise<Result<RepoFacts, AdapterError>> {
    if (!existsSync(this.root))
      return err({ kind: "not_found", message: `no directory ${this.root}` });
    return ok({
      packageJson: readSmall(join(this.root, "package.json")),
      markers: MARKER_FILES.filter((f) => existsSync(join(this.root, f))),
      cargoToml: readSmall(join(this.root, "Cargo.toml")),
      goMains: goMains(this.root),
    });
  }

  async config(): Promise<Result<string | null, AdapterError>> {
    return ok(readSmall(join(this.root, ".shipwright", "proof.json")));
  }

  async changedFiles(baseRef: string): Promise<Result<readonly string[], AdapterError>> {
    if (!/^[A-Za-z0-9._/@^~-]{1,200}$/.test(baseRef) || baseRef.startsWith("-"))
      return err({ kind: "failed", message: `invalid base ref ${baseRef}` });
    const lists = await Promise.all([
      // Deleted files are left out: a page the change removed is not a page to visit.
      this.git(["diff", "--name-only", "--diff-filter=d", `${baseRef}...HEAD`]),
      this.git(["diff", "--name-only", "--diff-filter=d", "HEAD"]),
      this.git(["ls-files", "--others", "--exclude-standard"]),
    ]);
    if (lists[0] === null)
      return err({ kind: "failed", message: `git diff ${baseRef}...HEAD failed` });
    const all = lists.flatMap((l) => l ?? []);
    return ok([...new Set(all)]);
  }

  private async git(args: readonly string[]): Promise<string[] | null> {
    const r = await runOrFail(this.runner, {
      argv: ["git", "-C", this.root, ...args],
      timeoutMs: GIT_TIMEOUT_MS,
    });
    if (r.exitCode !== 0) return null;
    return r.stdout.split("\n").filter((l) => PATH_LINE.test(l));
  }
}
