import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BunProcessRunner } from "../../src/adapters/process/bun-process-runner";
import { loadProgress, type ProgressEntry, ROOT } from "./progress";
import { buildSandbox, killSandboxTmux, parityEnv, suiteArgv, sweepStragglers } from "./sandbox";

const ACTIVE = new Set(["porting", "parity-green", "bash-deleted"]);
const DEFAULT_TIMEOUT_MS = 900_000;

// reapGroup: a suite's leftover background jobs must die when the suite ends.
const runner = new BunProcessRunner({ reapGroup: true });

export function selectSuites(progress: readonly ProgressEntry[]): ProgressEntry[] {
  return progress.filter((e) => ACTIVE.has(e.status) && e.parity);
}

export function parityTimeoutMs(env: Record<string, string | undefined>): number {
  const n = Number(env.SW_PARITY_TIMEOUT_MS);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_TIMEOUT_MS;
}

export function summarize(total: number, failed: number) {
  return { line: `${total - failed}/${total} parity suites passed`, exitCode: failed ? 1 : 0 };
}

export function gitChanged(before: string, after: string): boolean {
  return before !== after;
}

export function runSuite(
  argv: string[],
  env: Record<string, string>,
  timeoutMs: number,
  cwd?: string,
) {
  return runner.run({ argv, env, cwd, timeoutMs });
}

function gitStatus(): string {
  const r = Bun.spawnSync(["git", "-C", ROOT, "status", "--porcelain"], { stdout: "pipe" });
  return new TextDecoder().decode(r.stdout);
}

function failureReport(entry: ProgressEntry, why: string, out: string, err: string): string {
  const tail = `${out}\n${err}`.split("\n").slice(-30).join("\n");
  return `✗ parity ${entry.command} (${entry.parity}) ${why}\n${tail}`;
}

function cleanup(sandbox: string): void {
  killSandboxTmux(sandbox);
  sweepStragglers(sandbox);
  rmSync(sandbox, { recursive: true, force: true });
}

let activeSandbox: string | undefined;

async function runOne(entry: ProgressEntry, all: readonly ProgressEntry[]): Promise<boolean> {
  const sandbox = mkdtempSync(join(tmpdir(), "sw-parity-"));
  activeSandbox = sandbox;
  try {
    const repo = buildSandbox(sandbox, ROOT, all);
    const before = gitStatus();
    const env = parityEnv(sandbox, Bun.env);
    const r = await runSuite(suiteArgv(sandbox, entry), env, parityTimeoutMs(Bun.env), repo);
    const dirty = gitChanged(before, gitStatus());
    const ok = r.exitCode === 0 && !r.timedOut && !dirty;
    if (ok) console.log(`✓ parity ${entry.command}`);
    else {
      const why = r.timedOut
        ? "TIMED OUT"
        : dirty
          ? "modified the real repo"
          : `exit ${r.exitCode}`;
      console.error(failureReport(entry, why, r.stdout, r.stderr));
    }
    return ok;
  } finally {
    cleanup(sandbox);
    activeSandbox = undefined;
  }
}

async function onSignal(): Promise<void> {
  runner.killAll("SIGTERM");
  await new Promise((r) => setTimeout(r, 2000));
  runner.killAll("SIGKILL");
  if (activeSandbox) cleanup(activeSandbox);
  process.exit(130);
}

if (import.meta.main) {
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);
  const all = await loadProgress();
  const suites = selectSuites(all);
  let failed = 0;
  for (const entry of suites) if (!(await runOne(entry, all))) failed++;
  const { line, exitCode } = summarize(suites.length, failed);
  console.log(line);
  process.exit(exitCode);
}
