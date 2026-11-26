/**
 * How a tournament spends its budget. Judging (rubric, grading, the final comparison) is cheap
 * next to building, so it gets a fixed share up front and the attempts split the rest. Every agent
 * call carries its own cap, so the total can never exceed the tournament budget.
 */

export const TOURNAMENT_LIMITS = {
  minAttempts: 1,
  maxAttempts: 5,
  judgeShare: 0.2,
  /** Rubric draft, one grade per candidate, and one final judgement share the judging budget. */
  maxBudgetUsd: 200,
} as const;

export interface BudgetPlan {
  readonly perAttemptUsd: number;
  readonly rubricUsd: number;
  readonly perGradeUsd: number;
  readonly judgeUsd: number;
}

const cents = (usd: number): number => Math.floor(usd * 100) / 100;

export function planBudget(totalUsd: number, attempts: number): BudgetPlan {
  const judging = totalUsd * TOURNAMENT_LIMITS.judgeShare;
  // Judging: a quarter for the rubric, half across the grades, a quarter for the final judge.
  return {
    perAttemptUsd: cents((totalUsd - judging) / attempts),
    rubricUsd: cents(judging / 4),
    perGradeUsd: cents(judging / 2 / attempts),
    judgeUsd: cents(judging / 4),
  };
}

/**
 * Different opening strategies per attempt, so the attempts fail in different ways (the gain from
 * parallel attempts comes from their errors being uncorrelated).
 */
export const ATTEMPT_STRATEGIES: readonly string[] = [
  "Make the smallest change that fully solves the task, then add or update a test that proves it.",
  "Start by writing a test that fails because of the problem, confirm it fails, then make it pass.",
  "First read the code around the change and how similar cases are handled, then follow those patterns exactly.",
  "Write down the edge cases first (empty input, errors, limits), then implement and test each one.",
  "Find every caller of the code you change and make sure each still works; test the riskiest one.",
];

export const strategyFor = (attempt: number): string =>
  ATTEMPT_STRATEGIES[attempt % ATTEMPT_STRATEGIES.length] as string;
