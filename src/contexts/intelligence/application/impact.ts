import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { parseUnifiedDiff } from "../domain/diff";
import { type ChangeImpact, changeImpact } from "../domain/impact";
import { renderImpact } from "../domain/render-impact";
import type { RepoSession } from "./session";

export interface ImpactReport {
  readonly text: string;
  readonly impact: ChangeImpact;
}

/** The change-impact section for a diff, against the model of the tree the diff produced (ADR-0016). */
export async function analyzeChange(
  session: RepoSession,
  patch: string,
): Promise<Result<ImpactReport, AdapterError>> {
  const snap = await session.current();
  if (!snap.ok) return snap;
  const impact = changeImpact(snap.value.graph, parseUnifiedDiff(patch));
  return ok({ text: renderImpact(impact), impact });
}
