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
import { parseClaudeStream } from "./claude-stream";
import { startCommandLog } from "./command-log";

export interface ArmRunnerConfig {
  readonly claudeBin: string;
  readonly shipwrightBin: string;
  /** The permission policy Shipwright's own agents run under (config/agent-permissions.json). */
  readonly policyPath: string;
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly now: () => number;
}

type Dispatched = Omit<ArmOutcome, "durationMs">;

function statusOf(r: ProcessResult): ArmOutcome["status"] {
  if (r.timedOut) return "timeout";
  return r.exitCode === 0 ? "ok" : "error";
}

type Env = Record<string, string>;

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
    const own: Env = arm.kind === "shipwright" ? { PIPELINE_ATTEMPTS: String(arm.attempts) } : {};
    const env = agentEnv(this.cfg.env, { ...own, ...arm.env });
    const log = await startCommandLog(`${dir}.agent`, env.PATH ?? "");
    try {
      const out = await this.dispatch(arm, task, dir, start, { ...env, PATH: log.path });
      const commands = [...(out.commands ?? []), ...(await log.read())];
      return { ...out, commands, durationMs: this.cfg.now() - start };
    } catch (e) {
      const note = e instanceof Error ? e.message : String(e);
      const commands = await log.read();
      return { status: "error", costUsd: null, durationMs: this.cfg.now() - start, note, commands };
    } finally {
      await log.remove();
    }
  }

  private dispatch(arm: BenchArm, task: BenchTask, dir: string, start: number, env: Env) {
    if (arm.kind === "claude-code") return this.claudeCode(arm, task, dir, env);
    if (arm.kind === "shipwright") return this.shipwright(arm, task, dir, start, env);
    return this.command(arm, task, dir, env);
  }

  private async claudeCode(
    arm: BenchArm,
    task: BenchTask,
    dir: string,
    env: Env,
  ): Promise<Dispatched> {
    const { claudeBin, policyPath } = this.cfg;
    // stream-json (needs --verbose) carries every tool call, for the integrity audit.
    const format = ["--output-format", "stream-json", "--verbose"];
    const argv = [claudeBin, "-p", ...format, "--model", arm.model, "--settings", policyPath];
    const stdin = benchPrompt(task.problem);
    const timeoutMs = arm.timeoutMin * 60_000;
    const r = await this.runner.run({ argv, cwd: dir, stdin, env, timeoutMs });
    const parsed = parseClaudeStream(r.stdout);
    const status = r.timedOut ? "timeout" : parsed.isError || r.exitCode !== 0 ? "error" : "ok";
    const note = status === "ok" ? "" : tail(r);
    return {
      status,
      costUsd: parsed.costUsd,
      note,
      commands: parsed.commands,
      trajectory: r.stdout,
    };
  }

  private async shipwright(
    arm: BenchArm,
    task: BenchTask,
    dir: string,
    start: number,
    armEnv: Env,
  ): Promise<Dispatched> {
    const goal = ["--goal", task.problem, "--local", "--headless", "--model", arm.model];
    const argv = [this.cfg.shipwrightBin, "pipeline", "start", ...goal];
    const r = await this.runner.run({
      argv,
      cwd: dir,
      env: armEnv,
      timeoutMs: arm.timeoutMin * 60_000,
    });
    const spent = await this.spend.between(start, this.cfg.now());
    const status = statusOf(r);
    return { status, costUsd: spent.ok ? spent.value : null, note: status === "ok" ? "" : tail(r) };
  }

  private async command(
    arm: BenchArm,
    task: BenchTask,
    dir: string,
    env: Env,
  ): Promise<Dispatched> {
    const problemFile = join(dirname(dir), `${task.id}.${arm.id}.problem.md`);
    await mkdir(dirname(problemFile), { recursive: true });
    await writeFile(problemFile, benchPrompt(task.problem), "utf8");
    const argv = expandArgv(arm.argv ?? [], { workdir: dir, problemFile, model: arm.model });
    const r = await this.runner.run({ argv, cwd: dir, env, timeoutMs: arm.timeoutMin * 60_000 });
    const status = statusOf(r);
    return { status, costUsd: null, note: status === "ok" ? "" : tail(r) };
  }
}
