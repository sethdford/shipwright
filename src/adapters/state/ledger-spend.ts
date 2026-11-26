import type { CostLedger } from "../../contexts/orchestration";
import type { SpendSource } from "../../contexts/quality";
import { ok } from "../../shared/kernel/result";

/**
 * Spend in a window from the `shipwright cost` ledger. `null` (unknown) when there is no cost file
 * or no entry in the window with a real cost: a ledger of $0 placeholder rows is not "free".
 */
export class LedgerSpend implements SpendSource {
  constructor(private readonly ledger: CostLedger) {}

  async between(fromMs: number, toMs: number) {
    const r = await this.ledger.read();
    if (!r.ok) return r;
    if (!r.value.present) return ok(null);
    const inWindow = r.value.entries.filter(
      (e) => e.atEpochS * 1000 >= fromMs && e.atEpochS * 1000 <= toMs,
    );
    if (!inWindow.some((e) => e.costUsd > 0)) return ok(null);
    return ok(inWindow.reduce((sum, e) => sum + e.costUsd, 0));
  }
}
