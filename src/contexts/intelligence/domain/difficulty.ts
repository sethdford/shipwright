import type { IssueFeatures, IssueKind, Tier } from "./features";
import { TIERS } from "./features";

/**
 * Difficulty prior from issue features: a 0-100 score and a tier, with the reasons that moved it.
 * Every weight is written here so a decision log can be replayed and a ratchet can change one
 * number at a time (ADR-0009 rules 1 and 5). A size label a person set wins over the score.
 */

const KIND_BASE: Readonly<Record<IssueKind, number>> = {
  docs: 10,
  chore: 20,
  bug: 35,
  unknown: 40,
  feature: 45,
  refactor: 55,
  security: 60,
};

/** Lower bound of each tier's score band. */
const TIER_FLOOR: Readonly<Record<Tier, number>> = {
  trivial: 0,
  small: 25,
  medium: 45,
  large: 65,
  xl: 85,
};

export interface DifficultyPrior {
  readonly score: number;
  readonly tier: Tier;
  readonly reasons: readonly string[];
}

const clamp = (n: number, lo: number, hi: number): number => Math.min(hi, Math.max(lo, n));

export function tierOfScore(score: number): Tier {
  let tier: Tier = "trivial";
  for (const t of TIERS) if (score >= TIER_FLOOR[t]) tier = t;
  return tier;
}

export function tierUp(tier: Tier, steps = 1): Tier {
  return TIERS[clamp(TIERS.indexOf(tier) + steps, 0, TIERS.length - 1)] as Tier;
}

type Term = readonly [number, string];

function terms(f: IssueFeatures): readonly Term[] {
  const out: Term[] = [[KIND_BASE[f.kind], `kind ${f.kind}`]];
  if (f.words > 1000) out.push([20, `long issue (${f.words} words)`]);
  else if (f.words > 400) out.push([10, `detailed issue (${f.words} words)`]);
  else if (f.words < 30) out.push([5, `underspecified (${f.words} words)`]);
  if (f.paths > 2) out.push([Math.min(20, (f.paths - 2) * 5), `${f.paths} files named`]);
  if (f.criteria > 10) out.push([20, `${f.criteria} acceptance criteria`]);
  else if (f.criteria > 5) out.push([10, `${f.criteria} acceptance criteria`]);
  if (f.hardSignals.length > 0) {
    out.push([Math.min(24, 8 * f.hardSignals.length), `hard: ${f.hardSignals.join(", ")}`]);
  }
  if (f.easySignals.length > 0) {
    out.push([-Math.min(16, 8 * f.easySignals.length), `easy: ${f.easySignals.join(", ")}`]);
  }
  if (f.riskyPaths.length > 0) out.push([10, `risky paths: ${f.riskyPaths.join(", ")}`]);
  if (f.stackTrace) out.push([-5, "has a stack trace (easier to localize)"]);
  return out;
}

export function difficultyPrior(f: IssueFeatures): DifficultyPrior {
  const parts = terms(f);
  const score = clamp(
    parts.reduce((s, [n]) => s + n, 0),
    0,
    100,
  );
  const reasons = parts.map(([n, why]) => `${n >= 0 ? "+" : ""}${n} ${why}`);
  if (f.sizeLabel !== undefined) {
    return {
      score,
      tier: f.sizeLabel,
      reasons: [...reasons, `size label ${f.sizeLabel} overrides score tier`],
    };
  }
  return { score, tier: tierOfScore(score), reasons };
}
