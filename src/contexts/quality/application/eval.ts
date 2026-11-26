import { type EvalResults, parseEvalResults, scoreRuns } from "../domain/eval-results";
import { type CaseScore, decideRatchet, type RatchetVerdict } from "../domain/ratchet";

type Outcome<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly reason: string };

export interface EvalSummary {
  readonly policy: string;
  readonly k: number;
  readonly cases: readonly CaseScore[];
  /** Mean pass^k over cases: the headline reliability number. */
  readonly meanPassK: number;
  readonly totalCostUsd: number;
  readonly runs: number;
}

function load(json: unknown, label: string): Outcome<EvalResults> {
  const r = parseEvalResults(json);
  return r.ok ? r : { ok: false, reason: `${label}: ${r.reason}` };
}

/** Scores one results file: pass^k per case, mean pass^k and total spend. */
export function summarizeEval(json: unknown, k: number): Outcome<EvalSummary> {
  const results = load(json, "results");
  if (!results.ok) return results;
  const scores = scoreRuns(results.value.runs, k);
  if (!scores.ok) return scores;
  const cases = scores.value;
  if (cases.length === 0) return { ok: false, reason: "results: no runs" };
  return {
    ok: true,
    value: {
      policy: results.value.policy,
      k,
      cases,
      meanPassK: cases.reduce((s, c) => s + c.passK, 0) / cases.length,
      totalCostUsd: results.value.runs.reduce((s, r) => s + r.costUsd, 0),
      runs: results.value.runs.length,
    },
  };
}

export interface RatchetReport {
  readonly incumbent: string;
  readonly candidate: string;
  readonly verdict: RatchetVerdict;
}

/**
 * The paired ratchet (W2-13) over two results files on the same cases. The candidate's vetoes
 * apply; the incumbent's are ignored (it is already in force).
 */
export function compareEval(incumbentJson: unknown, candidateJson: unknown, k: number) {
  const inc = load(incumbentJson, "incumbent");
  if (!inc.ok) return inc;
  const cand = load(candidateJson, "candidate");
  if (!cand.ok) return cand;
  const incScores = scoreRuns(inc.value.runs, k);
  if (!incScores.ok) return { ok: false, reason: `incumbent: ${incScores.reason}` } as const;
  const candScores = scoreRuns(cand.value.runs, k);
  if (!candScores.ok) return { ok: false, reason: `candidate: ${candScores.reason}` } as const;
  const d = decideRatchet(incScores.value, candScores.value, cand.value.vetoes);
  if (!d.ok) return d;
  const report: RatchetReport = {
    incumbent: inc.value.policy,
    candidate: cand.value.policy,
    verdict: d.verdict,
  };
  return { ok: true, value: report } as const;
}
