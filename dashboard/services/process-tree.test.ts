// @vitest-environment node
// Real processes, no tmux: a `bash -c 'sleep 300 | cat'` tree stands in for a run whose
// recorded PID is a shell with children (the tmux pane case).
import { describe, it, expect, afterEach, vi } from "vitest";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  parsePsTable,
  pauseTrees,
  processTree,
  protectedPids,
  readProcessTable,
  resumeTrees,
  rootRefusal,
  stopTrees,
} from "./subprocess-guards";

// Each `ps -A` takes 50 ms idle and seconds on a loaded machine; a pause takes several.
vi.setConfig({ testTimeout: 30_000 });

const spawned: ChildProcess[] = [];
const tags: string[] = [];

/** Processes whose command line carries a test's unique tag (catches orphans too). */
function byCommand(tag: string): number[] {
  return readProcessTable()
    .filter((p) => p.command.includes(tag) && p.pid !== process.pid && !/^Z/.test(p.stat))
    .map((p) => p.pid);
}

/** A unique `sleep` duration, so a test can find every process it started, orphaned or not. */
function tag(): string {
  const t = `${3000 + Math.floor(Math.random() * 6000)}.${process.pid}${tags.length}`;
  tags.push(t);
  return t;
}

const job = (root: number, startedAt: string) => [{ root, startedAt }];

afterEach(() => {
  for (const c of spawned.splice(0)) {
    try {
      // Clean up anything a failed test left behind: the whole tree, continued first.
      const tree = processTree(c.pid as number, readProcessTable());
      for (const p of tree) process.kill(p, "SIGCONT");
      for (const p of tree) process.kill(p, "SIGKILL");
    } catch {
      // already gone
    }
  }
  for (const tag of tags.splice(0)) {
    try {
      for (const p of byCommand(tag)) process.kill(p, "SIGKILL");
    } catch {
      // already gone
    }
  }
});

/** `ownGroup` starts the root in its own session and process group, as a tmux pane shell is. */
async function startTree(script = "sleep 300 | cat", min = 3, ownGroup = false): Promise<{ root: number; startedAt: string }> {
  const startedAt = new Date().toISOString();
  const child = spawn("bash", ["-c", script], { stdio: "ignore", detached: ownGroup });
  spawned.push(child);
  const root = child.pid as number;
  for (let i = 0; i < 50; i++) {
    if (processTree(root, readProcessTable()).length >= min) return { root, startedAt };
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error("process tree did not start");
}

function stat(pid: number): string | null {
  try {
    return execFileSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).trim() || null;
  } catch {
    return null;
  }
}

async function waitGone(pids: number[], ms = 3000): Promise<number[]> {
  const deadline = Date.now() + ms;
  let alive = pids;
  while (alive.length && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 50));
    alive = alive.filter((p) => {
      const s = stat(p);
      return s !== null && !s.startsWith("Z");
    });
  }
  return alive;
}

describe("parsePsTable", () => {
  it("reads pid, ppid, pgid, uid, state, start time and the command with spaces", () => {
    const [p] = parsePsTable("  412   1  412  501 Ss   Sun Oct 26 10:00:05 2026 /bin/bash -c sleep 300\n");
    expect(p).toMatchObject({ pid: 412, ppid: 1, pgid: 412, uid: 501, stat: "Ss", command: "/bin/bash -c sleep 300" });
    expect(new Date(p.startMs).getFullYear()).toBe(2026);
  });

  it("skips lines it cannot read", () => {
    expect(parsePsTable("garbage\n\n")).toEqual([]);
  });
});

describe("processTree", () => {
  it("walks descendants, parents first, and adds the root's process group", () => {
    const t = (pid: number, ppid: number, pgid = pid) => ({ pid, ppid, pgid, uid: 1, stat: "S", startMs: 0, command: "" });
    const table = [t(10, 1), t(11, 10, 10), t(12, 11, 10), t(13, 1, 10), t(14, 1)];
    expect(processTree(10, table)).toEqual([10, 11, 12, 13]);
  });
});

describe("the dashboard server and its ancestors", () => {
  it("are protected: never a root, never walked into", () => {
    const table = readProcessTable();
    const guard = protectedPids(table);
    expect(guard.has(process.pid)).toBe(true);
    expect(guard.has(process.ppid)).toBe(true);
    const now = new Date().toISOString();
    expect(rootRefusal(process.pid, now, table)).toMatch(/dashboard server/);
    expect(rootRefusal(process.ppid, now, table)).toMatch(/dashboard server/);
    // Walking from an ancestor must not reach this process or anything else protected.
    for (const p of processTree(process.ppid, table)) expect(guard.has(p)).toBe(false);
  });

  it("refuses a recorded PID that is an ancestor, signalling nothing", async () => {
    const [r] = await pauseTrees([{ root: process.ppid, startedAt: new Date().toISOString() }]);
    expect(r.signalled).toEqual([]);
    expect(r.refused).toMatch(/dashboard server/);
  });
});

describe("rootRefusal", () => {
  it("refuses PID 1 and below, unknown PIDs and other users' processes", () => {
    const table = readProcessTable();
    expect(rootRefusal(1, new Date().toISOString(), table)).toMatch(/invalid pid/);
    expect(rootRefusal(0, new Date().toISOString(), table)).toMatch(/invalid pid/);
    expect(rootRefusal(-5, new Date().toISOString(), table)).toMatch(/invalid pid/);
    const other = table.find((p) => p.pid > 1 && p.uid !== process.getuid?.());
    if (other) expect(rootRefusal(other.pid, new Date(other.startMs).toISOString(), table)).toBe("owned by another user");
  });

  it("refuses a recycled PID that started after the job, and a job with no start time", async () => {
    const { root } = await startTree();
    const table = readProcessTable();
    const tenMinutesAgo = new Date(Date.now() - 600_000).toISOString();
    expect(rootRefusal(root, tenMinutesAgo, table)).toMatch(/stale pid: the process started after the job/);
    expect(rootRefusal(root, undefined, table)).toMatch(/no start time/);
  });

  it("refuses an older process with no pipeline under it", async () => {
    const { root } = await startTree();
    const inTenMinutes = new Date(Date.now() + 600_000).toISOString();
    expect(rootRefusal(root, inTenMinutes, readProcessTable())).toMatch(/older process with no pipeline/);
  });
});

describe("pauseTrees, resumeTrees and stopTrees on real process trees", () => {
  it("pauses every descendant (state T) and resumes them", async () => {
    const { root, startedAt } = await startTree();
    const tree = processTree(root, readProcessTable());
    expect(tree.length).toBeGreaterThanOrEqual(3);

    const [stopped] = await pauseTrees(job(root, startedAt));
    expect(stopped.refused).toBeUndefined();
    expect(stopped.failed).toEqual([]);
    expect([...stopped.signalled].sort()).toEqual([...tree].sort());
    expect(stopped.signalled[0]).toBe(root);
    for (const p of tree) expect(stat(p)).toMatch(/^T/);

    const [resumed] = await resumeTrees(job(root, startedAt));
    expect(resumed.signalled[0]).toBe(root);
    for (const p of tree) expect(stat(p)).not.toMatch(/^T/);
  });

  it("reports a run that is already paused as paused, not as nothing to do", async () => {
    const { root, startedAt } = await startTree();
    const tree = processTree(root, readProcessTable());
    await pauseTrees(job(root, startedAt));
    const [again] = await pauseTrees(job(root, startedAt));
    expect(again.failed).toEqual([]);
    expect([...again.signalled].sort()).toEqual([...tree].sort());
  });

  it("counts a zombie child (exited, waiting for its frozen parent) as paused", async () => {
    // The parent execs into `sleep`, which never reaps, so the exited child stays a zombie.
    const { root, startedAt } = await startTree("(exec sleep 0.3) & exec sleep 300", 2);
    await new Promise((res) => setTimeout(res, 700));
    expect(processTree(root, readProcessTable()).map(stat).some((s) => s?.startsWith("Z"))).toBe(true);
    const [r] = await pauseTrees(job(root, startedAt));
    expect(r.failed).toEqual([]);
    expect(r.signalled).toEqual([root]);
    expect(stat(root)).toMatch(/^T/);
  });

  it("pauses a tree that keeps forking: nothing in it is left running", async () => {
    const t = tag();
    const { root, startedAt } = await startTree(`while :; do sleep ${t} & sleep 0.02; done`, 5);
    const [r] = await pauseTrees(job(root, startedAt));
    expect(r.failed).toEqual([]);
    await new Promise((res) => setTimeout(res, 300));
    // A `sleep 0.02` that exited as the pause landed stays a zombie under its frozen parent:
    // it has exited, so it counts as paused.
    const running = () => {
      const table = readProcessTable();
      const tree = new Set(processTree(root, table));
      return table.filter((p) => tree.has(p.pid) && !p.stat.startsWith("Z")).map((p) => p.pid);
    };
    const live = running();
    expect(live.length).toBeGreaterThanOrEqual(5);
    for (const p of live) expect(stat(p)).toMatch(/^T/);
    // Nothing new started while it was paused.
    expect(running().sort()).toEqual(live.sort());
    expect(byCommand(t).every((p) => live.includes(p))).toBe(true);
  });

  it("stops the whole tree, paused or not, and never touches a process outside it", async () => {
    const { root, startedAt } = await startTree();
    const bystander = spawn("sleep", ["300"], { stdio: "ignore" });
    spawned.push(bystander);
    const tree = processTree(root, readProcessTable());
    await pauseTrees(job(root, startedAt));

    const [result] = await stopTrees(job(root, startedAt), 2000);
    expect(result.refused).toBeUndefined();
    expect(result.failed).toEqual([]);
    expect([...result.signalled].sort()).toEqual([...tree].sort());
    expect(result.signalled).not.toContain(bystander.pid);
    expect(await waitGone(tree)).toEqual([]);
    expect(stat(bystander.pid as number)).not.toBeNull();
  }, 10000);

  it("kills what ignores SIGTERM (an interactive pane shell does) after the grace period", async () => {
    // An ignored signal stays ignored across exec, so the whole tree ignores SIGTERM.
    const { root, startedAt } = await startTree('trap "" TERM; sleep 300 | cat; :');
    const tree = processTree(root, readProcessTable());
    const [result] = await stopTrees(job(root, startedAt), 500);
    expect(result.killed?.length).toBeGreaterThan(0);
    expect(result.failed).toEqual([]);
    expect(await waitGone(tree)).toEqual([]);
  }, 10000);

  it("leaves nothing of a forking tree that ignores SIGTERM, including children from the grace period", async () => {
    const t = tag();
    const { root, startedAt } = await startTree(`trap "" TERM; while :; do sleep ${t} & sleep 0.02; done`, 5);
    const [result] = await stopTrees(job(root, startedAt), 700);
    expect(result.failed).toEqual([]);
    expect(result.killed?.length).toBeGreaterThan(0);
    const deadline = Date.now() + 3000;
    while (byCommand(t).length && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
    const tagged = byCommand(t);
    const left = readProcessTable().filter((p) => tagged.includes(p.pid));
    expect(left.map((p) => `${p.pid} ppid=${p.ppid} pgid=${p.pgid} ${p.stat} ${p.command}`)).toEqual([]);
    expect(stat(root)).toBeNull();
  }, 10000);

  it("catches a background job started by a TERM handler that then exits (own process group)", async () => {
    const t = tag();
    const { root, startedAt } = await startTree(`trap '(sleep ${t}) & exit 0' TERM; while :; do sleep 0.05; done`, 2, true);
    const [result] = await stopTrees(job(root, startedAt), 1500);
    expect(result.failed).toEqual([]);
    const deadline = Date.now() + 3000;
    while (byCommand(t).length && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
    expect(byCommand(t)).toEqual([]);
    expect(stat(root)).toBeNull();
  });

  it("lets the run's own TERM cleanup finish: commands it starts are not sent SIGTERM", async () => {
    // Like the pipeline's trap (`git worktree remove …`): a step that must not be interrupted.
    const dir = mkdtempSync(join(tmpdir(), "sw-stop-"));
    const marker = join(dir, "cleaned");
    try {
      const { root, startedAt } = await startTree(
        `trap 'sleep 1 && touch "${marker}"; exit 0' TERM; while :; do sleep 0.05; done`,
        2,
        true,
      );
      const [result] = await stopTrees(job(root, startedAt));
      expect(result.failed).toEqual([]);
      expect(result.killed).toEqual([]);
      expect(existsSync(marker)).toBe(true);
      expect(stat(root)).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("stops several runs together within one grace period", async () => {
    const a = await startTree('trap "" TERM; sleep 300 | cat; :');
    const b = await startTree('trap "" TERM; sleep 300 | cat; :');
    const trees = [a, b].map((x) => processTree(x.root, readProcessTable()));
    const t0 = Date.now();
    const results = await stopTrees([...job(a.root, a.startedAt), ...job(b.root, b.startedAt)], 800);
    expect(Date.now() - t0).toBeLessThan(4000);
    for (const r of results) expect(r.failed).toEqual([]);
    expect(await waitGone(trees.flat())).toEqual([]);
  }, 10000);

  it("signals nothing when the recorded PID is refused", async () => {
    const { root } = await startTree();
    const [result] = await pauseTrees(job(root, new Date(Date.now() - 600_000).toISOString()));
    expect(result.signalled).toEqual([]);
    expect(result.refused).toMatch(/stale/);
    for (const p of processTree(root, readProcessTable())) expect(stat(p)).not.toMatch(/^T/);
  });

  it("counts a process that exits mid-signal as gone, not failed", async () => {
    const { root, startedAt } = await startTree("sleep 300 | cat");
    const real = readProcessTable();
    const gone = processTree(root, real)[1];
    process.kill(gone, "SIGKILL");
    await waitGone([gone]);
    // A stale snapshot still lists the dead child: signalling it gets ESRCH.
    let first = true;
    const snap = async () => (first ? ((first = false), real) : readProcessTable());
    const [r] = await pauseTrees(job(root, startedAt), snap);
    expect(r.failed).toEqual([]);
    expect(r.signalled).not.toContain(gone);
  });
});
