import { expect, test } from "bun:test";
import { BUILDER_TOOLS } from "../../contexts/delivery";
import { AGENT_ALLOWED_TOOLS, AGENT_DENIED_TOOLS, scopeAllowedTools } from "./agent-permissions";

test("tournament builders get a subset of the agent permission policy, never more", () => {
  const allowed = new Set(AGENT_ALLOWED_TOOLS);
  for (const tool of scopeAllowedTools(BUILDER_TOOLS)) expect(allowed.has(tool)).toBe(true);
  for (const tool of BUILDER_TOOLS) expect(AGENT_DENIED_TOOLS).not.toContain(tool);
});
