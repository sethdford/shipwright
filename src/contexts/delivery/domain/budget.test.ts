import { expect, test } from "bun:test";
import { ATTEMPT_STRATEGIES, planBudget, strategyFor } from "./budget";

test("judging gets a fifth of the budget and the attempts split the rest", () => {
  expect(planBudget(15, 3)).toEqual({
    perAttemptUsd: 4,
    rubricUsd: 0.75,
    perGradeUsd: 0.5,
    judgeUsd: 0.75,
  });
});

test("the plan never adds up to more than the budget", () => {
  for (const [total, n] of [
    [15, 3],
    [7.77, 5],
    [1, 1],
    [200, 4],
  ] as const) {
    const p = planBudget(total, n);
    const spent = p.perAttemptUsd * n + p.rubricUsd + p.perGradeUsd * n + p.judgeUsd;
    expect(spent).toBeLessThanOrEqual(total + 1e-9);
  }
});

test("each attempt opens with a different strategy, wrapping after the list", () => {
  expect(new Set([0, 1, 2, 3, 4].map(strategyFor)).size).toBe(ATTEMPT_STRATEGIES.length);
  expect(strategyFor(5)).toBe(strategyFor(0));
});
