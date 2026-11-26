import { classifyAndDecide } from "../../learning";
import type { Lesson } from "../domain/lesson";
import {
  type Candidate,
  DEFAULT_MINE,
  type FailedRun,
  type MineOptions,
  mineCandidates,
} from "../domain/mine";
import { nextLessonId, type Proposal, proposeLesson } from "../domain/propose";

export interface RunLog {
  readonly source: string;
  readonly log: string;
}

/** Classifies each failed run with the ADR-0009 classifier (no prior attempts: only the class and fingerprint). */
export function classifyRuns(logs: readonly RunLog[]): readonly FailedRun[] {
  return logs.map((r) => {
    const c = classifyAndDecide({ text: r.log, attempts: [] });
    return { source: r.source, failureClass: c.class, fingerprint: c.fingerprint, log: r.log };
  });
}

export interface MinedDraft {
  readonly candidate: Candidate;
  readonly draft: Extract<Proposal, { kind: "draft" }>;
}

/**
 * One mining pass: recurring, learnable failures that no lesson covers become `proposed` drafts with consecutive ids.
 * The sources of every run in a cluster are listed, so the reviewer sees how often it happened.
 */
export function mineDrafts(
  existing: readonly Lesson[],
  logs: readonly RunLog[],
  opts: MineOptions = DEFAULT_MINE,
): readonly MinedDraft[] {
  const candidates = mineCandidates(classifyRuns(logs), existing, opts);
  const out: MinedDraft[] = [];
  const taken: { id: string }[] = [...existing];
  for (const c of candidates) {
    const id = nextLessonId(taken);
    taken.push({ id });
    const input = {
      failureClass: c.failureClass,
      fingerprint: c.fingerprint,
      source: `${c.count} runs: ${c.sources.join(" ")}`,
      log: c.log,
    };
    // mineCandidates already dropped covered fingerprints, so this is always a draft.
    const p = proposeLesson(existing, input, id);
    if (p.kind === "draft") out.push({ candidate: c, draft: p });
  }
  return out;
}
