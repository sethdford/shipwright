import { z } from "zod";

/**
 * Run-the-app proof (ADR-0019): the optional `.shipwright/proof.json` of the target repository.
 * Everything here is data. Steps are interpreted by the browser driver, never run as code, so an
 * agent may write this file for its own change without widening what the proof stage can do.
 */
export type Step =
  | { readonly goto: string }
  | { readonly click: string }
  | { readonly fill: { readonly selector: string; readonly value: string } }
  | { readonly press: { readonly key: string; readonly selector?: string } }
  | { readonly waitFor: string }
  | { readonly expectText: string }
  | { readonly screenshot: string };

export interface Flow {
  readonly name: string;
  readonly steps: readonly Step[];
}

export interface CliRun {
  readonly name: string;
  readonly argv: readonly string[];
  readonly expectExit: number;
}

export interface WebConfig {
  readonly start?: readonly string[];
  readonly url?: string;
  readonly port?: number;
  readonly readyPath?: string;
  readonly readyTimeoutSec?: number;
  readonly allowHosts?: readonly string[];
  readonly flows?: readonly Flow[];
}

export interface ProofConfig {
  readonly enabled: boolean;
  readonly web?: WebConfig;
  readonly cli?: { readonly runs: readonly CliRun[] };
}

export const PROOF_LIMITS = { flows: 10, steps: 30, runs: 10, text: 300, screenshots: 20 };

const text = z.string().min(1).max(PROOF_LIMITS.text);
const path = text.regex(/^\//, "must start with /");
const name = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,59}$/, "letters, digits, . _ - only");
const host = z.string().regex(/^(\*\.)?[A-Za-z0-9.-]{1,253}$/, "a host name");
const argv = z.array(text).min(1).max(30);

const step = z.union([
  z.strictObject({ goto: path }),
  z.strictObject({ click: text }),
  z.strictObject({ fill: z.strictObject({ selector: text, value: z.string().max(300) }) }),
  z.strictObject({ press: z.strictObject({ key: text, selector: text.optional() }) }),
  z.strictObject({ waitFor: text }),
  z.strictObject({ expectText: text }),
  z.strictObject({ screenshot: name }),
]);

const flow = z.strictObject({ name, steps: z.array(step).min(1).max(PROOF_LIMITS.steps) });

const web = z.strictObject({
  start: argv.optional(),
  url: z
    .string()
    .regex(/^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?\/?$/, "a local http URL")
    .optional(),
  port: z.number().int().min(1024).max(65535).optional(),
  readyPath: path.optional(),
  readyTimeoutSec: z.number().int().min(5).max(600).optional(),
  allowHosts: z.array(host).max(20).optional(),
  flows: z.array(flow).max(PROOF_LIMITS.flows).optional(),
});

const cliRun = z.strictObject({
  name,
  argv,
  expectExit: z.number().int().min(0).max(255).default(0),
});

const schema = z.strictObject({
  enabled: z.boolean().default(true),
  web: web.optional(),
  cli: z.strictObject({ runs: z.array(cliRun).max(PROOF_LIMITS.runs) }).optional(),
});

export const NO_CONFIG: ProofConfig = { enabled: true };

export type ConfigResult =
  | { readonly ok: true; readonly config: ProofConfig }
  | { readonly ok: false; readonly problems: readonly string[] };

/** Parses `.shipwright/proof.json`. `null` (no file) is the empty config: detect everything. */
export function parseProofConfig(json: string | null): ConfigResult {
  if (json === null) return { ok: true, config: NO_CONFIG };
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return { ok: false, problems: [".shipwright/proof.json is not valid JSON"] };
  }
  const parsed = schema.safeParse(value);
  if (parsed.success) return { ok: true, config: parsed.data };
  const problems = parsed.error.issues.map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`);
  return { ok: false, problems };
}
