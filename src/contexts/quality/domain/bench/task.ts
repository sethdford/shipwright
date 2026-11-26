import { accept, isArgvList, isRecord, type Parsed, reject } from "./parsed";

export const SUITES = ["swe-bench-verified", "holdout"] as const;
export type BenchSuite = (typeof SUITES)[number];

/**
 * One benchmark task. The agent sees only `problem`, a checkout of `repo` at `baseCommit`, and the
 * repo's own files. Holdout tasks are graded here: `testPatch` (hidden from the agent) is applied
 * over the agent's work and every `testCommands` entry must exit 0. SWE-bench tasks are graded by
 * the official harness (`bench grade-swebench`), so they carry no test fields.
 */
export interface BenchTask {
  readonly id: string;
  readonly suite: BenchSuite;
  readonly repo: string;
  readonly baseCommit: string;
  readonly problem: string;
  readonly setup: readonly (readonly string[])[];
  readonly testPatch: string | null;
  readonly testCommands: readonly (readonly string[])[];
  /** The fixing commit, for `bench validate` (holdout only). */
  readonly goldCommit: string | null;
  /** When the issue was filed, to check it postdates a model's training cutoff. */
  readonly createdAt: string | null;
}

export interface BenchManifest {
  readonly name: string;
  readonly tasks: readonly BenchTask[];
}

const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const SHA = /^[0-9a-f]{40}$/;
const REPO = /^(https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9._/-]+|\/[^\0]+)$/;
const MAX_PROBLEM = 200_000;

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

type Tests = Pick<BenchTask, "testPatch" | "testCommands">;

function parseTests(t: Record<string, unknown>, suite: BenchSuite, at: string): Parsed<Tests> {
  const testPatch = str(t.testPatch);
  const testCommands = t.testCommands ?? [];
  if (!isArgvList(testCommands)) return reject(`${at}: testCommands must be argv lists`);
  if (suite === "holdout" && (testPatch === null || testCommands.length === 0)) {
    return reject(`${at}: a holdout task needs testPatch and testCommands`);
  }
  return accept({ testPatch, testCommands });
}

function parseTask(item: unknown, i: number): Parsed<BenchTask> {
  if (!isRecord(item)) return reject(`task ${i} is not an object`);
  const id = str(item.id);
  const at = `task ${id ?? i}`;
  if (id === null || !TASK_ID.test(id)) return reject(`task ${i}: id must match ${TASK_ID}`);
  const suite = item.suite as BenchSuite;
  if (!SUITES.includes(suite)) return reject(`${at}: suite must be one of ${SUITES.join(", ")}`);
  const repo = str(item.repo);
  if (repo === null || !REPO.test(repo)) return reject(`${at}: repo must be an https URL or path`);
  const baseCommit = str(item.baseCommit);
  if (baseCommit === null || !SHA.test(baseCommit))
    return reject(`${at}: baseCommit must be a 40-hex sha`);
  const problem = str(item.problem);
  if (problem === null || problem.length > MAX_PROBLEM) return reject(`${at}: problem is required`);
  const setup = item.setup ?? [];
  if (!isArgvList(setup)) return reject(`${at}: setup must be argv lists`);
  const tests = parseTests(item, suite, at);
  if (!tests.ok) return tests;
  const gold = str(item.goldCommit);
  if (gold !== null && !SHA.test(gold)) return reject(`${at}: goldCommit must be a 40-hex sha`);
  const createdAt = str(item.createdAt);
  return accept({
    id,
    suite,
    repo,
    baseCommit,
    problem,
    setup,
    ...tests.value,
    goldCommit: gold,
    createdAt,
  });
}

/** Validates a task manifest `{ name, tasks: [...] }`. Fails closed: one bad task rejects it. */
export function parseManifest(value: unknown): Parsed<BenchManifest> {
  if (!isRecord(value)) return reject("manifest must be a JSON object");
  const name = str(value.name);
  if (name === null) return reject("manifest name is required");
  if (!Array.isArray(value.tasks) || value.tasks.length === 0)
    return reject("manifest tasks must be a non-empty array");
  const tasks: BenchTask[] = [];
  const seen = new Set<string>();
  for (const [i, item] of value.tasks.entries()) {
    const t = parseTask(item, i);
    if (!t.ok) return t;
    if (seen.has(t.value.id)) return reject(`task ${t.value.id} appears twice`);
    seen.add(t.value.id);
    tasks.push(t.value);
  }
  return accept({ name, tasks });
}
