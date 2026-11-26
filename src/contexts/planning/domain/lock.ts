import { z } from "zod";
import type { Criterion } from "./manifest";
import type { RunTemplate, TemplateSource } from "./run-command";
import { testPathProblem } from "./test-path";

/**
 * The record that freezes the acceptance tests once they are proven red: the commit that holds
 * them and each file's blob id there. Git objects cannot change, so whatever happens to the
 * working tree later, the original tests can be restored and compared from this record alone.
 */
export interface AcceptanceLock {
  readonly version: 1;
  readonly commit: string;
  readonly criteria: readonly Criterion[];
  readonly tests: readonly {
    readonly path: string;
    readonly blob: string;
    readonly criteria: readonly string[];
  }[];
  readonly template: RunTemplate;
  readonly templateSource: TemplateSource;
}

const sha = z.string().regex(/^[0-9a-f]{40}([0-9a-f]{24})?$/);
const schema = z.strictObject({
  version: z.literal(1),
  commit: sha,
  criteria: z.array(z.strictObject({ id: z.string(), text: z.string() })).min(1),
  tests: z
    .array(
      z.strictObject({
        path: z.string().refine((p) => testPathProblem(p) === null, "not a test path"),
        blob: sha,
        criteria: z.array(z.string()).min(1),
      }),
    )
    .min(1),
  template: z.array(z.string()).min(1),
  templateSource: z.enum(["configured", "derived", "proposed"]),
});

/** Parses a lock file; anything malformed is an error (the gate fails closed). */
export function parseLock(
  json: string,
): { ok: true; lock: AcceptanceLock } | { ok: false; problem: string } {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return { ok: false, problem: "lock file is not valid JSON" };
  }
  const parsed = schema.safeParse(value);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return {
      ok: false,
      problem: `lock file: ${issue?.path.join(".") ?? ""} ${issue?.message ?? "invalid"}`,
    };
  }
  return { ok: true, lock: parsed.data };
}
