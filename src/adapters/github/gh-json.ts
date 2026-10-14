import type { ZodType } from "zod";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-issue-tracker";

/** Runs a read-only `gh … --json` call (argv only) and validates its output with `schema`. */
export async function runGhJson<T>(
  runner: ProcessRunner,
  argv: readonly string[],
  schema: ZodType<T>,
): Promise<Result<T, AdapterError>> {
  const r = await runOrFail(runner, { argv, timeoutMs: 30_000 });
  if (r.exitCode !== 0 || r.timedOut) return err(classifyGhError(r));
  let json: unknown;
  try {
    json = JSON.parse(r.stdout);
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    return err({ kind: "failed", message: `unexpected gh output: ${why}` });
  }
  const parsed = schema.safeParse(json);
  if (!parsed.success) {
    return err({ kind: "failed", message: `unexpected gh output: ${parsed.error.message}` });
  }
  return ok(parsed.data);
}
