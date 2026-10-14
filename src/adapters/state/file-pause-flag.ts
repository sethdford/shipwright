import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import type { LocalPause, PauseFlag } from "../../contexts/orchestration";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

// The bash daemon writes {reason, timestamp[, resume_after]} or {paused, reason}; any file pauses.
const FlagFile = z.object({
  reason: z.string().optional(),
  timestamp: z.string().optional(),
  resume_after: z.string().optional(),
});

/** Like the daemon, treats any existing flag file as a pause, even an unreadable one. */
export function parsePauseFlag(text: string): LocalPause {
  let json: unknown = {};
  try {
    json = JSON.parse(text);
  } catch {
    // Unparseable content still pauses (fail closed).
  }
  const parsed = FlagFile.safeParse(json);
  const data = parsed.success ? parsed.data : {};
  const resumeAfter = data.resume_after ? Date.parse(data.resume_after) : Number.NaN;
  return {
    reason: data.reason ?? "pause flag present",
    since: data.timestamp ?? "",
    resumeAfter: Number.isNaN(resumeAfter) ? null : resumeAfter,
  };
}

const failed = (e: unknown): AdapterError => ({
  kind: "failed",
  message: e instanceof Error ? e.message : String(e),
});

export class FilePauseFlag implements PauseFlag {
  constructor(private readonly path: string) {}

  async read(): Promise<Result<LocalPause | null, AdapterError>> {
    try {
      return ok(parsePauseFlag(await readFile(this.path, "utf8")));
    } catch (e) {
      return (e as { code?: string }).code === "ENOENT" ? ok(null) : err(failed(e));
    }
  }

  async write(reason: string, at: string): Promise<Result<void, AdapterError>> {
    const json = JSON.stringify({ reason, timestamp: at, source: "shipwright pause" });
    try {
      await mkdir(dirname(this.path), { recursive: true });
      await writeFile(`${this.path}.tmp`, `${json}\n`);
      await rename(`${this.path}.tmp`, this.path);
      return ok(undefined);
    } catch (e) {
      return err(failed(e));
    }
  }

  async clear(): Promise<Result<void, AdapterError>> {
    try {
      await rm(this.path, { force: true });
      return ok(undefined);
    } catch (e) {
      return err(failed(e));
    }
  }
}
