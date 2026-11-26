import { accept, isRecord, type Parsed, reject } from "./parsed";
import type { BenchRow } from "./row";
import { seededSample } from "./sample";
import type { BenchTask } from "./task";

/** One line of the SWE-bench Verified dataset export (only the fields the harness uses). */
interface SweInstance {
  readonly instance_id: string;
  readonly repo: string;
  readonly base_commit: string;
  readonly problem_statement: string;
  readonly created_at: string | null;
}

function parseInstance(value: unknown, line: number): Parsed<SweInstance> {
  if (!isRecord(value)) return reject(`line ${line}: not an object`);
  const { instance_id, repo, base_commit, problem_statement } = value;
  const strings = [instance_id, repo, base_commit, problem_statement];
  if (!strings.every((s) => typeof s === "string" && s.length > 0))
    return reject(`line ${line}: needs instance_id, repo, base_commit, problem_statement`);
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo as string))
    return reject(`line ${line}: repo must be owner/name`);
  const created = typeof value.created_at === "string" ? value.created_at : null;
  return accept({ ...(value as unknown as SweInstance), created_at: created });
}

/** Parses a JSONL export and draws a seeded sample of n tasks (n = 0: all of them). */
export function sweTasks(lines: readonly unknown[], n: number, seed: number): Parsed<BenchTask[]> {
  const all: SweInstance[] = [];
  for (const [i, line] of lines.entries()) {
    const p = parseInstance(line, i + 1);
    if (!p.ok) return p;
    all.push(p.value);
  }
  const picked = n > 0 ? seededSample(all, n, seed, (x) => x.instance_id) : all;
  return accept(
    picked.map((x) => ({
      id: x.instance_id,
      suite: "swe-bench-verified" as const,
      repo: `https://github.com/${x.repo}`,
      baseCommit: x.base_commit,
      problem: x.problem_statement,
      setup: [],
      testPatch: null,
      testCommands: [],
      goldCommit: null,
      createdAt: x.created_at,
    })),
  );
}

/** One predictions.jsonl line for the official harness. */
export const predictionLine = (taskId: string, armId: string, patch: string) =>
  JSON.stringify({ instance_id: taskId, model_name_or_path: armId, model_patch: patch });

/** Reads `resolved_ids` from the harness's report; the rest of its schema is not relied on. */
export function resolvedIds(report: unknown): Parsed<ReadonlySet<string>> {
  if (!isRecord(report) || !Array.isArray(report.resolved_ids))
    return reject("report has no resolved_ids array");
  return accept(new Set(report.resolved_ids.filter((x): x is string => typeof x === "string")));
}

/** Grades pending SWE-bench rows of one arm from the harness report: new rows to append. */
export function gradeRows(
  rows: readonly BenchRow[],
  armId: string,
  trial: number,
  resolved: ReadonlySet<string>,
  submitted: ReadonlySet<string>,
  at: string,
): BenchRow[] {
  return rows
    .filter(
      (r) =>
        r.armId === armId && r.trial === trial && r.resolved === null && submitted.has(r.taskId),
    )
    .map((r) => ({
      ...r,
      resolved: resolved.has(r.taskId),
      note: "graded by swebench harness",
      at,
    }));
}
