/**
 * F9 runtime guard: the last check before the SDK starts an agent. The static rules
 * (F9-no-agent-privilege, F9-agent-options-explicit) keep these spellings out of the rest of src/;
 * this file is on their allowlist because it has to name what it refuses.
 */
const GITHUB_TOKENS = [
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "GH_ENTERPRISE_TOKEN",
  "GITHUB_ENTERPRISE_TOKEN",
];

export interface GuardedOptions {
  readonly permissionMode?: string;
  readonly allowDangerouslySkipPermissions?: boolean;
  readonly env?: Readonly<Record<string, string | undefined>>;
}

/** Throws (a bug, not an expected failure) when options would give an agent a bypass or a token. */
export function assertAgentOptions(options: GuardedOptions): void {
  if (options.permissionMode === "bypassPermissions" || options.allowDangerouslySkipPermissions) {
    throw new Error("F9: refusing to start an agent with permission checks bypassed");
  }
  const leaked = GITHUB_TOKENS.filter((key) => options.env?.[key] !== undefined);
  if (leaked.length > 0) {
    throw new Error(
      `F9: refusing to pass ${leaked.join(", ")} to an agent; build env with agentEnv()`,
    );
  }
}
