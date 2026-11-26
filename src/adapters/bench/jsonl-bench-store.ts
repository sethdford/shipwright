import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { type BenchRow, type BenchStore, parseRow } from "../../contexts/quality";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const SAFE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function failed(e: unknown): AdapterError {
  return { kind: "failed", message: e instanceof Error ? e.message : String(e) };
}

/**
 * A results directory: `results.jsonl` (append-only, one row per line), `patches/<arm>/<task>.t<n>.diff`
 * and rendered reports. A line that does not parse fails the read: a log we cannot trust is not "empty".
 */
export class JsonlBenchStore implements BenchStore {
  constructor(private readonly dir: string) {}

  private get log() {
    return join(this.dir, "results.jsonl");
  }

  private patchPath(armId: string, taskId: string, trial: number): string | null {
    if (!SAFE.test(armId) || !SAFE.test(taskId)) return null;
    return join(this.dir, "patches", armId, `${taskId}.t${trial}.diff`);
  }

  async rows(): Promise<Result<readonly BenchRow[], AdapterError>> {
    let text: string;
    try {
      text = await readFile(this.log, "utf8");
    } catch (e) {
      if ((e as { code?: string }).code === "ENOENT") return ok([]);
      return err(failed(e));
    }
    const rows: BenchRow[] = [];
    for (const [i, line] of text.split("\n").entries()) {
      if (line.trim() === "") continue;
      let value: unknown;
      try {
        value = JSON.parse(line);
      } catch {
        return err({ kind: "failed", message: `${this.log}:${i + 1} is not JSON` });
      }
      const row = parseRow(value);
      if (!row.ok) return err({ kind: "failed", message: `${this.log}:${i + 1}: ${row.reason}` });
      rows.push(row.value);
    }
    return ok(rows);
  }

  async append(row: BenchRow) {
    return this.attempt(async () => {
      await mkdir(this.dir, { recursive: true });
      await appendFile(this.log, `${JSON.stringify(row)}\n`, "utf8");
    });
  }

  async savePatch(armId: string, taskId: string, trial: number, patch: string) {
    const path = this.patchPath(armId, taskId, trial);
    if (path === null) return err({ kind: "failed", message: "unsafe arm or task id" } as const);
    return this.attempt(async () => {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, patch, "utf8");
    });
  }

  async readPatch(armId: string, taskId: string, trial: number) {
    const path = this.patchPath(armId, taskId, trial);
    if (path === null) return err({ kind: "failed", message: "unsafe arm or task id" } as const);
    try {
      return ok(await readFile(path, "utf8"));
    } catch (e) {
      if ((e as { code?: string }).code === "ENOENT") return ok(null);
      return err(failed(e));
    }
  }

  async write(name: string, text: string): Promise<Result<string, AdapterError>> {
    if (!SAFE.test(name)) return err({ kind: "failed", message: `unsafe file name: ${name}` });
    const path = join(this.dir, name);
    const r = await this.attempt(async () => {
      await mkdir(this.dir, { recursive: true });
      await writeFile(path, text, "utf8");
    });
    return r.ok ? ok(path) : r;
  }

  private async attempt(fn: () => Promise<void>): Promise<Result<void, AdapterError>> {
    try {
      await fn();
      return ok(undefined);
    } catch (e) {
      return err(failed(e));
    }
  }
}
