import { rm } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import { type BenchGrader, type BenchTask, patchPaths } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const TEST_TIMEOUT_MS = 15 * 60_000;

/**
 * Holdout grading, SWE-bench style: the files the hidden test patch touches are reset to the base
 * commit (an agent cannot pass by editing the oracle), the patch is applied, and every test
 * command must exit 0 within the time limit.
 */
export class ProcessBenchGrader implements BenchGrader {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly env: Readonly<Record<string, string>>,
  ) {}

  private git(args: readonly string[], dir: string, stdin?: string) {
    return this.runner.run({
      argv: ["git", ...args],
      cwd: dir,
      stdin,
      env: this.env,
      timeoutMs: 120_000,
    });
  }

  private async resetOracle(task: BenchTask, dir: string): Promise<Result<void, AdapterError>> {
    for (const path of patchPaths(task.testPatch ?? "")) {
      const full = resolve(dir, path);
      if (!full.startsWith(resolve(dir) + sep))
        return err({ kind: "failed", message: `test patch path escapes: ${path}` });
      const r = await this.git(["checkout", task.baseCommit, "--", path], dir);
      if (r.exitCode !== 0) await rm(join(dir, path), { force: true });
    }
    return ok(undefined);
  }

  async grade(task: BenchTask, dir: string) {
    if (task.testPatch === null || task.testCommands.length === 0)
      return err({
        kind: "failed",
        message: `task ${task.id} has no hidden tests`,
      } as AdapterError);
    const reset = await this.resetOracle(task, dir);
    if (!reset.ok) return reset;
    const applied = await this.git(["apply", "--whitespace=nowarn", "-"], dir, task.testPatch);
    if (applied.exitCode !== 0)
      return err({
        kind: "failed",
        message: `test patch does not apply: ${applied.stderr.trim().slice(-200)}`,
      } as AdapterError);
    for (const argv of task.testCommands) {
      const r = await this.runner.run({
        argv,
        cwd: dir,
        env: this.env,
        timeoutMs: TEST_TIMEOUT_MS,
      });
      if (r.timedOut || r.exitCode !== 0) {
        const why = r.timedOut ? "timed out" : `exit ${r.exitCode}`;
        return ok({
          resolved: false,
          detail: `${argv.join(" ")} ${why}: ${(r.stderr || r.stdout).trim().slice(-200)}`,
        });
      }
    }
    return ok({ resolved: true, detail: `${task.testCommands.length} test command(s) passed` });
  }
}
