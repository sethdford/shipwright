import type { ProcessRequest, ProcessResult, ProcessRunner } from "../../shared/kernel/ports";

type Signal = "SIGTERM" | "SIGKILL";

export interface BunProcessRunnerOptions {
  /** Time between SIGTERM and SIGKILL on timeout. */
  readonly killGraceMs?: number;
  /** Max time to keep reading pipes after the child has exited. */
  readonly drainMs?: number;
}

/** Signals a whole process group; a group that is already gone is not an error. */
function killGroup(pid: number, signal: Signal): void {
  try {
    process.kill(-pid, signal);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
}

/** Reads a stream to the end, or until `deadline` (a promise) settles, whichever is first. */
async function readAll(
  stream: ReadableStream<Uint8Array>,
  deadline: Promise<void>,
): Promise<string> {
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
 * Runs a program with an argv array. Never invokes a shell, so arguments are never re-parsed.
 * Each child gets its own process group so timeouts and `killAll` reach grandchildren too.
 */
export class BunProcessRunner implements ProcessRunner {
  private readonly active = new Set<number>();
  private readonly killGraceMs: number;
  private readonly drainMs: number;

  constructor(options: BunProcessRunnerOptions = {}) {
    this.killGraceMs = options.killGraceMs ?? 2000;
    this.drainMs = options.drainMs ?? 1000;
  }

  /**
   * Signals every in-flight child's process group. Children are detached, so they no longer
   * receive the terminal's Ctrl-C; the entry point must call this from its SIGINT/SIGTERM handlers.
   */
  killAll(signal: Signal = "SIGTERM"): void {
    for (const pid of this.active) killGroup(pid, signal);
  }

  async run(request: ProcessRequest): Promise<ProcessResult> {
    if (request.argv.length === 0) throw new Error("argv must not be empty");
    const proc = Bun.spawn([...request.argv], {
      cwd: request.cwd,
      env: request.env ? { ...request.env } : undefined,
      stdin: request.stdin === undefined ? "ignore" : new Blob([request.stdin]),
      stdout: "pipe",
      stderr: "pipe",
      detached: true,
    });
    const pid = proc.pid;
    this.active.add(pid);
    const timers: ReturnType<typeof setTimeout>[] = [];
    let timedOut = false;
    try {
      if (request.timeoutMs !== undefined) {
        timers.push(
          setTimeout(() => {
            timedOut = true;
            killGroup(pid, "SIGTERM");
            timers.push(setTimeout(() => killGroup(pid, "SIGKILL"), this.killGraceMs));
          }, request.timeoutMs),
        );
      }
      // Pipes may be held open by grandchildren: bound the drain once the child itself is gone.
      const exited = proc.exited;
      const deadline = exited.then(
        () => new Promise<void>((resolve) => timers.push(setTimeout(resolve, this.drainMs))),
      );
      const [stdout, stderr, exitCode] = await Promise.all([
        readAll(proc.stdout, deadline),
        readAll(proc.stderr, deadline),
        exited,
      ]);
      return { exitCode, stdout, stderr, timedOut };
    } finally {
      for (const timer of timers) clearTimeout(timer);
      this.active.delete(pid);
    }
  }
}
