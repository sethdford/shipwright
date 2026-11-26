import { choose } from "./pass-k";

/** One eval case scored for one policy: its pass^k and its mean cost per run. */
export interface CaseScore {
  readonly caseId: string;
  readonly passK: number;
  readonly costUsd: number;
}

/** Hard vetoes (Wave 2 plan W2-13): any one rejects the candidate whatever the statistics say. */
export interface Vetoes {
  readonly fenceViolations: number;
  readonly protectedPathTouched: boolean;
  readonly oracleTampering: boolean;
}

export const NO_VETOES: Vetoes = {
  fenceViolations: 0,
  protectedPathTouched: false,
  oracleTampering: false,
};

/** The paired ratchet rule (W2-13). Adaptation may only tighten these. */
export const RATCHET_RULE = {
  /** Non-inferiority: losses minus wins at most this. */
  maxNetLosses: 0,
  /** Non-inferiority: at most this many losses. */
  maxLosses: 1,
  /** Superiority: exact one-sided sign test on the discordant pairs at this level. */
  alpha: 0.05,
  /** A cost-motivated change must cut the median paired cost ratio to at most this. */
  maxCostRatio: 0.9,
} as const;

export interface RatchetVerdict {
  readonly accept: boolean;
  readonly reason: string;
  readonly cases: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  readonly nonInferior: boolean;
  readonly superior: boolean;
  /** One-sided sign-test p on the discordant pairs; 1 when there are none. */
  readonly signTestP: number;
  /** Median of candidate cost ÷ incumbent cost over cases the incumbent spent on; null if none. */
  readonly medianCostRatio: number | null;
  readonly cheaper: boolean;
  readonly vetoes: readonly string[];
}

/** P(X ≥ wins) for X ~ Binomial(n, 1/2): the exact one-sided sign-test p-value. */
export function signTestP(wins: number, n: number): number {
  if (n <= 0) return 1;
  let tail = 0;
  for (let i = Math.max(0, wins); i <= n; i++) tail += choose(n, i);
  return tail / 2 ** n;
}

/** Fewest wins out of n discordant pairs that reach `alpha`; null when no count can. */
export function minWinsForSuperiority(n: number, alpha: number = RATCHET_RULE.alpha) {
  for (let w = 0; w <= n; w++) if (signTestP(w, n) <= alpha) return w;
  return null;
}

export function median(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const hi = sorted[mid] ?? 0;
  return sorted.length % 2 === 1 ? hi : ((sorted[mid - 1] ?? 0) + hi) / 2;
}

function vetoList(v: Vetoes): string[] {
  const out: string[] = [];
  if (v.fenceViolations > 0) out.push(`${v.fenceViolations} fence violation(s)`);
  if (v.protectedPathTouched) out.push("touched a protected path");
  if (v.oracleTampering) out.push("oracle tampering");
  return out;
}

type Pairing = { readonly pairs: [CaseScore, CaseScore][] } | { readonly error: string };

/** Pairs the two runs case by case. Both must cover exactly the same cases (a paired design). */
export function pairCases(incumbent: readonly CaseScore[], candidate: readonly CaseScore[]) {
  const byId = new Map(candidate.map((c) => [c.caseId, c]));
  if (byId.size !== candidate.length) return { error: "duplicate case in candidate" } as Pairing;
  if (new Set(incumbent.map((c) => c.caseId)).size !== incumbent.length) {
    return { error: "duplicate case in incumbent" } as Pairing;
  }
  const pairs: [CaseScore, CaseScore][] = [];
  for (const inc of incumbent) {
    const cand = byId.get(inc.caseId);
    if (!cand) return { error: `case ${inc.caseId} has no candidate result` } as Pairing;
    pairs.push([inc, cand]);
  }
  if (pairs.length !== candidate.length)
    return { error: "candidate has unpaired cases" } as Pairing;
  if (pairs.length === 0) return { error: "no cases to compare" } as Pairing;
  return { pairs } as Pairing;
}

function tally(pairs: readonly [CaseScore, CaseScore][]) {
  let wins = 0;
  let losses = 0;
  const ratios: number[] = [];
  for (const [inc, cand] of pairs) {
    if (cand.passK > inc.passK) wins++;
    else if (cand.passK < inc.passK) losses++;
    if (inc.costUsd > 0) ratios.push(cand.costUsd / inc.costUsd);
  }
  return { wins, losses, ties: pairs.length - wins - losses, ratio: median(ratios) };
}

function explain(v: Omit<RatchetVerdict, "accept" | "reason">): [boolean, string] {
  if (v.vetoes.length > 0) return [false, `vetoed: ${v.vetoes.join(", ")}`];
  if (!v.nonInferior) {
    return [false, `inferior: ${v.losses} loss(es) against ${v.wins} win(s)`];
  }
  if (v.superior) return [true, `superior: sign test p=${v.signTestP.toFixed(4)}`];
  if (v.cheaper) return [true, `non-inferior and cheaper: cost ratio ${v.medianCostRatio}`];
  return [false, "non-inferior but neither superior nor cheaper: keep the incumbent"];
}

/**
 * The W2-13 accept rule: accept when non-inferior AND (superior by the sign test OR the median
 * paired cost ratio ≤ 0.9). Any veto rejects. Pure; the caller records the verdict.
 */
export function decideRatchet(
  incumbent: readonly CaseScore[],
  candidate: readonly CaseScore[],
  vetoes: Vetoes = NO_VETOES,
):
  | { readonly ok: true; readonly verdict: RatchetVerdict }
  | { readonly ok: false; readonly reason: string } {
  const paired = pairCases(incumbent, candidate);
  if ("error" in paired) return { ok: false, reason: paired.error };
  const { wins, losses, ties, ratio } = tally(paired.pairs);
  const p = signTestP(wins, wins + losses);
  const facts = {
    cases: paired.pairs.length,
    wins,
    losses,
    ties,
    nonInferior: losses - wins <= RATCHET_RULE.maxNetLosses && losses <= RATCHET_RULE.maxLosses,
    superior: wins + losses > 0 && p <= RATCHET_RULE.alpha,
    signTestP: p,
    medianCostRatio: ratio,
    cheaper: ratio !== null && ratio <= RATCHET_RULE.maxCostRatio,
    vetoes: vetoList(vetoes),
  };
  const [accept, reason] = explain(facts);
  return { ok: true, verdict: { ...facts, accept, reason } };
}
