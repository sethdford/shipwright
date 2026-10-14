// Pre-dispatch budget guard (spec §6.2). Same arithmetic as scripts/sw-cost.sh: today is the UTC
// calendar day, and a cap of 0 or a disabled budget means unlimited.

export interface CostEntry {
  readonly costUsd: number;
  readonly atEpochS: number;
}

export interface DailyBudget {
  readonly limitUsd: number;
}

export interface BudgetVerdict {
  readonly allowed: boolean;
  /** `null` when no daily cap is configured. */
  readonly limitUsd: number | null;
  readonly spentTodayUsd: number;
  readonly remainingUsd: number | null;
  /**
   * Set (to true) when neither `budget.json` nor `costs.json` exists, as on a CI runner: the gate
   * passes but nothing was checked, and every report says so. Absent otherwise.
   */
  readonly noData?: true;
}

export function utcDayStartEpochS(nowMs: number): number {
  const d = new Date(nowMs);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) / 1000;
}

/** Blocks when today's spend plus `estimateUsd` reaches the cap (the daemon's `remaining <= 0`). */
export function evaluateBudget(
  budget: DailyBudget | null,
  entries: readonly CostEntry[],
  nowMs: number,
  estimateUsd = 0,
): BudgetVerdict {
  const since = utcDayStartEpochS(nowMs);
  const spentTodayUsd = entries
    .filter((e) => e.atEpochS >= since)
    .reduce((sum, e) => sum + e.costUsd, 0);
  if (budget === null) {
    return { allowed: true, limitUsd: null, spentTodayUsd, remainingUsd: null };
  }
  return {
    allowed: spentTodayUsd + estimateUsd < budget.limitUsd,
    limitUsd: budget.limitUsd,
    spentTodayUsd,
    remainingUsd: budget.limitUsd - spentTodayUsd,
  };
}

const usd = (n: number) => `$${n.toFixed(2)}`;

export function describeBudget(v: BudgetVerdict): string {
  if (v.noData) {
    return "no cost data (no budget.json or costs.json found); budget not enforced";
  }
  if (v.limitUsd === null || v.remainingUsd === null) {
    const spent = usd(v.spentTodayUsd);
    return `no daily cap (${spent} spent today); set one with: shipwright cost budget set <usd>`;
  }
  const left = usd(Math.max(0, v.remainingUsd));
  return `${usd(v.spentTodayUsd)} of ${usd(v.limitUsd)} spent today (UTC); ${left} left`;
}
