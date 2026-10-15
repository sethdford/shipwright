/** Terminates children on SIGINT/SIGTERM (spec §5): they run in their own process groups, so the
 * terminal's Ctrl-C does not reach them. SIGTERM, a short grace, SIGKILL, then exit 130/143. */
export interface ShutdownRunner {
  killAll(signal: "SIGTERM" | "SIGKILL"): void;
}

export interface ShutdownProcess {
  on(signal: "SIGINT" | "SIGTERM", handler: () => void): unknown;
  exit(code: number): unknown;
}

export function installShutdown(
  runner: ShutdownRunner,
  proc: ShutdownProcess,
  graceMs = 2000,
): void {
  let shuttingDown = false;
  const handle = (code: number) => () => {
    if (shuttingDown) return;
    shuttingDown = true;
    runner.killAll("SIGTERM");
    setTimeout(() => {
      runner.killAll("SIGKILL");
      proc.exit(code);
    }, graceMs);
  };
  proc.on("SIGINT", handle(130));
  proc.on("SIGTERM", handle(143));
}
