import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import type { ChangeSignals } from "../domain/change-features";
import { measureSurvival, type SurvivalSample } from "../domain/code-survival";
import {
  applySurvival,
  type LabelConfig,
  type LabelledPull,
  labelPulls,
  survivalCandidates,
} from "../domain/outcome-labels";
import { type ScoreRecord, signalsFor } from "../domain/score-log";
import type { VerifierPorts } from "../ports";

const DAY_MS = 86_400_000;

/** How the training labels were decided, for the report. */
export interface LabelSummary {
  readonly outcome: LabelConfig["outcome"];
  readonly horizonDays: number;
  /** Merged PRs labelled by survival, and how many of those were rewritten (label 0). */
  readonly bySurvival: number;
  readonly rewritten: number;
  /** Merged PRs that kept the merge label: too recent, too small, or not in local history. */
  readonly tooRecent: number;
  readonly tooSmall: number;
  readonly unmeasured: number;
  /** Labelled PRs that had a recorded score (run signals and critic) to learn from. */
  readonly withSignals: number;
  readonly notes: readonly string[];
}

export interface LabelledHistory {
  readonly labelled: readonly LabelledPull[];
  readonly signals: ReadonlyMap<number, ChangeSignals>;
  readonly summary: LabelSummary;
  readonly truncated: boolean;
}

async function samplesFor(
  ports: Pick<VerifierPorts, "survival">,
  pulls: readonly LabelledPull[],
  horizonMs: number,
  notes: string[],
): Promise<Map<number, SurvivalSample | null>> {
  const out = new Map<number, SurvivalSample | null>();
  for (const l of pulls) {
    const sha = l.pull.mergeSha;
    const at = l.pull.mergedAtMs;
    if (!sha || at === null) {
      out.set(l.pull.number, null);
      continue;
    }
    const r = await ports.survival.read(sha, at, horizonMs);
    if (!r.ok) notes.push(`survival of #${l.pull.number}: ${r.error.message}`);
    out.set(l.pull.number, r.ok && r.value ? measureSurvival(r.value) : null);
  }
  return out;
}

async function loadScores(ports: Pick<VerifierPorts, "scores">, notes: string[]) {
  const r = await ports.scores.all();
  if (r.ok) return r.value;
  notes.push(`could not read the score log (${r.error.message}); training without run signals`);
  return [] as readonly ScoreRecord[];
}

function summarize(
  labels: LabelConfig,
  labelled: readonly LabelledPull[],
  tooRecent: number,
  withSignals: number,
  notes: readonly string[],
): LabelSummary {
  const merged = labelled.filter((l) => l.pull.mergedAtMs !== null && l.verdict !== null);
  const count = (v: string) => merged.filter((l) => l.verdict === v).length;
  return {
    outcome: labels.outcome,
    horizonDays: labels.survivalDays,
    bySurvival: labelled.filter((l) => l.basis === "survival").length,
    rewritten: count("rewritten"),
    tooRecent,
    tooSmall: count("too-small"),
    unmeasured: count("unmeasured"),
    withSignals,
    notes,
  };
}

/**
 * The repository's closed PRs, labelled for training: merge outcome, then code survival for the
 * merged ones old enough to measure, plus the run signals recorded for each PR's branch.
 */
export async function labelHistory(
  ports: Pick<VerifierPorts, "now" | "pulls" | "survival" | "scores">,
  days: number,
  labels: LabelConfig,
): Promise<Result<LabelledHistory, AdapterError>> {
  const now = ports.now();
  const listed = await ports.pulls.closedSince(now - days * DAY_MS);
  if (!listed.ok) return listed;
  const notes: string[] = [];
  const merged = labelPulls(listed.value.pulls, labels);
  const due = survivalCandidates(merged, labels, now);
  const samples = await samplesFor(ports, due, labels.survivalDays * DAY_MS, notes);
  const labelled = applySurvival(merged, samples, labels);
  const records = await loadScores(ports, notes);
  const signals = new Map<number, ChangeSignals>();
  for (const l of labelled) {
    const s = signalsFor(l.pull, records);
    if (s) signals.set(l.pull.number, s);
  }
  const kept = merged.filter((l) => l.y === 1).length;
  const tooRecent = labels.outcome === "survival" ? kept - due.length : 0;
  const summary = summarize(labels, labelled, tooRecent, signals.size, notes.slice(0, 5));
  return ok({ labelled, signals, summary, truncated: listed.value.truncated });
}
