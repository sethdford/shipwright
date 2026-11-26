import { createServer } from "node:net";
import type { AppLauncher, RunningApp, StartOutcome, StartRequest } from "../../contexts/quality";

/**
 * Starts the app under test through scripts/lib/test-gate-exec.sh (ADR-0019), so it runs without
 * GitHub, git or Claude credentials, exactly like the test gate (#8608). The app gets its own
 * process group, and stop() kills the whole group, dev-server children included.
 */

const LOG_CAP = 1_000_000;
const POLL_MS = 500;
const PROBE_TIMEOUT_MS = 2_000;
const STOP_GRACE_MS = 5_000;
/** A local URL a dev server prints when it is listening. */
const LOCAL_URL = /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::\d{2,5})?/;

export type Fetcher = (url: string, init: { signal: AbortSignal }) => Promise<{ status: number }>;

export function urlFromOutput(text: string): string | null {
  // biome-ignore lint/suspicious/noControlCharactersInRegex: strips ANSI colour codes
  const plain = text.replace(/\u001b\[[0-9;]*m/g, "");
  const m = LOCAL_URL.exec(plain);
  return m ? m[0].replace("0.0.0.0", "127.0.0.1").replace(/\[::1?\]/, "localhost") : null;
}

function killGroup(pid: number, signal: "SIGTERM" | "SIGKILL"): void {
  try {
    process.kill(-pid, signal);
  } catch {
    // already gone
  }
}

/** Listens on 127.0.0.1:port (0 = any) and closes again: the port, or null when it is taken. */
function listenOn(port: number): Promise<number | null> {
  return new Promise((resolve) => {
    const server = createServer();
    server.once("error", () => resolve(null));
    server.listen(port, "127.0.0.1", () => {
      const address = server.address();
      const got = typeof address === "object" && address ? address.port : null;
      server.close(() => resolve(got));
    });
  });
}

/**
 * Kills the app's group if Shipwright itself exits or is signalled first, so a detached dev
 * server never outlives it; returns the normal stop, which also removes those handlers.
 */
function guardExit(pid: number, stop: () => Promise<void>): () => Promise<void> {
  const reap = () => killGroup(pid, "SIGKILL");
  const onSignal = (signal: NodeJS.Signals) => {
    reap();
    process.kill(process.pid, signal);
  };
  process.once("exit", reap);
  process.once("SIGTERM", onSignal);
  process.once("SIGINT", onSignal);
  return async () => {
    await stop();
    process.off("exit", reap);
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
  };
}

class Output {
  text = "";
  async pump(stream: ReadableStream<Uint8Array>): Promise<void> {
    const decoder = new TextDecoder();
    try {
      for await (const chunk of stream) {
        if (this.text.length < LOG_CAP) this.text += decoder.decode(chunk, { stream: true });
      }
    } catch {
      // stream closed when the group was killed
    }
  }
}

export class GatedAppLauncher implements AppLauncher {
  constructor(
    private readonly gateScript: string,
    private readonly cwd: string,
    private readonly env: Readonly<Record<string, string>>,
    private readonly fetcher: Fetcher = (url, init) => fetch(url, { ...init, redirect: "manual" }),
  ) {}

  freePort(): Promise<number> {
    return listenOn(0).then((port) => port ?? 0);
  }

  async start(request: StartRequest): Promise<StartOutcome> {
    // Another server on the port would answer the readiness probe and be screenshotted instead.
    if ((await listenOn(request.port)) === null)
      return { ok: false, reason: `port ${request.port} is already in use`, log: "" };
    const proc = Bun.spawn(["bash", this.gateScript, ...request.argv], {
      cwd: this.cwd,
      env: { ...this.env, PORT: String(request.port), BROWSER: "none", CI: "1" },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      detached: true,
    });
    const out = new Output();
    void out.pump(proc.stdout);
    void out.pump(proc.stderr);
    let exited = false;
    void proc.exited.then(() => {
      exited = true;
    });
    const stop = guardExit(proc.pid, () => this.stop(proc.pid, proc.exited));
    const url = await this.waitReady(request, out, () => exited);
    if (url === null) {
      // Decide why before stop(): stopping makes every app look like it exited.
      const reason = exited
        ? `the start command exited with code ${proc.exitCode ?? "?"}`
        : `nothing answered within ${Math.round(request.readyTimeoutMs / 1000)} s`;
      await stop();
      return { ok: false, reason, log: out.text };
    }
    const app: RunningApp = { url, log: () => out.text, stop };
    return { ok: true, app };
  }

  private async waitReady(
    request: StartRequest,
    out: Output,
    exited: () => boolean,
  ): Promise<string | null> {
    const deadline = Date.now() + request.readyTimeoutMs;
    while (Date.now() < deadline && !exited()) {
      const base = request.url ?? urlFromOutput(out.text) ?? `http://127.0.0.1:${request.port}`;
      const clean = base.replace(/\/$/, "");
      if (await this.answers(`${clean}${request.readyPath}`)) return clean;
      await Bun.sleep(POLL_MS);
    }
    return null;
  }

  private async answers(url: string): Promise<boolean> {
    try {
      const r = await this.fetcher(url, { signal: AbortSignal.timeout(PROBE_TIMEOUT_MS) });
      return r.status < 500;
    } catch {
      return false;
    }
  }

  private async stop(pid: number, exited: Promise<number>): Promise<void> {
    killGroup(pid, "SIGTERM");
    const timer = Bun.sleep(STOP_GRACE_MS).then(() => "late" as const);
    if ((await Promise.race([exited.then(() => "done" as const), timer])) === "late")
      killGroup(pid, "SIGKILL");
    // Grandchildren that ignored SIGTERM after the leader left.
    killGroup(pid, "SIGKILL");
  }
}
