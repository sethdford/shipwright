import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadProgress, type ProgressEntry, ROOT } from "./progress";

const ACTIVE = new Set(["porting", "parity-green", "bash-deleted"]);
const DEFAULT_TIMEOUT_MS = 900_000;
const KILL_GRACE_MS = 2000;
const DRAIN_MS = 1000;

export interface SuiteResult {
  readonly code: number;
  readonly timedOut: boolean;
  readonly stdout: string;
  readonly stderr: string;
}

export function selectSuites(progress: readonly ProgressEntry[]): ProgressEntry[] {
  return progress.filter((e) => ACTIVE.has(e.status) && e.parity);
}

/** Hermetic env: private tmux server dir and throwaway HOME; nothing else is inherited. */
export function parityEnv(sandbox: string, base: Record<string, string | undefined>) {
  return {
    PATH: base.PATH ?? "",
    HOME: join(sandbox, "home"),
    TMUX_TMPDIR: sandbox,
    TERM: "dumb",
  };
}

export function parityTimeoutMs(env: Record<string, string | undefined>): number {
  const n = Number(env.SW_PARITY_TIMEOUT_MS);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_TIMEOUT_MS;
}

export function summarize(total: number, failed: number) {
  return { line: `${total - failed}/${total} parity suites passed`, exitCode: failed ? 1 : 0 };
}

function killGroup(pid: number, signal: "SIGTERM" | "SIGKILL"): void {
  try {
    process.kill(-pid, signal);
  } catch {
    // group already gone
  }
}

/** Reads a stream to the end, or stops at `deadline`. */
async function drain(stream: ReadableStream<Uint8Array>, deadline: Promise<void>) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let text = "";
  const pump = (async () => {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return;
      text += decoder.decode(value, { stream: true });
    }
  })();
  await Promise.race([pump, deadline]);
  await reader.cancel().catch(() => {});
  await pump.catch(() => {});
  return text + decoder.decode();
}

/**
 * Runs argv in its own process group. stdout and stderr are drained concurrently so a chatty
 * suite cannot fill a pipe and block; on timeout the whole group is killed.
 */
export async function runBashSuite(
  argv: string[],
  env: Record<string, string>,
  timeoutMs: number,
  cwd?: string,
): Promise<SuiteResult> {
  const proc = Bun.spawn(argv, {
    env,
    cwd,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    detached: true,
  });
  let timedOut = false;
  const timers: ReturnType<typeof setTimeout>[] = [];
  timers.push(
    setTimeout(() => {
      timedOut = true;
      killGroup(proc.pid, "SIGTERM");
      timers.push(setTimeout(() => killGroup(proc.pid, "SIGKILL"), KILL_GRACE_MS));
    }, timeoutMs),
  );
  const exited = proc.exited.then(() => new Promise<void>((r) => setTimeout(r, DRAIN_MS)));
  const [stdout, stderr, code] = await Promise.all([
    drain(proc.stdout, exited),
    drain(proc.stderr, exited),
    proc.exited,
  ]);
  for (const t of timers) clearTimeout(t);
  killGroup(proc.pid, "SIGKILL"); // reap stragglers left behind by a finished suite
  return { code: timedOut && code === 0 ? 124 : code, timedOut, stdout, stderr };
}

function failureReport(entry: ProgressEntry, r: SuiteResult): string {
  const tail = `${r.stdout}\n${r.stderr}`.split("\n").slice(-30).join("\n");
  const why = r.timedOut ? "TIMED OUT" : `exit ${r.code}`;
  return `✗ parity ${entry.command} (${entry.parity}) ${why}\n${tail}`;
}

async function runOne(entry: ProgressEntry): Promise<boolean> {
  const sandbox = mkdtempSync(join(tmpdir(), "sw-parity-"));
  try {
    const env = parityEnv(sandbox, Bun.env);
    const r = await runBashSuite(
      ["bash", entry.parity as string],
      env,
      parityTimeoutMs(Bun.env),
      ROOT,
    );
    if (r.code === 0 && !r.timedOut) console.log(`✓ parity ${entry.command}`);
    else console.error(failureReport(entry, r));
    return r.code === 0 && !r.timedOut;
  } finally {
    rmSync(sandbox, { recursive: true, force: true });
  }
}

if (import.meta.main) {
  const suites = selectSuites(await loadProgress());
  let failed = 0;
  for (const entry of suites) if (!(await runOne(entry))) failed++;
  const { line, exitCode } = summarize(suites.length, failed);
  console.log(line);
  process.exit(exitCode);
}
