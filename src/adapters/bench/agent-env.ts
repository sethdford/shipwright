/** Tokens an agent must never see (rule F9): it cannot push, comment or merge from a benchmark run. */
const WITHHELD =
  /^(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|SHIPWRIGHT_GITHUB_TOKEN)$/;

/** The parent environment without GitHub tokens, plus the arm's own variables. */
export function agentEnv(
  parent: Readonly<Record<string, string | undefined>>,
  extra: Readonly<Record<string, string>> = {},
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [name, value] of Object.entries(parent)) {
    if (value !== undefined && !WITHHELD.test(name)) env[name] = value;
  }
  return { ...env, ...extra };
}
