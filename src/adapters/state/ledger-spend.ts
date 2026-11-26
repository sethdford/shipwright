import type { CostLedger } from "../../contexts/orchestration";
import type { SpendSource } from "../../contexts/quality";
import { ok } from "../../shared/kernel/result";

/** Spend in a window from the `shipwright cost` ledger. No cost file at all is `null` (unknown). */
export class LedgerSpend implements SpendSource {
  constructor(private readonly ledger: CostLedger) {}

  async between(fromMs: number, toMs: number) {
    const r = await this.ledger.read();
    if (!r.ok) return r;
    if (!r.value.present) return ok(null);
    const total = r.value.entries
      .filter((e) => e.atEpochS * 1000 >= fromMs && e.atEpochS * 1000 <= toMs)
      .reduce((sum, e) => sum + e.costUsd, 0);
    return ok(total);
  }
}
