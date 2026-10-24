/**
 * F9 runtime guard: the last check before the SDK starts an agent. The static rules
 * (F9-no-agent-privilege, F9-agent-options-explicit, F9-sdk-query-single-importer) keep these
 * spellings out of the rest of src/; this file is on their allowlist because it has to name what it
 * refuses. It is an allowlist, not a denylist: an option the runner does not set is refused, so a
 * new SDK option (one that could carry CLI flags or settings) cannot pass unreviewed (ADR-0008).
 */
import { AGENT_SANDBOX, AGENT_SETTINGS } from "./agent-permissions";

const GITHUB_TOKENS = [
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "GH_ENTERPRISE_TOKEN",
  "GITHUB_ENTERPRISE_TOKEN",
];

/** The SDK options the runner sets. extraArgs, executableArgs, settings and the rest are not here. */
const ALLOWED_OPTION_KEYS = new Set([
  "abortController",
  "allowedTools",
  "cwd",
  "disallowedTools",
  "effort",
  "env",
  "maxBudgetUsd",
  "maxTurns",
  "model",
  "sandbox",
  "settings",
  "outputFormat",
  "permissionMode",
  "persistSession",
  "settingSources",
  "strictMcpConfig",
  "systemPrompt",
  "tools",
]);

/** The only permission mode an agent runs in: dontAsk denies anything not pre-allowed, no prompts. */
const REQUIRED_PERMISSION_MODE = "dontAsk";

/**
 * An object's own data properties, as a plain record. Refuses what a check could read differently
 * from the SDK: a non-plain prototype (an inherited permissionMode), a getter (its value changes on
 * each read), and a symbol key (not on the allowlist). Values are read from the descriptors, never
 * through the object's prototype chain.
 */
function ownDataProperties(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null) throw new Error(`F9: ${what} must be an object`);
  const proto = Object.getPrototypeOf(value);
  if (proto !== Object.prototype && proto !== null) {
    throw new Error(
      `F9: ${what} must be a plain object (found a ${proto?.constructor?.name ?? "custom"} prototype)`,
    );
  }
  const out: Record<string, unknown> = {};
  for (const key of Reflect.ownKeys(value)) {
    const desc = Object.getOwnPropertyDescriptor(value, key);
    if (typeof key !== "string" || desc === undefined || !("value" in desc)) {
      throw new Error(`F9: ${what} has a symbol or accessor key (${String(key)}); pass plain data`);
    }
    out[key] = desc.value;
  }
  return out;
}

/**
 * Throws (a bug, not an expected failure) when options would give an agent a bypass or a token. The
 * runner passes this same frozen object to query(), so what is checked is what the SDK receives.
 */
export function assertAgentOptions(options: object): void {
  const record = ownDataProperties(options, "agent options");
  for (const key of Object.keys(record)) {
    if (!ALLOWED_OPTION_KEYS.has(key)) {
      throw new Error(
        `F9: refusing to start an agent with option "${key}" (not on the allowlist in privilege-guard.ts)`,
      );
    }
  }
  if (record.permissionMode !== REQUIRED_PERMISSION_MODE) {
    throw new Error(
      `F9: refusing to start an agent in permissionMode ${JSON.stringify(record.permissionMode)}; it must be "${REQUIRED_PERMISSION_MODE}"`,
    );
  }
  // settings and sandbox may only be the policy the runner sends (agent-permissions.ts), never another value.
  if (
    record.settings !== undefined &&
    JSON.stringify(record.settings) !== JSON.stringify(AGENT_SETTINGS)
  ) {
    throw new Error("F9: refusing settings other than the agent policy (agent-permissions.ts)");
  }
  if (
    record.sandbox !== undefined &&
    JSON.stringify(record.sandbox) !== JSON.stringify(AGENT_SANDBOX)
  ) {
    throw new Error("F9: refusing a sandbox other than the agent policy (agent-permissions.ts)");
  }
  const env = record.env === undefined ? {} : ownDataProperties(record.env, "agent env");
  // Environment names are case-insensitive on Windows and the SDK's own lookup may not be; compare upper case.
  const leaked = Object.keys(env).filter((key) => GITHUB_TOKENS.includes(key.toUpperCase()));
  if (leaked.length > 0) {
    throw new Error(
      `F9: refusing to pass ${leaked.join(", ")} to an agent; build env with agentEnv()`,
    );
  }
}
