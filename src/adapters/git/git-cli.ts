import type { AdapterError, ProcessRunner, Vcs } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

export class GitCli implements Vcs {
  constructor(private readonly runner: ProcessRunner) {}

  headSha(cwd: string): Promise<Result<string, AdapterError>> {
    return this.git(cwd, ["rev-parse", "HEAD"]);
  }

  currentBranch(cwd: string): Promise<Result<string, AdapterError>> {
    return this.git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]);
  }

  private async git(cwd: string, args: readonly string[]): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, { argv: ["git", ...args], cwd, timeoutMs: 30_000 });
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout.trim());
    const message = r.stderr.trim() || `git ${args.join(" ")} exited ${r.exitCode}`;
    if (r.timedOut) return err({ kind: "transient", message });
    return err({ kind: /not a git repository/i.test(message) ? "not_found" : "failed", message });
  }
}
