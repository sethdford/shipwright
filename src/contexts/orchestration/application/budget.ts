import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { type BudgetVerdict, evaluateBudget } from "../domain/budget";
import type { SafetyPorts } from "../ports";

export async function checkBudget(
  ports: Pick<SafetyPorts, "costs" | "now">,
  estimateUsd: number,
): Promise<Result<BudgetVerdict, AdapterError>> {
  const ledger = await ports.costs.read();
  if (!ledger.ok) return ledger;
  const { budget, entries, present } = ledger.value;
  const verdict = evaluateBudget(budget, entries, ports.now(), estimateUsd);
  // No cost files (a CI runner): allowed, but never silently. The flag travels to every report.
  return ok(present ? verdict : { ...verdict, noData: true });
}
