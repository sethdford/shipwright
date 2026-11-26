/**
 * Choosing one tournament winner. Gate first (the patch is non-empty and passes the repository's
 * own tests), then score (cross-test pass rate and rubric score), then a group-wise judge picks
 * among the close finalists (R4P, VeriHarness). The margin and whether the judge agreed with the
 * scores become the PR's confidence signal.
 */

export interface CandidateScore {
  readonly id: string;
  /** The attempt produced a non-empty patch. */
  readonly built: boolean;
  /** The repository's test command passed on this patch alone. */
  readonly ownTestsPass: boolean;
  readonly cross: number | null;
  readonly rubric: number | null;
  /** How many attempts produced this identical patch (1 when unique). */
  readonly votes: number;
  /**
   * The merge verifier's predicted chance that this patch merges and stays merged (ADR-0012), or
   * null/absent when no verifier ran. It captures what tests and the rubric miss: run output in
   * the diff, scope creep, weakened tests, oversized changes.
   */
  readonly verifier?: number | null;
}

export const SELECTION_RULE = {
  crossWeight: 0.5,
  rubricWeight: 0.5,
  /** Half the weight of the execution signals: it already reads them, so it must not dominate. */
  verifierWeight: 0.25,
  /** Candidates within this much of the best score go to the judge. */
  finalistMargin: 0.15,
  maxFinalists: 3,
  /** A lead at least this large, confirmed by the judge, is high confidence. */
  clearLead: 0.15,
} as const;

export type Confidence = "high" | "medium" | "low";

export interface Selection {
  readonly winner: string | null;
  readonly confidence: Confidence;
  /** Winner's score minus the best other eligible score (null with one eligible candidate). */
  readonly margin: number | null;
  readonly reason: string;
}

export const isEligible = (c: CandidateScore): boolean => c.built && c.ownTestsPass;

/** Weighted mean of the available signals; with neither, every eligible candidate ties at 0.5. */
export function compositeScore(c: CandidateScore): number {
  const parts: [number, number][] = [];
  if (c.cross !== null) parts.push([c.cross, SELECTION_RULE.crossWeight]);
  if (c.rubric !== null) parts.push([c.rubric, SELECTION_RULE.rubricWeight]);
  if (c.verifier != null) parts.push([c.verifier, SELECTION_RULE.verifierWeight]);
  if (parts.length === 0) return 0.5;
  const weight = parts.reduce((s, [, w]) => s + w, 0);
  return parts.reduce((s, [v, w]) => s + v * w, 0) / weight;
}

/** Eligible candidates, best first; ties break on votes, then on id for a stable order. */
export function rankCandidates(cs: readonly CandidateScore[]): CandidateScore[] {
  return cs
    .filter(isEligible)
    .sort(
      (a, b) =>
        compositeScore(b) - compositeScore(a) || b.votes - a.votes || a.id.localeCompare(b.id),
    );
}

/** The ranked candidates close enough to the leader for the judge to compare. */
export function finalists(cs: readonly CandidateScore[]): CandidateScore[] {
  const ranked = rankCandidates(cs);
  const best = ranked[0];
  if (!best) return [];
  const floor = compositeScore(best) - SELECTION_RULE.finalistMargin;
  return ranked.filter((c) => compositeScore(c) >= floor).slice(0, SELECTION_RULE.maxFinalists);
}

function marginOf(winner: CandidateScore, ranked: readonly CandidateScore[]): number | null {
  const others = ranked.filter((c) => c.id !== winner.id);
  const next = others[0];
  return next ? compositeScore(winner) - compositeScore(next) : null;
}

/**
 * The final pick. `judged` is the judge's choice among the finalists: an id, "none" (it found every
 * finalist wrong), or null (no judge ran: a single finalist, or the judge failed).
 */
export function select(cs: readonly CandidateScore[], judged: string | "none" | null): Selection {
  const ranked = rankCandidates(cs);
  const leader = ranked[0];
  if (!leader) {
    return {
      winner: null,
      confidence: "low",
      margin: null,
      reason: "no candidate passed the gate",
    };
  }
  if (judged === "none") {
    return {
      winner: null,
      confidence: "low",
      margin: null,
      reason: "the judge rejected every finalist",
    };
  }
  const pick = ranked.find((c) => c.id === judged) ?? leader;
  const margin = marginOf(pick, ranked);
  if (judged !== null && pick.id !== leader.id) {
    return { winner: pick.id, confidence: "low", margin, reason: "the judge overruled the scores" };
  }
  const agreed = judged !== null ? "the judge agreed with the scores" : "no judge was needed";
  const clear = margin === null ? pick.votes > 1 : margin >= SELECTION_RULE.clearLead;
  const confidence: Confidence = clear || (judged !== null && pick.votes > 1) ? "high" : "medium";
  return { winner: pick.id, confidence, margin, reason: agreed };
}

/** Groups attempts whose patches are byte-identical: one candidate per patch, with its votes. */
export function groupIdentical<T extends { readonly id: string; readonly patch: string }>(
  attempts: readonly T[],
): { readonly lead: T; readonly votes: number; readonly members: readonly string[] }[] {
  const groups = new Map<string, { lead: T; members: string[] }>();
  for (const a of attempts) {
    const g = groups.get(a.patch);
    if (g) g.members.push(a.id);
    else groups.set(a.patch, { lead: a, members: [a.id] });
  }
  return [...groups.values()].map((g) => ({
    lead: g.lead,
    votes: g.members.length,
    members: g.members,
  }));
}

/**
 * Anonymous labels for the judge (A, B, C...), assigned in an order drawn from `random` so the
 * judge cannot learn that the first candidate is the score leader (position bias).
 */
export function blindLabels(ids: readonly string[], random: () => number): Map<string, string> {
  const order = [...ids];
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [order[i], order[j]] = [order[j] as string, order[i] as string];
  }
  return new Map(order.map((id, i) => [String.fromCharCode(65 + i), id]));
}
