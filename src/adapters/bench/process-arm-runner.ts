import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import {
  type ArmOutcome,
  type ArmRunner,
  type BenchArm,
  type BenchTask,
  benchPrompt,
  expandArgv,
  type SpendSource,
} from "../../contexts/quality";
import type { ProcessResult, ProcessRunner } from "../../shared/kernel/ports";
import { agentEnv } from "./agent-env";

export interface ArmRunnerConfig {
  readonly claudeBin: string;
  readonly shipwrightBin: string;
  /** The permission policy Shipwright's own agents run under (config/agent-permissions.json). */
  readonly policyPath: string;
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly now: () => number;
}

/** `claude -p --output-format json` prints one object; its total_cost_usd is the run's spend. */
export function parseClaudeJson(stdout: string): { costUsd: number | null; isError: boolean } {
  try {
    const v = JSON.parse(stdout.trim()) as Record<string, unknown>;
    const cost = typeof v.total_cost_usd === "number" ? v.total_cost_usd : null;
    return { costUsd: cost, isError: v.is_error === true };
  } catch {
    return { costUsd: null, isError: true };
  }
}

function statusOf(r: ProcessResult): ArmOutcome["status"] {
  if (r.timedOut) return "timeout";
  return r.exitCode === 0 ? "ok" : "error";
}

const tail = (r: ProcessResult) => (r.stderr.trim() || r.stdout.trim()).slice(-300);

/**
 * Runs each arm kind with the same model, permission policy and time limit, and never with a
 * GitHub token. Shipwright's spend is read from its cost ledger for the run's time window, so
 * run one benchmark at a time and keep the daemon stopped while it runs.
 */
export class ProcessArmRunner implements ArmRunner {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly spend: SpendSource,
    private readonly cfg: ArmRunnerConfig,
  ) {}

  async run(arm: BenchArm, task: BenchTask, dir: string): Promise<ArmOutcome> {
    const start = this.cfg.now();
    try {
      const out = await this.dispatch(arm, task, dir, start);
      return { ...out, durationMs: this.cfg.now() - start };
    } catch (e) {
      const note = e instanceof Error ? e.message : String(e);
      return { status: "error", costUsd: null, durationMs: this.cfg.now() - start, note };
    }
  }

  private dispatch(arm: BenchArm, task: BenchTask, dir: string, start: number) {
    if (arm.kind === "claude-code") return this.claudeCode(arm, task, dir);
    if (arm.kind === "shipwright") return this.shipwright(arm, task, dir, start);
    return this.command(arm, task, dir);
  }

  private async claudeCode(
    arm: BenchArm,
    task: BenchTask,
    dir: string,
  ): Promise<Omit<ArmOutcome, "durationMs">> {
    const { claudeBin, policyPath } = this.cfg;
    const argv = [
      claudeBin,
      "-p",
      "--output-format",
      "json",
      "--model",
      arm.model,
      "--settings",
      policyPath,
    ];
    const stdin = benchPrompt(task.problem);
    const env = agentEnv(this.cfg.env, arm.env);
    const r = await this.runner.run({
      argv,
      cwd: dir,
      stdin,
      env,
      timeoutMs: arm.timeoutMin * 60_000,
    });
    const parsed = parseClaudeJson(r.stdout);
    const status = r.timedOut ? "timeout" : parsed.isError || r.exitCode !== 0 ? "error" : "ok";
    return { status, costUsd: parsed.costUsd, note: status === "ok" ? "" : tail(r) };
  }

  private async shipwright(
    arm: BenchArm,
    task: BenchTask,
    dir: string,
    start: number,
  ): Promise<Omit<ArmOutcome, "durationMs">> {
    const goal = ["--goal", task.problem, "--local", "--headless", "--model", arm.model];
    const argv = [this.cfg.shipwrightBin, "pipeline", "start", ...goal];
    const env = agentEnv(this.cfg.env, { PIPELINE_ATTEMPTS: String(arm.attempts), ...arm.env });
    const r = await this.runner.run({ argv, cwd: dir, env, timeoutMs: arm.timeoutMin * 60_000 });
    const spent = await this.spend.between(start, this.cfg.now());
    const status = statusOf(r);
    return { status, costUsd: spent.ok ? spent.value : null, note: status === "ok" ? "" : tail(r) };
  }

  private async command(
    arm: BenchArm,
    task: BenchTask,
    dir: string,
  ): Promise<Omit<ArmOutcome, "durationMs">> {
    const problemFile = join(dirname(dir), `${task.id}.${arm.id}.problem.md`);
    await mkdir(dirname(problemFile), { recursive: true });
    await writeFile(problemFile, benchPrompt(task.problem), "utf8");
    const argv = expandArgv(arm.argv ?? [], { workdir: dir, problemFile, model: arm.model });
    const env = agentEnv(this.cfg.env, arm.env);
    const r = await this.runner.run({ argv, cwd: dir, env, timeoutMs: arm.timeoutMin * 60_000 });
    const status = statusOf(r);
    return { status, costUsd: null, note: status === "ok" ? "" : tail(r) };
  }
}
