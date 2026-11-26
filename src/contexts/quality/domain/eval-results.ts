import { passHatK } from "./pass-k";
import { type CaseScore, NO_VETOES, type Vetoes } from "./ratchet";

/** One run of one eval case under one policy, as an eval harness reports it. */
export interface EvalRun {
  readonly caseId: string;
  readonly pass: boolean;
  readonly costUsd: number;
}

/** A results file: `{ policy, runs: [{case, pass, costUsd}], vetoes? }`. */
export interface EvalResults {
  readonly policy: string;
  readonly runs: readonly EvalRun[];
  readonly vetoes: Vetoes;
}

type Parsed<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly reason: string };

const CASE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

function parseRun(item: unknown, i: number): Parsed<EvalRun> {
  if (typeof item !== "object" || item === null)
    return { ok: false, reason: `run ${i} is not an object` };
  const { case: caseId, pass, costUsd } = item as Record<string, unknown>;
  if (typeof caseId !== "string" || !CASE_ID.test(caseId)) {
    return { ok: false, reason: `run ${i}: case must be an id like "c01"` };
  }
  if (typeof pass !== "boolean")
    return { ok: false, reason: `run ${i}: pass must be true or false` };
  if (typeof costUsd !== "number" || !Number.isFinite(costUsd) || costUsd < 0) {
    return { ok: false, reason: `run ${i}: costUsd must be a non-negative number` };
  }
  return { ok: true, value: { caseId, pass, costUsd } };
}

function parseVetoes(value: unknown): Parsed<Vetoes> {
  if (value === undefined) return { ok: true, value: NO_VETOES };
  if (typeof value !== "object" || value === null)
    return { ok: false, reason: "vetoes must be an object" };
  const v = value as Record<string, unknown>;
  const fence = v.fenceViolations ?? 0;
  const path = v.protectedPathTouched ?? false;
  const oracle = v.oracleTampering ?? false;
  if (typeof fence !== "number" || !Number.isInteger(fence) || fence < 0) {
    return { ok: false, reason: "vetoes.fenceViolations must be a non-negative integer" };
  }
  if (typeof path !== "boolean" || typeof oracle !== "boolean") {
    return {
      ok: false,
      reason: "vetoes.protectedPathTouched and oracleTampering must be booleans",
    };
  }
  return {
    ok: true,
    value: { fenceViolations: fence, protectedPathTouched: path, oracleTampering: oracle },
  };
}

/** Validates a results file. Fails closed: one bad run rejects the whole file. */
export function parseEvalResults(value: unknown): Parsed<EvalResults> {
  if (typeof value !== "object" || value === null)
    return { ok: false, reason: "results must be a JSON object" };
  const { policy, runs, vetoes } = value as Record<string, unknown>;
  if (typeof policy !== "string" || policy.length === 0)
    return { ok: false, reason: "policy is required" };
  if (!Array.isArray(runs)) return { ok: false, reason: "runs must be an array" };
  const parsed: EvalRun[] = [];
  for (const [i, item] of runs.entries()) {
    const run = parseRun(item, i);
    if (!run.ok) return run;
    parsed.push(run.value);
  }
  const v = parseVetoes(vetoes);
  if (!v.ok) return v;
  return { ok: true, value: { policy, runs: parsed, vetoes: v.value } };
}

/** pass^k and mean cost per case. Every case needs at least k runs, or nothing is scored. */
export function scoreRuns(runs: readonly EvalRun[], k: number): Parsed<readonly CaseScore[]> {
  const byCase = new Map<string, EvalRun[]>();
  for (const run of runs) byCase.set(run.caseId, [...(byCase.get(run.caseId) ?? []), run]);
  const scores: CaseScore[] = [];
  for (const [caseId, list] of byCase) {
    const passes = list.filter((r) => r.pass).length;
    const passK = passHatK(list.length, passes, k);
    if (passK === null)
      return { ok: false, reason: `case ${caseId}: ${list.length} run(s), need ${k}` };
    const costUsd = list.reduce((sum, r) => sum + r.costUsd, 0) / list.length;
    scores.push({ caseId, passK, costUsd });
  }
  return { ok: true, value: scores };
}
