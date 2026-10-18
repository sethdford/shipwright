import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  AGENT_ALLOWED_TOOLS,
  AGENT_DENIED_TOOLS,
  AGENT_PERMISSION_MODE,
  AGENT_SETTING_SOURCES,
} from "./agent-permissions";

// The JSON policy is the source of truth; the TS mirror must match it exactly (#8614).
const policy = JSON.parse(
  readFileSync(join(import.meta.dir, "../../../config/agent-permissions.json"), "utf8"),
) as {
  permissions: { defaultMode: string; allow: string[]; deny: string[] };
  sandbox: { enabled: boolean; failIfUnavailable: boolean; network: { allowedDomains: string[] } };
};

const NETWORK_TOOLS = /^Bash\((curl|wget|gh|ssh|scp|sftp|nc|ncat|telnet)\b/;

describe("agent permission policy", () => {
  test("the TS mirror equals config/agent-permissions.json", () => {
    expect([...AGENT_ALLOWED_TOOLS]).toEqual(policy.permissions.allow);
    expect([...AGENT_DENIED_TOOLS]).toEqual(policy.permissions.deny);
    expect(AGENT_PERMISSION_MODE).toBe(policy.permissions.defaultMode);
  });

  test("the policy runs agents in dontAsk, with the sandbox on and no network", () => {
    expect(policy.permissions.defaultMode).toBe("dontAsk");
    expect(policy.sandbox.enabled).toBe(true);
    expect(policy.sandbox.failIfUnavailable).toBe(true);
    expect(policy.sandbox.network.allowedDomains).toEqual([]);
  });

  test("the deny list holds the network, remote-git, privilege and config-write entries", () => {
    for (const entry of [
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(gh *)",
      "Bash(ssh *)",
      "Bash(nc *)",
      "Bash(sudo *)",
      "Bash(git push *)",
      "Bash(git fetch *)",
      "Bash(git remote *)",
      "Bash(git config *)",
      "Bash(rm -rf /*)",
      "Read(~/.ssh/**)",
      "Read(~/.config/gh/**)",
      "Read(~/.netrc)",
      "Edit(.claude/settings*.json)",
      "Write(.claude/settings*.json)",
      "Edit(.github/workflows/**)",
      "Edit(tools/arch/**)",
    ]) {
      expect(AGENT_DENIED_TOOLS).toContain(entry);
    }
  });

  test("the allow list has no network tool and no bare Bash", () => {
    for (const entry of AGENT_ALLOWED_TOOLS) {
      expect(entry).not.toMatch(NETWORK_TOOLS);
      expect(entry).not.toMatch(/^Bash$|^Bash\(\*\)$/);
    }
  });

  test("the runner loads only the user's settings", () => {
    expect([...AGENT_SETTING_SOURCES]).toEqual(["user"]);
  });
});
