import type { ProcessRequest, ProcessResult, ProcessRunner } from "../../shared/kernel/ports";

type Signal = "SIGTERM" | "SIGKILL";

export interface BunProcessRunnerOptions {
  /** Time between SIGTERM and SIGKILL on timeout. */
  readonly killGraceMs?: number;
  /**
   * Max time to keep reading pipes after the child has exited. Output written after this
   * deadline is dropped. Without a timeout, a background grandchild that outlives the leader is
   * not killed and may keep running after run() returns (same as the bash version).
   */
  readonly drainMs?: number;
  /** SIGKILL the child's whole process group after every run, so leftover background jobs die. */
  readonly reapGroup?: boolean;
}

/**
 * Signals a whole process group. Never throws: it runs from timers and from `killAll`'s loop,
 * where a failed kill (already gone, EPERM) must not crash the daemon or abort the other kills.
 */
function killGroup(pid: number, signal: Signal): void {
  try {
    process.kill(-pid, signal);
  } catch {
    // ESRCH (group already gone) or any other failure: nothing useful to do.
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
  private readonly reapGroup: boolean;

  constructor(options: BunProcessRunnerOptions = {}) {
    this.killGraceMs = options.killGraceMs ?? 2000;
    this.drainMs = options.drainMs ?? 1000;
    this.reapGroup = options.reapGroup ?? false;
  }

  /**
   * Signals every in-flight child's process group with exactly the given signal; it does not
   * escalate. Callers should send SIGTERM, wait a grace period, then send SIGKILL. Children are detached, so they no longer
   * receive the terminal's Ctrl-C; the entry point must call this from its SIGINT/SIGTERM handlers.
   */
  killAll(signal: Signal = "SIGTERM"): void {
    for (const pid of this.active) killGroup(pid, signal);
  }

  async run(request: ProcessRequest): Promise<ProcessResult> {
    if (request.argv.length === 0) throw new Error("argv must not be empty");
    const proc = this.spawn(request);
    const pid = proc.pid;
    this.active.add(pid);
    const timers: ReturnType<typeof setTimeout>[] = [];
    let timedOut = false;
    try {
      if (request.timeoutMs !== undefined) {
        const onTimeout = () => {
          timedOut = true;
          this.terminate(pid, timers);
        };
        timers.push(setTimeout(onTimeout, request.timeoutMs));
      }
      const [stdout, stderr, exitCode] = await this.collect(proc, timers);
      return { exitCode, stdout, stderr, timedOut };
    } finally {
      // The leader may have exited on SIGTERM while a grandchild ignored it: don't leave it behind.
      if (timedOut || this.reapGroup) killGroup(pid, "SIGKILL");
      for (const timer of timers) clearTimeout(timer);
      this.active.delete(pid);
    }
  }

  private spawn(request: ProcessRequest) {
    return Bun.spawn([...request.argv], {
      cwd: request.cwd,
      env: request.env ? { ...request.env } : undefined,
      stdin: request.stdin === undefined ? "ignore" : new Blob([request.stdin]),
      stdout: "pipe",
      stderr: "pipe",
      detached: true,
    });
  }

  /** SIGTERM now, SIGKILL after the grace period. */
  private terminate(pid: number, timers: ReturnType<typeof setTimeout>[]): void {
    killGroup(pid, "SIGTERM");
    timers.push(setTimeout(() => killGroup(pid, "SIGKILL"), this.killGraceMs));
  }

  private collect(
    proc: ReturnType<typeof Bun.spawn<"ignore" | Blob, "pipe", "pipe">>,
    timers: ReturnType<typeof setTimeout>[],
  ) {
    // Pipes may be held open by grandchildren: bound the drain once the child itself is gone.
    const exited = proc.exited;
    const deadline = exited.then(
      () => new Promise<void>((resolve) => timers.push(setTimeout(resolve, this.drainMs))),
    );
    return Promise.all([readAll(proc.stdout, deadline), readAll(proc.stderr, deadline), exited]);
  }
}
