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
// members, and a run is signalled only while a live pipeline process for its issue is in the
// tree (rootRefusal); the one exception is resume continuing what pause froze (`frozen`). Limit: a descendant whose parent exits before any snapshot sees it is
// reparented to launchd/init. It is still found through a process group led by a member (the
// tmux case), but not when the run shares a group it does not lead (the daemon's background
// fallback: Stop then reports `untraced`) or the descendant calls setsid.

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

/**
 * The daemon starts each run as `<scripts>/sw-pipeline.sh start --issue N …` (daemon-dispatch.sh,
 * tmux or background); ps shows it as that, or as `[/bin/]bash <scripts>/sw-pipeline.sh start
 * --issue N …`. Only that shape matches: the program (or the script a shell runs) must be
 * sw-pipeline and its first arguments `start --issue N`, so a command that merely mentions it
 * (`bash -c`, an editor, grep, an agent prompt) never does. A script path containing a space
 * cannot be told apart from other words in ps output, so it never matches: the run is refused.
 */
const PIPELINE_ARGV = /^(?:\S*\/)?(?:(?:ba|z)?sh\s+)?(?:\S*\/)?sw-pipeline(?:\.sh)?\s+start\s+--issue\s+(\d+)(?:\s|$)/;

/** Whether a ps command line is the daemon's pipeline for this issue. */
export function isPipelineFor(command: string, issue: number): boolean {
  return PIPELINE_ARGV.exec(command.trim())?.[1] === String(issue);
}

/** Same tolerance the daemon uses for PID reuse (daemon-dispatch.sh). */
const START_SLACK_MS = 60_000;

/**
 * Why the recorded PID must not be signalled, or null when it is the run's process. The daemon
 * state is trusted same-user data, but the PID in it can outlive the run (a tmux pane shell
 * stays after the pipeline exits) or be recycled, so the record is checked against the live
 * process table: the PID exists, belongs to this user, is not this server or an ancestor of
 * it, did not start after the job, and has a live pipeline process for this issue in its tree.
 */
export function rootRefusal(
  root: unknown,
  jobStartedAt: unknown,
  issue: unknown,
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
  if (!Number.isInteger(issue) || (issue as number) <= 0) return "cannot verify the process: the job has no issue number";
  const tree = new Set(processTree(root, table));
  const live = (p: ProcInfo) => tree.has(p.pid) && !/^Z/.test(p.stat) && isPipelineFor(p.command, issue as number);
  if (!table.some(live)) return `no pipeline for #${issue} under this process`;
  return null;
}

export interface TreeSignalResult {
  pid: number;
  signalled: number[];
  failed: Array<{ pid: number; error: string }>;
  refused?: string;
  killed?: number[];
  /** Stop only: why processes that left the tree could have escaped it. */
  untraced?: string;
  /** Pause only: every process was already stopped before this call (paused another way). */
  wasPaused?: boolean;
  /** Stop only: processes an earlier run of the issue left paused, continued (they now run on their own). */
  continued?: number[];
}

export interface TreeJob {
  root: unknown;
  startedAt: unknown;
  issue: unknown;
}

type Snapshot = () => Promise<ProcInfo[]>;

const isStopped = (p: ProcInfo) => /^[Tt]/.test(p.stat);

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
  /** Processes this call stopped (they were running), so a failed stop can undo its freeze. */
  readonly stopped: ProcInfo[] = [];
  /** Whether the root leads its own process group (tmux mode); see `untraced`. */
  readonly leadsGroup: boolean;
  readonly result: TreeSignalResult;

  constructor(readonly root: number, table: ProcInfo[]) {
    const proc = table.find((p) => p.pid === root);
    this.members.set(root, proc?.startMs ?? 0);
    this.leadsGroup = proc?.pgid === root;
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
      if (signal === "SIGSTOP" && !isStopped(p)) this.stopped.push(p);
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


/**
 * What pauseTrees stopped, per issue, by PID and start time. If a run's pipeline exits while it
 * is paused (killed, or the OOM killer), the run is refused from then on, or reaped from the
 * daemon's state, so resume continues exactly these instead and nothing this server froze is
 * left frozen. Limits: kept in memory, so after a dashboard restart such leftovers must be
 * continued by hand (kill -CONT); and a process continued and stopped again by hand in between
 * still counts as this server's.
 */
const frozen = new Map<number, Map<number, number>>();

function remember(jobs: TreeJob[], results: TreeSignalResult[], trees: Tree[]): void {
  for (const tree of trees) {
    const issue = jobs[results.indexOf(tree.result)].issue as number;
    const m = frozen.get(issue) ?? new Map<number, number>();
    for (const p of tree.stopped) m.set(p.pid, p.startMs);
    if (m.size) frozen.set(issue, m);
  }
}

/**
 * Continues what pause froze for this issue that is still that process and stopped (outside the
 * run's live tree by now, or the run is refused). Only a failed continue stays recorded, for a retry.
 */
function continueFrozen(issue: unknown, result: TreeSignalResult, table: ProcInfo[]): void {
  const m = frozen.get(issue as number);
  if (!m) return;
  for (const [pid, start] of m) {
    const p = table.find((q) => q.pid === pid);
    if (p?.startMs === start && isStopped(p)) {
      try {
        signalPid(pid, "SIGCONT");
        if (!result.signalled.includes(pid)) result.signalled.push(pid);
      } catch (err) {
        result.failed.push({ pid, error: String((err as Error).message ?? err) });
        continue;
      }
    }
    m.delete(pid);
  }
  if (!m.size) frozen.delete(issue as number);
}

/** Runs the daemon has reaped from its state: continues what pause froze in them. */
export async function resumeLeftovers(issues: number[], snap: Snapshot = readProcessTableAsync): Promise<TreeSignalResult[]> {
  const table = await snap();
  return issues.map((issue) => {
    const result: TreeSignalResult = { pid: 0, signalled: [], failed: [], refused: "not running" };
    continueFrozen(issue, result, table);
    return result;
  });
}

async function prepare(jobs: TreeJob[], snap: Snapshot): Promise<{ results: TreeSignalResult[]; trees: Tree[] }> {
  const table = await snap();
  const results: TreeSignalResult[] = [];
  const trees: Tree[] = [];
  for (const job of jobs) {
    const pid = typeof job.root === "number" ? job.root : 0;
    const refused = rootRefusal(job.root, job.startedAt, job.issue, table);
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

/**
 * Continues what this call stopped, skipping any PID a fresh snapshot shows was reused. Without
 * a snapshot it is sent anyway: SIGCONT to a running process does nothing.
 */
async function thaw(trees: Tree[], snap: Snapshot): Promise<void> {
  const table = await snap().catch(() => null);
  for (const tree of trees) {
    for (const p of tree.stopped) {
      const now = table?.find((q) => q.pid === p.pid);
      if (!table || now?.startMs === p.startMs) tree.send(p, "SIGCONT", false);
    }
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
  try {
    await freeze(trees, snap);
    await reportUnstopped(trees, snap);
  } catch (err) {
    // A pause that fails part way leaves nothing it froze: the caller sees an error, not a
    // half-paused fleet it cannot see.
    await thaw(trees, snap);
    throw err;
  }
  for (const tree of trees) tree.result.wasPaused = tree.stopped.length === 0;
  remember(jobs, results, trees);
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
  // What pause froze that this tree no longer reaches (its pipeline was killed while paused, or
  // the issue was dispatched again) is continued too.
  results.forEach((r, i) => continueFrozen(jobs[i].issue, r, after));
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
  try {
    await stopFrozen(trees, graceMs, snap);
  } catch (err) {
    // Never leave a run frozen because the stop failed part way (ps failed, for example).
    await thaw(trees, snap);
    throw err;
  }
  // An earlier run of the issue (re-dispatched after its pipeline was killed while paused) may
  // have left processes this server froze outside the stopped tree: they are continued, not lost,
  // and reported apart from the stop. One that fails to continue stays recorded for a resume.
  const after = await snap();
  for (const tree of trees) {
    const left: TreeSignalResult = { pid: 0, signalled: [], failed: [] };
    continueFrozen(jobs[results.indexOf(tree.result)].issue, left, after);
    if (left.signalled.length) tree.result.continued = left.signalled;
    if (!tree.leadsGroup) {
      tree.result.untraced = "the run does not lead its own process group, so processes that left its tree cannot be traced";
    }
  }
  return results;
}

async function stopFrozen(trees: Tree[], graceMs: number, snap: Snapshot): Promise<void> {
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
