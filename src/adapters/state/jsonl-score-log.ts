import { appendFile, mkdir, readFile } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import type { ScoreLog, ScoreRecord } from "../../contexts/quality";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const unit = z.number().min(0).max(1).nullable();
const Record = z.object({
  atMs: z.number(),
  branch: z.string().min(1),
  headSha: z.string(),
  probability: z.number().min(0).max(1),
  signals: z.object({
    ownTestsPass: z.boolean().nullable(),
    crossPassRate: unit,
    rubricScore: unit,
    criticProbability: unit,
  }),
});

const failed = (message: string): AdapterError => ({ kind: "failed", message });

// A line we cannot interpret fails the read (the routing log's rule): training then goes on
// without run signals and says so, instead of silently learning from part of the log.
function parseLines(path: string, text: string): Result<ScoreRecord[], AdapterError> {
  const out: ScoreRecord[] = [];
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
    if (!parsed.success) return err(failed(`${path}:${i + 1}: not a score record`));
    out.push(parsed.data);
  }
  return ok(out);
}

/** `$SHIPWRIGHT_STATE_DIR/verifier/scores.jsonl`: one `verify score` per line, append-only. */
export class JsonlScoreLog implements ScoreLog {
  constructor(private readonly path: string) {}

  async all(): Promise<Result<readonly ScoreRecord[], AdapterError>> {
    let text: string;
    try {
      text = await readFile(this.path, "utf8");
    } catch (e) {
      if ((e as { code?: string }).code === "ENOENT") return ok([]);
      return err(failed(`${this.path}: ${e instanceof Error ? e.message : String(e)}`));
    }
    return parseLines(this.path, text);
  }

  async append(record: ScoreRecord): Promise<Result<void, AdapterError>> {
    try {
      await mkdir(dirname(this.path), { recursive: true });
      await appendFile(this.path, `${JSON.stringify(record)}\n`, "utf8");
      return ok(undefined);
    } catch (e) {
      return err(failed(`${this.path}: ${e instanceof Error ? e.message : String(e)}`));
    }
  }
}
