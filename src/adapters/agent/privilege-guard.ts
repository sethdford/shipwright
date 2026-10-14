/**
 * F9 runtime guard: the last check before the SDK starts an agent. The static rules
 * (F9-no-agent-privilege, F9-agent-options-explicit, F9-sdk-query-single-importer) keep these
 * spellings out of the rest of src/; this file is on their allowlist because it has to name what it
 * refuses. It is an allowlist, not a denylist: an option the runner does not set is refused, so a
 * new SDK option (one that could carry CLI flags or settings) cannot pass unreviewed (ADR-0008).
 */
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
  "effort",
  "env",
  "maxBudgetUsd",
  "maxTurns",
  "model",
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

/** Throws (a bug, not an expected failure) when options would give an agent a bypass or a token. */
export function assertAgentOptions(options: object): void {
  const record = options as Record<string, unknown>;
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
  const env = (record.env ?? {}) as Record<string, string | undefined>;
  const leaked = GITHUB_TOKENS.filter((key) => env[key] !== undefined);
  if (leaked.length > 0) {
    throw new Error(
      `F9: refusing to pass ${leaked.join(", ")} to an agent; build env with agentEnv()`,
    );
  }
}
