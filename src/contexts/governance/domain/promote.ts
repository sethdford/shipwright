import type { Lesson } from "./lesson";
import { renderLesson } from "./render-lesson";

/** The fields of a paired-ratchet verdict (`shipwright eval ratchet --json`, PR #8735) a promotion needs. */
export interface TrialVerdict {
  readonly accept: boolean;
  readonly reason: string;
  readonly cases: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  readonly signTestP: number;
  readonly medianCostRatio: number | null;
}

/** The smallest corpus a promotion may rest on (ADR-0009 rule 5 uses about 24 cases; 12 is its stratified subset). */
export const MIN_TRIAL_CASES = 12;

type Parsed =
  | { readonly ok: true; readonly value: TrialVerdict }
  | { readonly ok: false; readonly reason: string };

function num(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= 0;
}

/** Accepts the full report (`{incumbent, candidate, verdict}`) or the bare verdict. Fails closed on any odd field. */
export function parseTrialVerdict(json: unknown): Parsed {
  const outer = json as Record<string, unknown> | null;
  const v = (
    outer !== null && typeof outer === "object" && "verdict" in outer ? outer.verdict : outer
  ) as Record<string, unknown> | null;
  if (v === null || typeof v !== "object") return { ok: false, reason: "verdict is not an object" };
  const { accept, reason, cases, wins, losses, ties, signTestP, medianCostRatio } = v;
  if (typeof accept !== "boolean" || typeof reason !== "string") {
    return { ok: false, reason: "verdict needs accept (boolean) and reason (string)" };
  }
  if (![cases, wins, losses, ties, signTestP].every(num)) {
    return { ok: false, reason: "verdict counts must be non-negative numbers" };
  }
  if (medianCostRatio !== null && !num(medianCostRatio)) {
    return { ok: false, reason: "medianCostRatio must be a number or null" };
  }
  return {
    ok: true,
    value: {
      accept,
      reason,
      cases,
      wins,
      losses,
      ties,
      signTestP,
      medianCostRatio,
    } as TrialVerdict,
  };
}

export interface Promotion {
  readonly outcome: "promote" | "retire";
  readonly why: string;
  readonly markdown: string;
}

function evaluation(
  v: TrialVerdict,
  outcome: Promotion["outcome"],
  why: string,
  trial: string,
): string {
  const ratio = v.medianCostRatio === null ? "n/a" : v.medianCostRatio.toFixed(2);
  return [
    `Trial: ${trial}`,
    `Outcome: ${outcome} (${why})`,
    `Paired ratchet: ${v.cases} cases, ${v.wins} wins, ${v.losses} losses, ${v.ties} ties; ` +
      `sign test p=${v.signTestP.toFixed(4)}; median cost ratio ${ratio}.`,
    "This change takes effect only when a maintainer merges it (ADR-0010).",
  ].join("\n");
}

function decide(v: TrialVerdict): [Promotion["outcome"], string] {
  if (v.cases < MIN_TRIAL_CASES)
    return ["retire", `only ${v.cases} cases; at least ${MIN_TRIAL_CASES} are needed`];
  return v.accept ? ["promote", v.reason] : ["retire", v.reason];
}

/**
 * A trialled lesson, rewritten from its verdict: `active` when the ratchet accepted it on enough cases, `retired`
 * otherwise, with an Evaluation section either way. Only a `proposed` lesson can be decided; the caller opens the
 * change as a pull request, and a person merges it.
 */
export function decidePromotion(
  l: Lesson,
  evidence: string | undefined,
  v: TrialVerdict,
  trial: string,
): Promotion {
  const [outcome, why] = decide(v);
  const sections = [
    ...(evidence === undefined ? [] : [{ heading: "Evidence", body: evidence }]),
    { heading: "Evaluation", body: evaluation(v, outcome, why, trial) },
  ];
  const markdown = renderLesson({
    id: l.id,
    status: outcome === "promote" ? "active" : "retired",
    ...(l.failureClass === undefined ? {} : { failureClass: l.failureClass }),
    ...(l.fingerprint === undefined ? {} : { fingerprint: l.fingerprint }),
    ...(l.source === undefined ? {} : { source: l.source }),
    appliesTo: l.appliesTo,
    keywords: l.keywords,
    hypothesis: l.hypothesis ?? "",
    title: l.title,
    rule: l.text,
    sections,
  });
  return { outcome, why, markdown };
}
