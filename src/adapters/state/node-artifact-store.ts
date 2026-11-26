import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { ArtifactStore } from "../../contexts/planning";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

/** Pipeline artifacts on disk. Writes go to a temp file first, then rename, so readers never see half a file. */
export class NodeArtifactStore implements ArtifactStore {
  async read(path: string): Promise<Result<string, AdapterError>> {
    try {
      return ok(await readFile(path, "utf8"));
    } catch (cause) {
      const missing = (cause as { code?: string }).code === "ENOENT";
      return err({ kind: missing ? "not_found" : "failed", message: String(cause) });
    }
  }

  async write(path: string, text: string): Promise<Result<void, AdapterError>> {
    const tmp = `${path}.tmp.${process.pid}`;
    try {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(tmp, text);
      await rename(tmp, path);
      return ok(undefined);
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
  }
}
