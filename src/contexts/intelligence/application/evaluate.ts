import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import {
  type CaseResult,
  casesOf,
  type EvalSummary,
  scoreCase,
  summarize,
} from "../domain/history-eval";
import { localize } from "../domain/localize";
import type { RepoModelPorts } from "../ports";
import { RepoSession } from "./session";

export interface EvalRequest {
  readonly root: string;
  readonly ref: string;
  /** Commits of history to look through (cases are fewer: only code PRs count). */
  readonly commits: number;
  readonly semantic: boolean;
}

export interface EvalReport {
  readonly summary: EvalSummary;
  readonly results: readonly CaseResult[];
}

/**
 * The localization check (ADR-0016): for each past PR, rebuild the model at its parent commit, localize its
 * title, and see where the files it actually changed rank. No model spend; leak-free (the answer did not exist
 * yet). Its per-case results export to the eval ratchet, so a change to the model is accepted only when it
 * finds more of the right files.
 */
export async function evaluateLocalization(
  ports: RepoModelPorts,
  req: EvalRequest,
): Promise<Result<EvalReport, AdapterError>> {
  const history = ports.history;
  if (!history) return err({ kind: "failed", message: "no git history source" });
  const commits = await history.commits(req.root, req.ref, req.commits);
  if (!commits.ok) return commits;
  const results: CaseResult[] = [];
  try {
    for (const c of casesOf(commits.value)) {
      const wt = await history.checkout(req.root, c.parent);
      if (!wt.ok) return wt;
      const snap = await new RepoSession(ports, wt.value, req.semantic).current();
      if (!snap.ok) return snap;
      const { graph, index } = snap.value;
      const ranked = localize(graph, index, c.task, 10, snap.value.semantic(c.task, 30))
        .filter((f) => !f.test)
        .map((f) => f.path);
      results.push(scoreCase(c, (p) => graph.byPath.has(p), ranked));
    }
  } finally {
    await history.release(req.root);
  }
  return ok({ summary: summarize(results), results });
}
