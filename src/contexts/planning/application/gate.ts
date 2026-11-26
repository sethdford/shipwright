import { blocks, checkIntegrity, parseDiff, type Violation } from "../domain/integrity";
import { type AcceptanceLock, parseLock } from "../domain/lock";
import { chooseTemplate } from "../domain/run-command";
import { greenVerdict } from "../domain/run-verdict";
import {
  type AcceptancePorts,
  loadManifest,
  type RunOptions,
  runOne,
  type TestRun,
} from "./acceptance";

export type LockResult =
  | { readonly ok: true; readonly lock: AcceptanceLock }
  | { readonly ok: false; readonly problems: readonly string[] };

/**
 * Freezes the proven-red tests: they must be committed at HEAD exactly as they are in the
 * working tree. The lock records that commit and each blob id.
 */
export async function lockTests(
  opts: RunOptions & { readonly lockPath: string },
  ports: AcceptancePorts,
): Promise<LockResult> {
  const loaded = await loadManifest(opts.manifestPath, ports.artifacts);
  if (!loaded.ok) return loaded;
  const m = loaded.manifest;
  if (m.kind !== "tests")
    return { ok: false, problems: ["the manifest says not_testable; there is nothing to lock"] };
  const chosen = chooseTemplate({
    configured: opts.configured,
    testCmd: opts.testCmd,
    proposed: m.run,
  });
  if (!chosen.ok) return { ok: false, problems: [chosen.problem] };
  const head = await ports.ws.headCommit();
  if (!head.ok) return { ok: false, problems: [head.error.message] };
  const { tests, problems } = await committedBlobs(head.value, m.tests, ports);
  if (problems.length > 0) return { ok: false, problems };
  const lock: AcceptanceLock = {
    version: 1,
    commit: head.value,
    criteria: m.criteria,
    tests,
    template: chosen.template,
    templateSource: chosen.source,
  };
  const saved = await ports.artifacts.write(opts.lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  return saved.ok ? { ok: true, lock } : { ok: false, problems: [saved.error.message] };
}

type LockedTest = AcceptanceLock["tests"][number];

/** Each test's blob at `commit`, which must match the working tree. */
async function committedBlobs(
  commit: string,
  wanted: readonly { readonly path: string; readonly criteria: readonly string[] }[],
  ports: AcceptancePorts,
): Promise<{ tests: LockedTest[]; problems: string[] }> {
  const tests: LockedTest[] = [];
  const problems: string[] = [];
  for (const t of wanted) {
    const committed = await ports.ws.blobAt(commit, t.path);
    const current = await ports.ws.worktreeBlob(t.path);
    if (!committed.ok) problems.push(`${t.path}: ${committed.error.message}`);
    else if (!current.ok) problems.push(`${t.path}: ${current.error.message}`);
    else if (committed.value === null) problems.push(`${t.path}: not committed at HEAD`);
    else if (committed.value !== current.value)
      problems.push(`${t.path}: working tree differs from HEAD`);
    else tests.push({ path: t.path, blob: committed.value, criteria: t.criteria });
  }
  return { tests, problems };
}

export type IntegrityMode = "enforce" | "warn";

export interface GreenReport {
  readonly ok: boolean;
  readonly problems: readonly string[];
  readonly violations: readonly Violation[];
  readonly restored: readonly string[];
  readonly runs: readonly TestRun[];
}

/**
 * The build gate. Checks the diff since the lock for test tampering, puts every locked test
 * back exactly as it was proven red, and requires each to pass. The tests that run are always
 * the locked ones, whatever the agent did to them.
 */
export async function verifyGreen(
  opts: {
    readonly lockPath: string;
    readonly timeoutMs: number;
    readonly integrity: IntegrityMode;
  },
  ports: AcceptancePorts,
): Promise<GreenReport> {
  const fail = (problems: readonly string[]): GreenReport => ({
    ok: false,
    problems,
    violations: [],
    restored: [],
    runs: [],
  });
  const text = await ports.artifacts.read(opts.lockPath);
  if (!text.ok) return fail([`lock: ${text.error.message}`]);
  const parsed = parseLock(text.value);
  if (!parsed.ok) return fail([parsed.problem]);
  const lock = parsed.lock;
  const diff = await ports.ws.diffSince(lock.commit);
  if (!diff.ok) return fail([`diff since ${lock.commit.slice(0, 12)}: ${diff.error.message}`]);
  const violations = checkIntegrity(
    parseDiff(diff.value),
    lock.tests.map((t) => t.path),
  );
  const { restored, problems } = await restoreLocked(lock, ports);
  if (problems.length > 0) return { ok: false, problems, violations, restored, runs: [] };
  const runs = await runLocked(lock, opts.timeoutMs, ports);
  const tampered = opts.integrity === "enforce" && blocks(violations);
  return { ok: !tampered && runs.every((r) => r.verdict.ok), problems, violations, restored, runs };
}

async function runLocked(
  lock: AcceptanceLock,
  timeoutMs: number,
  ports: AcceptancePorts,
): Promise<TestRun[]> {
  const runs: TestRun[] = [];
  for (const t of lock.tests) {
    const run = await runOne(t.path, lock.template, timeoutMs, ports.exec);
    runs.push({
      path: run.path,
      argv: run.argv,
      tail: run.tail,
      verdict: greenVerdict(run.outcome),
    });
  }
  return runs;
}

async function restoreLocked(
  lock: AcceptanceLock,
  ports: AcceptancePorts,
): Promise<{ restored: string[]; problems: string[] }> {
  const restored: string[] = [];
  const problems: string[] = [];
  for (const t of lock.tests) {
    const current = (await ports.ws.exists(t.path)) ? await ports.ws.worktreeBlob(t.path) : null;
    if (current?.ok && current.value === t.blob) continue;
    const r = await ports.ws.restore(lock.commit, t.path);
    if (!r.ok) problems.push(`${t.path}: cannot restore the locked test (${r.error.message})`);
    else restored.push(t.path);
  }
  return { restored, problems };
}
