import type { ProcessRequest, ProcessResult, ProcessRunner } from "../../shared/kernel/ports";

/** Runs a program with an argv array. Never invokes a shell, so arguments are never re-parsed. */
export class BunProcessRunner implements ProcessRunner {
  async run(request: ProcessRequest): Promise<ProcessResult> {
    if (request.argv.length === 0) throw new Error("argv must not be empty");
    const proc = Bun.spawn([...request.argv], {
      cwd: request.cwd,
      env: request.env ? { ...request.env } : undefined,
      stdin: request.stdin === undefined ? "ignore" : new Blob([request.stdin]),
      stdout: "pipe",
      stderr: "pipe",
    });
    let timedOut = false;
    const timer =
      request.timeoutMs === undefined
        ? undefined
        : setTimeout(() => {
            timedOut = true;
            proc.kill();
          }, request.timeoutMs);
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    if (timer) clearTimeout(timer);
    return { exitCode, stdout, stderr, timedOut };
  }
}
