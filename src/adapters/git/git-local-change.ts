import type { FileChange, LocalChange } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

/** A ref name an operator may pass: no leading dash (never an option), no spaces or `..`. */
const REF = /^(?!-)[A-Za-z0-9._/@^~{}-]{1,200}$/;

/** `git diff --numstat` lines; binary files ("-\t-\tpath") count as zero lines. */
export function parseNumstat(stdout: string): FileChange[] {
  const out: FileChange[] = [];
  for (const line of stdout.split("\n")) {
    const m = /^(\d+|-)\t(\d+|-)\t(.+)$/.exec(line);
    if (!m) continue;
    const n = (v: string | undefined) => (v === undefined || v === "-" ? 0 : Number(v));
    out.push({ path: m[3] as string, additions: n(m[1]), deletions: n(m[2]) });
  }
  return out;
}

/** The current branch's change against `base` (`git diff base...HEAD`), read-only. */
export class GitLocalChange implements LocalChange {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly cwd: string,
  ) {}

  async diff(baseRef: string, headRef = "HEAD") {
    for (const ref of [baseRef, headRef]) {
      if (!REF.test(ref) || ref.includes("..")) {
        return err({ kind: "failed" as const, message: `not a usable ref: ${ref}` });
      }
    }
    const range = `${baseRef}...${headRef}`;
    const stat = await this.git(["diff", "--no-renames", "--numstat", range]);
    if (!stat.ok) return stat;
    // Plain text whatever the user's config or in-tree attributes say: no colour, no external
    // diff or textconv, a/ b/ prefixes, and binary-marked files shown as text, so the scan sees
    // every added line.
    const patch = await this.git([
      "diff",
      "--no-renames",
      "--no-color",
      "--no-ext-diff",
      "--no-textconv",
      "--text",
      "--src-prefix=a/",
      "--dst-prefix=b/",
      range,
    ]);
    if (!patch.ok) return patch;
    return ok({ files: parseNumstat(stat.value), patch: patch.value });
  }

  private async git(args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: ["git", ...args],
      cwd: this.cwd,
      timeoutMs: 60_000,
    });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout);
    const message = r.stderr.trim() || `git ${args.join(" ")} exited ${r.exitCode}`;
    return err({ kind: r.timedOut ? "transient" : "failed", message });
  }
}
