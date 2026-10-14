// Validators for values that the dashboard server passes to subprocesses
// (signals to PIDs, ssh to registered machines). Paired with argv-based
// execFileSync calls so no request/state-file value is ever parsed by a local
// shell. Remote ssh commands ARE parsed by the remote shell, so the pieces that
// go into them are restricted to shell-inert characters.

/** A PID safe to signal: integer > 1 (never 0/-1/negative = process groups). */
export function isSignalablePid(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 1;
}

/** Send a signal to a validated PID. Throws (like `kill` did) on failure. */
export function signalPid(
  pid: unknown,
  signal: "SIGSTOP" | "SIGCONT" | "SIGTERM",
): void {
  if (!isSignalablePid(pid)) throw new Error(`Refusing to signal pid ${pid}`);
  process.kill(pid, signal);
}

export const SSH_USER_RE = /^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$/;
// Hostname, IPv4 or bare IPv6; must not start with "-" (ssh option injection).
export const SSH_HOST_RE = /^[A-Za-z0-9.:][A-Za-z0-9.:-]{0,252}$/;
// Path to the shipwright binary on the remote host; no whitespace or shell
// metacharacters. "~" is allowed (expanded by the remote shell, as before).
export const SHIPWRIGHT_PATH_RE = /^[A-Za-z0-9._~/][A-Za-z0-9._~/+-]{0,255}$/;

export function isValidSshUser(v: unknown): v is string {
  return typeof v === "string" && SSH_USER_RE.test(v);
}
export function isValidSshHost(v: unknown): v is string {
  return typeof v === "string" && SSH_HOST_RE.test(v);
}
export function isValidShipwrightPath(v: unknown): v is string {
  return typeof v === "string" && SHIPWRIGHT_PATH_RE.test(v);
}
export function isValidWorkerCount(v: unknown): v is number {
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 && v <= 1024;
}

/**
 * Validate optional machine-registry fields from a request body.
 * Returns an error message, or null if every present field is acceptable.
 */
export function validateMachineFields(
  body: Record<string, unknown>,
): string | null {
  // Absent/empty values keep their previous meaning (unset / default).
  const present = (v: unknown) => v !== undefined && v !== null && v !== "";
  if (present(body.host) && !isValidSshHost(body.host))
    return "host contains invalid characters";
  if (present(body.ssh_user) && !isValidSshUser(body.ssh_user))
    return "ssh_user contains invalid characters";
  if (present(body.shipwright_path) && !isValidShipwrightPath(body.shipwright_path))
    return "shipwright_path contains invalid characters";
  if (present(body.max_workers) && !isValidWorkerCount(body.max_workers))
    return "max_workers must be an integer between 0 and 1024";
  return null;
}

/** argv for `ssh` to run `remoteCommand` on user@host (all pre-validated). */
export function sshArgv(
  user: string,
  host: string,
  remoteCommand: string,
  extraOpts: string[] = [],
): string[] {
  return ["-o", "ConnectTimeout=5", ...extraOpts, `${user}@${host}`, remoteCommand];
}
