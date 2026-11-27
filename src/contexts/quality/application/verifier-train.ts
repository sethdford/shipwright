import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import {
  type Calibration,
  calibrate,
  leaveOneOut,
  type Scored,
  scoreWith,
} from "../domain/calibration";
import { extractFeatures, NO_SIGNALS } from "../domain/change-features";
import { DEFAULT_LABELS, type LabelConfig } from "../domain/outcome-labels";
import { type Example, fitVerifier } from "../domain/verifier-fit";
import { PRIOR_MODEL, type VerifierModel } from "../domain/verifier-model";
import { type Evidence, untrustedReason } from "../domain/verifier-policy";
import type { VerifierPorts } from "../ports";
import { type LabelSummary, labelHistory } from "./verifier-labels";

export interface TrainOptions {
  readonly days: number;
  readonly labels: Partial<LabelConfig>;
  /** Compute and report, but do not save the model. */
  readonly dryRun: boolean;
}

export interface TrainedExample {
  readonly number: number;
  readonly title: string;
  readonly merged: 0 | 1;
  readonly agent: boolean;
  /** What decided the label, and the share of added lines still present at the horizon. */
  readonly basis: "merge" | "survival";
  readonly survival: number | null;
  readonly priorP: number;
  /** Leave-one-out probability: scored by a model that never saw this PR. */
  readonly looP: number;
}

export interface TrainingReport {
  readonly model: VerifierModel;
  readonly evidence: Evidence;
  /** The hand-set prior scored on the same PRs: what training has to beat. */
  readonly prior: Calibration;
  readonly priorAgent: Calibration;
  /** Leave-one-out score of the trained model (an honest estimate on small data). */
  readonly loo: Calibration;
  /** Leave-one-out score on the factory's own PRs only, the population the gate is for. */
  readonly looAgent: Calibration;
  readonly examples: readonly TrainedExample[];
  /** Why the model may not block on probability yet; null when it may. */
  readonly untrusted: string | null;
  readonly labels: LabelSummary;
  readonly truncated: boolean;
  readonly saved: boolean;
}

async function toExamples(ports: VerifierPorts, days: number, labels: LabelConfig) {
  const h = await labelHistory(ports, days, labels);
  if (!h.ok) return h;
  const out: Row[] = [];
  for (const l of h.value.labelled) {
    const files = await ports.files.files(l.pull.number);
    if (!files.ok) return files;
    const x = extractFeatures({
      title: l.pull.title,
      body: l.pull.body,
      files: files.value,
      signals: h.value.signals.get(l.pull.number) ?? NO_SIGNALS,
      factory: l.agent,
    });
    out.push({
      ex: { id: l.pull.number, x, y: l.y, weight: l.weight },
      title: l.pull.title,
      agent: l.agent,
      basis: l.basis,
      survival: l.survival?.rate ?? null,
    });
  }
  return ok({ rows: out, truncated: h.value.truncated, summary: h.value.summary });
}

/**
 * The gate's evidence comes from the factory's own PRs only: the population it will judge. Human
 * PRs help fit the shared weights, but a model that ranks human PRs well has not shown it can
 * rank the factory's.
 */
function evidenceOf(factory: readonly Scored[], loo: Calibration): Evidence {
  return {
    examples: factory.length,
    merged: factory.filter((e) => e.y === 1).length,
    unmerged: factory.filter((e) => e.y === 0).length,
    looAuc: loo.auc,
    looBrier: loo.brier,
    baseBrier: loo.baseBrier,
  };
}

type Row = {
  readonly ex: Example;
  readonly title: string;
  readonly agent: boolean;
  readonly basis: "merge" | "survival";
  readonly survival: number | null;
};

function measure(rows: readonly Row[], now: number) {
  const data = rows.map((row) => row.ex);
  const looScores = leaveOneOut(data, now);
  const priorScores = scoreWith(PRIOR_MODEL, data);
  const factory = <T>(xs: readonly T[]) => xs.filter((_, i) => rows[i]?.agent);
  const looAgent = calibrate(factory(looScores));
  return {
    model: fitVerifier(data, now),
    evidence: evidenceOf(factory(looScores), looAgent),
    prior: calibrate(priorScores),
    priorAgent: calibrate(factory(priorScores)),
    loo: calibrate(looScores),
    looAgent,
    examples: rows.map((row, i) => ({
      number: row.ex.id,
      title: row.title,
      merged: row.ex.y,
      agent: row.agent,
      basis: row.basis,
      survival: row.survival,
      priorP: priorScores[i]?.p ?? Number.NaN,
      looP: looScores[i]?.p ?? Number.NaN,
    })),
  };
}

/**
 * Learns the verifier from the repository's closed PRs: label them, describe each by the same
 * features a candidate has, fit around the prior, and measure it leave-one-out. Saves the model
 * with its evidence unless `dryRun`.
 */
export async function trainVerifier(
  ports: VerifierPorts,
  opts: TrainOptions,
): Promise<Result<TrainingReport, AdapterError>> {
  const r = await toExamples(ports, opts.days, { ...DEFAULT_LABELS, ...opts.labels });
  if (!r.ok) return r;
  const m = measure(r.value.rows, ports.now());
  let saved = false;
  if (!opts.dryRun && r.value.rows.length > 0) {
    const s = await ports.store.save({ model: m.model, evidence: m.evidence });
    if (!s.ok) return s;
    saved = true;
  }
  return ok({
    ...m,
    untrusted: untrustedReason(m.evidence),
    labels: r.value.summary,
    truncated: r.value.truncated,
    saved,
  });
}

/** The verifier as last trained, or null when it was never trained. */
export function readVerifier(ports: VerifierPorts) {
  return ports.store.load();
}
