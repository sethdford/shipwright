/**
 * Per-issue review rubric (Agentic Rubrics, Scale AI 2026): weighted, binary criteria that name
 * the repository's real files and behaviours. A grader marks each criterion met or not met against
 * the final diff only, never the agent's trajectory. The score selects between tournament
 * candidates and explains the choice in the PR.
 */

export type Axis = "correctness" | "scope" | "tests" | "integrity";
export type Weight = 1 | 2 | 3;

export interface Criterion {
  readonly id: string;
  readonly text: string;
  readonly weight: Weight;
  readonly axis: Axis;
}

export interface Rubric {
  readonly criteria: readonly Criterion[];
}

export const RUBRIC_LIMITS = { minDrafted: 3, maxDrafted: 12, maxTextLength: 300 } as const;

/**
 * Criteria Shipwright always adds, so a candidate cannot win by weakening its own judge. The
 * Darwin Gödel Machine reward-hacked exactly this way (it deleted the markers its checker used).
 */
export const INTEGRITY_CRITERIA: readonly Criterion[] = [
  {
    id: "integrity-tests",
    text: "Does not delete, skip, or weaken existing tests or assertions.",
    weight: 3,
    axis: "integrity",
  },
  {
    id: "integrity-harness",
    text: "Does not change CI workflows, test runner configuration, or lint rules unless the task asks for it.",
    weight: 3,
    axis: "integrity",
  },
];

const ID = /^[a-z0-9][a-z0-9-]{0,39}$/;

/**
 * Validates a drafted rubric and appends the integrity criteria. Returns a reason string when the
 * draft is unusable: too few or too many criteria, a bad or duplicate id, or empty text.
 */
export function finalizeRubric(drafted: readonly Criterion[]): Rubric | string {
  const { minDrafted, maxDrafted, maxTextLength } = RUBRIC_LIMITS;
  if (drafted.length < minDrafted || drafted.length > maxDrafted) {
    return `a rubric needs ${minDrafted} to ${maxDrafted} criteria (got ${drafted.length})`;
  }
  const seen = new Set(INTEGRITY_CRITERIA.map((c) => c.id));
  for (const c of drafted) {
    if (!ID.test(c.id)) return `criterion id "${c.id}" is not lowercase-kebab`;
    if (seen.has(c.id)) return `criterion id "${c.id}" is used twice`;
    const text = c.text.trim();
    if (text.length === 0 || text.length > maxTextLength) {
      return `criterion "${c.id}" needs 1 to ${maxTextLength} characters of text`;
    }
    seen.add(c.id);
  }
  return { criteria: [...drafted, ...INTEGRITY_CRITERIA] };
}

/**
 * Weighted share of criteria met, from 0 to 1. A criterion the grader did not answer counts as
 * not met (fail closed), and a failed integrity criterion scores the whole candidate 0.
 */
export function scoreRubric(rubric: Rubric, met: Readonly<Record<string, boolean>>): number {
  const total = rubric.criteria.reduce((sum, c) => sum + c.weight, 0);
  if (total === 0) return 0;
  if (rubric.criteria.some((c) => c.axis === "integrity" && met[c.id] !== true)) return 0;
  const earned = rubric.criteria.reduce((sum, c) => sum + (met[c.id] === true ? c.weight : 0), 0);
  return earned / total;
}

/** The rubric as numbered lines, for the grader's data and the PR body. */
export function renderRubric(rubric: Rubric): string {
  return rubric.criteria
    .map((c) => `- [${c.id}] (${c.axis}, weight ${c.weight}) ${c.text}`)
    .join("\n");
}
