import type { AdapterError, FileReader } from "../shared/kernel/ports";
import { err, ok, type Result } from "../shared/kernel/result";

/** In-memory FileReader for command tests. A missing path is `not_found`. */
export class FakeFileReader implements FileReader {
  constructor(private readonly files: Readonly<Record<string, string>>) {}

  async readText(path: string): Promise<Result<string, AdapterError>> {
    const text = this.files[path];
    return text === undefined
      ? err({ kind: "not_found", message: `no fake file ${path}` })
      : ok(text);
  }
}
