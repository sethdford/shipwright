import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import { MODEL_SCHEMA, type ModelStore, type RepoModel } from "../../contexts/intelligence";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

const symbolSchema = z.object({
  name: z.string(),
  kind: z.string(),
  line: z.number(),
  signature: z.string(),
  exported: z.boolean(),
  container: z.string().optional(),
  doc: z.string().optional(),
});

const fileSchema = z.object({
  path: z.string(),
  hash: z.string(),
  size: z.number(),
  mtimeMs: z.number(),
  test: z.boolean(),
  lang: z.string(),
  lines: z.number(),
  symbols: z.array(symbolSchema),
  imports: z.array(z.string()),
  refs: z.array(z.string()),
});

const modelSchema = z.object({
  schema: z.literal(MODEL_SCHEMA),
  extractor: z.number(),
  root: z.string(),
  builtAt: z.string(),
  head: z.string(),
  files: z.array(fileSchema),
  codeowners: z.string(),
  authors: z.record(
    z.string(),
    z.array(z.object({ name: z.string(), commits: z.number(), last: z.string() })),
  ),
});

/**
 * The model cache as one JSON file per repository root under `<stateDir>/repo-model/`. A missing, unreadable
 * or older-schema file reads as no model (the next refresh rebuilds it); writes go through a rename.
 */
export class JsonModelStore implements ModelStore {
  constructor(private readonly dir: string) {}

  fileFor(root: string): string {
    return join(this.dir, `${createHash("sha256").update(root).digest("hex").slice(0, 16)}.json`);
  }

  async load(root: string): Promise<RepoModel | undefined> {
    try {
      const parsed = modelSchema.safeParse(JSON.parse(await readFile(this.fileFor(root), "utf8")));
      return parsed.success && parsed.data.root === root ? (parsed.data as RepoModel) : undefined;
    } catch {
      return undefined;
    }
  }

  async save(model: RepoModel): Promise<Result<void, AdapterError>> {
    const file = this.fileFor(model.root);
    const tmp = `${file}.${process.pid}.tmp`;
    try {
      await mkdir(this.dir, { recursive: true });
      await writeFile(tmp, JSON.stringify(model));
      await rename(tmp, file);
      return ok(undefined);
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
  }
}
