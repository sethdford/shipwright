import type { EnvExecutor, ExecOptions } from "../../contexts/platform";
import type { ProcessResult, ProcessRunner } from "../../shared/kernel/ports";
import { runOrFail } from "../process/run-or-fail";

/** Names a recipe may never set, even if one slipped past the recipe schema. */
const RESERVED = new Set(["PATH", "HOME", "SHELL", "USER", "TMPDIR", "BASH_ENV", "ENV"]);

function reserved(name: string): boolean {
  return RESERVED.has(name) || name.startsWith("LD_") || name.startsWith("DYLD_");
}

/**
 * Runs recipe commands through `scripts/lib/env-exec.sh`, which strips credentials and applies
 * the test sandbox's write jail where it exists. Main passes a runner that reaps the whole process
 * group, so a setup command cannot leave a background job behind.
 */
export class JailedEnvExecutor implements EnvExecutor {
  private readonly baseEnv: Readonly<Record<string, string>>;

  /**
   * @param script absolute path of `scripts/lib/env-exec.sh`
   * @param baseEnv the environment the commands start from (main passes `process.env`)
   */
  constructor(
    private readonly runner: ProcessRunner,
    private readonly script: string,
    baseEnv: Readonly<Record<string, string | undefined>>,
  ) {
    const clean: Record<string, string> = {};
    for (const [k, v] of Object.entries(baseEnv)) if (v !== undefined) clean[k] = v;
    this.baseEnv = clean;
  }

  run(
    argv: readonly string[],
    cwd: string,
    env: Readonly<Record<string, string>>,
    timeoutMs: number,
    opts: ExecOptions = {},
  ): Promise<ProcessResult> {
    if (argv.length === 0)
      return Promise.resolve({ exitCode: 2, stdout: "", stderr: "empty argv", timedOut: false });
    const merged: Record<string, string> = { ...this.baseEnv };
    for (const [k, v] of Object.entries(env)) if (!reserved(k)) merged[k] = v;
    // env-exec.sh refuses (exit 126) instead of running unjailed; the recipe cannot unset this.
    if (opts.requireJail) merged.SW_ENV_REQUIRE_JAIL = "1";
    else delete merged.SW_ENV_REQUIRE_JAIL;
    return runOrFail(this.runner, {
      argv: ["bash", this.script, ...argv],
      cwd,
      env: merged,
      timeoutMs,
    });
  }
}
