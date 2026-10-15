import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import type { CostEntry, CostLedger, DailyBudget } from "../../contexts/orchestration";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

// Formats written by scripts/sw-cost.sh (always dual-written next to the SQLite db). Everything
// that exists must match exactly: a file we cannot interpret must block, never read as "no spend".
const BudgetFile = z.object({ daily_budget_usd: z.number().nonnegative(), enabled: z.boolean() });
const Entry = z.object({ cost_usd: z.number().nonnegative(), ts_epoch: z.number() });
const CostsFile = z.object({ entries: z.array(Entry) });

type Read = Result<{ found: false } | { found: true; value: unknown }, AdapterError>;

async function readJson(path: string): Promise<Read> {
  try {
    return ok({ found: true, value: JSON.parse(await readFile(path, "utf8")) });
  } catch (e) {
    if ((e as { code?: string }).code === "ENOENT") return ok({ found: false });
    return err({
      kind: "failed",
      message: `${path}: ${e instanceof Error ? e.message : String(e)}`,
    });
  }
}

function describeIssues(error: z.ZodError): string {
  return error.issues.map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`).join("; ");
}

function toBudget(read: Read, path: string): Result<DailyBudget | null, AdapterError> {
  if (!read.ok) return read;
  if (!read.value.found) return ok(null);
  const b = BudgetFile.safeParse(read.value.value);
  if (!b.success) return err({ kind: "failed", message: `${path}: ${describeIssues(b.error)}` });
  const on = b.data.enabled && b.data.daily_budget_usd > 0;
  return ok(on ? { limitUsd: b.data.daily_budget_usd } : null);
}

/** Any malformed entry fails the whole read (jq would not skip it either: it errors or sums wrong). */
function toEntries(read: Read, path: string): Result<CostEntry[], AdapterError> {
  if (!read.ok) return read;
  if (!read.value.found) return ok([]);
  const file = CostsFile.safeParse(read.value.value);
  if (!file.success) {
    return err({ kind: "failed", message: `${path}: ${describeIssues(file.error)}` });
  }
  return ok(file.data.entries.map((e) => ({ costUsd: e.cost_usd, atEpochS: e.ts_epoch })));
}

/** Reads `costs.json` and `budget.json` from the bash cost directory (`~/.shipwright`). */
export class JsonCostLedger implements CostLedger {
  constructor(private readonly dir: string) {}

  async read() {
    const budgetPath = join(this.dir, "budget.json");
    const costsPath = join(this.dir, "costs.json");
    const [budgetRead, costsRead] = await Promise.all([readJson(budgetPath), readJson(costsPath)]);
    const budget = toBudget(budgetRead, budgetPath);
    if (!budget.ok) return budget;
    const entries = toEntries(costsRead, costsPath);
    if (!entries.ok) return entries;
    const present =
      (budgetRead.ok && budgetRead.value.found) || (costsRead.ok && costsRead.value.found);
    return ok({ budget: budget.value, entries: entries.value, present });
  }
}
