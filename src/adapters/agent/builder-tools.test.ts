import { expect, test } from "bun:test";
import { BUILDER_TOOLS } from "../../contexts/delivery";
import { ENV_AUTHOR_TOOLS } from "../../contexts/platform";
import { AGENT_ALLOWED_TOOLS, AGENT_DENIED_TOOLS, scopeAllowedTools } from "./agent-permissions";

test("tournament builders get a subset of the agent permission policy, never more", () => {
  const allowed = new Set(AGENT_ALLOWED_TOOLS);
  for (const tool of scopeAllowedTools(BUILDER_TOOLS)) expect(allowed.has(tool)).toBe(true);
  for (const tool of BUILDER_TOOLS) expect(AGENT_DENIED_TOOLS).not.toContain(tool);
});

test("the environment recipe author gets a subset of the policy, and cannot install or reach the network", () => {
  const allowed = new Set(AGENT_ALLOWED_TOOLS);
  for (const tool of scopeAllowedTools(ENV_AUTHOR_TOOLS)) expect(allowed.has(tool)).toBe(true);
  for (const tool of ENV_AUTHOR_TOOLS) expect(AGENT_DENIED_TOOLS).not.toContain(tool);
  expect(ENV_AUTHOR_TOOLS.some((t) => /npm|bun|pip|curl|Bash\(\*?\)$/.test(t))).toBe(false);
});
