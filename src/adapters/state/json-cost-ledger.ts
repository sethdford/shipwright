import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import type { CostEntry, CostLedger, DailyBudget } from "../../contexts/orchestration";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

// Formats written by scripts/sw-cost.sh (always dual-written next to the SQLite db).
const BudgetFile = z.object({ daily_budget_usd: z.number(), enabled: z.boolean() });
const CostsFile = z.object({ entries: z.array(z.unknown()) });
const Entry = z.object({ cost_usd: z.number(), ts_epoch: z.number() });

type Read = Result<unknown | null, AdapterError>;

async function readJson(path: string): Promise<Read> {
  try {
    return ok(JSON.parse(await readFile(path, "utf8")));
  } catch (e) {
    if ((e as { code?: string }).code === "ENOENT") return ok(null);
    return err({
      kind: "failed",
      message: `${path}: ${e instanceof Error ? e.message : String(e)}`,
    });
  }
}

function toBudget(json: unknown, path: string): Result<DailyBudget | null, AdapterError> {
  if (json === null) return ok(null);
  const b = BudgetFile.safeParse(json);
  if (!b.success) return err({ kind: "failed", message: `${path}: ${b.error.message}` });
  const on = b.data.enabled && b.data.daily_budget_usd > 0;
  return ok(on ? { limitUsd: b.data.daily_budget_usd } : null);
}

/** Malformed entries are skipped, as sw-cost.sh's jq sums skip them. */
function toEntries(json: unknown): CostEntry[] {
  const file = CostsFile.safeParse(json);
  if (!file.success) return [];
  return file.data.entries.flatMap((raw) => {
    const e = Entry.safeParse(raw);
    return e.success ? [{ costUsd: e.data.cost_usd, atEpochS: e.data.ts_epoch }] : [];
  });
}

/** Reads `costs.json` and `budget.json` from the bash cost directory (`~/.shipwright`). */
export class JsonCostLedger implements CostLedger {
  constructor(private readonly dir: string) {}

  async read() {
    const budgetPath = join(this.dir, "budget.json");
    const [budgetJson, costsJson] = await Promise.all([
      readJson(budgetPath),
      readJson(join(this.dir, "costs.json")),
    ]);
    if (!budgetJson.ok) return budgetJson;
    if (!costsJson.ok) return costsJson;
    const budget = toBudget(budgetJson.value, budgetPath);
    if (!budget.ok) return budget;
    return ok({
      budget: budget.value,
      entries: toEntries(costsJson.value),
      present: budgetJson.value !== null || costsJson.value !== null,
    });
  }
}
