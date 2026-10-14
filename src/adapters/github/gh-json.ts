import type { ZodType } from "zod";
import type { AdapterError, ProcessResult, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

export function classifyGhError(r: ProcessResult): AdapterError {
  const message = r.stderr.trim() || `gh exited ${r.exitCode}`;
  if (r.timedOut) return { kind: "transient", message };
  // Deliberately no bare "not found" or HTTP 404: "gh: command not found" is a broken environment,
  // and a 404 from a GraphQL call means a missing or invisible repo, not a missing issue.
  if (/could not resolve to an? (issue|pull request)/i.test(message)) {
    return { kind: "not_found", message };
  }
  if (
    /rate limit|HTTP (429|5\d\d)|timed? ?out|connection (reset|refused)|no such host|could not resolve host|dial tcp|EOF/i.test(
      message,
    )
  ) {
    return { kind: "transient", message };
  }
  if (/HTTP 401|HTTP 403|bad credentials|gh auth login|authentication/i.test(message)) {
    return { kind: "auth", message };
  }
  return { kind: "failed", message };
}

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
