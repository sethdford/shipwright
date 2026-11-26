import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import { FEATURES, type StoredVerifier, type VerifierStore } from "../../contexts/quality";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const nullableNumber = z.number().nullable();
const Stored = z.object({
  model: z.object({
    version: z.literal(1),
    bias: z.number(),
    weights: z.object(Object.fromEntries(FEATURES.map((f) => [f, z.number()]))),
    source: z.enum(["prior", "trained"]),
    examples: z.number().int().min(0),
    trainedAtMs: nullableNumber,
  }),
  evidence: z.object({
    examples: z.number().int().min(0),
    merged: z.number().int().min(0),
    unmerged: z.number().int().min(0),
    looAuc: nullableNumber,
    looBrier: nullableNumber,
    baseBrier: nullableNumber,
  }),
});

const failed = (e: unknown): AdapterError => ({
  kind: "failed",
  message: e instanceof Error ? e.message : String(e),
});

/** The trained verifier as one JSON file (written atomically: temp file, then rename). */
export class JsonVerifierStore implements VerifierStore {
  constructor(private readonly path: string) {}

  async load(): Promise<Result<StoredVerifier | null, AdapterError>> {
    let text: string;
    try {
      text = await readFile(this.path, "utf8");
    } catch (e) {
      return (e as { code?: string }).code === "ENOENT" ? ok(null) : err(failed(e));
    }
    try {
      const parsed = Stored.safeParse(JSON.parse(text));
      if (!parsed.success)
        return err({ kind: "failed", message: `${this.path} is not a verifier model` });
      return ok(parsed.data as StoredVerifier);
    } catch (e) {
      return err(failed(e));
    }
  }

  async save(v: StoredVerifier): Promise<Result<void, AdapterError>> {
    const tmp = `${this.path}.${process.pid}.tmp`;
    try {
      await mkdir(dirname(this.path), { recursive: true });
      await writeFile(tmp, `${JSON.stringify(v, null, 2)}\n`);
      await rename(tmp, this.path);
      return ok(undefined);
    } catch (e) {
      return err(failed(e));
    }
  }
}
