import { type BenchTask, classifyPull, filterDiff, type Rejection } from "../../domain/bench";
import type { HoldoutSource } from "../../ports";

export interface MineRequest {
  readonly repo: string;
  readonly sinceMs: number;
  readonly maxPulls: number;
  readonly setup: readonly (readonly string[])[];
}

export interface MineResult {
  readonly tasks: readonly BenchTask[];
  readonly rejected: readonly Rejection[];
}

/**
 * Turns merged PRs that close an issue into holdout tasks: the issue is the problem, the merge
 * commit's parent is the base, the PR's test changes are the hidden oracle and the merge commit
 * is the gold fix. Run `bench validate` next: only tasks whose oracle fails on base and passes
 * on gold are fair.
 */
export async function mineHoldout(req: MineRequest, source: HoldoutSource) {
  const pulls = await source.mergedSince(req.sinceMs, req.maxPulls);
  if (!pulls.ok) return pulls;
  const tasks: BenchTask[] = [];
  const rejected: Rejection[] = [];
  for (const pull of pulls.value) {
    const c = classifyPull(pull);
    if ("reason" in c) {
      rejected.push(c);
      continue;
    }
    const [issue, diff] = await Promise.all([
      source.issue(c.issue),
      source.diff(pull.baseSha, pull.mergeSha),
    ]);
    if (!issue.ok || !diff.ok) {
      rejected.push({ pull: pull.number, reason: `could not read issue #${c.issue} or the diff` });
      continue;
    }
    tasks.push({
      id: `pr-${pull.number}`,
      suite: "holdout",
      repo: req.repo,
      baseCommit: pull.baseSha,
      problem: `# ${issue.value.title}\n\n${issue.value.body}`,
      setup: req.setup,
      testPatch: filterDiff(diff.value, c.testFiles),
      testCommands: c.testCommands,
      goldCommit: pull.mergeSha,
      createdAt: issue.value.createdAt,
    });
  }
  return { ok: true, value: { tasks, rejected } as MineResult } as const;
}
