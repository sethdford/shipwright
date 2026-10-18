import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  AGENT_ALLOWED_TOOLS,
  AGENT_DENIED_TOOLS,
  AGENT_PERMISSION_MODE,
  AGENT_SANDBOX,
  AGENT_SETTING_SOURCES,
  AGENT_SETTINGS,
  scopeAllowedTools,
} from "./agent-permissions";

// The JSON policy is the source of truth; the TS mirror must match it exactly (#8614).
const policy = JSON.parse(
  readFileSync(join(import.meta.dir, "../../../config/agent-permissions.json"), "utf8"),
) as {
  disableAllHooks: boolean;
  permissions: {
    defaultMode: "dontAsk";
    blockReadsOutsideWorkingDirectories: boolean;
    allow: string[];
    deny: string[];
  };
  sandbox: { enabled: boolean; failIfUnavailable: boolean; network: { allowedDomains: string[] } };
};

const NETWORK_TOOLS = /^Bash\((curl|wget|gh|ssh|scp|sftp|nc|ncat|telnet)\b/;

describe("agent permission policy", () => {
  test("the TS mirror equals config/agent-permissions.json (permissions, sandbox, hooks)", () => {
    expect([...AGENT_ALLOWED_TOOLS]).toEqual(policy.permissions.allow);
    expect([...AGENT_DENIED_TOOLS]).toEqual(policy.permissions.deny);
    expect(AGENT_PERMISSION_MODE).toBe(policy.permissions.defaultMode);
    expect(AGENT_SANDBOX).toMatchObject(policy.sandbox);
    expect(JSON.parse(JSON.stringify(AGENT_SANDBOX))).toEqual(policy.sandbox);
    expect(AGENT_SETTINGS).toEqual({
      disableAllHooks: policy.disableAllHooks,
      permissions: {
        defaultMode: policy.permissions.defaultMode,
        blockReadsOutsideWorkingDirectories: policy.permissions.blockReadsOutsideWorkingDirectories,
        allow: policy.permissions.allow,
        deny: policy.permissions.deny,
      },
    });
  });

  test("hooks are off and project blockReads is on in the policy (#8614 review)", () => {
    expect(policy.disableAllHooks).toBe(true);
    expect(policy.permissions.blockReadsOutsideWorkingDirectories).toBe(true);
  });

  test("bare Edit and Write are scoped to the working tree, for callers too", () => {
    expect(AGENT_ALLOWED_TOOLS).not.toContain("Edit");
    expect(AGENT_ALLOWED_TOOLS).not.toContain("Write");
    expect(scopeAllowedTools(["Read", "Edit", "Write", "Bash(bun test *)"])).toEqual([
      "Read",
      "Edit(./**)",
      "Write(./**)",
      "Bash(bun test *)",
    ]);
  });

  test("the policy files, the GitHub env files and the .github tree are not editable by an agent", () => {
    for (const entry of [
      "Edit(config/agent-permissions.json)",
      "Write(config/agent-permissions.json)",
      "Edit(scripts/lib/agent-exec.sh)",
      "Edit(scripts/lib/test-gate-env.sh)",
      "Edit(.github/**)",
      "Write(.github/**)",
      "Edit(//home/runner/work/_temp/**)",
      "Edit(~/.ssh/**)",
      "Edit(~/.config/**)",
      "Read(~/.config/**)",
    ]) {
      expect(AGENT_DENIED_TOOLS).toContain(entry);
    }
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
      "Read(~/.config/**)",
      "Read(~/.netrc)",
      "Edit(.claude/settings*.json)",
      "Write(.claude/settings*.json)",
      "Edit(.github/**)",
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

  test("build-loop needs are allowed and installs are not", () => {
    for (const entry of [
      "Bash(bash scripts/*-test.sh *)",
      "Bash(mkdir *)",
      "Bash(chmod +x *)",
      "Bash(git mv *)",
      "Bash(git rm *)",
      "Bash(git restore *)",
      "Bash(shellcheck *)",
      "Bash(jq *)",
    ]) {
      expect(AGENT_ALLOWED_TOOLS).toContain(entry);
    }
    for (const entry of AGENT_ALLOWED_TOOLS) {
      expect(entry).not.toMatch(
        /\b(install|pip|brew|apt|apt-get)\b|(npm|bun|yarn) (i|add|install)\b/,
      );
    }
  });

  test("the runner loads only the user's settings", () => {
    expect([...AGENT_SETTING_SOURCES]).toEqual(["user"]);
  });
});
