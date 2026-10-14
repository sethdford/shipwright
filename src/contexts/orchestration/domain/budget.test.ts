import { expect, test } from "bun:test";
import { type CostEntry, describeBudget, evaluateBudget, utcDayStartEpochS } from "./budget";

const NOW = Date.parse("2026-10-14T15:30:00Z");
const TODAY = Date.parse("2026-10-14T00:00:00Z") / 1000;
const spent = (usd: number, epochS: number): CostEntry => ({ costUsd: usd, atEpochS: epochS });

test("today starts at UTC midnight, like sw-cost.sh", () => {
  expect(utcDayStartEpochS(NOW)).toBe(TODAY);
});

test("no cap configured is unlimited", () => {
  expect(evaluateBudget(null, [spent(500, TODAY)], NOW)).toEqual({
    allowed: true,
    limitUsd: null,
    spentTodayUsd: 500,
    remainingUsd: null,
  });
});

test("only today's entries count against the cap", () => {
  const entries = [spent(4, TODAY - 1), spent(2.5, TODAY), spent(1.25, TODAY + 3600)];
  expect(evaluateBudget({ limitUsd: 10 }, entries, NOW)).toEqual({
    allowed: true,
    limitUsd: 10,
    spentTodayUsd: 3.75,
    remainingUsd: 6.25,
  });
});

test("spend at or over the cap blocks; so does an estimate that would cross it", () => {
  expect(evaluateBudget({ limitUsd: 10 }, [spent(10, TODAY)], NOW).allowed).toBe(false);
  expect(evaluateBudget({ limitUsd: 10 }, [spent(8, TODAY)], NOW, 2).allowed).toBe(false);
  expect(evaluateBudget({ limitUsd: 10 }, [spent(8, TODAY)], NOW, 1.99).allowed).toBe(true);
});

test("a verdict with no cost data says so instead of reading as a pass", () => {
  const verdict = { ...evaluateBudget(null, [], NOW), noData: true as const };
  const text = describeBudget(verdict);
  expect(text).toContain("no cost data");
  expect(text).toContain("not enforced");
});

test("a full ledger whose oldest entry is today may hide spend: block", () => {
  const entries = Array.from({ length: 1000 }, () => spent(0.01, TODAY + 60));
  const v = evaluateBudget({ limitUsd: 1000 }, entries, NOW);
  expect(v.allowed).toBe(false);
  expect(v.truncated).toBe(true);
  expect(describeBudget(v)).toContain("cost ledger truncated today; spend unknown");
});

test("a full ledger reaching back before today is complete for today", () => {
  const entries = [spent(1, TODAY - 5), ...Array.from({ length: 999 }, () => spent(0.01, TODAY))];
  expect(evaluateBudget({ limitUsd: 1000 }, entries, NOW).allowed).toBe(true);
});

test("truncation does not matter without a cap", () => {
  const entries = Array.from({ length: 1000 }, () => spent(0.01, TODAY));
  expect(evaluateBudget(null, entries, NOW).allowed).toBe(true);
});
