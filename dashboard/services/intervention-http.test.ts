// @vitest-environment node
// Stop over HTTP against a real dashboard server and a real process tree (no tmux): the
// request is held through the grace period, so it must outlast Bun's 10 s default idle timeout.
// Bun applies it to a request with no body, which is how the client posts pause and stop.
import { describe, it, expect, afterAll } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { createServer, type AddressInfo } from "node:net";

const ISSUE = 7;
const home = mkdtempSync(join(tmpdir(), "sw-stop-http-"));
const children: ChildProcess[] = [];

/** Extra PIDs to kill at the end (orphans of a killed root), by recorded PID. */
const orphans: number[] = [];

afterAll(() => {
  for (const pid of [...children.map((c) => c.pid as number), ...orphans]) {
    try {
      process.kill(pid, "SIGCONT");
      process.kill(pid, "SIGKILL");
    } catch {
      // already gone
    }
  }
  rmSync(home, { recursive: true, force: true });
});

function writeState(jobs: unknown[]): void {
  mkdirSync(join(home, ".shipwright"), { recursive: true });
  writeFileSync(join(home, ".shipwright", "daemon-state.json"), JSON.stringify({ active_jobs: jobs, queued: [] }));
}

async function startServer(env: Record<string, string> = {}): Promise<string> {
  const port = await freePort();
  const server = spawn("bun", [join(__dirname, "..", "server.ts")], {
    env: { PATH: process.env.PATH, HOME: home, SHIPWRIGHT_DASHBOARD_PORT: String(port), ...env },
    stdio: "ignore",
  });
  children.push(server);
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 100; i++) {
    try {
      if ((await fetch(base + "/api/health")).ok) break;
    } catch {
      // not listening yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  return base;
}

function stat(pid: number): string {
  try {
    return execFileSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = (srv.address() as AddressInfo).port;
      srv.close(() => resolve(port));
    });
  });
}

function alive(pid: number): boolean {
  const s = stat(pid);
  return s !== "" && !s.startsWith("Z");
}

describe("POST /api/intervention/:issue/abort", () => {
  it("returns the stop's result after a grace period longer than Bun's idle timeout", async () => {
    // The run: a pipeline for issue 7 that ignores SIGTERM, in its own group as tmux runs it.
    const dir = join(home, "run");
    mkdirSync(dir);
    const script = join(dir, "sw-pipeline.sh");
    writeFileSync(script, "trap '' TERM; while :; do sleep 0.1; done");
    const startedAt = new Date().toISOString();
    const run = spawn("bash", [script, "start", "--issue", String(ISSUE)], { stdio: "ignore", detached: true });
    children.push(run);
    writeState([{ issue: ISSUE, pid: run.pid, started_at: startedAt }]);
    const base = await startServer({ SW_DASHBOARD_STOP_GRACE_MS: "15000" });

    const t0 = Date.now();
    // No body, as api.sendIntervention sends a stop.
    const res = await fetch(`${base}/api/intervention/${ISSUE}/abort`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    });
    const body = (await res.json()) as { ok: boolean; killed?: number[]; failed: unknown[]; untraced?: string };
    expect(Date.now() - t0).toBeGreaterThan(15_000);
    expect(res.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(body.failed).toEqual([]);
    expect(body.untraced).toBeUndefined();
    expect(body.killed).toContain(run.pid);
    expect(alive(run.pid as number)).toBe(false);
  }, 45_000);
});

describe("POST /api/intervention/:issue/resume", () => {
  it("continues what a pause froze after the pipeline was killed and the daemon reaped the run", async () => {
    const dir = join(home, "run2");
    mkdirSync(dir);
    const script = join(dir, "sw-pipeline.sh");
    writeFileSync(script, "sleep 303 | cat");
    const startedAt = new Date().toISOString();
    const run = spawn("bash", [script, "start", "--issue", "8"], { stdio: "ignore", detached: true });
    children.push(run);
    const root = run.pid as number;
    let kids: number[] = [];
    for (let i = 0; i < 50 && kids.length < 2; i++) {
      await new Promise((r) => setTimeout(r, 50));
      kids = execFileSync("ps", ["-A", "-o", "pid=,pgid="], { encoding: "utf8" })
        .trim()
        .split("\n")
        .map((l) => l.trim().split(/\s+/).map(Number))
        .filter(([pid, pgid]) => pgid === root && pid !== root)
        .map(([pid]) => pid);
    }
    orphans.push(...kids);
    expect(kids.length).toBe(2);
    writeState([{ issue: 8, pid: root, started_at: startedAt }]);
    const base = await startServer();
    const post = (action: string) =>
      fetch(`${base}/api/intervention/8/${action}`, { method: "POST", headers: { "Content-Type": "application/json" } }).then((r) => r.json() as Promise<{ ok: boolean; signalled: number[]; refused?: string }>);

    expect((await post("pause")).ok).toBe(true);
    for (const k of kids) expect(stat(k)).toMatch(/^T/);
    // The pipeline is killed while paused, and the daemon reaps the run from its state.
    process.kill(root, "SIGKILL");
    writeState([]);
    const res = await post("resume");
    expect(res.refused).toBe("not running");
    expect([...res.signalled].sort()).toEqual([...kids].sort());
    for (const k of kids) expect(stat(k)).not.toMatch(/^T/);
  }, 30_000);
});
