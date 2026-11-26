import { appendFile, mkdir, readFile } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import type { RoutingLog, RoutingRecord } from "../../contexts/intelligence";
import { ISSUE_KINDS, OUTCOME_RESULTS, TIERS } from "../../contexts/intelligence";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

// The fields the router reads back (history joins and stats) are checked exactly; the rest of a
// decision is kept as written. A line we cannot interpret fails the read: a history we cannot trust
// must not silently become "no history" (the same rule as the cost ledger).
const Tier = z.enum(TIERS);
const Decision = z
  .object({
    kind: z.literal("decision"),
    schema: z.literal(1),
    id: z.string().min(1),
    mode: z.enum(["shadow", "apply"]),
    inputs: z
      .object({ features: z.object({ kind: z.enum(ISSUE_KINDS) }).passthrough() })
      .passthrough(),
    difficulty: z.object({ prior: Tier, tier: Tier }).passthrough(),
  })
  .passthrough();
const Outcome = z
  .object({
    kind: z.literal("outcome"),
    schema: z.literal(1),
    decisionId: z.string().min(1),
    result: z.enum(OUTCOME_RESULTS),
    failureClass: z.string().optional(),
    costUsd: z.number().nonnegative().optional(),
    pr: z.number().int().positive().optional(),
  })
  .passthrough();
const Record = z.discriminatedUnion("kind", [Decision, Outcome]);

const failed = (message: string): AdapterError => ({ kind: "failed", message });

function parseLines(path: string, text: string): Result<RoutingRecord[], AdapterError> {
  const out: RoutingRecord[] = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = (lines[i] ?? "").trim();
    if (line.length === 0) continue;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch (e) {
      return err(failed(`${path}:${i + 1}: ${e instanceof Error ? e.message : String(e)}`));
    }
    const parsed = Record.safeParse(value);
    if (!parsed.success) {
      const why = parsed.error.issues.map((x) => `${x.path.join(".") || "(root)"}: ${x.message}`);
      return err(failed(`${path}:${i + 1}: ${why.join("; ")}`));
    }
    out.push(parsed.data as unknown as RoutingRecord);
  }
  return ok(out);
}

/** `~/.shipwright/routing/decisions.jsonl`: one decision or outcome per line, append-only. */
export class JsonlRoutingLog implements RoutingLog {
  constructor(private readonly path: string) {}

  async read(): Promise<Result<readonly RoutingRecord[], AdapterError>> {
    let text: string;
    try {
      text = await readFile(this.path, "utf8");
    } catch (e) {
      if ((e as { code?: string }).code === "ENOENT") return ok([]);
      return err(failed(`${this.path}: ${e instanceof Error ? e.message : String(e)}`));
    }
    return parseLines(this.path, text);
  }

  async append(record: RoutingRecord): Promise<Result<void, AdapterError>> {
    try {
      await mkdir(dirname(this.path), { recursive: true });
      // One write per line; O_APPEND keeps concurrent pipelines' lines whole.
      await appendFile(this.path, `${JSON.stringify(record)}\n`, "utf8");
      return ok(undefined);
    } catch (e) {
      return err(failed(`${this.path}: ${e instanceof Error ? e.message : String(e)}`));
    }
  }
}
