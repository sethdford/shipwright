import type {
  AdapterError,
  ProcessResult,
  ProcessRunner,
  Terminal,
} from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const NO_SERVER = /no server running|error connecting to/i;
const NO_SESSION = /can't find session|session not found/i;

/** All tmux access goes through one named socket; there is no "current server" fallback. */
export class TmuxTerminal implements Terminal {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly socketName: string,
  ) {
    if (!socketName) throw new Error("TmuxTerminal requires an explicit socket name");
  }

  async newSession(name: string, cwd: string): Promise<Result<void, AdapterError>> {
    const r = await this.tmux(["new-session", "-d", "-s", name, "-c", cwd]);
    return r.exitCode === 0 && !r.timedOut ? ok(undefined) : err(failure(r));
  }

  async listSessions(): Promise<Result<readonly string[], AdapterError>> {
    const r = await this.tmux(["list-sessions", "-F", "#{session_name}"]);
    if (r.exitCode === 0 && !r.timedOut) return ok(r.stdout.split("\n").filter(Boolean));
    if (!r.timedOut && NO_SERVER.test(r.stderr)) return ok([]);
    return err(failure(r));
  }

  async killSession(name: string): Promise<Result<void, AdapterError>> {
    const r = await this.tmux(["kill-session", "-t", `=${name}`]);
    if (r.exitCode === 0 && !r.timedOut) return ok(undefined);
    if (!r.timedOut && (NO_SERVER.test(r.stderr) || NO_SESSION.test(r.stderr))) {
      return ok(undefined);
    }
    return err(failure(r));
  }

  private tmux(args: readonly string[]): Promise<ProcessResult> {
    return this.runner.run({ argv: ["tmux", "-L", this.socketName, ...args], timeoutMs: 10_000 });
  }
}

function failure(r: ProcessResult): AdapterError {
  const message = r.stderr.trim() || `tmux exited ${r.exitCode}`;
  return { kind: r.timedOut ? "transient" : "failed", message };
}
