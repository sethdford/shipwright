// Validators for values that the dashboard server passes to subprocesses
// (signals to PIDs, ssh to registered machines). Paired with argv-based
// execFileSync calls so no request/state-file value is ever parsed by a local
// shell. Remote ssh commands ARE parsed by the remote shell, so the pieces that
// go into them are restricted to shell-inert characters.

import { execFile, execFileSync } from "child_process";

/** A PID safe to signal: integer > 1 (never 0/-1/negative = process groups). */
export function isSignalablePid(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 1;
}

export type Signal = "SIGSTOP" | "SIGCONT" | "SIGTERM" | "SIGKILL";

/** Send a signal to a validated PID. Throws (like `kill` did) on failure. */
export function signalPid(pid: unknown, signal: Signal): void {
  if (!isSignalablePid(pid)) throw new Error(`Refusing to signal pid ${pid}`);
  process.kill(pid, signal);
}

// ── Process trees ──────────────────────────────────────────────────────
// The daemon records one PID per run: in tmux mode the pane's shell, otherwise the pipeline's
// bash. Signalling only that PID leaves its children (the agent, tests) running, so pause,
// resume and stop act on the whole tree, after checking the recorded PID is still the
// process the daemon started (a recycled PID is never signalled). Membership is tracked by
// PID and start time across fresh snapshots, so children started while we signal are caught
// and a PID recycled in between is never touched. This server and its ancestors are never
// members. Limit: a descendant whose parent exits before any snapshot sees it is reparented to
// launchd/init. It is still found through a process group led by a member (the tmux case),
// but not when the run shares a group it does not lead or the descendant calls setsid.

export interface ProcInfo {
  pid: number;
  ppid: number;
  pgid: number;
  uid: number;
  stat: string;
  startMs: number;
  command: string;
}

/** Parses `ps -A -o pid=,ppid=,pgid=,uid=,stat=,lstart=,command=` (C locale; lstart is 5 tokens). */
export function parsePsTable(text: string): ProcInfo[] {
  const out: ProcInfo[] = [];
  for (const line of text.split("\n")) {
    const m = line
      .trim()
      .match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d{4})\s*(.*)$/);
    if (!m) continue;
    const startMs = Date.parse(m[6]);
    if (Number.isNaN(startMs)) continue;
    out.push({ pid: +m[1], ppid: +m[2], pgid: +m[3], uid: +m[4], stat: m[5], startMs, command: m[7] });
  }
  return out;
}

const PS_ARGS = ["-A", "-o", "pid=,ppid=,pgid=,uid=,stat=,lstart=,command="];
const PS_OPTS = { encoding: "utf8" as const, env: { ...process.env, LC_ALL: "C", LANG: "C" }, maxBuffer: 16 * 1024 * 1024 };

export function readProcessTable(): ProcInfo[] {
  return parsePsTable(execFileSync("ps", PS_ARGS, PS_OPTS));
}

/** The same snapshot without blocking the server's event loop. */
export function readProcessTableAsync(): Promise<ProcInfo[]> {
  return new Promise((resolve, reject) => {
    execFile("ps", PS_ARGS, PS_OPTS, (err, stdout) => (err ? reject(err) : resolve(parsePsTable(stdout))));
  });
}

/** This server and every ancestor of it: never signalled, never walked into. */
export function protectedPids(table: ProcInfo[], self: number = process.pid): Set<number> {
  const byPid = new Map(table.map((p) => [p.pid, p]));
  const out = new Set<number>([self, 0, 1]);
  for (let p = byPid.get(self); p && !out.has(p.ppid); p = byPid.get(p.ppid)) out.add(p.ppid);
  return out;
}

/**
 * The recorded PID and everything under it in one snapshot: descendants, plus members of its
 * process group when it leads one. Root first, parents before children; protected PIDs and
 * their subtrees are left out.
 */
export function processTree(root: number, table: ProcInfo[]): number[] {
  const guard = protectedPids(table);
  if (guard.has(root)) return [];
  const children = new Map<number, number[]>();
  for (const p of table) children.set(p.ppid, [...(children.get(p.ppid) ?? []), p.pid]);
  const seen = new Set<number>([root]);
  const order = [root];
  for (let i = 0; i < order.length; i++) {
    for (const c of children.get(order[i]) ?? []) {
      if (!seen.has(c) && !guard.has(c)) {
        seen.add(c);
        order.push(c);
      }
    }
  }
  for (const p of table) {
    if (p.pgid === root && !seen.has(p.pid) && !guard.has(p.pid)) {
      seen.add(p.pid);
      order.push(p.pid);
    }
  }
  return order.filter(isSignalablePid);
}

const PIPELINE_COMMAND = /sw-pipeline|sw-loop|claude|shipwright/;
/** Same tolerance the daemon uses for PID reuse (daemon-dispatch.sh). */
const START_SLACK_MS = 60_000;

/**
 * Why the recorded PID must not be signalled, or null when it is the run's process: it exists,
 * belongs to this user, is not this server or an ancestor of it, and either started with the
 * job (within 60 s) or started earlier and runs a pipeline below it (a reused tmux window).
 * Started after the job means a recycled PID.
 */
export function rootRefusal(
  root: unknown,
  jobStartedAt: unknown,
  table: ProcInfo[],
  uid: number = process.getuid?.() ?? -1,
): string | null {
  if (!isSignalablePid(root)) return `invalid pid ${String(root)}`;
  if (protectedPids(table).has(root)) return "the dashboard server or one of its parents";
  const proc = table.find((p) => p.pid === root);
  if (!proc) return "not running";
  if (proc.uid !== uid) return "owned by another user";
  const jobStart = typeof jobStartedAt === "string" ? Date.parse(jobStartedAt) : NaN;
  if (Number.isNaN(jobStart)) return "cannot verify the process: the job has no start time";
  if (proc.startMs > jobStart + START_SLACK_MS) return "stale pid: the process started after the job";
  if (proc.startMs < jobStart - START_SLACK_MS) {
    const tree = new Set(processTree(root, table));
    const isPipeline = table.some((p) => tree.has(p.pid) && PIPELINE_COMMAND.test(p.command));
    if (!isPipeline) return "stale pid: an older process with no pipeline under it";
  }
  return null;
}

export interface TreeSignalResult {
  pid: number;
  signalled: number[];
  failed: Array<{ pid: number; error: string }>;
  refused?: string;
  killed?: number[];
}

export interface TreeJob {
  root: unknown;
  startedAt: unknown;
}

type Snapshot = () => Promise<ProcInfo[]>;

/** Members of one run's tree, keyed by PID and start time so a recycled PID never matches. */
class Tree {
  private readonly members = new Map<number, number>();
  /**
   * Process groups led by a member. A child inherits its parent's group, so a process in one
   * of these groups belongs to the run even after its parent exited and it was reparented to
   * launchd/init (a TERM handler that starts a background job and exits). In tmux mode the
   * pipeline leads its own group. Each group is keyed to its leader's start time: it is
   * dropped once a snapshot shows it empty (only then can its ID be reused) or shows a
   * different process leading it.
   */
  private readonly groups = new Map<number, number>();
  readonly result: TreeSignalResult;

  constructor(readonly root: number, table: ProcInfo[]) {
    const start = table.find((p) => p.pid === root)?.startMs ?? 0;
    this.members.set(root, start);
    this.result = { pid: root, signalled: [], failed: [] };
  }

  /**
   * Live members in this snapshot, parents first, after adding any new children. A zombie has
   * already exited (it only waits for a frozen parent to reap it), so it is not returned.
   */
  live(table: ProcInfo[]): ProcInfo[] {
    const guard = protectedPids(table);
    const byPid = new Map(table.map((p) => [p.pid, p]));
    for (const [pid, start] of this.members) {
      if (byPid.get(pid)?.startMs !== start) this.members.delete(pid);
    }
    const inUse = new Set(table.map((p) => p.pgid));
    for (const [g, start] of this.groups) {
      const leader = byPid.get(g);
      if (!inUse.has(g) || (leader && leader.startMs !== start)) this.groups.delete(g);
    }
    for (const p of table) if (this.members.has(p.pid) && p.pgid === p.pid) this.groups.set(p.pid, p.startMs);
    for (let grew = true; grew; ) {
      grew = false;
      for (const p of table) {
        if (this.members.has(p.pid) || guard.has(p.pid)) continue;
        if (this.members.has(p.ppid) || this.groups.has(p.pgid)) {
          this.members.set(p.pid, p.startMs);
          if (p.pgid === p.pid) this.groups.set(p.pid, p.startMs);
          grew = true;
        }
      }
    }
    return [...this.members.keys()].map((pid) => byPid.get(pid) as ProcInfo).filter((p) => !/^Z/.test(p.stat));
  }

  /** Sends a signal; a process that already exited (ESRCH) is gone, not a failure. */
  send(p: ProcInfo, signal: Signal, record = true): boolean {
    try {
      signalPid(p.pid, signal);
      if (record && !this.result.signalled.includes(p.pid)) this.result.signalled.push(p.pid);
      return true;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code === "ESRCH") return false;
      this.result.failed.push({ pid: p.pid, error: String((err as Error).message ?? err) });
      return false;
    }
  }
}

const isStopped = (p: ProcInfo) => /^[Tt]/.test(p.stat);

async function prepare(jobs: TreeJob[], snap: Snapshot): Promise<{ results: TreeSignalResult[]; trees: Tree[] }> {
  const table = await snap();
  const results: TreeSignalResult[] = [];
  const trees: Tree[] = [];
  for (const job of jobs) {
    const pid = typeof job.root === "number" ? job.root : 0;
    const refused = rootRefusal(job.root, job.startedAt, table);
    if (refused) {
      results.push({ pid, signalled: [], failed: [], refused });
      continue;
    }
    const tree = new Tree(pid, table);
    trees.push(tree);
    results.push(tree.result);
  }
  return { results, trees };
}

/**
 * SIGSTOP every member, parents first so they stop forking, repeating with fresh snapshots
 * until a round finds nothing new to stop. The first round signals every member, so a run that
 * is already paused reports its processes as paused rather than as nothing to do.
 */
async function freeze(trees: Tree[], snap: Snapshot, maxRounds = 10): Promise<void> {
  for (let round = 0; round < maxRounds; round++) {
    const table = await snap();
    let sent = false;
    for (const tree of trees) {
      for (const p of tree.live(table)) {
        if ((round === 0 || !isStopped(p)) && tree.send(p, "SIGSTOP") && !isStopped(p)) sent = true;
      }
    }
    if (!sent) break;
  }
}

async function reportUnstopped(trees: Tree[], snap: Snapshot): Promise<void> {
  const table = await snap();
  for (const tree of trees) {
    for (const p of tree.live(table)) {
      if (!isStopped(p)) tree.result.failed.push({ pid: p.pid, error: "still running" });
    }
  }
}

/** Pauses each run's whole tree; a run is paused only when its result has no failures. */
export async function pauseTrees(jobs: TreeJob[], snap: Snapshot = readProcessTableAsync): Promise<TreeSignalResult[]> {
  const { results, trees } = await prepare(jobs, snap);
  await freeze(trees, snap);
  await reportUnstopped(trees, snap);
  return results;
}

/** Resumes each run's whole tree, parents first. */
export async function resumeTrees(jobs: TreeJob[], snap: Snapshot = readProcessTableAsync): Promise<TreeSignalResult[]> {
  const { results, trees } = await prepare(jobs, snap);
  const table = await snap();
  for (const tree of trees) for (const p of tree.live(table)) tree.send(p, "SIGCONT");
  const after = await snap();
  for (const tree of trees) {
    for (const p of tree.live(after)) {
      if (isStopped(p)) tree.result.failed.push({ pid: p.pid, error: "still stopped" });
    }
  }
  return results;
}

/**
 * Stops each run: freeze the tree (so nothing forks), then SIGTERM and SIGCONT every member
 * of the frozen tree so it can clean up. Processes started after that (the run's own cleanup:
 * `git worktree remove` in the pipeline's trap) are tracked but not sent SIGTERM, so cleanup
 * can finish. When all are gone or the grace period ends, freeze whatever is left, including
 * late children, and SIGKILL it. The runs are handled together, so several stops share one
 * grace period.
 */
export async function stopTrees(
  jobs: TreeJob[],
  graceMs = 5000,
  snap: Snapshot = readProcessTableAsync,
): Promise<TreeSignalResult[]> {
  const { results, trees } = await prepare(jobs, snap);
  await freeze(trees, snap);
  const frozen = await snap();
  for (const tree of trees) {
    for (const p of tree.live(frozen)) {
      tree.send(p, "SIGTERM");
      tree.send(p, "SIGCONT", false);
    }
  }
  const deadline = Date.now() + graceMs;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 150));
    const table = await snap();
    if (trees.every((tree) => tree.live(table).length === 0)) break;
  }
  await freeze(trees, snap);
  for (const tree of trees) tree.result.killed = [];
  // SIGKILL every member, then look again: a child that appears under a member is killed too.
  // A killed process can still be listed for a moment while it exits, so this runs up to 2 s.
  let left: ProcInfo[][] = [];
  for (let i = 0; i < 10; i++) {
    const table = await snap();
    left = trees.map((tree) => tree.live(table));
    if (!left.some((l) => l.length)) break;
    trees.forEach((tree, t) => {
      for (const p of left[t]) {
        if (tree.send(p, "SIGKILL", false) && !tree.result.killed?.includes(p.pid)) tree.result.killed?.push(p.pid);
      }
    });
    await new Promise((r) => setTimeout(r, 200));
  }
  if (left.some((l) => l.length)) {
    const table = await snap();
    left = trees.map((tree) => tree.live(table));
  }
  trees.forEach((tree, i) => {
    for (const p of left[i]) tree.result.failed.push({ pid: p.pid, error: "survived SIGKILL" });
  });
  return results;
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
