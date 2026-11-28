import type { CommandOutcome, CommandRunner } from "../../contexts/delivery";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "./run-or-fail";

/** Variables a test run never gets: the code under test is agent-written (F9). */
const SCRUBBED =
  /^(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|GITHUB_PAT|.*_GITHUB_TOKEN)$/;

/** The parent environment minus GitHub credentials. */
export function testEnv(
  source: Readonly<Record<string, string | undefined>>,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(source)) if (v !== undefined && !SCRUBBED.test(k)) out[k] = v;
  return out;
}

const TAIL_LINES = 40;
const TAIL_CHARS = 4000;

function tail(text: string): string {
  return text.split("\n").slice(-TAIL_LINES).join("\n").slice(-TAIL_CHARS);
}

/**
 * Runs an operator-configured command (the pipeline's test or setup command, the same string
 * `shipwright loop --test-cmd` takes) with `bash -c`. The command never comes from issue, PR or
 * model text; the tournament command takes it from its own flags only. The code it runs is
 * agent-written, so with `gateScript` (scripts/lib/test-gate-exec.sh) it runs without GitHub,
 * git or Claude credentials, the same as the bash test gate (#8608).
 */
export class BashCommandRunner implements CommandRunner {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly env: Readonly<Record<string, string>>,
    private readonly gateScript?: string,
  ) {}

  async run(
    command: string,
    cwd: string,
    timeoutMs: number,
  ): Promise<Result<CommandOutcome, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: [...(this.gateScript ? ["bash", this.gateScript] : []), "bash", "-c", command],
      cwd,
      env: this.env,
      stdin: "",
      timeoutMs,
    });
    const passed = r.exitCode === 0 && !r.timedOut;
    return ok({ passed, timedOut: r.timedOut, tail: tail(`${r.stdout}\n${r.stderr}`.trim()) });
  }
}
