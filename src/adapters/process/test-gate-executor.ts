import type { TestExecutor } from "../../contexts/planning";
import type { ProcessResult, ProcessRunner } from "../../shared/kernel/ports";
import { runOrFail } from "./run-or-fail";

/**
 * Runs a test argv through scripts/lib/test-gate-exec.sh, which strips GitHub, git and Claude
 * credentials first (#8608). The argv is passed as arguments, never through a shell string.
 */
export class TestGateExecutor implements TestExecutor {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly gateScript: string,
    private readonly cwd: string,
  ) {}

  run(argv: readonly string[], timeoutMs: number): Promise<ProcessResult> {
    return runOrFail(this.runner, {
      argv: ["bash", this.gateScript, ...argv],
      cwd: this.cwd,
      timeoutMs,
    });
  }
}
