// @vitest-environment node
// Real processes, no tmux. Each run's root is a pipeline as the daemon starts it,
// `bash …/sw-pipeline.sh start --issue 7`, whose script body is the test's process tree.
import { describe, it, expect, afterEach, afterAll, vi } from "vitest";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  isPipelineFor,
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

const ISSUE = 7;
const job = (root: number, startedAt: string, issue = ISSUE) => [{ root, startedAt, issue }];

const scriptDir = mkdtempSync(join(tmpdir(), "sw-pt-"));
let scripts = 0;
afterAll(() => rmSync(scriptDir, { recursive: true, force: true }));

/** A script file named sw-pipeline.sh holding `body`; run it as `bash <file> start --issue N`. */
function pipelineScript(body: string): string {
  const dir = join(scriptDir, String(++scripts));
  mkdirSync(dir);
  const file = join(dir, "sw-pipeline.sh");
  writeFileSync(file, body);
  return file;
}

/** Argv of a pipeline for `issue` running `body`. */
const pipelineArgv = (body: string, issue = ISSUE) => [pipelineScript(body), "start", "--issue", String(issue)];

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

/**
 * Starts a pipeline for issue 7 whose body is `script`. `ownGroup` starts it in its own session
 * and process group, as tmux runs it; otherwise it shares the test's group, as the daemon's
 * background fallback shares the daemon's. `argv` replaces the command (a shell, say).
 */
async function startTree(
  script = "sleep 300 | cat",
  min = 3,
  ownGroup = false,
  argv: string[] = pipelineArgv(script),
): Promise<{ root: number; startedAt: string }> {
  const startedAt = new Date().toISOString();
  const child = spawn("bash", argv, { stdio: "ignore", detached: ownGroup });
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
    expect(rootRefusal(process.pid, now, ISSUE, table)).toMatch(/dashboard server/);
    expect(rootRefusal(process.ppid, now, ISSUE, table)).toMatch(/dashboard server/);
    // Walking from an ancestor must not reach this process or anything else protected.
    for (const p of processTree(process.ppid, table)) expect(guard.has(p)).toBe(false);
  });

  it("refuses a recorded PID that is an ancestor, signalling nothing", async () => {
    const [r] = await pauseTrees(job(process.ppid, new Date().toISOString()));
    expect(r.signalled).toEqual([]);
    expect(r.refused).toMatch(/dashboard server/);
  });
});

describe("rootRefusal", () => {
  it("refuses PID 1 and below, unknown PIDs and other users' processes", () => {
    const table = readProcessTable();
    const now = new Date().toISOString();
    expect(rootRefusal(1, now, ISSUE, table)).toMatch(/invalid pid/);
    expect(rootRefusal(0, now, ISSUE, table)).toMatch(/invalid pid/);
    expect(rootRefusal(-5, now, ISSUE, table)).toMatch(/invalid pid/);
    const other = table.find((p) => p.pid > 1 && p.uid !== process.getuid?.());
    if (other) expect(rootRefusal(other.pid, new Date(other.startMs).toISOString(), ISSUE, table)).toBe("owned by another user");
  });

  it("refuses a recycled PID that started after the job, and a job with no start time", async () => {
    const { root } = await startTree();
    const table = readProcessTable();
    const tenMinutesAgo = new Date(Date.now() - 600_000).toISOString();
    expect(rootRefusal(root, tenMinutesAgo, ISSUE, table)).toMatch(/stale pid: the process started after the job/);
    expect(rootRefusal(root, undefined, ISSUE, table)).toMatch(/no start time/);
    expect(rootRefusal(root, new Date().toISOString(), undefined, table)).toMatch(/no issue number/);
  });

  it("accepts the run's own pipeline, under the recorded PID or as it", async () => {
    const now = new Date(Date.now() + 1000).toISOString();
    const own = await startTree();
    expect(rootRefusal(own.root, now, ISSUE, readProcessTable())).toBeNull();
    // The tmux case: the recorded PID is the pane shell, with the pipeline as its child.
    const pane = await startTree("", 2, true, ["-c", `bash ${pipelineArgv("sleep 300").join(" ")}; :`]);
    expect(rootRefusal(pane.root, now, ISSUE, readProcessTable())).toBeNull();
  });

  it("refuses a forged record: the user's shell, with its real start time copied in", async () => {
    // Anyone can read a process's start time with ps, so the time proves nothing on its own.
    const { root } = await startTree("", 3, true, ["-c", "sleep 300 | cat"]);
    const table = readProcessTable();
    const lstart = new Date(table.find((p) => p.pid === root)?.startMs ?? 0).toISOString();
    expect(rootRefusal(root, lstart, ISSUE, table)).toBe(`no pipeline for #${ISSUE} under this process`);
    const [r] = await pauseTrees(job(root, lstart));
    expect(r.signalled).toEqual([]);
    for (const p of processTree(root, readProcessTable())) expect(stat(p)).not.toMatch(/^T/);
  });

  it("refuses a pane shell that outlived its pipeline, or runs another issue's", async () => {
    const now = new Date(Date.now() + 1000).toISOString();
    // The pipeline exited; the operator is now running something else in the pane.
    const lingering = await startTree("", 2, true, ["-c", "sleep 300; :"]);
    expect(rootRefusal(lingering.root, now, ISSUE, readProcessTable())).toMatch(/no pipeline for #7/);
    // #12 must not match #123's pipeline (tmux matches window names by prefix).
    const other = await startTree("", 2, true, ["-c", `bash ${pipelineArgv("sleep 300", 123).join(" ")}; :`]);
    expect(rootRefusal(other.root, now, 12, readProcessTable())).toMatch(/no pipeline for #12/);
    expect(rootRefusal(other.root, now, 123, readProcessTable())).toBeNull();
  });
});

describe("isPipelineFor", () => {
  it("matches the daemon's launch of the pipeline, with this exact issue number", () => {
    expect(isPipelineFor("/bin/bash /x/scripts/sw-pipeline.sh start --issue 12 --pipeline standard", 12)).toBe(true);
    expect(isPipelineFor("bash /x/scripts/sw-pipeline.sh start --issue 12", 12)).toBe(true);
    expect(isPipelineFor("/x/scripts/sw-pipeline.sh start --issue 12", 12)).toBe(true);
    expect(isPipelineFor("/bin/bash /x/scripts/sw-pipeline.sh start --issue 123", 12)).toBe(false);
    expect(isPipelineFor("/bin/bash /x/scripts/sw-pipeline.sh start --issue 12", 123)).toBe(false);
  });

  it.each([
    ["an agent whose prompt names it", "claude -p run sw-pipeline start --issue 12 please"],
    ["bash -c", "bash -c /x/sw-pipeline.sh start --issue 12"],
    ["an editor", "vim /x/scripts/sw-pipeline.sh start --issue 12"],
    ["grep", "grep -r sw-pipeline start --issue 12"],
    ["another interpreter", "node /x/sw-pipeline start --issue 12"],
    ["a lookalike script", "bash /x/my-sw-pipeline.sh start --issue 12"],
    ["the issue as another flag's value", "bash /x/sw-pipeline.sh start --goal --issue 12"],
    ["a loop (the daemon never starts one with an issue)", "bash /x/sw-loop.sh --issue 12"],
    ["a script path with a space", "bash /x/my scripts/sw-pipeline.sh start --issue 12"],
  ])("never matches %s", (_name, command) => {
    expect(isPipelineFor(command, 12)).toBe(false);
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

  it("resumes what a pause froze after the run's pipeline was killed while paused", async () => {
    // A pane shell running the pipeline, as tmux runs it.
    const { root, startedAt } = await startTree("", 4, true, ["-c", `bash ${pipelineArgv("sleep 300 | cat").join(" ")}; sleep 301`]);
    const frozenTree = processTree(root, readProcessTable());
    await pauseTrees(job(root, startedAt));
    const pipeline = readProcessTable().find((p) => frozenTree.includes(p.pid) && isPipelineFor(p.command, ISSUE));
    process.kill(pipeline?.pid as number, "SIGKILL");
    expect(await waitGone([pipeline?.pid as number])).toEqual([]);
    const left = frozenTree.filter((p) => p !== pipeline?.pid);
    for (const p of left) expect(stat(p)).toMatch(/^T/);

    const [resumed] = await resumeTrees(job(root, startedAt));
    expect(resumed.refused).toMatch(/no pipeline for #7/);
    expect([...resumed.signalled].sort()).toEqual([...left].sort());
    for (const p of left) expect(stat(p)).not.toMatch(/^T/);
  });

  it("after a pipeline that was its own root is killed while paused, resumes its frozen children, nothing else", async () => {
    const { root, startedAt } = await startTree();
    const kids = processTree(root, readProcessTable()).filter((p) => p !== root);
    // Paused another way before the brake: not this server's to continue.
    const other = spawn("sleep", ["302"], { stdio: "ignore" });
    spawned.push(other);
    process.kill(other.pid as number, "SIGSTOP");
    try {
      await pauseTrees(job(root, startedAt));
      process.kill(root, "SIGKILL");
      expect(await waitGone([root])).toEqual([]);

      const [resumed] = await resumeTrees(job(root, startedAt));
      expect(resumed.refused).toBe("not running");
      expect([...resumed.signalled].sort()).toEqual([...kids].sort());
      for (const p of kids) expect(stat(p)).not.toMatch(/^T/);
      expect(stat(other.pid as number)).toMatch(/^T/);
      // Continued once: a second resume has nothing left to continue.
      expect((await resumeTrees(job(root, startedAt)))[0].signalled).toEqual([]);
    } finally {
      // Orphaned in the test's own group, so no tree reaches them: killed by recorded PID.
      for (const p of kids) {
        try {
          process.kill(p, "SIGCONT");
          process.kill(p, "SIGKILL");
        } catch {
          // already gone
        }
      }
    }
  });

  it("continues the old run's frozen leftovers when the issue was dispatched again", async () => {
    const old = await startTree();
    const kids = processTree(old.root, readProcessTable()).filter((p) => p !== old.root);
    try {
      await pauseTrees(job(old.root, old.startedAt));
      process.kill(old.root, "SIGKILL");
      expect(await waitGone([old.root])).toEqual([]);
      // The daemon starts a new run for the same issue; resuming it reaches the old leftovers too.
      const fresh = await startTree();
      const [resumed] = await resumeTrees(job(fresh.root, fresh.startedAt));
      expect(resumed.refused).toBeUndefined();
      for (const p of kids) expect(resumed.signalled).toContain(p);
      for (const p of kids) expect(stat(p)).not.toMatch(/^T/);
    } finally {
      // Orphaned in the test's own group: killed by recorded PID.
      for (const p of kids) {
        try {
          process.kill(p, "SIGKILL");
        } catch {
          // already gone
        }
      }
    }
  });

  it("stopping the re-dispatched run continues the old run's frozen leftovers, not losing them", async () => {
    const old = await startTree();
    const kids = processTree(old.root, readProcessTable()).filter((p) => p !== old.root);
    try {
      await pauseTrees(job(old.root, old.startedAt));
      process.kill(old.root, "SIGKILL");
      expect(await waitGone([old.root])).toEqual([]);
      const fresh = await startTree();
      const [stopped] = await stopTrees(job(fresh.root, fresh.startedAt), 200);
      expect(stopped.failed).toEqual([]);
      // Reported apart from what the stop signalled: they now run on their own.
      expect([...(stopped.continued ?? [])].sort()).toEqual([...kids].sort());
      for (const p of kids) expect(stopped.signalled).not.toContain(p);
      for (const p of kids) expect(stat(p)).not.toMatch(/^T/);
    } finally {
      for (const p of kids) {
        try {
          process.kill(p, "SIGKILL");
        } catch {
          // already gone
        }
      }
    }
  });

  it("reports a run that is already paused as paused, and says it already was", async () => {
    const { root, startedAt } = await startTree();
    const tree = processTree(root, readProcessTable());
    const [first] = await pauseTrees(job(root, startedAt));
    expect(first.wasPaused).toBe(false);
    const [again] = await pauseTrees(job(root, startedAt));
    expect(again.failed).toEqual([]);
    expect(again.wasPaused).toBe(true);
    expect([...again.signalled].sort()).toEqual([...tree].sort());
  });

  it("counts a zombie child (exited, waiting for its frozen parent) as paused", async () => {
    // The child execs into `sleep`, which never reaps, so its exited child stays a zombie.
    const { root, startedAt } = await startTree("bash -c '(exec sleep 0.3) & exec sleep 300'", 3);
    await new Promise((res) => setTimeout(res, 700));
    const zombies = processTree(root, readProcessTable()).filter((p) => stat(p)?.startsWith("Z"));
    expect(zombies.length).toBe(1);
    const [r] = await pauseTrees(job(root, startedAt));
    expect(r.failed).toEqual([]);
    expect(r.signalled).not.toContain(zombies[0]);
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
    // It shares the test's process group, like the daemon's background fallback.
    expect(result.untraced).toMatch(/does not lead its own process group/);
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
    expect(result.untraced).toBeUndefined();
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

  it("thaws the frozen tree when the stop fails before SIGTERM", async () => {
    const { root, startedAt } = await startTree();
    // ps works until the tree is frozen, then fails (the next snapshot is the one before TERM).
    let frozen = false;
    const snap = async () => {
      if (frozen) throw new Error("ps failed");
      const t = readProcessTable();
      const tree = processTree(root, t);
      frozen = tree.length >= 3 && tree.every((pid) => t.find((p) => p.pid === pid)?.stat.startsWith("T"));
      return t;
    };
    await expect(stopTrees(job(root, startedAt), 1000, snap)).rejects.toThrow("ps failed");
    await new Promise((r) => setTimeout(r, 100));
    const tree = processTree(root, readProcessTable());
    expect(tree.length).toBeGreaterThanOrEqual(3);
    for (const p of tree) expect(stat(p)).not.toMatch(/^T/);
  });

  it("thaws what a pause froze when it fails part way, and reports the failure", async () => {
    const { root, startedAt } = await startTree();
    // Snapshots: prepare, freeze round 0 (stops the tree), then ps fails once.
    let calls = 0;
    const snap = async () => {
      calls++;
      if (calls === 3) throw new Error("ps failed");
      return readProcessTable();
    };
    await expect(pauseTrees(job(root, startedAt), snap)).rejects.toThrow("ps failed");
    await new Promise((r) => setTimeout(r, 100));
    const tree = processTree(root, readProcessTable());
    expect(tree.length).toBeGreaterThanOrEqual(3);
    for (const p of tree) expect(stat(p)).not.toMatch(/^T/);
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
