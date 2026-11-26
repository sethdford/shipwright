import {
  type BenchTask,
  classifyCommit,
  classifyPull,
  commitTaskId,
  type DirectCommit,
  filterDiff,
  type MergedPull,
  type Rejection,
} from "../../domain/bench";
import type { HoldoutSource } from "../../ports";

export interface MineRequest {
  readonly repo: string;
  readonly sinceMs: number;
  readonly maxPulls: number;
  readonly setup: readonly (readonly string[])[];
  /** `pulls` (merged PRs, the default) or `commits` (direct commits on the default branch). */
  readonly from?: "pulls" | "commits";
  /** Curated problem statements by task id; they win over a linked issue. */
  readonly problems?: Readonly<Record<string, string>>;
}

export interface MineResult {
  readonly tasks: readonly BenchTask[];
  readonly rejected: readonly Rejection[];
}

type Mined = { task: BenchTask } | { rejection: Rejection };

const iso = (ms: number) => new Date(ms).toISOString();

async function minePull(req: MineRequest, pull: MergedPull, source: HoldoutSource): Promise<Mined> {
  const id = `pr-${pull.number}`;
  const curated = req.problems?.[id];
  const c = classifyPull(pull, curated !== undefined);
  if ("reason" in c) return { rejection: c };
  const [issue, diff] = await Promise.all([
    curated !== undefined || c.issue === null ? null : source.issue(c.issue),
    source.diff(pull.baseSha, pull.mergeSha),
  ]);
  if ((issue !== null && !issue.ok) || !diff.ok)
    return {
      rejection: { ref: `#${pull.number}`, reason: `could not read the issue or the diff` },
    };
  return {
    task: {
      id,
      suite: "holdout",
      repo: req.repo,
      baseCommit: pull.baseSha,
      problem: issue?.ok ? `# ${issue.value.title}\n\n${issue.value.body}` : (curated ?? ""),
      setup: req.setup,
      testPatch: filterDiff(diff.value, c.testFiles),
      testCommands: c.testCommands,
      goldCommit: pull.mergeSha,
      createdAt: issue?.ok ? issue.value.createdAt : iso(pull.mergedAtMs),
    },
  };
}

async function mineCommit(
  req: MineRequest,
  commit: DirectCommit,
  source: HoldoutSource,
): Promise<Mined> {
  const id = commitTaskId(commit.sha);
  const curated = req.problems?.[id];
  const c = classifyCommit(commit, curated !== undefined);
  if ("reason" in c) return { rejection: c };
  const diff = await source.diff(commit.parentSha, commit.sha);
  if (!diff.ok)
    return { rejection: { ref: commit.sha.slice(0, 7), reason: "could not read the diff" } };
  return {
    task: {
      id,
      suite: "holdout",
      repo: req.repo,
      baseCommit: commit.parentSha,
      problem: curated ?? "",
      setup: req.setup,
      testPatch: filterDiff(diff.value, c.testFiles),
      testCommands: c.testCommands,
      goldCommit: commit.sha,
      createdAt: iso(commit.committedAtMs),
    },
  };
}

/**
 * Turns merged PRs that close an issue, or direct commits, into holdout tasks: the issue (or a
 * curated statement) is the problem, the parent commit is the base, the change's test edits are
 * the hidden oracle and the commit itself is the gold fix. A commit message describes the fix,
 * so commits need a curated statement. Run `bench validate` next: only tasks whose oracle fails
 * on base and passes on gold are fair.
 */
export async function mineHoldout(req: MineRequest, source: HoldoutSource) {
  const mined: Mined[] = [];
  if (req.from === "commits") {
    const list = await source.commitsSince(req.sinceMs, req.maxPulls);
    if (!list.ok) return list;
    for (const c of list.value) mined.push(await mineCommit(req, c, source));
  } else {
    const list = await source.mergedSince(req.sinceMs, req.maxPulls);
    if (!list.ok) return list;
    for (const p of list.value) mined.push(await minePull(req, p, source));
  }
  const tasks = mined.flatMap((m) => ("task" in m ? [m.task] : []));
  const rejected = mined.flatMap((m) => ("rejection" in m ? [m.rejection] : []));
  return { ok: true, value: { tasks, rejected } as MineResult } as const;
}
