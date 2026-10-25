import { readFile } from "node:fs/promises";
import type { AdapterError, FileReader } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

export class NodeFileReader implements FileReader {
  async readText(path: string): Promise<Result<string, AdapterError>> {
    try {
      return ok(await readFile(path, "utf8"));
    } catch (cause) {
      const missing = (cause as { code?: string }).code === "ENOENT";
      return err({ kind: missing ? "not_found" : "failed", message: String(cause) });
    }
  }
}
